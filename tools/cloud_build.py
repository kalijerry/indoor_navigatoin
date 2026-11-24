#!/usr/bin/env python3
"""云端融合建图（GitHub Actions 里跑）。

1. 从后台拉所有采集会话（zip），按会话里记的地图编号（meta.json 的 map_id）分组；purpose=test 的当测试会话；
2. 每张地图：拉地图 JSON（/api/maps/<id>，App 连上后台时会自动上传当前地图），读云端已有地图包里的名字、类型、地图朝向；
   实时定位记录（meta.live = true，App 定位时自动传）按同样的 map_id 归到地图，用 --live 传给 hpass-build：
   可信的路段低权重并进磁场图（地图自愈）；
   房间的视觉特征地图：会话目录里带 worldmap.arexperience + worldmap.json（App 在认出房间的会话结束时存，
   见 WorldMapKeeper）。挑同一张地图里最新的、坐标系和地图 JSON 一致的（两边都有 frameId 时比 frameId，
   否则比 arAlign 等价；规则同 WorldMapSidecar，见 cloud_build_lib.py），
   用 --worldmap 打进包；没有就沿用云端旧包里的（同样要 arAlign 等价）。≤15 MB，>8 MB 报告里警告；
3. 看板「路线」页手动改过的段（/api/config/segments/<地图>）用 --edits 传给 hpass-build；每次都导出路线分段和着色
   （--segments-out），传到 /api/segments/<地图> 给看板画；
4. 会话（含实时记录）、手动分段修改都和上次融合时一样、看板也已经有分段数据就跳过；否则跑 hpass-build（多会话偏移联合求解 + 蓝牙 + 覆盖率 + 测试会话精度），
   上传地图包（版本 = 现在，盖过手机上生成的）和报告（/api/reports/build_<地图>_<时间>.json）。

环境变量：HPASS_URL（后台地址）、HPASS_TOKEN（口令）、HPASS_BUILD（hpass-build 可执行文件路径）、
MAP_ID（可选，只处理这一张）、EXCLUDE（可选，不用的会话名，逗号分隔；后台 /api/config/exclude 的名单也会合并进来）、FORCE=1（会话没变也重建）、LIVE_MAX（每张地图最多用最近多少个实时记录，默认 40）、DRY_RUN=1（只算、不上传）。会话数据只放在临时目录，不进仓库、不进 artifact。
"""
import io, json, math, os, struct, subprocess, sys, tempfile, time, urllib.parse, urllib.request, zipfile, zlib

URL = os.environ["HPASS_URL"].rstrip("/")
if not URL.startswith("http"):
    URL = "https://" + URL
TOKEN = os.environ["HPASS_TOKEN"]
BUILD = os.environ.get("HPASS_BUILD", "hpass-build")
ONLY = os.environ.get("MAP_ID", "").strip()
EXCLUDE = {x.strip() for x in os.environ.get("EXCLUDE", "").split(",") if x.strip()}   # 不用的会话（名字，逗号分隔）
FORCE = os.environ.get("FORCE") == "1"
LIVE_MAX = int(os.environ.get("LIVE_MAX") or 40)
DRY = os.environ.get("DRY_RUN") == "1"          # 只算不上传


def req(path, method="GET", data=None, headers=None):
    h = {"Authorization": "Bearer " + TOKEN, "User-Agent": "hpass-cloud-build/1.0"}   # 默认的 Python UA 会被 Cloudflare 拦（403）
    h.update(headers or {})
    r = urllib.request.Request(URL + path, data=data, method=method, headers=h)
    with urllib.request.urlopen(r, timeout=300) as resp:
        return resp.read()


def get_json(path):
    return json.loads(req(path))


def package_sections(map_id):
    """云端已有地图包的各段（说明、地图 JSON、磁场、蓝牙、视觉特征地图…）；没有返回 None"""
    try:
        raw = req("/api/packages/" + urllib.parse.quote(map_id))
    except urllib.error.HTTPError:
        return None
    d = zlib.decompress(raw, -15)                  # NSData .zlib = 不带头的 deflate
    assert d[:4] == b"HPMP"
    out, o = [], 6
    while o + 4 <= len(d):
        n = struct.unpack_from("<I", d, o)[0]
        out.append(d[o + 4:o + 4 + n])
        o += 4 + n
    return out


def package_meta(map_id, secs=None):
    """云端已有地图包的说明（名字、类型、地图朝向）；没有返回 None"""
    secs = secs if secs is not None else package_sections(map_id)
    return json.loads(secs[0]) if secs else None


# ---- 房间的视觉特征地图（ARWorldMap）：纯函数在 cloud_build_lib.py（不读环境变量，单元测试直接 import）----
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cloud_build_lib import (survey_summary, format_survey_summary, WM_FILE, WM_META, WM_WARN, WM_MAX, map_align, map_frame_id,  # noqa: E402
                             align_equivalent, worldmap_compatible, pick_worldmap,
                             map_geometry_version, build_unchanged, quality_rejected, edits_hash)


def main():
    work = tempfile.mkdtemp(prefix="hpass-")
    # 后台存的排除名单（/api/config/exclude，比如带磁吸配件采的那几次），和 EXCLUDE 合并
    try:
        saved = get_json("/api/config/exclude")
        if saved:
            EXCLUDE.update(x for x in saved if isinstance(x, str))
            print(f"后台排除名单 {len(saved)} 个会话")
    except (urllib.error.HTTPError, ValueError):
        pass
    sessions = get_json("/api/sessions")
    print(f"后台有 {len(sessions)} 个会话")
    groups = {}                                     # map_id -> {"build": [...], "test": [...], "live": [...]}
    wm_dirs = {}                                    # map_id -> 带视觉特征地图的会话目录（建图 / 测试 / 实时都算）
    for o in sessions:
        name = o["key"].split("/", 1)[1]
        z = zipfile.ZipFile(io.BytesIO(req("/api/sessions/" + urllib.parse.quote(name))))
        z.extractall(work)
        metas = [n for n in z.namelist() if n.endswith("meta.json") and n.count("/") == 1]
        for m in metas:
            d = os.path.join(work, os.path.dirname(m))
            meta = json.load(open(os.path.join(work, m)))
            if meta.get("map_id") and os.path.exists(os.path.join(d, WM_FILE)):
                wm_dirs.setdefault(meta["map_id"], []).append(d)
            is_live = bool(meta.get("live")) and not meta.get("survey")
            if is_live:
                # 实时定位记录：要有定位轨迹和 ARKit 位姿才能用
                if not all(os.path.exists(os.path.join(d, f)) for f in ("track.csv", "arkit_pose.csv", "imu.csv")):
                    continue
            elif not meta.get("survey") or not os.path.exists(os.path.join(d, "anchors.csv")):
                continue
            why = quality_rejected(d)
            if why:
                print(f"  跳过 {os.path.basename(d)}：采集质量不合格（{why}）")
                continue
            mid = meta.get("map_id") or ""
            if not mid:
                print(f"  跳过 {os.path.basename(d)}：旧版本会话，没记地图编号")
                continue
            if os.path.basename(d) in EXCLUDE:
                print(f"  跳过 {os.path.basename(d)}：手动排除")
                continue
            if not is_live:
                ss = survey_summary(d)
                if ss:
                    print(format_survey_summary(os.path.basename(d), ss))
            g = groups.setdefault(mid, {"build": [], "test": [], "live": []})
            g["live" if is_live else ("test" if meta.get("purpose") == "test" else "build")].append(d)
    reports = get_json("/api/reports")
    # 标签位置表（App「场地数据 → 蓝牙」导入时会传到后台）：当蓝牙底图
    tag_path = None
    try:
        tags_csv = req("/api/esl/locations.csv")
        tag_path = os.path.join(work, "esl_locations.csv")
        open(tag_path, "wb").write(tags_csv)
        print(f"标签位置表 {len(tags_csv) // 1024} KB")
    except urllib.error.HTTPError:
        print("后台没有标签位置表，蓝牙只用采集学到的")
    for mid, g in sorted(groups.items()):
        if ONLY and mid != ONLY:
            continue
        # 实时记录只留最近 LIVE_MAX 个（目录名带时间）
        g["live"] = sorted(g["live"], key=os.path.basename)[-LIVE_MAX:]
        print(f"\n== 地图 {mid}：建图 {len(g['build'])} 个、测试 {len(g['test'])} 个、实时定位 {len(g['live'])} 个")
        if not g["build"]:
            continue
        names = sorted(os.path.basename(d) for d in g["build"] + g["test"])
        live_names = sorted(os.path.basename(d) for d in g["live"])
        try:
            map_json = req("/api/maps/" + urllib.parse.quote(mid))
        except urllib.error.HTTPError:
            print("  后台没有这张地图的 JSON（用这张地图的手机连一次后台就会上传），跳过")
            continue
        align = map_align(map_json)
        frame_id = map_frame_id(map_json)
        picked = pick_worldmap(wm_dirs.get(mid, []), mid, align, frame_id)
        wm_session = picked[1]["session"] if picked else None
        geometry_version = map_geometry_version(map_json)
        # 看板「路线」页手动改过的段
        try:
            seg_edits = get_json("/api/config/segments/" + urllib.parse.quote(mid)).get("edits") or []
        except (urllib.error.HTTPError, ValueError, AttributeError):
            seg_edits = []
        ehash = edits_hash(seg_edits)
        if seg_edits:
            print(f"  看板手动分段修改 {len(seg_edits)} 条")
        try:
            req("/api/segments/" + urllib.parse.quote(mid), "GET")
            have_segments = True
        except urllib.error.HTTPError:
            have_segments = False
        # 上次融合的输入：会话、实时记录、特征地图会话、地图几何版本（手机接着扫 / 重扫后只有它变）都没变才跳过
        last = [r for r in reports if r["key"].startswith(f"reports/build_{mid}_")]
        if last and not FORCE:
            prev = get_json("/api/" + last[0]["key"])
            if build_unchanged(prev, names, live_names, wm_session, geometry_version) and prev.get("segmentEditsHash") == ehash and have_segments:
                print("  会话、地图几何、手动分段修改都没变，跳过")
                continue
            if prev.get("segmentEditsHash") != ehash:
                print("  看板改过路线分段，重建")
            elif not have_segments:
                print("  看板还没有路线分段数据，重建一次")
            if prev.get("mapGeometryVersion") != geometry_version:
                print(f"  地图几何版本 {prev.get('mapGeometryVersion')} → {geometry_version}（手机接着扫 / 重扫过），重建")
        map_path = os.path.join(work, f"map_{mid}.json")
        open(map_path, "wb").write(map_json)
        secs = package_sections(mid)
        pm = package_meta(mid, secs) or {}
        wm_path = None
        wm_info = None
        if picked:
            wm_path, wm_info = picked
            print(f"  视觉特征地图：{wm_info['session']}（{wm_info['bytes'] / 1048576:.1f} MB，{wm_info['source']}）")
        elif align is not None and secs and len(secs) > 4 and secs[4]:
            # 会话里没有：沿用云端旧包里的（它的地图 JSON 里 arAlign 要和现在一致）
            if worldmap_compatible(map_align(secs[1]), map_frame_id(secs[1]), align, frame_id) and len(secs[4]) <= WM_MAX:
                wm_path = os.path.join(work, f"worldmap_{mid}.arexperience")
                open(wm_path, "wb").write(secs[4])
                wm_info = {"session": None, "bytes": len(secs[4]), "source": "旧包"}
                print(f"  视觉特征地图：沿用云端旧包的（{len(secs[4]) / 1048576:.1f} MB）")
        # 名字：云端已有包的名字 → 地图里的楼层名 → 地图编号
        if not pm.get("name") or pm.get("name") == mid:
            try:
                root = json.loads(map_json)
                root = root.get("data", root) if isinstance(root, dict) else root
                if isinstance(root, dict) and root.get("floorName"):
                    pm["name"] = root["floorName"]
            except ValueError:
                pass
        # 类型看地图本身：有地面多边形、没有通道 = 房间
        try:
            root = json.loads(map_json)
            root = root.get("data", root) if isinstance(root, dict) else root
            els = root.get("mapElementList", []) if isinstance(root, dict) else []
            is_room = bool(root.get("floorPolygons")) and not any(e.get("shapeType") == "MapCross" for e in els)
            pm["kind"] = "room" if is_room else "store"
        except (ValueError, AttributeError):
            pm["kind"] = pm.get("kind") or "store"
        out = os.path.join(work, f"{mid}.hpmp")
        rep = os.path.join(work, f"{mid}.json")
        seg_out = os.path.join(work, f"{mid}.segments.json")
        cmd = [BUILD, "--map", map_path, "--sessions", ",".join(g["build"]), "--id", mid,
               "--name", pm.get("name") or mid, "--kind", pm.get("kind") or "store", "--out", out, "--report", rep,
               "--segments-out", seg_out]
        if seg_edits:
            ep = os.path.join(work, f"{mid}.edits.json")
            json.dump({"version": 1, "mapId": mid, "edits": seg_edits}, open(ep, "w"))
            cmd += ["--edits", ep]
        if g["test"]:
            cmd += ["--test", ",".join(g["test"])]
        if g["live"]:
            cmd += ["--live", ",".join(g["live"])]
        if tag_path:
            cmd += ["--tag-locations", tag_path]
        if wm_path:
            cmd += ["--worldmap", wm_path]
        if pm.get("mapUpBearingDeg") is not None:
            cmd += ["--bearing", str(pm["mapUpBearingDeg"])]
        rc = subprocess.run(cmd).returncode
        # 路线分段（全部没过质量筛选时也有，用户才能在看板上看哪段不对）
        if os.path.exists(seg_out) and not DRY:
            try:
                req("/api/segments/" + urllib.parse.quote(mid), "PUT", open(seg_out, "rb").read(), {"Content-Type": "application/json"})
                print("  已上传路线分段")
            except urllib.error.HTTPError as e:
                print(f"  路线分段上传失败（{e.code}），后台可能还没部署新版本")
        if rc == 3:
            print("  没有合格的会话（质量筛选全部没过），保留云端现有版本")
            continue
        if rc != 0:
            raise SystemExit(f"hpass-build 出错（{rc}）")
        report = json.load(open(rep))
        report["testSessions"] = sorted(os.path.basename(d) for d in g["test"])
        report["liveSessions"] = live_names
        report["worldMapSession"] = wm_session
        report["worldMap"] = wm_info
        report["mapGeometryVersion"] = geometry_version
        report["segmentEditsHash"] = ehash
        pkg = open(out, "rb").read()
        if DRY:
            print(f"  试运行：地图包 {len(pkg) // 1024} KB，不上传")
            continue
        hdr = {"Content-Type": "application/octet-stream", "X-Map-Name": urllib.parse.quote(report["name"]),
               "X-Map-Kind": pm.get("kind") or "store", "X-Map-Version": str(report["version"]),
               "X-Field-Cells": str(report["fieldCells"]), "X-Ble-Tags": str(report["bleTags"]),
               "X-Map-Origin": "cloud", "X-Map-Sessions": str(len(report.get("sessions", [])))}
        print(req("/api/packages/" + urllib.parse.quote(mid), "PUT", pkg, hdr).decode())
        stamp = time.strftime("%Y%m%d_%H%M%S", time.gmtime())
        req(f"/api/reports/build_{mid}_{stamp}.json", "PUT", json.dumps(report, ensure_ascii=False).encode(),
            {"Content-Type": "application/json"})
        print(f"  已上传地图包（{len(pkg) // 1024} KB）和报告")


if __name__ == "__main__":
    main()

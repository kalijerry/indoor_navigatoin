#!/usr/bin/env python3
"""云端融合建图（GitHub Actions 里跑）。

1. 从后台拉所有采集会话（zip），按会话里记的地图编号（meta.json 的 map_id）分组；purpose=test 的当测试会话；
2. 每张地图：拉地图 JSON（/api/maps/<id>，App 连上后台时会自动上传当前地图），读云端已有地图包里的名字、类型、地图朝向；
   实时定位记录（meta.live = true，App 定位时自动传）按同样的 map_id 归到地图，用 --live 传给 hpass-build：
   可信的路段低权重并进磁场图（地图自愈）；
   房间的视觉特征地图：会话目录里带 worldmap.arexperience + worldmap.json（App 在认出房间的会话结束时存，
   见 WorldMapKeeper）。挑同一张地图里最新的、坐标系和地图 JSON 里 arAlign 等价的（规则同 WorldMapSidecar），
   用 --worldmap 打进包；没有就沿用云端旧包里的（同样要 arAlign 等价）。≤15 MB，>8 MB 报告里警告；
3. 会话（含实时记录）和上次融合时一样就跳过；否则跑 hpass-build（多会话偏移联合求解 + 蓝牙 + 覆盖率 + 测试会话精度），
   上传地图包（版本 = 现在，盖过手机上生成的）和报告（/api/reports/build_<地图>_<时间>.json）。

环境变量：HPASS_URL（后台地址）、HPASS_TOKEN（口令）、HPASS_BUILD（hpass-build 可执行文件路径）、
MAP_ID（可选，只处理这一张）、FORCE=1（会话没变也重建）、LIVE_MAX（每张地图最多用最近多少个实时记录，默认 40）、DRY_RUN=1（只算、不上传）。会话数据只放在临时目录，不进仓库、不进 artifact。
"""
import io, json, math, os, struct, subprocess, sys, tempfile, time, urllib.parse, urllib.request, zipfile, zlib

URL = os.environ["HPASS_URL"].rstrip("/")
if not URL.startswith("http"):
    URL = "https://" + URL
TOKEN = os.environ["HPASS_TOKEN"]
BUILD = os.environ.get("HPASS_BUILD", "hpass-build")
ONLY = os.environ.get("MAP_ID", "").strip()
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


# ---- 房间的视觉特征地图（ARWorldMap）----
# 特征地图只在保存时的 AR 坐标系里有意义。会话带来的 worldmap.json 记着它的 arAlign（AR → 地图），
# 只收和地图 JSON 里 arAlign 等价的：说明那个会话认出了房间，坐标系和房间扫描时一致。
WM_FILE, WM_META = "worldmap.arexperience", "worldmap.json"
WM_WARN, WM_MAX = 8 * 1024 * 1024, 15 * 1024 * 1024        # 与 WorldMapPolicy 一致


def _align(a):
    if not isinstance(a, dict) or "phi" not in a or "pRefX" not in a or "pRefY" not in a:
        return None
    try:
        return tuple(float(a.get(k) or 0) for k in ("phi", "pRefX", "pRefY", "aRefX", "aRefY"))
    except (TypeError, ValueError):
        return None


def map_align(map_json):
    """地图 JSON 里的 arAlign；没有返回 None"""
    try:
        root = json.loads(map_json)
        root = root.get("data", root) if isinstance(root, dict) else {}
        return _align(root.get("arAlign"))
    except ValueError:
        return None


def _to_map(t, x, y):
    phi, px, py, ax, ay = t
    dx, dy = x - ax, y - ay
    c, s = math.cos(phi), math.sin(phi)
    return (px + dx * c - dy * s, py + dx * s + dy * c)


def align_equivalent(a, b, tol_cm=2.0):
    """两个变换把 AR 平面上几个点映到地图上一致（同 WorldMapSidecar.equivalent）"""
    if a is None or b is None:
        return False
    return all(math.dist(_to_map(a, x, y), _to_map(b, x, y)) <= tol_cm for x, y in ((0, 0), (1000, 0), (0, 1000)))


def pick_worldmap(dirs, mid, align):
    """会话目录里挑最新的有效特征地图 → (文件路径, 说明) 或 None"""
    if align is None:
        return None
    best = None
    for d in dirs:
        f, m = os.path.join(d, WM_FILE), os.path.join(d, WM_META)
        if not (os.path.exists(f) and os.path.exists(m)):
            continue
        name = os.path.basename(d)
        try:
            meta = json.load(open(m))
            size = os.path.getsize(f)
            head = open(f, "rb").read(8)
        except (OSError, ValueError):
            print(f"  特征地图 {name}：说明读不出来，跳过")
            continue
        if not isinstance(meta, dict) or meta.get("version") != 1:
            print(f"  特征地图 {name}：说明版本不认识，跳过")
        elif meta.get("mapId") and meta["mapId"] != mid:
            print(f"  特征地图 {name}：属于别的地图，跳过")
        elif not head.startswith(b"bplist"):
            print(f"  特征地图 {name}：不是 ARWorldMap 归档，跳过")
        elif size == 0 or size > WM_MAX:
            print(f"  特征地图 {name}：{size / 1048576:.1f} MB，超过 {WM_MAX // 1048576} MB 或为空，跳过")
        elif not align_equivalent(_align(meta.get("arAlign")), align):
            print(f"  特征地图 {name}：坐标系和地图的 arAlign 对不上（会话没认出房间，或房间重新扫过），跳过")
        else:
            key = (int(meta.get("createdMs") or 0), name)
            if best is None or key > best[0]:
                best = (key, f, meta, size)
    if best is None:
        return None
    return best[1], {"session": best[0][1], "createdMs": best[0][0], "bytes": best[3], "source": best[2].get("source")}


def main():
    work = tempfile.mkdtemp(prefix="hpass-")
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
            mid = meta.get("map_id") or ""
            if not mid:
                print(f"  跳过 {os.path.basename(d)}：旧版本会话，没记地图编号")
                continue
            g = groups.setdefault(mid, {"build": [], "test": [], "live": []})
            g["live" if is_live else ("test" if meta.get("purpose") == "test" else "build")].append(d)
    reports = get_json("/api/reports")
    # 价签位置表（App「门店数据 → 蓝牙」导入时会传到后台）：当蓝牙底图
    esl_path = None
    try:
        esl = req("/api/esl/locations.csv")
        esl_path = os.path.join(work, "esl_locations.csv")
        open(esl_path, "wb").write(esl)
        print(f"价签位置表 {len(esl) // 1024} KB")
    except urllib.error.HTTPError:
        print("后台没有价签位置表，蓝牙只用采集学到的")
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
        picked = pick_worldmap(wm_dirs.get(mid, []), mid, align)
        wm_session = picked[1]["session"] if picked else None
        # 上次融合用的会话
        last = [r for r in reports if r["key"].startswith(f"reports/build_{mid}_")]
        if last and not FORCE:
            prev = get_json("/api/" + last[0]["key"])
            # quality 里有全部建图会话（包括质量筛选没用上的），没有就用 sessions（旧报告）
            used = [q["name"] for q in prev["quality"]] if prev.get("quality") else [s["name"] for s in prev.get("sessions", [])]
            prev_names = sorted(used + prev.get("testSessions", []))
            # 实时记录也算：有新的（或少了的）才重建，没变就不因为它们重跑
            # 有了更新的特征地图也要重建（没有新的就不因为它重跑）
            if (prev_names == names and sorted(prev.get("liveSessions", [])) == live_names
                    and (wm_session is None or prev.get("worldMapSession") == wm_session)):
                print("  会话没变，跳过")
                continue
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
            if align_equivalent(map_align(secs[1]), align) and len(secs[4]) <= WM_MAX:
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
        cmd = [BUILD, "--map", map_path, "--sessions", ",".join(g["build"]), "--id", mid,
               "--name", pm.get("name") or mid, "--kind", pm.get("kind") or "store", "--out", out, "--report", rep]
        if g["test"]:
            cmd += ["--test", ",".join(g["test"])]
        if g["live"]:
            cmd += ["--live", ",".join(g["live"])]
        if esl_path:
            cmd += ["--esl-locations", esl_path]
        if wm_path:
            cmd += ["--worldmap", wm_path]
        if pm.get("mapUpBearingDeg") is not None:
            cmd += ["--bearing", str(pm["mapUpBearingDeg"])]
        rc = subprocess.run(cmd).returncode
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

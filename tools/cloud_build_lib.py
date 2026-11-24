"""cloud_build.py 用的纯函数（不读环境变量、不联网），单元测试直接 import（tools/tests/test_cloud_build.py）。

房间的视觉特征地图（ARWorldMap）只在保存时的 AR 坐标系里有意义。会话带来的 worldmap.json 记着它的
arAlign（AR → 地图）和 frameId（地图基准 AR 坐标系的身份，见 HPASSKit WorldMapSidecar / ScanRegistry）。
兼容规则与 WorldMapSidecar.isCompatible(with:frameId:) 一致：
  - 两边（特征地图说明、地图 JSON）都有 frameId → 相等即兼容（地图原点平移后 arAlign 的 pRef 变了也照样能用）；
  - 否则 → arAlign 等价（AR 平面上几个点映到地图上相差 ≤ 2 cm）。
说明的 version 只认 1。
"""
import json
import math
import os

WM_FILE, WM_META = "worldmap.arexperience", "worldmap.json"
WM_WARN, WM_MAX = 8 * 1024 * 1024, 15 * 1024 * 1024        # 与 WorldMapPolicy 一致


def _align(a):
    if not isinstance(a, dict) or "phi" not in a or "pRefX" not in a or "pRefY" not in a:
        return None
    try:
        return tuple(float(a.get(k) or 0) for k in ("phi", "pRefX", "pRefY", "aRefX", "aRefY"))
    except (TypeError, ValueError):
        return None


def _root(map_json):
    """地图 JSON 的根对象（剥掉 data 包装）；读不出来返回 {}"""
    try:
        root = json.loads(map_json)
    except (ValueError, TypeError):
        return {}
    if isinstance(root, dict) and isinstance(root.get("data"), dict) and "mapElementList" not in root:
        root = root["data"]
    return root if isinstance(root, dict) else {}


def map_align(map_json):
    """地图 JSON 里的 arAlign；没有返回 None"""
    return _align(_root(map_json).get("arAlign"))


def map_frame_id(map_json):
    """地图 JSON 里的 frameId（扫描段注册表写入）；没有返回 None"""
    f = _root(map_json).get("frameId")
    return f if isinstance(f, str) and f else None


def map_geometry_version(map_json):
    """地图 JSON 里的 geometryVersion（扫描段注册表每次合成加一）；没有返回 None"""
    v = _root(map_json).get("geometryVersion")
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return int(v)


def build_unchanged(prev, names, live_names, wm_session, geometry_version):
    """上次融合的报告 prev 和这次的输入一样（建图 / 测试会话、实时记录、特征地图会话、地图几何版本都没变）→ 可以跳过。
    手机接着扫 / 重扫后只上传新的 map.json（geometryVersion 变大），没有新会话也要重建，
    否则手机一直拒装旧几何的包、停在「本机较新」。旧报告没记几何版本：地图有版本号就重建一次把它记上。"""
    used = [q["name"] for q in prev["quality"]] if prev.get("quality") else [s["name"] for s in prev.get("sessions", [])]
    prev_names = sorted(used + prev.get("testSessions", []))
    if prev_names != sorted(names) or sorted(prev.get("liveSessions", [])) != sorted(live_names):
        return False
    if wm_session is not None and prev.get("worldMapSession") != wm_session:
        return False
    return prev.get("mapGeometryVersion") == geometry_version


def edits_hash(edits):
    """看板手动分段修改的指纹（内容一样 → 一样；没有修改 → None，和旧报告没记这个键时一致）"""
    if not edits:
        return None
    import hashlib
    return hashlib.sha1(json.dumps(edits, sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:16]


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


def worldmap_compatible(wm_align, wm_frame, map_align_, map_frame):
    """特征地图（arAlign、frameId）能不能用在这张地图（arAlign、frameId）上"""
    if wm_frame and map_frame:
        return wm_frame == map_frame
    return align_equivalent(wm_align, map_align_)


def pick_worldmap(dirs, mid, align, frame_id=None):
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
            with open(m, encoding="utf-8") as fh:
                meta = json.load(fh)
            size = os.path.getsize(f)
            with open(f, "rb") as fh:
                head = fh.read(8)
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
        elif not worldmap_compatible(_align(meta.get("arAlign")), meta.get("frameId"), align, frame_id):
            print(f"  特征地图 {name}：坐标系和地图对不上（会话没认出房间，或房间重新扫过），跳过")
        else:
            key = (int(meta.get("createdMs") or 0), name)
            if best is None or key > best[0]:
                best = (key, f, meta, size)
    if best is None:
        return None
    return best[1], {"session": best[0][1], "createdMs": best[0][0], "bytes": best[3], "source": best[2].get("source")}


def quality_rejected(session_dir):
    """App 采集时质量打分（quality.json，见 CollectionQualityMonitor）判为整个不能用：返回原因；能用 / 没打分（旧会话）返回 None"""
    p = os.path.join(session_dir, "quality.json")
    try:
        with open(p, encoding="utf-8") as f:
            q = json.load(f)
    except (OSError, ValueError):
        return None
    if q.get("kept", True):
        return None
    return q.get("reason") or f"质量分 {q.get('score', 0)}"


def survey_summary(session_dir):
    """一段建图采集的「校准」情况，给云端日志看：走了多久 / 多远、起点怎么定的、
    途中修正（长按 / 视觉重定位 / 标签）几次、每次修正前偏了多少、ARKit 跟踪受限的比例。
    读 anchors.csv 和 arkit_pose.csv；缺文件返回 None。"""
    import csv, re
    ap = os.path.join(session_dir, "anchors.csv")
    if not os.path.exists(ap):
        return None
    rows = list(csv.DictReader(open(ap, encoding="utf-8")))
    s = {"anchors": len(rows), "reanchors": 0, "visual": 0, "jumps_cm": [], "walk_m": 0.0, "dur_s": 0.0,
         "limited": 0.0, "start": ""}
    for r in rows:
        note = r.get("note") or ""
        if r.get("kind") == "reanchor":
            s["reanchors"] += 1
            if "视觉" in note:
                s["visual"] += 1
            m = re.search(r"修正前偏 (\d+) cm", note)
            if m:
                s["jumps_cm"].append(int(m.group(1)))
        elif not s["start"] and r.get("kind") in ("start", "align"):
            s["start"] = "自动（地磁 / 认房间）" if "自动" in note else "手动长按"
    pp = os.path.join(session_dir, "arkit_pose.csv")
    if os.path.exists(pp):
        n = lim = 0
        last = None
        t0 = t1 = None
        for r in csv.DictReader(open(pp, encoding="utf-8")):
            try:
                t, x, z = int(r["t_ms"]), float(r["x_m"]), float(r["z_m"])
            except (KeyError, TypeError, ValueError):
                continue
            t0 = t if t0 is None else t0
            t1 = t
            n += 1
            if (r.get("tracking") or "2") != "2":     # 2 = normal，1 = limited，0 = 不可用
                lim += 1
            if last is not None:
                d = math.hypot(x - last[0], z - last[1])
                if d < 2:                          # 跳变不算走路
                    s["walk_m"] += d
            last = (x, z)
        if n:
            s["limited"] = lim / n
            s["dur_s"] = (t1 - t0) / 1000
    return s


def format_survey_summary(name, s):
    j = s["jumps_cm"]
    jt = ("，修正前偏 " + "/".join(str(x) for x in j) + " cm") if j else ""
    every = f"，平均每 {s['walk_m'] / s['reanchors']:.0f} m 修正一次" if s["reanchors"] else "，途中一次都没修正"
    return (f"  {name}：{s['dur_s'] / 60:.1f} 分钟 {s['walk_m']:.0f} m，起点{s['start'] or '?'}，"
            f"修正 {s['reanchors']} 次（视觉 {s['visual']}）{every}{jt}，ARKit 受限 {s['limited'] * 100:.0f}%")

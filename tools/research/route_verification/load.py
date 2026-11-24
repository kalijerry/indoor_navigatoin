"""Load survey sessions -> per-sample map-frame position + features (|B|, Bz, Bh, Bx_map, By_map).

Positions: anchor-based alignment from tools/magmap.py (no multi-session registration).
Vector: raw magnetometer - session bias (device frame), rotated by ARKit camera attitude into
ARKit world, then horizontal part rotated by the anchor segment's phi into map frame.
"""
import bisect, math, sys
from pathlib import Path
import numpy as np

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
import magmap  # noqa
from calibrate import read_csv  # noqa


def quat_to_R(qx, qy, qz, qw):
    x, y, z, w = qx, qy, qz, qw
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def Rz(k):
    a = k * math.pi / 2
    c, s = round(math.cos(a)), round(math.sin(a))
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1.0]])


def load_session(d):
    d = Path(d)
    rep = []
    pose = magmap.Pose(read_csv(d / "arkit_pose.csv"))
    prow = read_csv(d / "arkit_pose.csv")
    pt = np.array([int(r["t_ms"]) for r in prow])
    pq = np.array([[float(r["qx"]), float(r["qy"]), float(r["qz"]), float(r["qw"])] for r in prow])
    anchors = magmap.load_anchors(d / "anchors.csv")
    segs = magmap.build_segments(anchors, pose, {"warnings": []})
    rows = read_csv(d / "imu.csv")
    t = np.array([int(r["t_ms"]) for r in rows])
    cal = [(float(r["mx"]), float(r["my"]), float(r["mz"])) for r in rows]
    if "gvx" in rows[0] and rows[0]["gvx"]:
        up = np.array([[float(r["gvx"] or 0), float(r["gvy"] or 0), float(r["gvz"] or 0)] for r in rows])
    else:
        acc = np.array([[float(r["ax"]), float(r["ay"]), float(r["az"])] for r in rows])
        k = np.ones(25) / 25
        up = np.stack([np.convolve(acc[:, c], k, mode="same") for c in range(3)], axis=1)
    rf = magmap.raw_field(d, list(t), cal)
    if rf is None:
        return None
    field = rf[0]
    ok = np.array([f is not None for f in field])
    m = np.array([f if f is not None else (np.nan,) * 3 for f in field])
    upn = up / np.maximum(np.linalg.norm(up, axis=1, keepdims=True), 1e-6)
    # nearest ARKit quaternion
    idx = np.clip(np.searchsorted(pt, t), 1, len(pt) - 1)
    idx = np.where(np.abs(pt[idx - 1] - t) < np.abs(pt[idx] - t), idx - 1, idx)
    Rs = np.array([quat_to_R(*q) for q in pq])
    Ri = Rs[idx]
    # camera<-device: pick the z-rotation that maps device 'up' to ARKit +y
    best = None
    for k in range(4):
        Rcd = Rz(k)
        u = np.einsum("nij,jk,nk->ni", Ri, Rcd, upn)
        sc = np.nanmedian(u[:, 1])
        if best is None or sc > best[0]:
            best = (sc, Rcd)
    Rcd = best[1]
    Bw = np.einsum("nij,jk,nk->ni", Ri, Rcd, m)   # ARKit world: x right, y up, z toward viewer
    out = []
    seg_i = 0
    prev_ok = None
    for i, ti in enumerate(t):
        if not ok[i]:
            continue
        while seg_i < len(segs) - 1 and ti >= segs[seg_i + 1]["t0"]:
            seg_i += 1
        if not segs or ti < segs[0]["t0"]:
            continue
        seg = segs[seg_i]
        if ti > seg["t1"] or "bad" in seg or seg.get("phi") is None:
            continue
        p = pose.at(int(ti))
        if not p or not p[2]:
            continue
        if seg["tail"] and pose.path_at(ti) - pose.path_at(seg["t0"]) > magmap.TAIL_MAX_CM:
            continue
        q = pose.at(int(ti) - 500)
        if q and math.hypot(p[0] - q[0], p[1] - q[1]) / 0.5 < magmap.MIN_SPEED_CM_S:
            continue
        xy = magmap.to_map(seg, (p[0], p[1]), ti)
        bh = magmap.rot((Bw[i, 0], Bw[i, 2]), seg["phi"])
        mag = float(np.linalg.norm(m[i]))
        bz = float(np.dot(m[i], upn[i]))
        out.append((ti, xy[0] / 100, xy[1] / 100, mag, bz, bh[0], bh[1], float(Bw[i, 1]), (pose.path_at(ti) - pose.path_at(seg["t0"]) if seg["tail"] else min(pose.path_at(ti) - pose.path_at(seg["t0"]), pose.path_at(seg["t1"]) - pose.path_at(ti))) / 100))
    a = np.array(out)
    if len(a) < 20:
        return None
    # light smoothing (0.1 s ~ 5 samples) on features
    if len(a) > 10:
        k = np.ones(5) / 5
        for c in range(3, 8):  # not col 8
            a[:, c] = np.convolve(a[:, c], k, mode="same")
    return {"name": d.name, "a": a, "Rcd_score": best[0]}


if __name__ == "__main__":
    for p in sys.argv[1:]:
        s = load_session(p)
        if s is None:
            print(p, "none"); continue
        a = s["a"]
        print(s["name"], len(a), "upscore %.3f" % s["Rcd_score"],
              "Bz(dev-up) vs Bw_y diff median %.2f" % np.median(np.abs(a[:, 4] - a[:, 7])),
              "|B| %.1f" % np.median(a[:, 3]), "Bh dir spread", np.round(np.percentile(np.degrees(np.arctan2(a[:, 6], a[:, 5])), [10, 50, 90])))

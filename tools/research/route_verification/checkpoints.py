#!/usr/bin/env python3
"""过点打卡（精度实验）：每遍建图采集在打卡点的真实误差。

App 建图页「采集选项」里打开「精度实验：过点打卡」后，起点之后的长按只在 anchors.csv 记一行 kind=checkpoint
（地图坐标 = 长按的已知点 = 真值；ARKit 坐标 = 那一刻；备注里有当时 App 估计的位置），不修正位置、不参与对齐。

这里用和建图一样的对齐（tools/magmap.py：起点 / 修正点 + ARKit）算出每个打卡时刻的地图位置，和真值比：
- 总误差、沿走路方向（纵向）和横向分开（直走廊里两者的成因不同：纵向多是步长 / 漂移，横向多是朝向）；
- 当时 App 实时估计的位置的误差（备注里记的）。

用法：python3 tools/research/route_verification/checkpoints.py 会话目录1 会话目录2 …
"""
import math
import re
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import magmap  # noqa: E402
from calibrate import read_csv  # noqa: E402


def session_errors(d):
    d = Path(d)
    if not (d / "anchors.csv").exists() or not (d / "arkit_pose.csv").exists():
        return None
    pose = magmap.Pose(read_csv(d / "arkit_pose.csv"))
    rows = read_csv(d / "anchors.csv")
    anchors = magmap.load_anchors(d / "anchors.csv")
    segs = magmap.build_segments(anchors, pose, {"warnings": []})
    cps = [r for r in rows if r["kind"] == "checkpoint"]
    out = []
    for r in cps:
        t = int(r["t_ms"])
        truth = (float(r["map_x_cm"]), float(r["map_y_cm"]))
        seg = None
        for s in segs:
            if s["t0"] <= t and (t <= s["t1"] or s["tail"]):
                seg = s
        if seg is None or seg.get("phi") is None or "bad" in seg:
            continue
        a = (float(r["ar_x_cm"]), float(r["ar_z_cm"]))
        est = magmap.to_map(seg, a, t)
        # 走路方向：前后 1 s 的 ARKit 位移，转到地图坐标
        p0, p1 = pose.at(t - 1000), pose.at(t + 1000)
        along = cross = None
        ex, ey = est[0] - truth[0], est[1] - truth[1]
        if p0 and p1 and math.hypot(p1[0] - p0[0], p1[1] - p0[1]) > 30:
            u = magmap.rot((p1[0] - p0[0], p1[1] - p0[1]), seg["phi"])
            n = math.hypot(*u)
            u = (u[0] / n, u[1] / n)
            along = ex * u[0] + ey * u[1]
            cross = -ex * u[1] + ey * u[0]
        live = None
        m = re.search(r"估计 (-?[\d.]+) (-?[\d.]+)", r.get("note") or "")
        if m:
            live = math.hypot(float(m.group(1)) - truth[0], float(m.group(2)) - truth[1])
        dist = pose.path_at(t) - pose.path_at(seg["t0"])
        out.append({"t": t, "err": math.hypot(ex, ey), "along": along, "cross": cross, "live": live,
                    "from_anchor_m": dist / 100})
    return out


def summary(xs):
    xs = [abs(x) for x in xs if x is not None]
    if not xs:
        return "—"
    xs.sort()
    return f"中位 {statistics.median(xs):.0f} cm，P90 {xs[min(len(xs) - 1, int(len(xs) * 0.9))]:.0f} cm（{len(xs)} 个）"


def main(dirs):
    allr = []
    for d in dirs:
        e = session_errors(d)
        if not e:
            print(f"{Path(d).name}：没有打卡点")
            continue
        allr += e
        print(f"{Path(d).name}：对齐后 {summary([x['err'] for x in e])}；实时估计 {summary([x['live'] for x in e])}")
    if allr:
        print("合计")
        print(f"  对齐后总误差   {summary([x['err'] for x in allr])}")
        print(f"  纵向（沿走路） {summary([x['along'] for x in allr])}")
        print(f"  横向           {summary([x['cross'] for x in allr])}")
        print(f"  实时估计       {summary([x['live'] for x in allr])}")
        far = [x for x in allr if x["from_anchor_m"] >= 15]
        near = [x for x in allr if x["from_anchor_m"] < 15]
        print(f"  离起点 / 修正点 < 15 m：{summary([x['err'] for x in near])}；≥ 15 m：{summary([x['err'] for x in far])}")


if __name__ == "__main__":
    main(sys.argv[1:])

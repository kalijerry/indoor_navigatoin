#!/usr/bin/env python3
"""把真实 IMU 纯计步推算的误差拆开：计步数 / 步长（尺度）/ 航向（起步偏差、漂移、转弯）。

输入是 hpass-eval --dr-dump 写的 CSV（每帧惯导输出 + 参考位置，起点和起步朝向取法同 --oracle-start）：
  hpass-eval --map map.json --test <会话父目录> --dr-dump dr.csv [--carry-motion]
  dr_decompose.py dr.csv [--per-session]

拆法（都只用参考轨迹有点、且参考在动的时段）：
- 尺度：每走 10 m 参考路程，推算路程 / 参考路程；
- 步频 / 隐含真步长：检出步数、移动时间 → 步频；参考路程 / 步数 = 每检出一步实际走了多远（> 0.85 m 多半是漏步）；
- 航向：每 3 m 参考路程一段，推算位移方向 − 参考位移方向；起步偏差 = 前 15 m 的中位数，漂移 = 对时间的稳健斜率，
  转弯 = 参考方向 5 m 内变了 > 45° 的地方，推算转角 / 参考转角；
- 相对误差（和粒子滤波相关的量）：任一起点往后 20 m 参考路程，推算位移和参考位移之差 / 20 m。
  另算三种「神谕修正」后的同一个量：尺度按会话真值修正 / 航向按会话恒定偏差修正 / 两个都修，
  看哪一项是主要误差来源。
"""
from __future__ import annotations

import argparse
import csv
import math
import statistics as st
from collections import defaultdict


def wrap(a: float) -> float:
    return (a + math.pi) % (2 * math.pi) - math.pi


def pct(xs, q):
    xs = sorted(xs)
    if not xs:
        return float("nan")
    return xs[min(len(xs) - 1, int(q * len(xs)))]


def load(path):
    by = defaultdict(list)
    with open(path) as f:
        for r in csv.DictReader(f):
            if not r["ref_x"]:
                continue
            by[r["session"]].append(dict(
                t=int(r["t_ms"]), x=float(r["x"]), y=float(r["y"]), h=float(r["heading_rad"]),
                steps=int(r["steps"]), L=float(r["step_len_m"]), moving=r["moving"] == "1", mode=r["carry_mode"],
                k=float(r["step_k"]), rx=float(r["ref_x"]), ry=float(r["ref_y"])))
    return by


def cumpath(xs, ys):
    out = [0.0]
    for i in range(1, len(xs)):
        out.append(out[-1] + math.hypot(xs[i] - xs[i - 1], ys[i] - ys[i - 1]))
    return out


def theil_sen(ts, es):
    """稳健斜率（抽样）"""
    n = len(ts)
    if n < 4:
        return 0.0
    sl = []
    step = max(1, n // 60)
    idx = list(range(0, n, step))
    for a in range(len(idx)):
        for b in range(a + 1, len(idx)):
            i, j = idx[a], idx[b]
            if ts[j] - ts[i] > 5:
                sl.append(wrap(es[j] - es[i]) / (ts[j] - ts[i]))
    return st.median(sl) if sl else 0.0


def rot(px, py, a):
    """方向角约定 θ = atan2(x, y)（x = sin θ、y = cos θ）：把向量的方向角加 a"""
    r_ = math.hypot(px, py)
    th = math.atan2(px, py) + a
    return r_ * math.sin(th), r_ * math.cos(th)


def analyse(rows):
    """一个会话（load() 的一项，坐标 cm）→ 各项误差统计"""
    t = [r["t"] / 1000 for r in rows]
    rx = [r["rx"] for r in rows]
    ry = [r["ry"] for r in rows]
    dx = [r["x"] for r in rows]
    dy = [r["y"] for r in rows]
    rp = cumpath(rx, ry)
    dp = cumpath(dx, dy)
    res = {}
    T = t[-1] - t[0]
    res["dur_s"] = T
    res["ref_m"] = rp[-1] / 100
    res["dr_m"] = dp[-1] / 100
    steps = rows[-1]["steps"] - rows[0]["steps"]
    res["steps"] = steps
    mov_t = sum(t[i] - t[i - 1] for i in range(1, len(t)) if rows[i]["moving"])
    res["moving_s"] = mov_t
    res["cadence_hz"] = steps / mov_t if mov_t > 0 else float("nan")
    res["true_m_per_step"] = rp[-1] / 100 / steps if steps else float("nan")
    res["dr_m_per_step"] = dp[-1] / 100 / steps if steps else float("nan")
    # 参考在动但推算基本没动的时间（漏步 / 没判动）：每 2 s 窗
    stall = 0.0
    tot = 0.0
    j = 0
    for i in range(len(t)):
        while j < len(t) and t[j] - t[i] < 2:
            j += 1
        if j >= len(t):
            break
        rm = math.hypot(rx[j] - rx[i], ry[j] - ry[i])
        if rm > 120:  # 参考 2 s 走了 > 1.2 m
            tot += 1
            if (dp[j] - dp[i]) < 0.4 * rm:
                stall += 1
    res["stall_share"] = stall / tot if tot else float("nan")
    # 尺度：每 10 m 参考路程
    scales = []
    i = 0
    for j in range(len(rp)):
        if rp[j] - rp[i] >= 1000:
            scales.append((dp[j] - dp[i]) / (rp[j] - rp[i]))
            i = j
    res["scale_med"] = st.median(scales) if scales else float("nan")
    res["scale_p10"] = pct(scales, 0.1)
    res["scale_p90"] = pct(scales, 0.9)
    res["scales"] = scales
    # 航向：每 3 m 参考路程一段
    segs = []
    i = 0
    for j in range(len(rp)):
        if rp[j] - rp[i] >= 300:
            ddx, ddy = dx[j] - dx[i], dy[j] - dy[i]
            if math.hypot(ddx, ddy) > 50:
                th_r = math.atan2(rx[j] - rx[i], ry[j] - ry[i])
                th_d = math.atan2(ddx, ddy)
                segs.append(((t[i] + t[j]) / 2, rp[i] / 100, th_r, wrap(th_d - th_r)))
            i = j
    errs = [s[3] for s in segs]
    if segs:
        # 用单位向量平均，避免 ±π
        def circmed(es):
            return math.atan2(sum(math.sin(e) for e in es), sum(math.cos(e) for e in es))
        first = [s[3] for s in segs if s[1] <= 15] or errs[:3]
        res["head_init_deg"] = math.degrees(circmed(first))
        res["head_abs_med_deg"] = math.degrees(st.median([abs(e) for e in errs]))
        res["head_abs_p90_deg"] = math.degrees(pct([abs(e) for e in errs], 0.9))
        # 漂移：把误差展开（unwrap）后对时间的稳健斜率
        un = [errs[0]]
        for e in errs[1:]:
            un.append(un[-1] + wrap(e - un[-1]))
        res["head_drift_deg_per_min"] = math.degrees(theil_sen([s[0] for s in segs], un)) * 60
        res["head_err_series"] = [(s[0] - t[0], s[1], math.degrees(s[3])) for s in segs]
        # 转弯：参考方向在相邻段变了 > 45°
        turns = []
        for a in range(1, len(segs)):
            dr_ = wrap(segs[a][2] - segs[a - 1][2])
            if abs(dr_) > math.radians(45):
                dd = wrap((segs[a][2] + segs[a][3]) - (segs[a - 1][2] + segs[a - 1][3]))
                turns.append((math.degrees(dr_), math.degrees(dd)))
        res["turns"] = turns
        if turns:
            res["turn_ratio_med"] = st.median([d / r for r, d in turns])
            res["turn_err_abs_med_deg"] = st.median([abs(d - r) for r, d in turns])
    # 相对误差（20 m 窗），原始 + 神谕修正
    sc = (dp[-1] / rp[-1]) if rp[-1] > 0 else 1
    hoff = math.radians(res.get("head_init_deg", 0.0))
    # 会话恒定航向偏差：全部段误差的圆均值
    hall = math.atan2(sum(math.sin(e) for e in errs), sum(math.cos(e) for e in errs)) if errs else 0.0
    rel = {"raw": [], "scale": [], "head": [], "both": []}
    j = 0
    for i in range(0, len(rp), 3):
        while j < len(rp) and rp[j] - rp[i] < 2000:
            j += 1
        if j >= len(rp):
            break
        trx, tr_y = rx[j] - rx[i], ry[j] - ry[i]
        ddx, ddy = dx[j] - dx[i], dy[j] - dy[i]
        L = rp[j] - rp[i]
        hx, hy = rot(ddx, ddy, -hall)
        rel["raw"].append(math.hypot(ddx - trx, ddy - tr_y) / L)
        rel["scale"].append(math.hypot(ddx / sc - trx, ddy / sc - tr_y) / L)
        rel["head"].append(math.hypot(hx - trx, hy - tr_y) / L)
        rel["both"].append(math.hypot(hx / sc - trx, hy / sc - tr_y) / L)
    res["rel20"] = {k: (st.median(v) if v else float("nan"), pct(v, 0.9)) for k, v in rel.items()}
    res["head_mean_deg"] = math.degrees(hall)
    modes = defaultdict(int)
    for r in rows:
        modes[r["mode"]] += 1
    res["modes"] = {k: v / len(rows) for k, v in modes.items()}
    return res


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--per-session", action="store_true")
    ap.add_argument("--series", help="打印这个会话的航向误差序列")
    a = ap.parse_args(argv)
    by = load(a.csv)
    allres = {}
    for s, rows in sorted(by.items()):
        if len(rows) < 30:
            continue
        r = analyse(rows)
        if r["ref_m"] < 20:
            continue
        allres[s] = r
        if a.per_session:
            print(f"{s[-8:]} {r['dur_s']:5.0f}s ref {r['ref_m']:5.0f}m dr {r['dr_m']:5.0f}m steps {r['steps']:4d} "
                  f"cad {r['cadence_hz']:.2f}Hz trueL {r['true_m_per_step']:.2f} drL {r['dr_m_per_step']:.2f} "
                  f"scale {r['scale_med']:.2f}[{r['scale_p10']:.2f},{r['scale_p90']:.2f}] stall {r['stall_share']:.2f} "
                  f"h0 {r.get('head_init_deg', float('nan')):+5.1f} hmean {r['head_mean_deg']:+5.1f} "
                  f"drift {r.get('head_drift_deg_per_min', float('nan')):+5.1f}°/min |h| {r.get('head_abs_med_deg', float('nan')):4.1f}/{r.get('head_abs_p90_deg', float('nan')):4.1f} "
                  f"turn {r.get('turn_ratio_med', float('nan')):.2f} rel20 {r['rel20']['raw'][0]:.2f}/{r['rel20']['scale'][0]:.2f}/{r['rel20']['head'][0]:.2f}/{r['rel20']['both'][0]:.2f} "
                  + " ".join(f"{k}:{v:.2f}" for k, v in sorted(r["modes"].items(), key=lambda kv: -kv[1])[:3]))
        if a.series and s.endswith(a.series):
            for x in r["head_err_series"]:
                print(f"  t {x[0]:6.1f}s path {x[1]:6.1f}m err {x[2]:+6.1f}°")
    if not allres:
        print("没有可用会话")
        return
    R = list(allres.values())
    tot_ref = sum(r["ref_m"] for r in R)
    tot_dr = sum(r["dr_m"] for r in R)
    tot_steps = sum(r["steps"] for r in R)
    tot_mov = sum(r["moving_s"] for r in R)
    allsc = [x for r in R for x in r["scales"]]
    print(f"会话 {len(R)}，参考 {tot_ref:.0f} m，推算 {tot_dr:.0f} m（总尺度 {tot_dr / tot_ref:.3f}），"
          f"步 {tot_steps}，步频 {tot_steps / tot_mov:.2f} Hz，每步实际 {tot_ref / tot_steps:.3f} m / 推算 {tot_dr / tot_steps:.3f} m")
    print(f"10 m 尺度：中位 {st.median(allsc):.3f}  P10 {pct(allsc, .1):.3f}  P90 {pct(allsc, .9):.3f}  "
          f"会话间尺度 σ {st.pstdev([r['dr_m'] / r['ref_m'] for r in R]):.3f}  卡住时段 {st.mean([r['stall_share'] for r in R]):.3f}")
    h0 = [r["head_init_deg"] for r in R if "head_init_deg" in r]
    hm = [r["head_mean_deg"] for r in R]
    dr = [r["head_drift_deg_per_min"] for r in R if "head_drift_deg_per_min" in r]
    hab = [r["head_abs_med_deg"] for r in R if "head_abs_med_deg" in r]
    print(f"航向：起步偏差 |中位| {st.median([abs(x) for x in h0]):.1f}° P90 {pct([abs(x) for x in h0], .9):.1f}°；"
          f"会话平均偏差 |中位| {st.median([abs(x) for x in hm]):.1f}° P90 {pct([abs(x) for x in hm], .9):.1f}°；"
          f"漂移 |中位| {st.median([abs(x) for x in dr]):.1f}°/min P90 {pct([abs(x) for x in dr], .9):.1f}°/min；"
          f"3 m 段 |误差| 中位 {st.median(hab):.1f}°")
    turns = [x for r in R for x in r.get("turns", [])]
    if turns:
        print(f"转弯 {len(turns)} 个：推算/参考 转角比 中位 {st.median([d / r for r, d in turns]):.3f}，"
              f"|转角误差| 中位 {st.median([abs(d - r) for r, d in turns]):.1f}° P90 {pct([abs(d - r) for r, d in turns], .9):.1f}°")
    for k in ("raw", "scale", "head", "both"):
        v = [r["rel20"][k][0] for r in R]
        v9 = [r["rel20"][k][1] for r in R]
        print(f"20 m 相对误差（{k:5s}）：会话中位的中位 {st.median(v):.3f}  会话 P90 的中位 {st.median(v9):.3f}")
    modes = defaultdict(float)
    for r in R:
        for k, v in r["modes"].items():
            modes[k] += v / len(R)
    print("携带模式：" + "  ".join(f"{k} {v:.2f}" for k, v in sorted(modes.items(), key=lambda kv: -kv[1])))


if __name__ == "__main__":
    main()

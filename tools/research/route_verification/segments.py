"""Shift-detection experiment: how well does each feature set flag a deliberately misplaced segment?

Feature sets:  S1 = (|B|, Bz)  (what PR #79 uses);  S2 = (Bx_map, By_map, Bz)  (full vector in map frame).
"""
import math, sys, json
from pathlib import Path
import numpy as np
from load import load_session

CELL = 0.5
W3 = {0: 1.0, 1: 0.5, 2: 0.25}


def split(a, turn_deg=55, min_len=3.0, max_len=20.0):
    """Approx. port of SurveySegments.split on (t,x,y) samples. Returns list of index arrays."""
    xy = a[:, 1:3]
    step = np.r_[0, np.linalg.norm(np.diff(xy, axis=0), axis=1)]
    gap = np.r_[False, (np.diff(a[:, 0]) > 3000) | (step[1:] > 3)]
    s = np.cumsum(np.where(gap, 0, step))
    # resample every 0.25 m
    grid = np.arange(0, s[-1], 0.25)
    gi = np.searchsorted(s, grid).clip(0, len(s) - 1)
    P = xy[gi]
    cuts = set()
    h = 6  # 1.5 m chord
    ang = np.zeros(len(P))
    for k in range(h, len(P) - h):
        v1, v2 = P[k] - P[k - h], P[k + h] - P[k]
        if np.linalg.norm(v1) < 0.5 or np.linalg.norm(v2) < 0.5:
            continue
        d = math.degrees(abs(math.atan2(v1[0] * v2[1] - v1[1] * v2[0], v1 @ v2)))
        ang[k] = d
    for k in range(1, len(P) - 1):
        if ang[k] >= turn_deg and ang[k] >= ang[k - 1] and ang[k] >= ang[k + 1]:
            cuts.add(grid[k])
    for k in np.where(gap)[0]:
        cuts.add(s[k])
    cuts = sorted(cuts)
    bounds = [0.0]
    for c in cuts:
        if c - bounds[-1] >= min_len and s[-1] - c >= min_len:
            bounds.append(c)
    bounds.append(s[-1] + 1e-6)
    out = []
    for b0, b1 in zip(bounds, bounds[1:]):
        n = max(1, int(math.ceil((b1 - b0) / max_len)))
        for j in range(n):
            lo, hi = b0 + (b1 - b0) * j / n, b0 + (b1 - b0) * (j + 1) / n
            idx = np.where((s >= lo) & (s < hi))[0]
            if len(idx) > 10:
                out.append(idx)
    return out


def subsample(a, idx, every=0.25):
    """every 25 cm along path"""
    xy = a[idx, 1:3]
    s = np.r_[0, np.cumsum(np.linalg.norm(np.diff(xy, axis=0), axis=1))]
    grid = np.arange(0, s[-1], every)
    return idx[np.searchsorted(s, grid).clip(0, len(idx) - 1)]


class Ref:
    """3x3-weighted 50 cm grid of another segment's samples."""

    def __init__(self, xy, f):
        self.cells = {}
        for p, v in zip(xy, f):
            i, j = int(math.floor(p[0] / CELL)), int(math.floor(p[1] / CELL))
            for di in (-1, 0, 1):
                for dj in (-1, 0, 1):
                    w = W3[abs(di) + abs(dj)]
                    c = self.cells.setdefault((i + di, j + dj), [0.0, np.zeros(len(v))])
                    c[0] += w
                    c[1] += w * v

    def at(self, xy):
        vals, mask = [], []
        for p in xy:
            c = self.cells.get((int(math.floor(p[0] / CELL)), int(math.floor(p[1] / CELL))))
            if c is None or c[0] < 2:
                vals.append(None); mask.append(False)
            else:
                vals.append(c[1] / c[0]); mask.append(True)
        return vals, np.array(mask)


def pair_resid(xy, f, ref):
    vals, m = ref.at(xy)
    if m.sum() < 12:  # < 3 m overlap
        return None, 0.0
    d = np.array([f[k] - vals[k] for k in range(len(xy)) if m[k]])
    d = d - np.median(d, axis=0)
    return float(np.median(np.mean(np.abs(d), axis=1))), m.sum() * 0.25


def lower_wmedian(rs):
    rs = sorted(rs)
    tot = sum(w for _, w in rs)
    acc = 0
    for r, w in rs:
        acc += w
        if acc >= tot / 2:
            return r
    return None


def segment_resid(seg, others, cols, shift=(0, 0)):
    xy = seg["xy"] + np.array(shift)
    f = seg["a"][:, cols]
    rs = []
    for o in others:
        r, ov = pair_resid(xy, f, o["ref"][tuple(cols)])
        if r is not None:
            rs.append((r, ov))
    if not rs or sum(w for _, w in rs) < 3:
        return None, 0
    return lower_wmedian(rs), sum(w for _, w in rs)


def main(dirs):
    segs = []
    for d in dirs:
        s = load_session(d)
        if s is None:
            continue
        for k, idx in enumerate(split(s["a"])):
            sub = subsample(s["a"], idx)
            segs.append({"name": f"{s['name'][-6:]}#{k}", "sess": s["name"], "a": s["a"][sub], "xy": s["a"][sub, 1:3]})
    SETS = {"S1 |B|,Bz": [3, 4], "S2 Bx,By,Bz": [5, 6, 4], "S3 |B|,Bz,Bx,By": [3, 4, 5, 6]}
    for sg in segs:
        sg["ref"] = {tuple(c): Ref(sg["xy"], sg["a"][:, c]) for c in SETS.values()}
    print(f"{len(segs)} segments")
    res = {}
    for name, cols in SETS.items():
        base, shifted = [], {0.5: [], 1.0: [], 1.5: []}
        for i, sg in enumerate(segs):
            others = [o for o in segs if o["sess"] != sg["sess"]]
            r0, ov = segment_resid(sg, others, cols)
            if r0 is None or ov < 8:
                continue
            base.append(r0)
            for dist in shifted:
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    r, _ = segment_resid(sg, others, cols, (dx * dist, dy * dist))
                    if r is not None:
                        shifted[dist].append((r0, r))
        base = np.array(base)
        # threshold such that 25% of unshifted segments are non-green (matched false-alarm)
        thr = float(np.percentile(base, 75))
        line = [f"{name}: n={len(base)} base median {np.median(base):.2f} thr(P75) {thr:.2f}"]
        for dist, pr in shifted.items():
            pr = np.array(pr)
            det = np.mean(pr[:, 1] > thr)
            rel = np.mean(pr[:, 1] > pr[:, 0] * 1.3)
            line.append(f"  shift {dist} m: flagged {det*100:.0f}%  resid↑>30% {rel*100:.0f}%  median ratio {np.median(pr[:,1]/pr[:,0]):.2f}")
        print("\n".join(line))
        res[name] = line
    return segs


if __name__ == "__main__":
    main(sys.argv[1:])

#!/usr/bin/env python3
"""磁场图质量的交叉验证：留出的会话在「参考位置」上的实测特征和地图比，分「采过的格子」和「补出来的格子」统计。

建图算法（补空格、偏移对齐、格子标准差）改了之后先用它量地图本身，再跑 Lab 定位场景：

    python -I -X utf8 tools/bench/map_cv.py run  --eval hpass-eval --data <数据集目录> --out <目录> --tag base [-- 额外 hpass-eval 参数]
    python -I -X utf8 tools/bench/map_cv.py report --out <目录> --tags base,r300

- 数据集目录里有 build/ 和 test/（公开数据、合成小场地：build 建图、test 的 truth.csv 当参考）；
  只有 build/ 时按留一法（自采：其余建图会话建图，留下那次用它自己的锚点对齐当参考）。
- run 每次都另跑一份 `--fill-radius 0`（tag = nofill）：地图在参考位置有没有「采过的」数据就按它分。
- report 每个会话先减掉自己的整体偏移（采过格子上的中位数，各 tag 用同一个），再统计：
  覆盖（地图在参考位置有值的比例）、残差按 Student-t（ν=4）的尺度、|z| 中位（下限 4 µT，t4 应为 0.74）、
  平均 t4 对数似然（下限 4 µT，越大越好：既看残差也看标准差报得老不老实）。

输出只有汇总数字；残差 CSV（含参考坐标）留在 --out 目录，自采数据不要拷出去。
"""
from __future__ import annotations

import argparse
import csv
import math
import os
import statistics as st
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

C = ("total", "vertical", "horizontal")
FLOOR_UT = 4.0


def folds(data: Path) -> list[tuple[str, str, str]]:
    """[(折名, --build, --test)]：test/ 里有会话时一折（build/ → test/），否则留一法"""
    def sessions(d: Path) -> list[str]:
        return sorted(p.name for p in d.iterdir() if (p / "imu.csv").exists()) if d.is_dir() else []
    builds = sessions(data / "build")
    if sessions(data / "test"):
        return [("all", str(data / "build"), str(data / "test"))]
    return [(b, ",".join(str(data / "build" / x) for x in builds if x != b), str(data / "build" / b)) for b in builds]


def run(ev: str, data: Path, out: Path, tag: str, extra: list[str], runner=subprocess.run) -> list[Path]:
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, SWIFT_DETERMINISTIC_HASHING="1")
    written = []
    for t, flags in (("nofill", ["--fill-radius", "0"]), (tag, extra)):
        for name, build, test in folds(data):
            dst = out / f"{t}--{name}.csv"
            if t == "nofill" and dst.exists():
                written.append(dst)
                continue
            r = runner([ev, "--map", str(data / "map.json"), "--build", build, "--test", test, "--residuals", str(dst)] + flags,
                       capture_output=True, text=True, env=env)
            if r.returncode != 0:
                raise RuntimeError(f"hpass-eval 失败（{name}）：{(r.stdout or '')[-500:]}{(r.stderr or '')[-500:]}")
            written.append(dst)
    return written


def load(fn: Path) -> dict:
    out = {}
    with open(fn, encoding="utf-8") as f:
        for r in csv.DictReader(f):
            m = [float(r["m_" + c]) for c in C] if r["m_total"] else None
            s = [float(r["s_" + c]) for c in C] if r["s_total"] else None
            out[(r["session"], r["t_ms"])] = ([float(r["f_" + c]) for c in C], m, s)
    return out


def t4_loglik(r: float, s: float, floor: float = FLOOR_UT) -> float:
    sc = math.sqrt(s * s + floor * floor)
    return -2.5 * math.log(1 + (r / sc) ** 2 / 4) - math.log(sc)


def summarize(base: dict, cur: dict) -> dict:
    """base = nofill（定「采过」和每个会话的偏移），cur = 要量的地图。返回 {'meas': {...}, 'gap': {...}}"""
    sess = defaultdict(list)
    for k, (f, m, _) in base.items():
        if m is not None:
            sess[k[0]].append([f[i] - m[i] for i in range(3)])
    off = {s: [st.median(x[i] for x in v) for i in range(3)] for s, v in sess.items() if len(v) >= 10}
    acc = {c: {"n": 0, "cov": 0, "r": [], "z": [], "ll": []} for c in ("meas", "gap")}
    for k, (f, m, s) in cur.items():
        if k[0] not in off:
            continue
        cat = "meas" if base.get(k, (None, None, None))[1] is not None else "gap"
        a = acc[cat]
        a["n"] += 1
        if m is None:
            continue
        a["cov"] += 1
        for i in range(3):
            r = f[i] - off[k[0]][i] - m[i]
            a["r"].append(abs(r))
            a["z"].append(abs(r) / math.sqrt(s[i] ** 2 + FLOOR_UT ** 2))
            a["ll"].append(t4_loglik(r, s[i]))
    res = {}
    for cat, a in acc.items():
        if a["n"] == 0:
            continue
        res[cat] = {"n": a["n"], "coverage": a["cov"] / a["n"],
                    "t4_scale": st.median(a["r"]) / 0.741 if a["r"] else None,
                    "z_median": st.median(a["z"]) if a["z"] else None,
                    "loglik": st.mean(a["ll"]) if a["ll"] else None}
    return res


def report(out: Path, tags: list[str]) -> dict:
    result = {}
    for tag in tags:
        fs = sorted(out.glob(f"{tag}--*.csv"))
        base, cur = {}, {}
        for fn in fs:
            fold = fn.name[len(tag) + 2:]
            b = out / f"nofill--{fold}"
            if not b.exists():
                continue
            # 不同折的会话名不重复（留一法每折一个留下的会话；公开数据一折）
            base.update(load(b))
            cur.update(load(fn))
        if cur:
            result[tag] = summarize(base, cur)
    return result


def fmt(v, p=2):
    return "—" if v is None else f"{v:.{p}f}"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--eval", required=True)
    r.add_argument("--data", required=True, type=Path)
    r.add_argument("--out", required=True, type=Path)
    r.add_argument("--tag", required=True)
    r.add_argument("extra", nargs=argparse.REMAINDER)
    p = sub.add_parser("report")
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--tags", required=True)
    a = ap.parse_args(argv)
    if a.cmd == "run":
        extra = a.extra[1:] if a.extra[:1] == ["--"] else a.extra
        run(a.eval, a.data, a.out, a.tag, extra)
        return 0
    res = report(a.out, ["nofill"] + [t for t in a.tags.split(",") if t and t != "nofill"])
    for tag, cats in res.items():
        line = f"{tag:12s}"
        for cat in ("meas", "gap"):
            c = cats.get(cat)
            if c:
                line += (f" | {cat} n={c['n']} 覆盖 {c['coverage']:.1%} t4 尺度 {fmt(c['t4_scale'])} µT"
                         f" |z| {fmt(c['z_median'])} 对数似然 {fmt(c['loglik'], 3)}")
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())

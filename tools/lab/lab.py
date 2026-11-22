#!/usr/bin/env python3
"""定位实验室（Lab CI）：每次改动都在固定的数据和协议上回放，量化精度、拦住退步、显示离 Oriient 档还差多少。

子命令：
  prepare-public --ilc <楼层目录> --work <目录>      把公开数据集转成 suite.json 里要的各个变体
  prepare-private --work <目录>                      从后台拉自采会话（需要 HPASS_URL / HPASS_TOKEN）
  run --tier pr|nightly --work <目录> --eval <hpass-eval> --out results.json
  report --results results.json [--baseline baseline.json] [--md report.md] [--fail-on-regression]
  baseline --results results.json --out baseline.json  用这次结果当新基线

指标（每个场景把所有测试会话、所有随机种子的点混在一起算）：
  median_cm / p75_cm（IPIN 竞赛口径）/ p90_cm、wrong_fix（已定位点里误差 > 5 m 的比例）、
  within2m、coverage（参考轨迹上给出定位的比例）、first_fix_m（首次定位前走了多远，中位）、
  fixed_share（定到过的回放比例）。

自采数据的协议：
  walk-once     每个建图会话单独建图（= 只走一遍），测试会话只用「不是同一天」的；Oriient「走一遍就能用」的对标指标
  all-builds    全部建图会话融合后测试
  track         全部建图会话融合 → 已知起点跟踪
  leave-one-out 留一法：一个地图有 ≥ 3 次能用的建图会话时，每次拿掉一个，用其余的建图，再用拿掉那次的真实 IMU + 磁力计
                （--motion pdr-imu）回放，参考轨迹 = 它自己的锚点 + ARKit 对齐。不用专门去走测试，小场地（办公室）也有分数
  office-carry  盲测机（摄像头关，按被测携带方式带）+ 真值伴随机（ARKit），敲击对时（bump_sync.py），真实 IMU 回放
                （--motion pdr-imu），冷启动和已知起点各一次；办公室指标（office_metrics.py）按携带方式 / 地图年龄聚合
站点在报告里只用代号：设置了 HPASS_LAB_SALT 时 = HMAC-SHA256(盐, map_id) 前 6 位（仓库公开，没有盐就猜不出），
否则退回老的 sha1(map_id) 前 6 位。

场景里写 "office_metrics": true 的（公开 public/imu/*），回放时多要一份逐点轨迹（hpass-eval --track-out），
另算 ≤1 m（按时间）、TTFF 等（结果的 "office" 键）；没有房间单元的地图房间类指标为空。
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import io
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SUITE = HERE / "suite.json"
sys.path.insert(0, str(HERE))

import office_metrics  # noqa: E402
MARKER = "<!-- hpass-lab -->"


# ───────────────────────── 指标 ─────────────────────────

def pct(sorted_vals, q):
    """和 hpass-eval 同一种分位数取法。"""
    if not sorted_vals:
        return None
    return sorted_vals[min(int((len(sorted_vals) - 1) * q + 0.5), len(sorted_vals) - 1)]


def metrics(reports: list[dict]) -> dict:
    """hpass-eval --json 的报告列表（可以来自多次调用）→ 场景指标。"""
    errs = sorted(e for r in reports for e in (r.get("errorsCm") or []))
    ref = sum(r.get("refPoints") or 0 for r in reports)
    ff = sorted(r["firstFixM"] for r in reports if r.get("firstFixM") is not None)
    n = len(reports)
    out = {
        "replays": n,
        "points": len(errs),
        "median_cm": pct(errs, 0.5),
        "p75_cm": pct(errs, 0.75),
        "p90_cm": pct(errs, 0.9),
        "wrong_fix": (sum(e > 500 for e in errs) / len(errs)) if errs else None,
        "within2m": (sum(e <= 200 for e in errs) / len(errs)) if errs else None,
        "coverage": (len(errs) / ref) if ref else None,
        "first_fix_m": pct(ff, 0.5),
        "fixed_share": (len(ff) / n) if n else None,
    }
    for k in ("median_cm", "p75_cm", "p90_cm", "first_fix_m"):
        if out[k] is not None:
            out[k] = round(out[k], 1)
    for k in ("wrong_fix", "within2m", "coverage", "fixed_share"):
        if out[k] is not None:
            out[k] = round(out[k], 4)
    return out


def ladder_level(m: dict, ladder: list[dict]) -> str | None:
    """满足的最高档位。所有门槛同时满足才算。"""
    best = None
    for lv in ladder:
        ok = True
        for k in ("median_cm", "p90_cm", "wrong_fix"):
            if k in lv and (m.get(k) is None or m[k] > lv[k]):
                ok = False
        if "coverage" in lv and (m.get("coverage") is None or m["coverage"] < lv["coverage"]):
            ok = False
        if ok:
            best = lv["name"]
    return best


LOWER_IS_BETTER = ("median_cm", "p75_cm", "p90_cm", "wrong_fix", "first_fix_m")


# 场景目标里不是指标的选项
TARGET_OPTIONS = ("no_fix_ok",)


def target_thresholds(target: dict) -> dict:
    """场景目标里的指标门槛（去掉 no_fix_ok 这类选项）"""
    return {k: v for k, v in target.items() if k not in TARGET_OPTIONS}


def target_metric(m: dict, k: str, no_fix_ok: bool = False):
    """场景目标里用的指标值。一个位置都没报时错定率没有定义：只有场景目标明说 "no_fix_ok": true
    （「宁可不报」，例如 App 冷启动配置档 MagneticConfig.liveColdStart 只靠地磁不报位置）才按 0 算；否则是 None，算没达标 / 退步。"""
    v = m.get(k)
    if v is None and no_fix_ok and k == "wrong_fix" and m.get("points") == 0 and m.get("replays"):
        return 0.0
    return v


def meets_target(m: dict, target: dict) -> bool:
    """场景自己的目标（suite.json 里场景的 "target"）：列出的门槛同时满足才算达标，没列的不看。"""
    ok0 = bool(target.get("no_fix_ok"))
    for k, thr in target_thresholds(target).items():
        v = target_metric(m, k, ok0)
        if v is None:
            return False
        if (v > thr) if k in LOWER_IS_BETTER else (v < thr):
            return False
    return True


def scenario_target(r: dict, suite: dict) -> dict | None:
    """结果条目（或场景定义）的场景目标；没有就是 None（用完整档位）。"""
    if r.get("target"):
        return r["target"]
    s = next((s for s in suite.get("scenarios", []) if s["id"] == r.get("id")), None)
    return (s or {}).get("target")


def compare(cur: dict, base: dict | None, tolerance: dict, keys=None, no_fix_ok: bool = False) -> dict:
    """逐项和基线比：regressions / improvements / changes 是 [(指标, 基线, 现在)]。
    keys 不是 None 时只有这些指标变差算退步，其余指标变差只记进 changes（只显示，不拦）——
    场景目标不看的指标（例如只看错定的冷启动场景的覆盖）按设计就会变。no_fix_ok 见 target_metric。"""
    res = {"regressions": [], "improvements": [], "changes": [], "new": base is None}
    if base is None:
        return res
    for k, rule in tolerance.items():
        b, c = base.get(k), cur.get(k)
        if keys is not None:
            b, c = target_metric(base, k, no_fix_ok), target_metric(cur, k, no_fix_ok)
        if b is None:
            continue
        bad = res["regressions"] if keys is None or k in keys else res["changes"]
        if c is None:
            bad.append((k, b, c))
            continue
        slack = abs(b) * rule.get("rel", 0) + rule.get("abs", 0)
        if rule["better"] == "lower":
            if c > b + slack:
                bad.append((k, b, c))
            elif c < b - slack:
                res["improvements"].append((k, b, c))
        else:
            if c < b - slack:
                bad.append((k, b, c))
            elif c > b + slack:
                res["improvements"].append((k, b, c))
    return res


# ───────────────────────── 场景 ─────────────────────────

def load_suite(path=SUITE) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def public_scenarios(suite: dict, tier: str) -> list[dict]:
    return [s for s in suite["scenarios"] if tier in s.get("tiers", [])]


DAY_RE = re.compile(r"(20\d{6})")


def session_day(name: str) -> str | None:
    m = DAY_RE.search(name)
    return m.group(1) if m else None


def walk_once_pairs(build: list[str], test: list[str]) -> list[tuple[str, list[str]]]:
    """每个建图会话配「不是同一天」的测试会话；全是同一天就退一步用除它以外的全部。"""
    out = []
    for b in build:
        bd = session_day(b)
        ts = [t for t in test if t != b and (bd is None or session_day(t) != bd)]
        if not ts:
            ts = [t for t in test if t != b]
        if ts:
            out.append((b, ts))
    return out


def site_label(map_id: str, salt: str | None = None) -> str:
    """站点代号。有盐（HPASS_LAB_SALT）时用 HMAC-SHA256：仓库公开，sha1(map_id) 拿已知的 map_id 一试就能对上，加盐才藏得住；
    没有盐时退回老的 sha1 前 6 位（老结果的代号不变）"""
    salt = os.environ.get("HPASS_LAB_SALT", "") if salt is None else salt
    if salt:
        return "site-" + hmac.new(salt.encode(), map_id.encode(), hashlib.sha256).hexdigest()[:6]
    return "site-" + hashlib.sha1(map_id.encode()).hexdigest()[:6]


# ───────────────────────── 准备数据 ─────────────────────────

CONVERT_KEY_FILE = ".convert-key"


def convert_key(conv: Path, args: list[str]) -> str:
    """转换缓存键：转换脚本内容 + 转换参数（不含输入 / 输出路径）。脚本或参数一变，缓存的转换结果就作废。"""
    h = hashlib.sha256(conv.read_bytes())
    h.update(b"\n" + json.dumps(args).encode())
    return h.hexdigest()[:16]


def prepare_public(suite: dict, ilc_floor: Path, work: Path, conv: Path | None = None, run=subprocess.run,
                   sim_conv: Path | None = None):
    """公开数据：ilc = 微软商场数据（MIT）转换；sim = tools/bench/sim_small.py 合成的小场地（不用任何外部数据）"""
    conv = conv or ROOT / "tools" / "bench" / "ilc_convert.py"
    sim_conv = sim_conv or ROOT / "tools" / "bench" / "sim_small.py"
    for name, ds in suite["datasets"].items():
        if ds.get("kind") not in ("ilc", "sim"):
            continue
        dst = work / "public" / name
        args = ["--drift", ds["drift"]]
        if ds.get("kind") == "sim":
            args += ["--layout", ds["layout"], "--seed", str(ds.get("seed", 1))]
        if ds.get("build_max"):
            args += ["--build-max", str(ds["build_max"])]
        if ds.get("flip_y"):
            args += ["--flip-y"]
        script = sim_conv if ds.get("kind") == "sim" else conv
        key = convert_key(script, args)
        key_file = dst / CONVERT_KEY_FILE
        if (dst / "manifest.json").exists():
            old = key_file.read_text().strip() if key_file.exists() else ""
            if old == key:
                print(f"[lab] {name} 已转换（{key}），跳过")
                continue
            print(f"[lab] {name} 的转换脚本或参数变了（{old or '无记录'} → {key}），重新转换")
        if dst.exists():
            shutil.rmtree(dst)
        cmd = ([sys.executable, str(script), str(dst)] if ds.get("kind") == "sim"
               else [sys.executable, str(conv), str(ilc_floor), str(dst)]) + args
        print("[lab] " + " ".join(cmd[1:]))
        run(cmd, check=True)
        dst.mkdir(parents=True, exist_ok=True)
        key_file.write_text(key + "\n")


def _req(url, token, path):
    r = urllib.request.Request(url + path, headers={"Authorization": "Bearer " + token, "User-Agent": "hpass-lab/1.0"})
    with urllib.request.urlopen(r, timeout=300) as resp:
        return resp.read()


def group_sessions(dirs: list[Path]) -> dict[str, dict]:
    """解压好的会话目录 → 按 map_id 分组的 {build, test, blind, companion}（每项 [(目录, meta)]）。
    伴随真值会话没写 map_id 时按 pair_id 跟着它的盲测会话走"""
    import office_carry
    groups: dict[str, dict] = {}
    pending_comp = []
    for d in dirs:
        mp = d / "meta.json"
        if not mp.exists():
            continue
        meta = json.loads(mp.read_text(encoding="utf-8"))
        kind = office_carry.classify(meta, d)
        if kind is None:
            continue
        if kind == "companion" and not meta.get("map_id"):
            pending_comp.append((d, meta))
            continue
        if not meta.get("map_id"):
            continue
        g = groups.setdefault(meta["map_id"], {"build": [], "test": [], "blind": [], "companion": []})
        g[kind].append((d, meta))
    for d, meta in pending_comp:
        for g in groups.values():
            if any(str(m.get("pair_id")) == str(meta["pair_id"]) for _, m in g["blind"]):
                g["companion"].append((d, meta))
                break
    return groups


LOO_MIN_BUILDS = 3


def prepare_site(mid: str, g: dict, work: Path, map_json: bytes) -> dict | None:
    """一个地图的会话 → <work>/private/<代号>/{map.json, build/, test/, office/}，返回清单条目（没有可用测试就 None）"""
    import office_carry
    label = site_label(mid)
    dst = work / "private" / label
    office, rejected = [], []
    if g["build"] and g["blind"]:
        pairs, unpaired = office_carry.pair_sessions(g["blind"], g["companion"])
        rejected += [{"name": n, "reason": "没有配对的真值伴随会话"} for n in unpaired]
        built = [office_carry.first_imu_ms(d) for d, _ in g["build"]]
        built_ms = max((t for t in built if t is not None), default=None)
        for b, c, bm, cm in pairs:
            info = office_carry.make_blind_session(b, c, bm, cm, dst / "office" / b.name, built_ms)
            if info["ok"]:
                office.append({k: info[k] for k in ("name", "carry_mode", "map_age_days", "start_heading")})
            else:
                rejected.append({"name": b.name, "reason": info["reason"]})
    loo = len(g["build"]) >= LOO_MIN_BUILDS
    if not g["build"] or not (g["test"] or office or loo):
        return None
    for kind in ("build", "test"):
        (dst / kind).mkdir(parents=True, exist_ok=True)
        for d, _ in g[kind]:
            tgt = dst / kind / d.name
            if not tgt.exists():
                shutil.copytree(d, tgt)
    (dst / "map.json").write_bytes(map_json)
    entry = {"label": label, "build": sorted(d.name for d, _ in g["build"]), "test": sorted(d.name for d, _ in g["test"])}
    if loo:
        entry["loo"] = True
    if office or rejected:
        entry["office"] = sorted(office, key=lambda o: o["name"])
        entry["office_rejected"] = rejected
    print(f"[lab] {label}：建图 {len(g['build'])}，测试 {len(g['test'])}，盲测 {len(office)}（不用 {len(rejected)}）"
          + ("，留一法" if loo else ""))
    for r in rejected:
        print(f"[lab]   盲测不用：{r['reason']}")
    return entry


def backend_exclude(url, token) -> set[str]:
    """后台的排除名单（/api/config/exclude，云端建图也按它排除，比如带磁吸配件采的那几次）；拿不到就空"""
    try:
        return {str(n) for n in json.loads(_req(url, token, "/api/config/exclude"))}
    except Exception as e:  # noqa: BLE001
        print(f"[lab] 拿不到排除名单（{e}），不排除")
        return set()


def session_excluded(name: str, exclude: set[str]) -> bool:
    """name = 后台的 zip 名（ios_survey_x.zip / mag_x_files.zip）；排除名单里写不写 .zip 都认"""
    base = name[:-4] if name.endswith(".zip") else name
    return name in exclude or base in exclude


def usable_dirs(dirs: list[Path]) -> list[Path]:
    """App 采集时质量打分判为整个不能用的会话不要（和云端建图同一个规则，cloud_build_lib.quality_rejected）"""
    sys.path.insert(0, str(ROOT / "tools"))
    from cloud_build_lib import quality_rejected
    out = []
    for d in dirs:
        why = quality_rejected(str(d))
        if why:
            print(f"[lab] 不用 {d.name}：采集质量不合格（{why}）")
            continue
        out.append(d)
    return out


def loo_folds(builds: list[str]) -> list[tuple[list[str], str]]:
    """留一法：[(其余建图会话, 拿掉的那次)]"""
    return [([b for b in builds if b != t], t) for t in builds]


def loo_runs(eval_cmd, d: Path, site: dict, runs: int, flags: list[str]):
    """留一法：每折一次 hpass-eval（建图 = 其余，测试 = 拿掉的那次），报告合并；逐点轨迹合并后算办公室指标"""
    reps, track = [], {}
    for others, held in loo_folds(site["build"]):
        reps += run_eval(eval_cmd, d, ",".join("build/" + b for b in others), "build/" + held, runs, flags, track=track)
    return reps, track_office(track, d)


def prepare_private(work: Path) -> list[dict]:
    """后台的会话按地图分组，写 <work>/private/<代号>/{map.json, build/, test/, office/}。
    office/ = office-carry 协议的盲测会话（配好真值伴随会话、敲击对时、写好 truth.csv），见 office_carry.py。"""
    url = os.environ.get("HPASS_URL", "").rstrip("/")
    token = os.environ.get("HPASS_TOKEN", "")
    if not url or not token:
        print("[lab] 没有 HPASS_URL / HPASS_TOKEN，跳过自采数据")
        return []
    if not url.startswith("http"):
        url = "https://" + url
    raw = work / "private-raw"
    raw.mkdir(parents=True, exist_ok=True)
    exclude = backend_exclude(url, token)
    dirs = []
    for o in json.loads(_req(url, token, "/api/sessions")):
        name = o["key"].split("/", 1)[1]
        if session_excluded(name, exclude):
            continue
        z = zipfile.ZipFile(io.BytesIO(_req(url, token, "/api/sessions/" + urllib.parse.quote(name))))
        z.extractall(raw)
        dirs += [raw / os.path.dirname(m) for m in z.namelist() if m.endswith("meta.json") and m.count("/") == 1]
    dirs = usable_dirs(dirs)
    manifest = []
    for mid, g in sorted(group_sessions(dirs).items()):
        if not g["build"]:
            continue
        try:
            map_json = _req(url, token, "/api/maps/" + urllib.parse.quote(mid))
        except urllib.error.HTTPError:
            continue
        entry = prepare_site(mid, g, work, map_json)
        if entry:
            manifest.append(entry)
    (work / "private").mkdir(parents=True, exist_ok=True)
    (work / "private" / "manifest.json").write_text(json.dumps(manifest, indent=1), encoding="utf-8")
    return manifest


# ───────────────────────── 回放 ─────────────────────────

def run_eval(eval_cmd: list[str], cwd: Path, build: str, test: str, runs: int, flags: list[str],
             timeout_s: float = 3600, track: dict | None = None) -> list[dict]:
    """track 不是 None 时多要一份逐点轨迹（hpass-eval --track-out），按 (会话, 第几次) 合并进 track"""
    with tempfile.TemporaryDirectory() as td:
        out = Path(td) / "r.json"
        tr = Path(td) / "track.csv"
        cmd = eval_cmd + ["--map", "map.json", "--build", build, "--test", test, "--runs", str(runs),
                          *flags, "--json", str(out)] + (["--track-out", str(tr)] if track is not None else [])
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, encoding="utf-8", errors="replace",
                           timeout=timeout_s)
        if p.returncode != 0 or not out.exists():
            tail = (p.stdout or "")[-1500:] + (p.stderr or "")[-1500:]
            raise RuntimeError(f"hpass-eval 失败（退出码 {p.returncode}）：{tail}")
        # 建图摘要（会话数、合格数、连通分量、哪些会话不在主体里）进 Lab 日志
        for line in (p.stdout or "").splitlines():
            if line.startswith("建图："):
                print(f"[lab]   {line}")
        if track is not None and tr.exists():
            track.update(office_metrics.load_track(tr))
        return json.loads(out.read_text(encoding="utf-8"))


def track_office(track: dict, d: Path, meta: dict | None = None) -> dict | None:
    """逐点轨迹 + 数据集的 map.json → 办公室指标（office_metrics.compute）；没有轨迹（例如假的 hpass-eval）就 None"""
    if not track:
        return None
    try:
        m = json.loads((d / "map.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        m = {}
    return office_metrics.compute(track, m, meta)


def office_runs(eval_cmd, d: Path, site: dict, runs: int, flags: list[str], oracle: bool):
    """office-carry：盲测会话按起步朝向分两批跑（已知起点时 texting 等给真值朝向，其余整圆），合并成一个场景"""
    reps, track = [], {}
    groups: dict[str, list[str]] = {}
    for o in site["office"]:
        groups.setdefault(o.get("start_heading") or "unknown", []).append(o["name"])
    for sh, names in sorted(groups.items()):
        fl = list(flags) + (["--oracle-start", "--start-heading", sh] if oracle else [])
        reps += run_eval(eval_cmd, d, ",".join("build/" + b for b in site["build"]), ",".join("office/" + n for n in names),
                         runs, fl, track=track)
    meta = {o["name"]: {"carry_mode": o.get("carry_mode"), "map_age_days": o.get("map_age_days")} for o in site["office"]}
    return reps, track_office(track, d, meta)


def run_suite(suite: dict, tier: str, work: Path, eval_cmd: list[str], only: str | None = None,
              jobs: int = 1) -> dict:
    """jobs > 1 时各场景并行回放（本地多核用；CI 默认 1）。结果顺序和场景顺序一致。"""
    runs = suite["runs"][tier]
    tasks = []

    def record(sid, title, gate, fn, extra=None):
        if only and only not in sid:
            return
        tasks.append((sid, title, gate, fn, extra))

    def execute(sid, title, gate, fn, extra):
        t0 = time.time()
        entry = {"id": sid, "title": title, "gate": gate}
        try:
            reps = fn()
            if isinstance(reps, tuple):                   # (报告, 办公室指标)
                reps, office = reps
                if office is not None:
                    entry["office"] = office
            entry["metrics"] = metrics(reps)
        except Exception as e:  # noqa: BLE001 — 失败本身就是要报告的结果
            entry["error"] = str(e)[:3000]
        entry["seconds"] = round(time.time() - t0, 1)
        if extra:
            entry.update(extra)
        print(f"[lab] {sid}：{entry.get('metrics') or entry.get('error')}（{entry['seconds']} s）", flush=True)
        return entry

    def public_fn(d, s):
        if not s.get("office_metrics"):
            return run_eval(eval_cmd, d, "build", "test", runs, s["flags"])
        track: dict = {}
        reps = run_eval(eval_cmd, d, "build", "test", runs, s["flags"], track=track)
        return reps, track_office(track, d)

    for s in public_scenarios(suite, tier):
        d = work / "public" / s["dataset"]
        record(s["id"], s["title"], s.get("gate", False), lambda d=d, s=s: public_fn(d, s),
               {"dataset": s["dataset"], **({"target": s["target"]} if s.get("target") else {})})

    priv = suite.get("private", {})
    mf = work / "private" / "manifest.json"
    if tier in priv.get("tiers", []) and mf.exists():
        for site in json.loads(mf.read_text(encoding="utf-8")):
            d = work / "private" / site["label"]
            for proto, pcfg in priv["protocols"].items():
                sid = f"private/{site['label']}/{proto}"
                if proto == "office-carry":
                    if not site.get("office"):
                        continue
                    for sub, oracle in (("track", True), ("cold", False)):
                        fl = pcfg["flags"] + (pcfg.get("track_flags", []) if oracle else pcfg.get("cold_flags", []))
                        record(f"{sid}/{sub}", f"{pcfg['title']}（{'已知起点' if oracle else '冷启动'}）", priv.get("gate", False),
                               lambda d=d, site=site, fl=fl, oracle=oracle: office_runs(eval_cmd, d, site, runs, fl, oracle),
                               {"office_sessions": len(site["office"])})
                    continue
                if proto == "leave-one-out":
                    if not site.get("loo"):
                        continue
                    for sub, fl in (("track", pcfg["flags"] + pcfg.get("track_flags", [])),
                                    ("cold", pcfg["flags"] + pcfg.get("cold_flags", []))):
                        record(f"{sid}/{sub}", f"{pcfg['title']}（{'已知起点' if sub == 'track' else '冷启动'}）",
                               pcfg.get("gate", priv.get("gate", False)),
                               lambda d=d, site=site, fl=fl: loo_runs(eval_cmd, d, site, runs, fl),
                               {"loo_folds": len(site["build"])})
                    continue
                if not site.get("test"):
                    continue
                if proto == "walk-once":
                    pairs = walk_once_pairs(site["build"], site["test"])

                    def fn(d=d, pairs=pairs, pcfg=pcfg):
                        reps = []
                        for b, ts in pairs:
                            reps += run_eval(eval_cmd, d, "build/" + b, ",".join("test/" + t for t in ts),
                                             runs, pcfg["flags"])
                        return reps
                    record(sid, pcfg["title"], priv.get("gate", False), fn, {"pairs": len(pairs)})
                else:
                    record(sid, pcfg["title"], priv.get("gate", False),
                           lambda d=d, site=site, pcfg=pcfg: run_eval(
                               eval_cmd, d, ",".join("build/" + b for b in site["build"]),
                               ",".join("test/" + t for t in site["test"]), runs, pcfg["flags"]))
    if jobs > 1 and len(tasks) > 1:
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=jobs) as ex:
            results = list(ex.map(lambda t: execute(*t), tasks))
    else:
        results = [execute(*t) for t in tasks]
    return {"kind": "lab", "tier": tier, "runs": runs, "commit": os.environ.get("GITHUB_SHA", ""),
            "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "results": results}


# ───────────────────────── 报告 ─────────────────────────

def _fmt(k, v):
    if v is None:
        return "—"
    if k in ("wrong_fix", "within2m", "coverage", "fixed_share"):
        return f"{v * 100:.0f}%"
    if k.endswith("_cm"):
        return f"{v / 100:.1f} m"
    if k.endswith("_m"):
        return f"{v:.1f} m"
    return str(v)


def target_text(target: dict) -> str:
    s = "、".join(f"{NAMES[k]} {'≤' if k in LOWER_IS_BETTER else '≥'} {_fmt(k, v)}" for k, v in target_thresholds(target).items())
    return s + ("；不报位置也算" if target.get("no_fix_ok") else "")


NAMES = {"median_cm": "中位", "p75_cm": "P75", "p90_cm": "P90", "wrong_fix": "错定", "coverage": "覆盖",
         "first_fix_m": "首次定位", "fixed_share": "定到率", "within2m": "≤2 m"}


def build_report(res: dict, baseline: dict | None, suite: dict) -> tuple[str, bool]:
    """返回 (markdown, 是否有退步)。"""
    base_map = {r["id"]: r.get("metrics") for r in (baseline or {}).get("results", [])}
    rows, notes = [], []
    regressed = False
    targets = suite["ladder"][-1]
    for r in res["results"]:
        m = r.get("metrics")
        if m is None:
            rows.append(f"| {r['title']}<br>`{r['id']}` | ❌ 运行失败 | | | | | | |")
            if r.get("gate") and r["id"] in base_map:
                regressed = True
            notes.append(f"- `{r['id']}` 运行失败：`{(r.get('error') or '')[:300]}`")
            continue
        target = scenario_target(r, suite)
        if r["id"] in base_map:
            cmp_ = compare(m, base_map[r["id"]], suite["tolerance"], keys=set(target_thresholds(target)) if target else None,
                           no_fix_ok=bool((target or {}).get("no_fix_ok")))
        else:
            cmp_ = {"new": True, "regressions": [], "improvements": [], "changes": []}
        if r.get("gate") and cmp_["regressions"]:
            regressed = True
        if cmp_["new"]:
            verdict = "🆕 无基线"
        elif cmp_["regressions"]:
            verdict = "🔴 退步：" + "，".join(f"{NAMES[k]} {_fmt(k, b)}→{_fmt(k, c)}" for k, b, c in cmp_["regressions"])
        elif cmp_["improvements"]:
            verdict = "🟢 改善：" + "，".join(f"{NAMES[k]} {_fmt(k, b)}→{_fmt(k, c)}" for k, b, c in cmp_["improvements"])
        else:
            verdict = "⚪ 持平"
        if cmp_.get("changes"):
            verdict += "（目标不看：" + "，".join(f"{NAMES[k]} {_fmt(k, b)}→{_fmt(k, c)}" for k, b, c in cmp_["changes"]) + "）"
        gap = []
        if target:
            # 场景自己的目标（例如只靠地磁冷启动只看错定）：档位列只写达没达标，差距按目标算
            level = ("✅ 达标" if meets_target(m, target) else "未达标") + f"（场景目标：{target_text(target)}）"
            if m.get("points") == 0:
                level += "，没有报位置"
            for k, thr in target_thresholds(target).items():
                v = target_metric(m, k, bool(target.get("no_fix_ok")))
                if v is not None and ((v > thr) if k in LOWER_IS_BETTER else (v < thr)):
                    gap.append(f"{NAMES[k]} {_fmt(k, v)}")
        else:
            level = ladder_level(m, suite["ladder"]) or "未达「可用」"
            if m.get("median_cm") is not None and m["median_cm"] > targets["median_cm"]:
                gap.append(f"中位差 {(m['median_cm'] - targets['median_cm']) / 100:.1f} m")
            if m.get("wrong_fix") is not None and m["wrong_fix"] > targets["wrong_fix"]:
                gap.append(f"错定多 {(m['wrong_fix'] - targets['wrong_fix']) * 100:.0f} 点")
        rows.append(f"| {r['title']}<br>`{r['id']}` | {_fmt('median_cm', m['median_cm'])} | {_fmt('p75_cm', m['p75_cm'])} | "
                    f"{_fmt('p90_cm', m['p90_cm'])} | {_fmt('wrong_fix', m['wrong_fix'])} | {_fmt('coverage', m['coverage'])} | "
                    f"{_fmt('first_fix_m', m['first_fix_m'])} | {level}{'（' + '，'.join(gap) + '）' if gap else ''}<br>{verdict} |")
    head = "🔴 **有退步**" if regressed else ("🟢 **没有退步**" if baseline else "🆕 **还没有基线**（这次结果可以作为第一版基线）")
    md = [MARKER, f"## 定位实验室（{res['tier']}，每场景 {res['runs']} 个随机种子）", "",
          f"{head}　·　提交 `{(res.get('commit') or 'local')[:7]}`", "",
          "| 场景 | 中位 | P75 | P90 | 错定 >5 m | 覆盖 | 首次定位 | 档位 / 离「对标 Oriient」还差 · 对比基线 |",
          "|---|---|---|---|---|---|---|---|", *rows, ""]
    office_rows = [office_row(r, suite) for r in res["results"] if r.get("office")]
    if office_rows:
        md += ["**办公室指标**（office_metrics.py，1 Hz 网格；房间类指标只有带房间单元的地图才有）", "",
               "| 场景 | 房间判对（有定位 / 全部时间） | 错房间 相邻 / 远 | 过门延迟 P50 / P90 · 漏 | ≤1 m（点 / 时间） | P50 / P90 | 覆盖 | TTFF 时间 / 路程 · 定到率 | 档位 |",
               "|---|---|---|---|---|---|---|---|---|", *office_rows, ""]
    if notes:
        md += ["**失败详情**", *notes, ""]
    lad = "；".join(f"{lv['name']}：中位 ≤ {lv['median_cm'] / 100:g} m、P90 ≤ {lv['p90_cm'] / 100:g} m、错定 ≤ {lv['wrong_fix'] * 100:g}%、"
                   f"覆盖 ≥ {lv['coverage'] * 100:g}%" for lv in suite["ladder"])
    md += ["<details><summary>口径说明</summary>", "",
           f"- 档位：{lad}。",
           "- 有「场景目标」的场景（例如只靠地磁冷启动：只看错定 ≤ 20%，不要求覆盖）只按自己的目标判达标，"
           "退步也只看目标里的指标；其余指标的变化写在「目标不看」里，只显示不拦。",
           "- 公开数据（Microsoft Indoor Location Competition 2.0 商场一层）的测试位姿是合成漂移，真值是稀疏路标插值，只适合比较版本之间的相对变化。",
           "- 自采数据的站点只用哈希代号。`walk-once` = 每个建图会话单独建图（只走一遍），换一天的测试会话来测。",
           "- 退步判定：中位、P90 变差超过 15% + 0.3 / 0.6 m，错定率多 5 个点，覆盖少 7 个点，定到率少 10 个点。",
           "", "</details>"]
    return "\n".join(md), regressed


def office_level(o: dict, ladder: list[dict]) -> str | None:
    """办公室档位（suite.json office_ladder）：键 min_<指标> / max_<指标>，列出的门槛同时满足才算；
    指标没有（例如没有房间单元）就不算达到"""
    best = None
    for lv in ladder:
        ok = True
        for k, thr in lv.items():
            if k == "name":
                continue
            higher = k.startswith("min_")
            v = o.get(k[4:])
            if v is None or (v < thr if higher else v > thr):
                ok = False
        if ok:
            best = lv["name"]
    return best


def office_row(r: dict, suite: dict) -> str:
    o = r["office"].get("all", {})

    def pc(k):
        return "—" if o.get(k) is None else f"{o[k] * 100:.0f}%"

    def m(k):
        return "—" if o.get(k) is None else f"{o[k] / 100:.1f} m"

    def sec(k):
        return "—" if o.get(k) is None else f"{o[k]:.0f} s"
    lv = office_level(o, suite.get("office_ladder", [])) or "未达「可用」"
    ttff_m = "—" if o.get("ttff_m_p50") is None else f"{o['ttff_m_p50']:.0f} m"
    return (f"| `{r['id']}` | {pc('room_correct')} / {pc('room_correct_all')} | {pc('wrong_room_adjacent')} / {pc('wrong_room_far')} | "
            f"{sec('door_latency_p50_s')} / {sec('door_latency_p90_s')} · {pc('door_miss')} | {pc('within1m_points')} / {pc('within1m_time')} | "
            f"{m('p50_cm')} / {m('p90_cm')} | {pc('coverage')} | {sec('ttff_s_p50')} / {ttff_m} · {pc('ttff_rate')} | {lv} |")


# ───────────────────────── 命令行 ─────────────────────────

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prepare-public")
    p.add_argument("--ilc", type=Path, required=True)
    p.add_argument("--work", type=Path, required=True)
    p = sub.add_parser("prepare-private")
    p.add_argument("--work", type=Path, required=True)
    p = sub.add_parser("run")
    p.add_argument("--tier", choices=["pr", "nightly"], default="pr")
    p.add_argument("--work", type=Path, required=True)
    p.add_argument("--eval", required=True, help="hpass-eval 可执行文件")
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--only", help="只跑 id 含这个字符串的场景")
    p.add_argument("--jobs", type=int, default=1, help="并行回放的场景数（本地多核用）")
    p = sub.add_parser("report")
    p.add_argument("--results", type=Path, required=True)
    p.add_argument("--baseline", type=Path)
    p.add_argument("--md", type=Path)
    p.add_argument("--fail-on-regression", action="store_true")
    p = sub.add_parser("baseline")
    p.add_argument("--results", type=Path, required=True)
    p.add_argument("--out", type=Path, default=HERE / "baseline.json")
    a = ap.parse_args(argv)
    suite = load_suite()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")     # Windows 控制台默认 GBK，打不出表情符号

    if a.cmd == "prepare-public":
        prepare_public(suite, a.ilc, a.work)
    elif a.cmd == "prepare-private":
        prepare_private(a.work)
    elif a.cmd == "run":
        res = run_suite(suite, a.tier, a.work, [str(Path(a.eval).resolve())], a.only, a.jobs)
        a.out.write_text(json.dumps(res, ensure_ascii=False, indent=1), encoding="utf-8")
    elif a.cmd == "report":
        res = json.loads(a.results.read_text(encoding="utf-8"))
        base = None
        if a.baseline and a.baseline.exists():
            base = json.loads(a.baseline.read_text(encoding="utf-8"))
            if not base.get("results"):
                base = None
        md, regressed = build_report(res, base, suite)
        if a.md:
            a.md.write_text(md, encoding="utf-8")
        print(md)
        if regressed and a.fail_on_regression:
            return 1
    elif a.cmd == "baseline":
        res = json.loads(a.results.read_text(encoding="utf-8"))
        keep = {"tier": res["tier"], "runs": res["runs"], "commit": res.get("commit"), "created": res.get("created"),
                "results": [{"id": r["id"], "metrics": r["metrics"], **({"office": r["office"]} if r.get("office") else {})}
                            for r in res["results"] if r.get("metrics")]}
        a.out.write_text(json.dumps(keep, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(f"基线已写入 {a.out}（{len(keep['results'])} 个场景）")
    return 0


if __name__ == "__main__":
    sys.exit(main())

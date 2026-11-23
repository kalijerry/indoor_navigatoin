"""定位实验室 lab.py 的单元测试：指标、档位、基线对比、走一遍协议的配对、报告，以及用假的 hpass-eval 跑通整条流程。"""
import json
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "lab"))

import lab  # noqa: E402

SUITE = lab.load_suite()


def rep(errs, ref=None, first_fix=10.0):
    return {"errorsCm": errs, "refPoints": ref if ref is not None else len(errs), "firstFixM": first_fix}


class MetricsTests(unittest.TestCase):
    def test_percentiles_and_shares(self):
        m = lab.metrics([rep([100] * 8 + [600, 700], ref=20), rep([], ref=0, first_fix=None)])
        self.assertEqual(m["replays"], 2)
        self.assertEqual(m["median_cm"], 100)
        self.assertEqual(m["p90_cm"], 600)        # 最近秩：索引 int(9×0.9+0.5) = 8
        self.assertAlmostEqual(m["wrong_fix"], 0.2)
        self.assertAlmostEqual(m["coverage"], 0.5)
        self.assertAlmostEqual(m["fixed_share"], 0.5)
        self.assertEqual(m["first_fix_m"], 10.0)

    def test_empty(self):
        m = lab.metrics([rep([], ref=5, first_fix=None)])
        self.assertIsNone(m["median_cm"])
        self.assertEqual(m["coverage"], 0)
        self.assertEqual(m["fixed_share"], 0)

    def test_robustness_metrics(self):
        r = rep([50, 100, 300, 900], ref=4)
        r.update({"uncertaintiesCm": [100, 100, 100, -1], "estPathCm": 600.0, "refPathFixCm": 400.0, "bigJumps": 1})
        m = lab.metrics([r])
        # 误差 / 1σ：0.5、1、3（第四个点没报不确定度，不算）
        self.assertEqual(m["unc_ratio_p50"], 1.0)
        self.assertAlmostEqual(m["within_1sigma"], 2 / 3, places=3)
        self.assertAlmostEqual(m["within_2sigma"], 2 / 3, places=3)
        self.assertEqual(m["path_ratio"], 1.5)
        self.assertEqual(m["jumps3m_per_100m"], 25.0)     # 1 次 / 4 m 参考路程

    def test_robustness_absent_in_old_reports(self):
        m = lab.metrics([rep([100, 200])])
        for k in ("unc_ratio_p50", "within_1sigma", "within_2sigma", "path_ratio", "jumps3m_per_100m"):
            self.assertIsNone(m[k])

    def test_robustness_is_not_a_gate(self):
        base = {"median_cm": 300, "p90_cm": 800, "wrong_fix": 0.2, "coverage": 0.8, "fixed_share": 1.0,
                "unc_ratio_p50": 0.8, "path_ratio": 1.1}
        c = lab.compare(dict(base, unc_ratio_p50=3.0, path_ratio=2.5), base, SUITE["tolerance"])
        self.assertFalse(c["regressions"])

    def test_ladder(self):
        ladder = SUITE["ladder"]
        self.assertEqual(lab.ladder_level({"median_cm": 120, "p90_cm": 250, "wrong_fix": 0.02, "coverage": 0.9}, ladder),
                         "对标 Oriient")
        self.assertEqual(lab.ladder_level({"median_cm": 250, "p90_cm": 500, "wrong_fix": 0.1, "coverage": 0.9}, ladder), "可用")
        # 覆盖太低不算，防止「只在少数点上报位置」刷指标
        self.assertIsNone(lab.ladder_level({"median_cm": 100, "p90_cm": 200, "wrong_fix": 0, "coverage": 0.1}, ladder))


class CompareTests(unittest.TestCase):
    tol = SUITE["tolerance"]

    def test_regression_and_improvement(self):
        base = {"median_cm": 300, "p90_cm": 800, "wrong_fix": 0.2, "coverage": 0.8, "fixed_share": 1.0}
        worse = dict(base, median_cm=400, wrong_fix=0.3)
        c = lab.compare(worse, base, self.tol)
        self.assertEqual({k for k, _, _ in c["regressions"]}, {"median_cm", "wrong_fix"})
        better = dict(base, p90_cm=500, coverage=0.95)
        c = lab.compare(better, base, self.tol)
        self.assertFalse(c["regressions"])
        self.assertEqual({k for k, _, _ in c["improvements"]}, {"p90_cm", "coverage"})

    def test_noise_within_tolerance_is_flat(self):
        base = {"median_cm": 300, "p90_cm": 800, "wrong_fix": 0.2, "coverage": 0.8, "fixed_share": 1.0}
        c = lab.compare(dict(base, median_cm=340, wrong_fix=0.23), base, self.tol)
        self.assertFalse(c["regressions"])
        self.assertFalse(c["improvements"])

    def test_losing_a_metric_is_a_regression(self):
        c = lab.compare({"median_cm": None}, {"median_cm": 300}, {"median_cm": self.tol["median_cm"]})
        self.assertEqual(len(c["regressions"]), 1)


class ScenarioTargetTests(unittest.TestCase):
    """场景自己的目标（suite.json 场景里的 "target"）：只按列出的指标判达标、判退步。"""
    tol = SUITE["tolerance"]
    target = {"wrong_fix": 0.2, "no_fix_ok": True}

    def test_suite_cold_mag_scenarios_judge_wrong_fix_only(self):
        by_id = {s["id"]: s for s in SUITE["scenarios"]}
        for sid in ("public/pdr/cold-mag", "public/vio/cold-mag"):
            self.assertEqual(by_id[sid].get("target"), {"wrong_fix": 0.2, "no_fix_ok": True})
            # 「不报位置」是明说的产品开关（App 冷启动配置档 MagneticConfig.liveColdStart），不是藏在收敛门里的
            self.assertIn("--no-mag-only-cold-fix", by_id[sid]["flags"])
            # 一个位置都不报的场景按构造只能「达标」：不当退步门槛
            self.assertFalse(by_id[sid]["gate"])
        # 冷启动搜索本身（照常报位置）才是拦退步的：共用的冷启动代码坏了 PR 就失败
        for sid in ("public/pdr/cold-mag-search", "public/vio/cold-mag-search"):
            self.assertTrue(by_id[sid]["gate"])
            self.assertNotIn("--no-mag-only-cold-fix", by_id[sid]["flags"])
            self.assertIsNone(by_id[sid].get("target"))
        self.assertIn("pr", by_id["public/pdr/cold-mag-search"]["tiers"])
        # 凡是拦退步的场景都可能报位置（没有 no_fix_ok）
        for s in SUITE["scenarios"]:
            if s.get("gate"):
                self.assertFalse((s.get("target") or {}).get("no_fix_ok"), s["id"])
        # 跟踪场景没有场景目标，照旧用完整档位
        self.assertIsNone(by_id["public/pdr/track-mag"].get("target"))

    def test_meets_target_ignores_unlisted_metrics(self):
        self.assertTrue(lab.meets_target({"median_cm": 5000, "p90_cm": 9000, "wrong_fix": 0.15, "coverage": 0.01},
                                         self.target))
        self.assertFalse(lab.meets_target({"median_cm": 100, "wrong_fix": 0.25, "coverage": 0.9}, self.target))
        self.assertTrue(lab.meets_target({"coverage": 0.6, "median_cm": 250}, {"coverage": 0.5, "median_cm": 300}))
        self.assertFalse(lab.meets_target({"coverage": 0.4, "median_cm": 250}, {"coverage": 0.5, "median_cm": 300}))

    def test_no_fix_at_all_counts_as_zero_wrong_only_when_target_says_so(self):
        m = lab.metrics([rep([], ref=50, first_fix=None)])
        self.assertIsNone(m["wrong_fix"])
        self.assertTrue(lab.meets_target(m, self.target))
        # 目标没说 no_fix_ok：一个位置都没报 = 没量到，不算达标
        self.assertFalse(lab.meets_target(m, {"wrong_fix": 0.2}))
        self.assertIn("不报位置也算", lab.target_text(self.target))
        self.assertNotIn("no_fix_ok", lab.target_text(self.target))
        # 一次回放都没有（跑失败）不算达标
        self.assertFalse(lab.meets_target({"wrong_fix": None, "points": 0, "replays": 0}, self.target))
        # 没有场景目标时仍按完整档位：没报位置 = 未达「可用」
        self.assertIsNone(lab.ladder_level(m, SUITE["ladder"]))

    def test_coverage_drop_is_not_a_regression_when_target_excludes_it(self):
        base = {"median_cm": 7000, "p90_cm": 13000, "wrong_fix": 0.98, "coverage": 0.65, "fixed_share": 1.0,
                "points": 1000, "replays": 5}
        cur = dict(base, median_cm=None, p90_cm=None, wrong_fix=None, coverage=0.0, fixed_share=0.0, points=0)
        c = lab.compare(cur, base, self.tol, keys={"wrong_fix"}, no_fix_ok=True)
        self.assertFalse(c["regressions"])
        self.assertIn("wrong_fix", {k for k, _, _ in c["improvements"]})
        self.assertEqual({k for k, _, _ in c["changes"]}, {"median_cm", "p90_cm", "coverage", "fixed_share"})
        # 同样的变化，没有场景目标时就是退步
        self.assertTrue(lab.compare(cur, base, self.tol)["regressions"])
        # 目标只看错定、但没说 no_fix_ok：从有定位变成一个都不报，错定「没量到」= 退步
        c = lab.compare(cur, base, self.tol, keys={"wrong_fix"})
        self.assertEqual([k for k, _, _ in c["regressions"]], ["wrong_fix"])

    def test_wrong_fix_rising_is_still_a_regression(self):
        base = {"wrong_fix": 0.1, "coverage": 0.1, "points": 100, "replays": 5}
        c = lab.compare(dict(base, wrong_fix=0.3), base, self.tol, keys={"wrong_fix"}, no_fix_ok=True)
        self.assertEqual([k for k, _, _ in c["regressions"]], ["wrong_fix"])

    def test_report_uses_scenario_target(self):
        res = {"tier": "nightly", "runs": 5, "results": [
            {"id": "public/pdr/cold-mag", "title": "冷启动", "gate": True, "target": {"wrong_fix": 0.2, "no_fix_ok": True},
             "metrics": lab.metrics([rep([], ref=50, first_fix=None)])},
            {"id": "public/pdr/track-mag", "title": "跟踪", "gate": True,
             "metrics": lab.metrics([rep([100] * 10)])}]}
        base = {"results": [
            {"id": "public/pdr/cold-mag", "metrics": lab.metrics([rep([9000] * 30 + [100], ref=50)])},
            {"id": "public/pdr/track-mag", "metrics": lab.metrics([rep([100] * 10)])}]}
        md, regressed = lab.build_report(res, base, SUITE)
        self.assertFalse(regressed)
        cold = next(line for line in md.splitlines() if "public/pdr/cold-mag" in line)
        self.assertIn("✅ 达标", cold)
        self.assertIn("没有报位置", cold)
        self.assertIn("目标不看", cold)
        self.assertNotIn("未达「可用」", cold)
        track = next(line for line in md.splitlines() if "public/pdr/track-mag" in line)
        self.assertIn("对标 Oriient", track)
        # 结果里没带 target（旧结果文件）时从 suite.json 查
        del res["results"][0]["target"]
        md, _ = lab.build_report(res, base, SUITE)
        self.assertIn("✅ 达标", next(line for line in md.splitlines() if "public/pdr/cold-mag" in line))


class ProtocolTests(unittest.TestCase):
    def test_walk_once_uses_other_days(self):
        build = ["ios_survey_20261006_114810", "ios_survey_20261007_091813"]
        test = ["ios_survey_20261006_120000", "ios_survey_20261008_100000"]
        pairs = dict(lab.walk_once_pairs(build, test))
        self.assertEqual(pairs["ios_survey_20261006_114810"], ["ios_survey_20261008_100000"])
        self.assertEqual(pairs["ios_survey_20261007_091813"], test)

    def test_walk_once_falls_back_when_same_day(self):
        pairs = lab.walk_once_pairs(["s_20261006_a"], ["s_20261006_b"])
        self.assertEqual(pairs, [("s_20261006_a", ["s_20261006_b"])])

    def test_site_label_hides_id(self):
        lbl = lab.site_label("site-alpha-secret")
        self.assertTrue(lbl.startswith("site-"))
        self.assertNotIn("alpha", lbl)
        self.assertEqual(lbl, lab.site_label("site-alpha-secret"))


class PreparePublicCacheTests(unittest.TestCase):
    """转换结果按「转换脚本内容 + 参数」缓存：没变就跳过，变了就重转。"""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.conv = self.tmp / "conv.py"
        self.conv.write_text("# v1\n")
        self.work = self.tmp / "work"
        self.suite = {"datasets": {"d": {"kind": "ilc", "drift": "pdr"}, "x": {"kind": "private"}}}
        self.calls = []

    def fake_run(self, cmd, check):
        self.calls.append(cmd)
        dst = Path(cmd[3])
        dst.mkdir(parents=True, exist_ok=True)
        (dst / "manifest.json").write_text("{}")

    def prep(self):
        lab.prepare_public(self.suite, self.tmp / "ilc", self.work, conv=self.conv, run=self.fake_run)

    def test_skips_when_unchanged_and_reconverts_on_change(self):
        self.prep()
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0][4:], ["--drift", "pdr"])
        self.prep()
        self.assertEqual(len(self.calls), 1)
        self.conv.write_text("# v2\n")
        self.prep()
        self.assertEqual(len(self.calls), 2)
        self.suite["datasets"]["d"]["build_max"] = 5
        self.prep()
        self.assertEqual(len(self.calls), 3)
        self.assertEqual(self.calls[2][4:], ["--drift", "pdr", "--build-max", "5"])
        self.prep()
        self.assertEqual(len(self.calls), 3)

    def test_old_cache_without_key_is_rebuilt(self):
        dst = self.work / "public" / "d"
        dst.mkdir(parents=True)
        (dst / "manifest.json").write_text("{}")
        (dst / "stale.txt").write_text("old")
        self.prep()
        self.assertEqual(len(self.calls), 1)
        self.assertFalse((dst / "stale.txt").exists())
        self.assertTrue((dst / lab.CONVERT_KEY_FILE).exists())

    def test_key_depends_on_script_and_args(self):
        k1 = lab.convert_key(self.conv, ["--drift", "pdr"])
        self.assertEqual(k1, lab.convert_key(self.conv, ["--drift", "pdr"]))
        self.assertNotEqual(k1, lab.convert_key(self.conv, ["--drift", "arkit"]))
        self.conv.write_text("# changed\n")
        self.assertNotEqual(k1, lab.convert_key(self.conv, ["--drift", "pdr"]))


class SimAndLooTests(unittest.TestCase):
    """合成小场地数据集的转换缓存，留一法协议，后台排除名单。"""

    def test_sim_dataset_uses_sim_script(self):
        tmp = Path(tempfile.mkdtemp())
        sim = tmp / "sim.py"
        sim.write_text("# sim\n")
        calls = []

        def fake_run(cmd, check):
            calls.append(cmd)
            Path(cmd[2]).mkdir(parents=True, exist_ok=True)
            (Path(cmd[2]) / "manifest.json").write_text("{}")
        suite = {"datasets": {"s": {"kind": "sim", "layout": "pair", "drift": "phone", "seed": 3}}}
        lab.prepare_public(suite, tmp / "ilc", tmp / "work", conv=tmp / "nope.py", run=fake_run, sim_conv=sim)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][1:3], [str(sim), str(tmp / "work" / "public" / "s")])
        self.assertEqual(calls[0][3:], ["--drift", "phone", "--layout", "pair", "--seed", "3"])
        lab.prepare_public(suite, tmp / "ilc", tmp / "work", conv=tmp / "nope.py", run=fake_run, sim_conv=sim)
        self.assertEqual(len(calls), 1)                          # 没变：用缓存

    def test_suite_sim_datasets_exist(self):
        for s in SUITE["scenarios"]:
            self.assertIn(s["dataset"], SUITE["datasets"], s["id"])
        sims = [n for n, d in SUITE["datasets"].items() if d.get("kind") == "sim"]
        self.assertTrue(sims)

    def test_loo_folds(self):
        folds = lab.loo_folds(["a", "b", "c"])
        self.assertEqual(folds, [(["b", "c"], "a"), (["a", "c"], "b"), (["a", "b"], "c")])

    def test_session_excluded_accepts_both_spellings(self):
        ex = {"ios_survey_20261109_141403", "mag_20261109_161905_files"}
        self.assertTrue(lab.session_excluded("ios_survey_20261109_141403.zip", ex))
        self.assertTrue(lab.session_excluded("mag_20261109_161905_files.zip", ex))
        self.assertFalse(lab.session_excluded("ios_survey_20261112_135825.zip", ex))

    def test_loo_protocol_runs_each_fold(self):
        tmp = Path(tempfile.mkdtemp())
        work = tmp / "work"
        d = work / "private" / "site-x"
        d.mkdir(parents=True)
        (d / "map.json").write_text("{}")
        (work / "private" / "manifest.json").write_text(json.dumps([{"label": "site-x", "build": ["a", "b", "c"], "test": [], "loo": True}]))
        fake = tmp / "fake_eval.py"
        fake.write_text(FAKE_EVAL)
        suite = {"runs": {"pr": 1}, "datasets": {}, "scenarios": [],
                 "private": {"tiers": ["pr"], "gate": True, "protocols": {
                     "leave-one-out": {"title": "loo", "flags": ["--motion", "pdr-imu"], "track_flags": ["--oracle-start"],
                                       "cold_flags": [], "gate": False}}}}
        res = lab.run_suite(suite, "pr", work, [sys.executable, str(fake)])
        ids = [r["id"] for r in res["results"]]
        self.assertEqual(ids, ["private/site-x/leave-one-out/track", "private/site-x/leave-one-out/cold"])
        for r in res["results"]:
            self.assertNotIn("error", r)
            self.assertFalse(r["gate"])
            self.assertEqual(r["metrics"]["replays"], 3)         # 3 折 × 1 次
            self.assertEqual(r["loo_folds"], 3)


FAKE_EVAL = textwrap.dedent("""
    import json, sys
    a = sys.argv
    out = a[a.index("--json") + 1]
    runs = int(a[a.index("--runs") + 1])
    cold = "--oracle-start" not in a
    errs = [150.0] * 9 + ([900.0] if cold else [250.0])
    json.dump([{"session": "t", "errorsCm": errs, "refPoints": 12, "firstFixM": 20.0 if cold else 0.0}] * runs, open(out, "w"))
""")


class EndToEndTests(unittest.TestCase):
    def test_run_report_baseline(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            fake = td / "fake_eval.py"
            fake.write_text(FAKE_EVAL, encoding="utf-8")
            for ds in SUITE["datasets"]:
                d = td / "work" / "public" / ds
                (d / "build").mkdir(parents=True)
                (d / "test").mkdir()
                (d / "map.json").write_text("{}")
            res = lab.run_suite(SUITE, "pr", td / "work", [sys.executable, str(fake)])
            ids = [r["id"] for r in res["results"]]
            self.assertEqual(ids, [s["id"] for s in SUITE["scenarios"] if "pr" in s["tiers"]])
            self.assertTrue(all("metrics" in r for r in res["results"]))
            cold = next(r for r in res["results"] if r["id"] == "public/pdr/cold-mag-search")["metrics"]
            self.assertAlmostEqual(cold["wrong_fix"], 0.1)
            self.assertEqual(cold["replays"], SUITE["runs"]["pr"])

            md, regressed = lab.build_report(res, None, SUITE)
            self.assertIn(lab.MARKER, md)
            self.assertIn("还没有基线", md)
            self.assertFalse(regressed)

            # 写基线 → 同样结果持平；中位变差 → 退步
            rp = td / "results.json"
            rp.write_text(json.dumps(res), encoding="utf-8")
            bp = td / "baseline.json"
            self.assertEqual(lab.main(["baseline", "--results", str(rp), "--out", str(bp)]), 0)
            base = json.loads(bp.read_text(encoding="utf-8"))
            _, regressed = lab.build_report(res, base, SUITE)
            self.assertFalse(regressed)
            worse = json.loads(json.dumps(res))
            worse["results"][0]["metrics"]["median_cm"] = 900
            md, regressed = lab.build_report(worse, base, SUITE)
            self.assertTrue(regressed)
            self.assertIn("退步", md)
            wp = td / "worse.json"
            wp.write_text(json.dumps(worse), encoding="utf-8")
            self.assertEqual(lab.main(["report", "--results", str(wp), "--baseline", str(bp), "--fail-on-regression"]), 1)

    def test_parallel_jobs_keep_order(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            fake = td / "fake_eval.py"
            fake.write_text(FAKE_EVAL, encoding="utf-8")
            for ds in SUITE["datasets"]:
                d = td / "work" / "public" / ds
                (d / "build").mkdir(parents=True)
                (d / "test").mkdir()
                (d / "map.json").write_text("{}")
            serial = lab.run_suite(SUITE, "nightly", td / "work", [sys.executable, str(fake)])
            par = lab.run_suite(SUITE, "nightly", td / "work", [sys.executable, str(fake)], jobs=4)
            self.assertEqual([r["id"] for r in par["results"]], [r["id"] for r in serial["results"]])
            self.assertEqual([r["metrics"] for r in par["results"]], [r["metrics"] for r in serial["results"]])

    def test_eval_failure_is_reported(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            bad = td / "bad.py"
            bad.write_text("import sys; print('boom'); sys.exit(3)", encoding="utf-8")
            d = td / "work" / "public" / "ilc-pdr"
            d.mkdir(parents=True)
            res = lab.run_suite(SUITE, "pr", td / "work", [sys.executable, str(bad)], only="public/pdr/track-mag")
            self.assertEqual(len(res["results"]), 1)
            self.assertIn("boom", res["results"][0]["error"])
            base = {"results": [{"id": "public/pdr/track-mag", "metrics": {"median_cm": 100}}]}
            md, regressed = lab.build_report(res, base, SUITE)
            self.assertTrue(regressed)
            self.assertIn("运行失败", md)


if __name__ == "__main__":
    unittest.main()

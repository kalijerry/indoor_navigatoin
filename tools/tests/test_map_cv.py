"""map_cv.py 的单元测试：折的划分（有 test/ 一折、没有就留一法）、run 调 hpass-eval 的参数、
汇总时「采过 / 补出来」的分法、每个会话减自己的偏移、t4 对数似然对标准差老不老实敏感。"""
import csv
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "bench"))

import map_cv  # noqa: E402

HEAD = ["session", "t_ms", "path_cm", "f_total", "f_vertical", "f_horizontal", "m_total", "m_vertical", "m_horizontal",
        "s_total", "s_vertical", "s_horizontal", "ref_x", "ref_y"]


def write(fn, rows):
    with open(fn, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(HEAD)
        for r in rows:
            w.writerow(r)


def row(sess, t, f, m, s):
    return [sess, t, 0, *f, *(m if m else ["", "", ""]), *(s if s else ["", "", ""]), 0, 0]


class MapCVTests(unittest.TestCase):
    def test_folds(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            for b in ("a", "b", "c"):
                (d / "build" / b).mkdir(parents=True)
                (d / "build" / b / "imu.csv").write_text("t\n")
            loo = map_cv.folds(d)
            self.assertEqual([x[0] for x in loo], ["a", "b", "c"])
            self.assertEqual(loo[0][1].split(","), [str(d / "build" / "b"), str(d / "build" / "c")])
            self.assertEqual(loo[0][2], str(d / "build" / "a"))
            (d / "test").mkdir()
            self.assertEqual(len(map_cv.folds(d)), 3)       # 空的 test/ 照旧留一法
            (d / "test" / "t1").mkdir()
            (d / "test" / "t1" / "imu.csv").write_text("t\n")
            self.assertEqual(map_cv.folds(d), [("all", str(d / "build"), str(d / "test"))])

    def test_run_passes_nofill_and_extra_flags(self):
        calls = []

        class R:
            returncode = 0
            stdout = stderr = ""

        def runner(cmd, **kw):
            calls.append(cmd)
            Path(cmd[cmd.index("--residuals") + 1]).write_text("x")
            return R()

        with tempfile.TemporaryDirectory() as td:
            d = Path(td) / "data"
            for b in ("a", "b"):
                (d / "build" / b).mkdir(parents=True)
                (d / "build" / b / "imu.csv").write_text("t\n")
            out = Path(td) / "out"
            map_cv.run("ev", d, out, "r300", ["--fill-radius", "300"], runner=runner)
            self.assertEqual(len(calls), 4)
            self.assertEqual(calls[0][-2:], ["--fill-radius", "0"])
            self.assertEqual(calls[2][-2:], ["--fill-radius", "300"])
            # nofill 已经有了就不重跑
            calls.clear()
            map_cv.run("ev", d, out, "other", [], runner=runner)
            self.assertEqual(len(calls), 2)

    def test_summary_offsets_categories_and_loglik(self):
        # 会话 S 整体偏 +5 µT；前 12 个点在采过的格子上（地图 = 真值），后 4 个只在补出来的格子上
        base, honest, liar = [], [], []
        for k in range(16):
            f = [50 + 5, -40 + 5, 20 + 5]
            truth = [50, -40, 20]
            if k < 12:
                base.append(row("S", k, f, truth, [1, 1, 1]))
                honest.append(row("S", k, f, truth, [1, 1, 1]))
                liar.append(row("S", k, f, truth, [1, 1, 1]))
            else:
                base.append(row("S", k, f, None, None))
                wrong = [v + 6 for v in truth]          # 补出来的值差 6 µT
                honest.append(row("S", k, f, wrong, [6, 6, 6]))
                liar.append(row("S", k, f, wrong, [0.5, 0.5, 0.5]))
        with tempfile.TemporaryDirectory() as td:
            out = Path(td)
            write(out / "nofill--all.csv", base)
            write(out / "honest--all.csv", honest)
            write(out / "liar--all.csv", liar)
            res = map_cv.report(out, ["nofill", "honest", "liar"])
            # 偏移按采过的格子减掉：采过的格子残差 0
            self.assertAlmostEqual(res["honest"]["meas"]["t4_scale"], 0, places=6)
            self.assertEqual(res["honest"]["meas"]["n"], 12)
            self.assertEqual(res["honest"]["gap"]["n"], 4)
            self.assertAlmostEqual(res["honest"]["gap"]["coverage"], 1.0)
            self.assertAlmostEqual(res["nofill"]["gap"]["coverage"], 0.0)
            self.assertAlmostEqual(res["honest"]["gap"]["t4_scale"], 6 / 0.741, places=6)
            # 同样的残差，标准差报得老实的对数似然更高
            self.assertGreater(res["honest"]["gap"]["loglik"], res["liar"]["gap"]["loglik"])


if __name__ == "__main__":
    unittest.main()

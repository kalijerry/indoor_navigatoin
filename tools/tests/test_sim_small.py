"""合成小场地数据集 sim_small.py：输出格式、地图（单元 / 门）、漂移、磁场统计量在合理范围。"""
import csv
import json
import math
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "bench"))

import sim_small  # noqa: E402


class SimSmallTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.out = Path(tempfile.mkdtemp()) / "pair"
        sim_small.main([str(cls.out), "--layout", "pair", "--drift", "phone", "--test-n", "2",
                        "--test-min-s", "20", "--test-max-s", "30", "--seed", "2"])

    def test_layout_and_map(self):
        m = json.loads((self.out / "map.json").read_text())
        self.assertEqual([u["id"] for u in m["units"]], ["R1", "R2"])
        doors = [e for e in m["mapElementList"] if e["shapeType"] == "MapDoor"]
        self.assertEqual(len(doors), 1)
        self.assertEqual(doors[0]["rotation"], 90)                # 竖墙上的门：宽沿 y
        self.assertEqual(len(m["floorPolygons"]), 3)              # 两间房 + 门洞

    def test_sessions_have_expected_files(self):
        man = json.loads((self.out / "manifest.json").read_text())
        self.assertEqual(len(man["build"]), 2)
        self.assertEqual(len(man["test"]), 2)
        for sid in man["build"]:
            d = self.out / "build" / sid
            for f in ("imu.csv", "mag_raw.csv", "arkit_pose.csv", "anchors.csv", "meta.json"):
                self.assertTrue((d / f).exists(), f)
            self.assertFalse((d / "truth.csv").exists())
        for sid in man["test"]:
            d = self.out / "test" / sid
            self.assertTrue((d / "truth.csv").exists())
            rows = list(csv.DictReader(open(d / "arkit_pose.csv")))
            self.assertGreater(len(rows), 100)

    def test_truth_stays_inside_rooms_or_doors(self):
        m = json.loads((self.out / "map.json").read_text())
        rects = [(p[0], p[1], p[4], p[5]) for p in m["floorPolygons"]]
        for sid in json.loads((self.out / "manifest.json").read_text())["test"]:
            for r in csv.DictReader(open(self.out / "test" / sid / "truth.csv")):
                x, y = float(r["x_cm"]), float(r["y_cm"])
                self.assertTrue(any(x0 - 1 <= x <= x1 + 1 and y0 - 1 <= y <= y1 + 1 for x0, y0, x1, y1 in rects), (x, y))

    def test_phone_drift_is_short(self):
        """phone 漂移：里程计走的路比真值短（尺度均值 0.82）"""
        for sid in json.loads((self.out / "manifest.json").read_text())["test"]:
            d = self.out / "test" / sid
            tr = [(float(r["x_cm"]), float(r["y_cm"])) for r in csv.DictReader(open(d / "truth.csv"))]
            po = [(float(r["x_m"]) * 100, float(r["z_m"]) * 100) for r in csv.DictReader(open(d / "arkit_pose.csv"))]
            L = lambda p: sum(math.dist(a, b) for a, b in zip(p, p[1:]))
            self.assertLess(L(po) / L(tr), 1.0)
            self.assertGreater(L(po) / L(tr), 0.55)

    def test_field_statistics_look_like_an_office(self):
        import random
        rooms, _, w, h = sim_small.layout("office")
        f = sim_small.Field(random.Random(1), rooms)
        tot = sorted(math.sqrt(sum(v * v for v in f.at(x, y))) for x in range(100, 1800, 50) for y in range(100, 2000, 50))
        p5, p95 = tot[len(tot) // 20], tot[len(tot) * 19 // 20]
        self.assertGreater(p5, 15)
        self.assertLess(p95, 90)
        self.assertGreater(p95 - p5, 15)                          # 有足够起伏才能匹配


if __name__ == "__main__":
    unittest.main()

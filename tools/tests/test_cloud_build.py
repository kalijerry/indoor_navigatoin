"""cloud_build_lib.py 的单元测试：特征地图兼容规则（frameId 优先，否则 arAlign 等价）和挑选。"""
import json
import math
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import cloud_build_lib as cb  # noqa: E402

ALIGN = {"phi": -0.6, "pRefX": 120.0, "pRefY": 80.0, "aRefX": 0.0, "aRefY": 0.0}


def map_json(align=ALIGN, frame=None, wrap=False):
    root = {"mapElementList": [], "arAlign": align}
    if frame:
        root["frameId"] = frame
    return json.dumps({"data": root} if wrap else root).encode()


def shifted(a, dx, dy):
    return dict(a, pRefX=a["pRefX"] + dx, pRefY=a["pRefY"] + dy)


class CompatTest(unittest.TestCase):
    def test_frame_id_rule(self):
        a = cb._align(ALIGN)
        far = cb._align(shifted(ALIGN, 300, 0))
        self.assertTrue(cb.worldmap_compatible(far, "F", a, "F"))          # 同一 frameId：arAlign 差 3 m 也兼容
        self.assertFalse(cb.worldmap_compatible(a, "F", a, "G"))           # frameId 不同：arAlign 一样也不兼容
        self.assertTrue(cb.worldmap_compatible(a, None, a, "F"))           # 一方没有：退回 arAlign
        self.assertFalse(cb.worldmap_compatible(far, None, a, "F"))
        self.assertTrue(cb.worldmap_compatible(a, "F", a, None))
        self.assertFalse(cb.worldmap_compatible(None, None, a, None))

    def test_map_fields(self):
        self.assertEqual(cb.map_frame_id(map_json(frame="F1")), "F1")
        self.assertEqual(cb.map_frame_id(map_json(frame="F1", wrap=True)), "F1")    # 带 data 包装
        self.assertIsNone(cb.map_frame_id(map_json()))
        self.assertEqual(cb.map_align(map_json(wrap=True)), cb._align(ALIGN))
        self.assertIsNone(cb.map_align(b"not json"))

    def test_equivalent_anchor_rewrite(self):
        # 同一个映射换锚点写法仍然等价；旋转差 2° 不等价
        a = cb._align(ALIGN)
        ax, ay = 300.0, -150.0
        px, py = cb._to_map(a, ax, ay)
        alt = (a[0], px, py, ax, ay)
        self.assertTrue(cb.align_equivalent(a, alt))
        self.assertFalse(cb.align_equivalent(a, (a[0] + math.radians(2),) + a[1:]))


class PickTest(unittest.TestCase):
    def session(self, root, name, meta, payload=b"bplist00" + b"x" * 100):
        d = Path(root) / name
        d.mkdir()
        (d / cb.WM_FILE).write_bytes(payload)
        (d / cb.WM_META).write_text(json.dumps(meta), encoding="utf-8")
        return str(d)

    def test_pick(self):
        with tempfile.TemporaryDirectory() as t:
            base = {"version": 1, "mapId": "m", "source": "scan"}
            dirs = [
                self.session(t, "old", dict(base, createdMs=1, arAlign=ALIGN)),
                self.session(t, "shifted", dict(base, createdMs=5, arAlign=shifted(ALIGN, 50, 100), frameId="F")),
                self.session(t, "other", dict(base, createdMs=9, arAlign=ALIGN, frameId="G")),
                self.session(t, "v2", dict(base, createdMs=10, arAlign=ALIGN, version=2)),
                self.session(t, "notmine", dict(base, createdMs=11, arAlign=ALIGN, mapId="x")),
            ]
            a = cb._align(ALIGN)
            # 地图有 frameId F（原点平移过，arAlign 已经变了）：只有 shifted 那份（同 frameId）和没 frameId 但 arAlign 等价的 old
            path, info = cb.pick_worldmap(dirs, "m", cb._align(shifted(ALIGN, 50, 100)), "F")
            self.assertEqual(info["session"], "shifted")
            # 老地图（没有 frameId）：按 arAlign，最新的等价那份是 other（frameId 不参与）
            path, info = cb.pick_worldmap(dirs, "m", a, None)
            self.assertEqual(info["session"], "other")
            # 地图 frameId = F、arAlign 是原来的：other（G）不收；shifted（同 F）和 old（无 frameId、arAlign 等价）都收，挑新的
            path, info = cb.pick_worldmap(dirs, "m", a, "F")
            self.assertEqual(info["session"], "shifted")
            path, info = cb.pick_worldmap(dirs[:1] + dirs[2:], "m", a, "F")
            self.assertEqual(info["session"], "old")
            self.assertIsNone(cb.pick_worldmap(dirs, "m", None, "F"))



class RebuildTest(unittest.TestCase):
    PREV = {"sessions": [{"name": "b1"}], "testSessions": ["t1"], "liveSessions": ["l1"],
            "worldMapSession": "b1", "mapGeometryVersion": 3}

    def test_geometry_version_read(self):
        root = {"mapElementList": [], "geometryVersion": 4}
        self.assertEqual(cb.map_geometry_version(json.dumps(root).encode()), 4)
        self.assertEqual(cb.map_geometry_version(json.dumps({"data": root}).encode()), 4)
        self.assertIsNone(cb.map_geometry_version(map_json()))

    def test_unchanged_skips(self):
        self.assertTrue(cb.build_unchanged(self.PREV, ["t1", "b1"], ["l1"], "b1", 3))
        self.assertTrue(cb.build_unchanged(self.PREV, ["t1", "b1"], ["l1"], None, 3))

    def test_new_geometry_rebuilds(self):
        # 接着扫 / 重扫后手机只上传了新的 map.json，会话一个没变也要重建
        self.assertFalse(cb.build_unchanged(self.PREV, ["t1", "b1"], ["l1"], "b1", 4))
        old_report = {k: v for k, v in self.PREV.items() if k != "mapGeometryVersion"}
        self.assertFalse(cb.build_unchanged(old_report, ["t1", "b1"], ["l1"], "b1", 4))
        self.assertTrue(cb.build_unchanged(old_report, ["t1", "b1"], ["l1"], "b1", None))

    def test_sessions_changed_rebuilds(self):
        self.assertFalse(cb.build_unchanged(self.PREV, ["t1", "b1", "b2"], ["l1"], "b1", 3))
        self.assertFalse(cb.build_unchanged(self.PREV, ["t1", "b1"], [], "b1", 3))
        self.assertFalse(cb.build_unchanged(self.PREV, ["t1", "b1"], ["l1"], "b2", 3))

class QualityRejectedTest(unittest.TestCase):
    def test_reads_quality_json(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertIsNone(cb.quality_rejected(d))                       # 旧会话没打分：照用
            (Path(d) / "quality.json").write_text(json.dumps({"kept": True, "score": 82}))
            self.assertIsNone(cb.quality_rejected(d))
            (Path(d) / "quality.json").write_text(json.dumps({"kept": False, "score": 31, "reason": "质量分太低（31 分）"}))
            self.assertEqual(cb.quality_rejected(d), "质量分太低（31 分）")
            (Path(d) / "quality.json").write_text("{坏的")
            self.assertIsNone(cb.quality_rejected(d))


class SurveySummaryTest(unittest.TestCase):
    def test_counts_corrections_and_limited(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertIsNone(cb.survey_summary(d))
            (Path(d) / "anchors.csv").write_text(
                "t_ms,kind,map_x_cm,map_y_cm,ar_x_cm,ar_z_cm,heading_rad,note\n"
                "0,start,0,0,0,0,,\n0,align,0,0,0,0,0.1,\n"
                "5000,reanchor,1,1,1,1,,路口 修正前偏 230 cm\n9000,reanchor,1,1,1,1,,视觉重定位\n", encoding="utf-8")
            rows = ["t_ms,x_m,y_m,z_m,qx,qy,qz,qw,tracking,limited_reason"]
            rows += [f"{i * 100},{i * 0.1},0,0,0,0,0,1,{1 if i < 5 else 2},0" for i in range(101)]
            (Path(d) / "arkit_pose.csv").write_text("\n".join(rows) + "\n")
            s = cb.survey_summary(d)
            self.assertEqual((s["reanchors"], s["visual"], s["jumps_cm"], s["start"]), (2, 1, [230], "手动长按"))
            self.assertAlmostEqual(s["walk_m"], 10.0, places=3)
            self.assertAlmostEqual(s["dur_s"], 10.0)
            self.assertAlmostEqual(s["limited"], 5 / 101)
            self.assertIn("修正 2 次", cb.format_survey_summary("x", s))


class EditsHashTest(unittest.TestCase):
    def test_empty_is_none_and_content_decides(self):
        from cloud_build_lib import edits_hash
        self.assertIsNone(edits_hash([]))
        a = [{"session": "s", "t0Ms": 1, "t1Ms": 2, "dx": 10}]
        b = [{"dx": 10, "t1Ms": 2, "t0Ms": 1, "session": "s"}]
        self.assertEqual(edits_hash(a), edits_hash(b))
        self.assertNotEqual(edits_hash(a), edits_hash([dict(a[0], dx=11)]))


if __name__ == "__main__":
    unittest.main()

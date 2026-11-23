"""纯推算误差拆解 dr_decompose.py：已知尺度 / 航向偏差 / 漏步的合成推算，拆出来的量要对得上。"""
import contextlib
import io
import math
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "bench"))

import dr_decompose  # noqa: E402

HEADER = "session,t_ms,x,y,heading_rad,steps,step_len_m,moving,carry_mode,step_k,ref_x,ref_y"


def synth(scale: float, bias_deg: float, stall=(None, None), dur_s=120.0, speed=1.2, cadence=1.8):
    """参考：直走 30 m → 右转 90° → 直走……（方形绕圈，cm）；推算 = 参考位移 × scale、方向 + bias。
    stall=(t0, t1) 时段推算不动、也不计步（漏步）。"""
    rows = []
    rx = ry = 0.0
    x = y = 0.0
    th = 0.0
    side = 0.0
    steps = 0.0
    b = math.radians(bias_deg)
    dt = 0.1
    for k in range(int(dur_s / dt)):
        t = k * dt
        d = speed * dt * 100
        rx += d * math.sin(th)
        ry += d * math.cos(th)
        stalled = stall[0] is not None and stall[0] <= t < stall[1]
        if not stalled:
            x += d * scale * math.sin(th + b)
            y += d * scale * math.cos(th + b)
            steps += cadence * dt
        side += d
        if side >= 3000:
            side = 0.0
            th += math.pi / 2
        rows.append(f"s1,{int(t * 1000)},{x:.1f},{y:.1f},{th + b:.5f},{int(steps)},0.700,1,texting,0.4500,{rx:.1f},{ry:.1f}")
    return rows


class DrDecomposeTests(unittest.TestCase):
    def analyse(self, rows):
        p = Path(tempfile.mkdtemp()) / "dr.csv"
        p.write_text("\n".join([HEADER] + rows) + "\n")
        by = dr_decompose.load(str(p))
        return dr_decompose.analyse(by["s1"]), p

    def test_scale_and_heading_bias(self):
        r, p = self.analyse(synth(0.8, 10.0))
        self.assertAlmostEqual(r["scale_med"], 0.8, delta=0.01)
        self.assertAlmostEqual(r["head_mean_deg"], 10.0, delta=0.5)
        self.assertAlmostEqual(r["head_init_deg"], 10.0, delta=0.5)
        self.assertLess(abs(r["head_drift_deg_per_min"]), 0.5)
        self.assertAlmostEqual(r["cadence_hz"], 1.8, delta=0.05)
        self.assertLess(r["stall_share"], 0.01)
        # 三处 90° 转弯，推算转角和参考一样
        self.assertGreaterEqual(len(r["turns"]), 3)
        self.assertAlmostEqual(r["turn_ratio_med"], 1.0, delta=0.05)
        # 原始 20 m 相对误差：直段 = |0.8·e^{i10°} − 1| ≈ 0.25，跨转角的窗位移弦比路程短、比值更小；两项都按神谕修正后 ≈ 0
        straight = abs(0.8 * complex(math.cos(math.radians(10)), math.sin(math.radians(10))) - 1)
        self.assertLessEqual(r["rel20"]["raw"][0], straight + 0.005)
        self.assertGreater(r["rel20"]["raw"][0], 0.8 * straight)
        self.assertLess(r["rel20"]["both"][0], 0.01)
        self.assertLess(r["rel20"]["scale"][0], r["rel20"]["raw"][0])
        self.assertLess(r["rel20"]["head"][0], r["rel20"]["raw"][0])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            dr_decompose.main([str(p), "--per-session"])
        self.assertIn("总尺度 0.80", out.getvalue())

    def test_stall_counts_missed_steps(self):
        r, _ = self.analyse(synth(1.0, 0.0, stall=(30.0, 54.0)))
        # 120 s 里有 24 s 推算不动：卡住占比 ≈ 0.2；每检出一步实际走的路程变长
        self.assertAlmostEqual(r["stall_share"], 0.2, delta=0.03)
        self.assertGreater(r["true_m_per_step"], 1.2 / 1.8 * 1.15)


if __name__ == "__main__":
    unittest.main()

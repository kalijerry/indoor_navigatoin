#!/usr/bin/env python3
"""合成的小场地数据集（办公室 / 两间房 / 单间）：不用去现场走，也不用任何外部数据，可以放心商用和公开。

  python3 tools/bench/sim_small.py <输出目录> [--layout office|pair|room] [--drift pdr|phone|vio|imu]
        [--test-n 12] [--seed 1] [--lane-cm 120]

输出和 ilc_convert.py 一样（hpass-eval 直接吃）：
  <out>/map.json            宽高 + floorPolygons（房间 + 门洞矩形）+ units（房间多边形，--rooms / 办公室指标用）
  <out>/build/<id>/         建图会话（--build-n 次）：经门走遍每间房，房里按 lane-cm 间距来回走（「割草机」，各次车道错开），
                            位姿 = 真值，锚点每 5 s 一个
  <out>/test/<id>/          测试会话：房间之间随机走（过门、偶尔停下），truth.csv = 真值；
                            arkit_pose.csv = 真值位移加合成漂移（--drift），imu 时只有表头（用 --motion pdr-imu 回放合成 IMU）
  <out>/manifest.json

怎么合成的（全是自己定的模型，没有拷贝任何数据集）：
- 磁场（世界系，东北天，µT）= 地磁背景（水平 19、竖直 −44，英国一带）+ 一堆随机平面波（波长 2–8 m，
  每个分量标准差约 8 µT）+ 沿墙放的几个偶极子（钢柱 / 暖气片，1/r³ 衰减，近处 ±20～40 µT）。
  统计量对着真实办公室地图包调：总场 P5–P95 约 27–62 µT、0.5 m 相邻格差中位 1–2 µT。
- 手机：平拿（屏幕朝上），朝向 = 行走方向；mag_raw = 设备系磁场 + 固定硬铁偏置 + 0.4 µT 噪声，imu.csv 里是去掉偏置的值。
  加速度 = 重力 + 走路时 1.8 Hz 上下颠（停下时没有），陀螺 z = 转向角速度。
- 漂移（测试会话的「里程计」）：
    pdr    尺度 σ4%、朝向随机游走 1.5°/√s（和公开 ilc-pdr 一样）
    phone  按 2026-11 办公室实测：步长系统性偏短（尺度均值 0.82、σ0.07），朝向 2°/√s
    vio    尺度 σ1%、朝向 0.5°/√s（举着手机开摄像头）
    imu    不写位姿，只有合成 IMU（量 FusionEngine 计步；合成的颠簸信号和真人差得远，只当冒烟测试）
纯标准库。
"""
import argparse, json, math, os, random

G = 9.80665
IMU_HEADER_V4 = "t_ms,ax,ay,az,gx,gy,gz,mx,my,mz,mag_acc,qw,qx,qy,qz,heading_deg,gvx,gvy,gvz"
WALL = 20          # 墙厚 cm
DOOR = 90          # 门宽 cm
T0 = 1_800_000_000_000

# ---------------------------------------------------------------- 布局
# 房间：(id, x0, y0, x1, y1)，cm，y 朝下；门：(房间 a, 房间 b, 门洞矩形)


def _door_v(x_wall, y_mid):  # 竖墙上的门（左右两间房之间）
    return (x_wall, y_mid - DOOR / 2, x_wall + WALL, y_mid + DOOR / 2)


def _door_h(y_wall, x_mid):  # 横墙上的门（上下两间房之间）
    return (x_mid - DOOR / 2, y_wall, x_mid + DOOR / 2, y_wall + WALL)


def layout(name):
    if name == "room":            # 单间 8 × 10 m
        rooms = [("R1", 100, 100, 900, 1100)]
        doors = []
    elif name == "pair":          # 两间并排、一个门：最典型的「两间房认反」
        rooms = [("R1", 100, 100, 800, 1000), ("R2", 820, 100, 1520, 1000)]
        doors = [("R1", "R2", _door_v(800, 550))]
    elif name == "office":        # 约 320 m²：上两间、中间走廊、下两间（和真实办公室差不多大）
        rooms = [("R1", 100, 100, 900, 1100), ("R2", 920, 100, 1820, 1100), ("R3", 100, 1120, 1820, 1420),
                 ("R4", 100, 1440, 1000, 2040), ("R5", 1020, 1440, 1820, 2040)]
        doors = [("R1", "R2", _door_v(900, 600)), ("R1", "R3", _door_h(1100, 450)), ("R2", "R3", _door_h(1100, 1350)),
                 ("R3", "R4", _door_h(1420, 550)), ("R3", "R5", _door_h(1420, 1450))]
    else:
        raise SystemExit("--layout 只能是 office / pair / room")
    w = max(r[3] for r in rooms) + 100
    h = max(r[4] for r in rooms) + 100
    return rooms, doors, w, h


# ---------------------------------------------------------------- 磁场


class Field:
    def __init__(self, rng, rooms, comp_sigma=8.0, n_waves=40, n_dipoles=8):
        self.waves = []
        for _ in range(n_waves):
            lam = rng.uniform(200, 800)
            th = rng.uniform(0, 2 * math.pi)
            k = 2 * math.pi / lam
            amp = [rng.gauss(0, comp_sigma * math.sqrt(2 / n_waves)) for _ in range(3)]
            self.waves.append((k * math.cos(th), k * math.sin(th), rng.uniform(0, 2 * math.pi), amp))
        self.dipoles = []
        for _ in range(n_dipoles):
            rid, x0, y0, x1, y1 = rng.choice(rooms)
            side = rng.randrange(4)
            x = rng.uniform(x0, x1) if side < 2 else (x0 if side == 2 else x1)
            y = rng.uniform(y0, y1) if side >= 2 else (y0 if side == 0 else y1)
            m = [rng.gauss(0, 1) for _ in range(3)]
            n = math.sqrt(sum(v * v for v in m)) or 1
            self.dipoles.append((x, y, rng.uniform(15, 35), [v / n for v in m]))

    def at(self, x, y):
        """世界系东北天 (E, N, U)，µT。地图 x = 东，地图 y = 南"""
        b = [0.0, 19.0, -44.0]
        for kx, ky, ph, amp in self.waves:
            s = math.sin(kx * x + ky * y + ph)
            for i in range(3):
                b[i] += amp[i] * s
        for dx0, dy0, strength, m in self.dipoles:
            dx, dy = (x - dx0) / 100, -(y - dy0) / 100      # m，东北
            r2 = dx * dx + dy * dy + 0.35 ** 2                # 0.35 m 软化（偶极子在墙里、离人至少半臂）
            r = math.sqrt(r2)
            rv = (dx / r, dy / r, 0.0)
            md = sum(m[i] * rv[i] for i in range(3))
            f = strength * 0.35 ** 3 / (r2 * r)
            for i in range(3):
                b[i] += f * (3 * md * rv[i] - m[i])
        return b


# ---------------------------------------------------------------- 轨迹


def inset(r, d):
    return (r[0], r[1] + d, r[2] + d, r[3] - d, r[4] - d)


def lawnmower(room, lane):
    _, x0, y0, x1, y1 = inset(room, 50)
    pts, up, x = [], True, x0
    if x1 - x0 >= y1 - y0:          # 沿长边来回
        y, down = y0, True
        while y <= y1 + 1:
            pts += [(x0, y), (x1, y)] if down else [(x1, y), (x0, y)]
            down = not down
            y += lane
    else:
        while x <= x1 + 1:
            pts += [(x, y0), (x, y1)] if up else [(x, y1), (x, y0)]
            up = not up
            x += lane
    return pts


def room_graph(rooms, doors):
    g = {r[0]: [] for r in rooms}
    for a, b, d in doors:
        c = ((d[0] + d[2]) / 2, (d[1] + d[3]) / 2)
        g[a].append((b, c))
        g[b].append((a, c))
    return g


def route(g, a, b):
    """房间 a → b 经过的门中心（BFS）"""
    prev, q = {a: None}, [a]
    while q:
        u = q.pop(0)
        if u == b:
            break
        for v, c in g[u]:
            if v not in prev:
                prev[v] = (u, c)
                q.append(v)
    out, u = [], b
    while prev.get(u):
        u, c = prev[u]
        out.append(c)
    return out[::-1]


def random_walk(rng, rooms, g, min_s, max_s):
    """[(x, y, 停留秒数)]：随机挑房间里的点，经门走过去，偶尔停 2–5 s"""
    rmap = {r[0]: r for r in rooms}
    cur = rng.choice(rooms)[0]
    _, x0, y0, x1, y1 = inset(rmap[cur], 60)
    pts = [(rng.uniform(x0, x1), rng.uniform(y0, y1), 0.0)]
    dur, speed = 0.0, 1.15
    target = rng.uniform(min_s, max_s)
    while dur < target:
        nxt = rng.choice(rooms)[0] if len(rooms) > 1 and rng.random() < 0.6 else cur
        for c in route(g, cur, nxt):
            pts.append((c[0], c[1], 0.0))
        _, x0, y0, x1, y1 = inset(rmap[nxt], 60)
        stop = rng.uniform(2, 5) if rng.random() < 0.25 else 0.0
        pts.append((rng.uniform(x0, x1), rng.uniform(y0, y1), stop))
        cur = nxt
        dur = sum(math.dist(p[:2], q[:2]) for p, q in zip(pts, pts[1:])) / 100 / speed + sum(p[2] for p in pts)
    return pts


def sample(pts, rng, hz=100, speed_cm_s=None):
    """折线 → [(t_s, x, y, 走着吗)]，hz 采样，速度 1.0–1.3 m/s"""
    v = speed_cm_s or rng.uniform(100, 130)
    out, t = [], 0.0
    for (ax, ay, _), (bx, by, stop) in zip(pts, pts[1:]):
        L = math.hypot(bx - ax, by - ay)
        n = max(int(L / v * hz), 1)
        for i in range(n):
            f = i / n
            out.append((t, ax + (bx - ax) * f, ay + (by - ay) * f, True))
            t += 1 / hz
        for _ in range(int(stop * hz)):
            out.append((t, bx, by, False))
            t += 1 / hz
    lx, ly = pts[-1][0], pts[-1][1]
    out.append((t, lx, ly, False))
    return out


def headings(track, win=25):
    """行走方向（地图系，0 = 地图 +y），转弯处平滑；停下时沿用上一次"""
    hs, last = [], 0.0
    n = len(track)
    for i in range(n):
        a, b = track[max(0, i - win)], track[min(n - 1, i + win)]
        dx, dy = b[1] - a[1], b[2] - a[2]
        if math.hypot(dx, dy) > 5:
            last = math.atan2(dx, dy)
        hs.append(last)
    return hs


# ---------------------------------------------------------------- 写文件


def write_session(dst, track, field, rng, bias, poses, anchors, truth, meta_extra):
    os.makedirs(dst, exist_ok=True)
    hs = headings(track)
    with open(os.path.join(dst, "imu.csv"), "w", newline="\n") as fi, \
            open(os.path.join(dst, "mag_raw.csv"), "w", newline="\n") as fr:
        fi.write(IMU_HEADER_V4 + "\n")
        fr.write("t_ms,mx,my,mz\n")
        prev_h = hs[0]
        for i, ((t, x, y, walking), h) in enumerate(zip(track, hs)):
            tm = T0 + int(round(t * 1000))
            # 手机设备系：y = 行走方向，x = 右，z = 上。地图 heading h：dx = sin h、dy = cos h（地图 y 朝南）
            fe, fn = math.sin(h), -math.cos(h)                # 前方，东北
            re, rn = -fn, fe                                    # 右方 = 前方顺时针转 90°（俯视东北系）
            be, bn, bu = field.at(x, y)
            bd = (be * re + bn * rn, be * fe + bn * fn, bu)
            fr.write(f"{tm},{bd[0] + bias[0] + rng.gauss(0, .4):.3f},{bd[1] + bias[1] + rng.gauss(0, .4):.3f},"
                     f"{bd[2] + bias[2] + rng.gauss(0, .4):.3f}\n")
            if i % 2:
                continue                                        # imu 50 Hz
            bounce = 1.6 * math.sin(2 * math.pi * 1.8 * t) if walking else 0.0
            fwd = 0.6 * math.sin(2 * math.pi * 1.8 * t + 1.2) if walking else 0.0
            dh = (h - prev_h + math.pi) % (2 * math.pi) - math.pi
            prev_h = h
            gz = -dh * 50                                       # 俯视：地图 heading 顺时针增大 → 绕上方轴转 = 负
            th = math.atan2(-fe, fn)                            # 设备 → 东北天：绕 z 转 th，把 (0, 1) 转到 (fe, fn)
            qw, qz = math.cos(th / 2), math.sin(th / 2)
            comp = math.degrees(math.atan2(fe, fn)) % 360
            fi.write(f"{tm},{rng.gauss(0, .05):.4f},{fwd + rng.gauss(0, .05):.4f},{G + bounce + rng.gauss(0, .05):.4f},"
                     f"{rng.gauss(0, .003):.5f},{rng.gauss(0, .003):.5f},{gz + rng.gauss(0, .003):.5f},"
                     f"{bd[0] + rng.gauss(0, .4):.3f},{bd[1] + rng.gauss(0, .4):.3f},{bd[2] + rng.gauss(0, .4):.3f},3,"
                     f"{qw:.6f},0,0,{qz:.6f},{comp:.1f},0,0,{G:.4f}\n")
    with open(os.path.join(dst, "arkit_pose.csv"), "w", newline="\n") as f:
        f.write("t_ms,x_m,y_m,z_m,qx,qy,qz,qw,tracking,limited_reason\n")
        for tm, x, y in poses:
            f.write(f"{tm},{x / 100:.4f},0,{y / 100:.4f},0,0,0,1,2,0\n")
    with open(os.path.join(dst, "anchors.csv"), "w", newline="\n") as f:
        f.write("t_ms,kind,map_x_cm,map_y_cm,ar_x_cm,ar_z_cm,heading_rad,note\n")
        for row in anchors:
            f.write(row + "\n")
    for name in ("ble.csv", "wifi.csv"):
        open(os.path.join(dst, name), "w", newline="\n").write(
            "t_ms,point_id,esl_id,rssi,src,mfg_hex\n" if name == "ble.csv" else "t_ms,bssid,rssi,freq\n")
    if truth is not None:
        with open(os.path.join(dst, "truth.csv"), "w", newline="\n") as f:
            f.write("t_ms,x_cm,y_cm\n")
            for tm, x, y in truth:
                f.write(f"{tm},{x:.1f},{y:.1f}\n")
    meta = {"format_version": 4, "survey": True, "source": "sim_small", "imu_quat_frame": "android_rotation_vector"}
    meta.update(meta_extra)
    json.dump(meta, open(os.path.join(dst, "meta.json"), "w", newline="\n"))


DRIFTS = {  # (尺度均值, 尺度 σ, 朝向 σ/√s)
    "pdr": (1.0, 0.04, math.radians(1.5)),
    "phone": (0.82, 0.07, math.radians(2.0)),
    "vio": (1.0, 0.01, math.radians(0.5)),
    "imu": None,
}


def drift_poses(truth, rng, mean, sigma, head):
    th = rng.uniform(0, 2 * math.pi)
    scale = mean + rng.gauss(0, sigma)
    x = y = 0.0
    out = [(truth[0][0], x, y)]
    for (t0, a0, b0), (t1, a1, b1) in zip(truth, truth[1:]):
        th += rng.gauss(0, head) * math.sqrt(max(t1 - t0, 1) / 1000)
        dx, dy = (a1 - a0) * scale, (b1 - b0) * scale
        x += dx * math.cos(th) - dy * math.sin(th)
        y += dx * math.sin(th) + dy * math.cos(th)
        out.append((t1, x, y))
    return out


def rect_poly(x0, y0, x1, y1):
    return [x0, y0, x1, y0, x1, y1, x0, y1]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out")
    ap.add_argument("--layout", default="office")
    ap.add_argument("--drift", default="pdr", choices=sorted(DRIFTS))
    ap.add_argument("--test-n", type=int, default=12)
    ap.add_argument("--test-min-s", type=float, default=60)
    ap.add_argument("--test-max-s", type=float, default=150)
    ap.add_argument("--lane-cm", type=float, default=120)
    ap.add_argument("--build-n", type=int, default=2)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args(argv)

    rng = random.Random(a.seed)
    rooms, doors, w, h = layout(a.layout)
    field = Field(random.Random(a.seed * 7919 + 1), rooms)
    g = room_graph(rooms, doors)
    bias = (rng.uniform(-60, 60), rng.uniform(-60, 60), rng.uniform(-80, 80))
    os.makedirs(a.out, exist_ok=True)

    build_ids, t_off = [], 0
    order = [r[0] for r in rooms]
    rmap = {r[0]: r for r in rooms}
    for k in range(a.build_n):                         # 每次建图采集都走遍全部房间（经门连起来），各次起点 / 车道错开
        seq = order if k % 2 == 0 else order[::-1]
        pts, cur = [], None
        for rid in seq:
            if cur is not None:
                pts += [(c[0], c[1], 0.0) for c in route(g, cur, rid)]
            off = (k * a.lane_cm / max(a.build_n, 1)) % a.lane_cm
            pts += [(x, y, 0.0) for x, y in lawnmower(inset(rmap[rid], -off / 2 if off else 0), a.lane_cm)]
            cur = rid
        tr = sample(pts, rng)
        tr = [(t + t_off, x, y, wk) for t, x, y, wk in tr]
        t_off = tr[-1][0] + 60
        poses = [(T0 + int(round(t * 1000)), x, y) for t, x, y, _ in tr[::3]]        # 33 Hz，地图坐标
        anchors = [f"{poses[0][0]},align,0,0,0,0,0,"]
        last = -1e9
        for i, (tm, x, y) in enumerate(poses):
            if tm - last >= 5000 or i == len(poses) - 1:
                anchors.append(f"{tm},{'start' if last < 0 else 'reanchor'},{x:.1f},{y:.1f},{x:.1f},{y:.1f},,")
                last = tm
        sid = f"sim_build_{k:02d}"
        write_session(os.path.join(a.out, "build", sid), tr, field, rng, bias, poses, anchors, None, {"purpose": "build"})
        build_ids.append(sid)

    test_ids = []
    for k in range(a.test_n):
        pts = random_walk(rng, rooms, g, a.test_min_s, a.test_max_s)
        tr = sample(pts, rng)
        tr = [(t + t_off, x, y, wk) for t, x, y, wk in tr]
        t_off = tr[-1][0] + 60
        truth = [(T0 + int(round(t * 1000)), x, y) for t, x, y, _ in tr[::3]]
        d = DRIFTS[a.drift]
        poses = [] if d is None else drift_poses(truth, rng, *d)
        sid = f"sim_test_{k:02d}"
        write_session(os.path.join(a.out, "test", sid), tr, field, rng, bias, poses, [], truth, {"purpose": "test"})
        test_ids.append(sid)

    floor = [rect_poly(*r[1:]) for r in rooms] + [rect_poly(*d[2]) for d in doors]
    units = [{"id": r[0], "category": "room", "polygon": rect_poly(*r[1:])} for r in rooms]
    elems = []
    for _, _, d in doors:                               # 门：房间约束（--rooms）靠它知道哪里能穿墙
        vertical = (d[2] - d[0]) < (d[3] - d[1])        # 竖墙上的门洞：宽沿 y
        elems.append({"shapeType": "MapDoor", "x": (d[0] + d[2]) / 2, "y": (d[1] + d[3]) / 2,
                      "width": DOOR, "height": WALL, "rotation": 90 if vertical else 0, "heightCm": 210})
    json.dump({"width": w, "height": h, "mapElementList": elems, "floorPolygons": floor, "units": units,
               "floorName": f"sim-{a.layout}"}, open(os.path.join(a.out, "map.json"), "w", newline="\n"))
    area = sum((r[3] - r[1]) * (r[4] - r[2]) for r in rooms) / 1e4
    json.dump({"layout": a.layout, "drift": a.drift, "seed": a.seed, "area_m2": round(area), "build": build_ids, "test": test_ids},
              open(os.path.join(a.out, "manifest.json"), "w", newline="\n"), indent=1)
    print(f"sim-{a.layout}：{round(area)} m²，建图 {len(build_ids)} 次，测试 {len(test_ids)} 次（漂移 {a.drift}）-> {a.out}")


if __name__ == "__main__":
    main()

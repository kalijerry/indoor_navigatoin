import XCTest
@testable import HPASSKit

/// 携带无关的运动模型：携带模式分类、分模式步长 / 航向、摆臂步幅平均、重力列、粒子滤波按模式重撒。
/// 全部用合成 IMU（SyntheticCarryIMU.swift）：看屏 → 口袋 / 通话 / 摆臂切换后航向能找回、粒子不瞬移。
final class CarryMotionTests: XCTestCase {

    // MARK: - 工具

    /// 60 m × 4 m 走廊的磁场（m 为单位），x 和 y 都有起伏，30 m 内不重复
    private static func fieldAt(_ p: Point2) -> (vertical: Double, horizontal: Double) {
        let x = p.x / 100, y = p.y / 100
        let bz = -42 + 6 * sin(0.9 * x) + 4 * sin(0.37 * x + 1) + 2 * sin(1.7 * x + 0.5) + 3 * sin(1.1 * y + 0.3 * x)
        let bh = 24 + 5 * sin(0.6 * x + 2) + 3 * sin(1.3 * x) + 2 * sin(0.9 * y - 0.2 * x)
        return (bz, bh)
    }

    private func corridorField() -> MagneticFieldMap {
        let w = 6000.0, h = 400.0, cell = 50.0
        let cols = Int(w / cell), rows = Int(h / cell)
        var cells = [MagneticFeature?](), sig = [MagneticFeature?]()
        for j in 0..<rows {
            for i in 0..<cols {
                let p = Point2((Double(i) + 0.5) * cell, (Double(j) + 0.5) * cell)
                let f = Self.fieldAt(p)
                cells.append(MagneticFeature(total: (f.vertical * f.vertical + f.horizontal * f.horizontal).squareRoot(),
                                             vertical: f.vertical, horizontal: f.horizontal))
                sig.append(MagneticFeature(total: 0.5, vertical: 0.5, horizontal: 0.5))
            }
        }
        return MagneticFieldMap(widthCm: w, heightCm: h, cellCm: cell, cells: cells, sigmas: sig)
    }

    private func corridorWalkable() -> WalkableMap {
        WalkableMap(crosses: [CrossSegment(code: "C", a: Point2(0, 200), b: Point2(6000, 200), lineWidth: 400)], widthCm: 6000, heightCm: 400)
    }

    private func simulate(_ script: CarryScript) -> (samples: [IMUSample], truth: [CarryTruth]) {
        var sim = CarrySim(script: script)
        sim.field = Self.fieldAt
        return sim.generate()
    }

    /// 沿走廊 +x 走（地图航向 90°）
    private func straightScript(durationS: Double, postures: [CarryScript.PostureSeg], pauses: [CarryScript.Pause] = []) -> CarryScript {
        CarryScript(durationS: durationS, headings: [.init(fromS: 0, headingDeg: 90)], postures: postures, pauses: pauses)
    }

    private static func angleDiffDeg(_ a: Double, _ b: Double) -> Double {
        FusionMath.degrees(FusionMath.wrapPi(a - b))
    }

    private static func circularStdDeg(_ degs: [Double]) -> Double {
        guard !degs.isEmpty else { return 0 }
        var s = 0.0, c = 0.0
        for d in degs { s += sin(FusionMath.radians(d)); c += cos(FusionMath.radians(d)) }
        let r = min(max((s * s + c * c).squareRoot() / Double(degs.count), 1e-12), 1)
        return FusionMath.degrees((-2 * log(r)).squareRoot())
    }

    private static func circularMeanDeg(_ degs: [Double]) -> Double {
        var s = 0.0, c = 0.0
        for d in degs { s += sin(FusionMath.radians(d)); c += cos(FusionMath.radians(d)) }
        return FusionMath.degrees(atan2(s, c))
    }

    /// 跑一遍引擎，返回每帧输出和对应真值
    private func runEngine(_ data: (samples: [IMUSample], truth: [CarryTruth]), motionOn: Bool,
                           configure: ((inout FusionConfig) -> Void)? = nil) -> (engine: FusionEngine, outs: [(FusionOutput, CarryTruth)]) {
        var cfg = FusionConfig()
        cfg.useMagneticHeading = false
        cfg.useCorridorConstraint = false
        cfg.motion.enabled = motionOn
        configure?(&cfg)
        let engine = FusionEngine(corridors: [], config: cfg)
        engine.setInitialPosition(data.truth[0].position, headingRad: data.truth[0].headingRad)
        var outs: [(FusionOutput, CarryTruth)] = []
        for (s, t) in zip(data.samples, data.truth) {
            if let o = engine.process(s) { outs.append((o, t)) }
        }
        return (engine, outs)
    }

    // MARK: - 合成器自检（约定一致）

    /// 平放看屏、向左转（航向增大）→ 陀螺 gz > 0（和 FusionTests 的 ω_up 约定一致）；静止时 az ≈ +g、重力列 = 加速度。
    func testSimulatorConventions() {
        var script = CarryScript(durationS: 8, headings: [.init(fromS: 0, headingDeg: 0), .init(fromS: 3, headingDeg: 90)],
                                 postures: [.init(fromS: 0, posture: .texting(tiltDeg: 0))], pauses: [.init(fromS: 0, toS: 2), .init(fromS: 5, toS: 8)])
        script.turnRampS = 2
        let d = simulate(script)
        let still = d.samples.filter { Double($0.tMs - CarrySim.t0) / 1000 < 1.5 }
        XCTAssertGreaterThan(still.count, 50)
        for s in still.prefix(20) {
            XCTAssertEqual(s.az, FusionMath.gravity, accuracy: 0.3)
            XCTAssertEqual(abs(s.ax) + abs(s.ay), 0, accuracy: 0.4)
            XCTAssertEqual(s.gravity!.z, FusionMath.gravity, accuracy: 1e-6)
        }
        let turning = d.samples.filter { let t = Double($0.tMs - CarrySim.t0) / 1000; return t > 3.2 && t < 4.8 }
        let gz = turning.map(\.gz).reduce(0, +) / Double(turning.count)
        XCTAssertEqual(gz, (Double.pi / 2) / 2, accuracy: 0.05, "左转 90°/2 s 应给 +0.785 rad/s 的 gz")
        // 四元数给的「向上」和重力列一致
        for s in d.samples.prefix(200) where s.attitude != nil {
            let u = FusionMath.upFromQuaternion(w: s.attitude!.w, x: s.attitude!.x, y: s.attitude!.y, z: s.attitude!.z)!
            let g = FusionVec3(s.gravity!.x, s.gravity!.y, s.gravity!.z).normalized
            XCTAssertLessThan(FusionMath.degrees(u.angle(to: g)), 0.5)
        }
        // 姿态滤波只靠陀螺积分也能跟上这次转弯（合成器的陀螺和旋转自洽）
        let (_, outs) = runEngine(d, motionOn: false)
        let last = outs.last!.0
        XCTAssertEqual(Self.angleDiffDeg(last.headingRad, FusionMath.radians(90)), 0, accuracy: 6)
    }

    /// 摆臂时手的离心加速度会把「加速度低通」的向上方向带偏；重力列不受影响，Bz 误差明显更小。
    func testGravityColumnFixesVerticalFeatureWhileSwinging() {
        let d = simulate(straightScript(durationS: 14, postures: [.init(fromS: 0, posture: .swinging(armDeg: 15, wristYawDeg: 20))]))
        func bzError(useGravity: Bool) -> Double {
            let ex = MagneticFeatureExtractor()
            ex.useSampleGravity = useGravity
            var errs: [Double] = []
            for (s, t) in zip(d.samples, d.truth) {
                guard let f = ex.process(s) else { continue }
                if Double(s.tMs - CarrySim.t0) / 1000 > 3 { errs.append(abs(f.vertical - Self.fieldAt(t.position).vertical)) }
            }
            let sorted = errs.sorted()
            return sorted[sorted.count / 2]
        }
        let lpf = bzError(useGravity: false), grav = bzError(useGravity: true)
        XCTAssertLessThan(grav, 1.5, "重力列当向上：Bz 中位误差 \(grav) µT")
        XCTAssertLessThan(grav, lpf * 0.5, "加速度低通 \(lpf) µT vs 重力列 \(grav) µT")
        // 老数据（没有重力列）：和以前一样走加速度低通，不崩
        var v3 = straightScript(durationS: 4, postures: [.init(fromS: 0, posture: .texting(tiltDeg: 40))])
        v3.v4 = false
        let old = simulate(v3)
        XCTAssertNil(old.samples[10].gravity)
        let ex = MagneticFeatureExtractor()
        var f: MagneticFeature?
        for s in old.samples { f = ex.process(s) ?? f }
        XCTAssertNotNil(f)
        XCTAssertFalse(ex.upIsExternal)
    }

    // MARK: - IMUSample：格式 v4 列

    func testIMUSampleCSVParsesV3AndV4() {
        let v3 = "1700000000000,0.1,0.2,9.8,0,0,0,20,0,-40,2,1,0,0,0,-1".split(separator: ",")
        let a = IMUSample.fromCSV(v3)!
        XCTAssertNil(a.gravity, "v3 的四元数是占位，不读；没有重力列")
        XCTAssertNil(a.attitude)
        XCTAssertEqual(a.az, 9.8)
        let v4 = "1700000000000,0.1,0.2,9.8,0,0,0,20,0,-40,2,0.7071068,0.7071068,0,0,-1,0,0,9.80".split(separator: ",")
        let b = IMUSample.fromCSV(v4)!
        XCTAssertEqual(b.gravity!.z, 9.80, accuracy: 1e-9)
        XCTAssertEqual(b.attitude!.w, 0.7071068, accuracy: 1e-6)
        XCTAssertEqual(b.upFromSample!.z, 1, accuracy: 1e-6)
        // 重力列全 0（当时不可用）→ nil；四元数模长离谱 → nil
        let bad = "1700000000000,0.1,0.2,9.8,0,0,0,20,0,-40,2,3,0,0,0,-1,0,0,0".split(separator: ",")
        let c = IMUSample.fromCSV(bad)!
        XCTAssertNil(c.gravity)
        XCTAssertNil(c.attitude)
        XCTAssertNil(IMUSample.fromCSV("x,1".split(separator: ",")))
        // 四元数 → 向上：设备绕 x 转 +90°（设备 → 世界）后设备 +y 指向世界 z，所以世界 z 在设备系里是 +y
        let s2 = 0.5.squareRoot()
        let u = FusionMath.upFromQuaternion(w: s2, x: s2, y: 0, z: 0)!
        XCTAssertEqual(u.y, 1, accuracy: 1e-9)
        XCTAssertEqual(u.z, 0, accuracy: 1e-9)
    }

    func testSurveySessionLoaderReadsV4Columns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hpass-v4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let header = "t_ms,ax,ay,az,gx,gy,gz,mx,my,mz,mag_acc,qw,qx,qy,qz,heading_deg,gvx,gvy,gvz\n"
        var imu = header
        for i in 0..<5 { imu += "\(1700000000000 + i * 20),0,0,9.81,0,0,0,20,0,-40,2,1,0,0,0,-1,0,0,9.81\n" }
        try imu.write(to: dir.appendingPathComponent("imu.csv"), atomically: true, encoding: .utf8)
        try "t_ms,x_m,y_m,z_m,qx,qy,qz,qw,tracking,limited_reason\n".write(to: dir.appendingPathComponent("arkit_pose.csv"), atomically: true, encoding: .utf8)
        let s = try SurveySessionLoader.load(dir, requireAnchors: false)
        XCTAssertEqual(s.imu.count, 5)
        XCTAssertEqual(s.imu[0].gravity!.z, 9.81, accuracy: 1e-9)
        XCTAssertEqual(s.imu[0].attitude!.w, 1, accuracy: 1e-9)
    }

    // MARK: - 携带模式分类

    private func classify(_ posture: CarryPosture, proximity: Bool? = nil, stepHz: Double = 2.0,
                          after prior: CarryPosture? = nil) -> (modes: [CarryMode], state: CarryState) {
        // prior：先这样拿 6 s 再换成 posture（竖持只能从手持过来），统计换之后 6 s 起的判定
        let off = prior == nil ? 0.0 : 6.0
        var postures: [CarryScript.PostureSeg] = [.init(fromS: off, posture: posture)]
        if let pr = prior { postures.insert(.init(fromS: 0, posture: pr), at: 0) }
        var script = straightScript(durationS: 12 + off, postures: postures)
        script.stepHz = stepHz
        script.speedMS = 0.65 * stepHz
        let d = simulate(script)
        let c = CarryModeClassifier()
        c.proximityNear = proximity
        var modes: [CarryMode] = []
        var last = c.state
        for s in d.samples {
            last = c.process(s)
            if Double(s.tMs - CarrySim.t0) / 1000 > 6 + off { modes.append(last.mode) }
        }
        return (modes, last)
    }

    private func share(_ modes: [CarryMode], _ m: CarryMode) -> Double {
        Double(modes.filter { $0 == m }.count) / Double(max(modes.count, 1))
    }

    func testClassifierRecognisesEachPosture() {
        let cases: [(CarryPosture, CarryMode)] = [
            (.texting(tiltDeg: 40), .texting), (.texting(tiltDeg: 10), .texting),
            (.upright(backDeg: 15), .upright),
            (.calling(tiltDeg: 40, rightEar: true, headTurnDeg: 15), .calling),
            (.pocket(yawDeg: 35, thighDeg: 25), .pocket),
            (.swinging(armDeg: 15, wristYawDeg: 20), .swinging),
            (.bag(yawDeg: 60, swayDeg: 15), .bag),
        ]
        for (p, expected) in cases {
            // 竖持只能从手持过来（一上来就竖着、陀螺小的按包里处理）
            let r = expected == .upright ? classify(p, after: .texting(tiltDeg: 40)) : classify(p)
            XCTAssertGreaterThanOrEqual(share(r.modes, expected), 0.8,
                                        "\(p) → \(expected)：实际 \(Dictionary(grouping: r.modes, by: { $0 }).mapValues(\.count))，特征 \(r.state.features)")
        }
        // 一上来就竖着、晃得少（包里 / 胸前口袋）：δ 未知，不能给竖持的紧先验（评审：1.5 Hz 的包里 100% 判成竖持）
        for hz in [1.5, 2.0] {
            XCTAssertEqual(share(classify(.upright(backDeg: 15), stepHz: hz).modes, .upright), 0, "\(hz) Hz")
            XCTAssertEqual(share(classify(.bag(yawDeg: 60, swayDeg: 15), stepHz: hz).modes, .upright), 0, "\(hz) Hz")
        }
        // 近距离传感器说贴着：竖直的手机一律算通话（竖持和通话的 δ 先验相反，宁可算通话）
        let near = classify(.upright(backDeg: 15), proximity: true, after: .texting(tiltDeg: 40))
        XCTAssertGreaterThanOrEqual(share(near.modes, .calling), 0.8)
        // 近距离传感器说没贴着：接近竖直的后仰手机算竖持
        let far = classify(.calling(tiltDeg: 40, rightEar: true, headTurnDeg: 15), proximity: false)
        XCTAssertEqual(share(far.modes, .calling), 0)
    }

    /// 站着不动 → still，但「携带姿态」沿用（口袋里站一会儿不会变成未知）
    func testClassifierStillKeepsActiveMode() {
        let d = simulate(straightScript(durationS: 16, postures: [.init(fromS: 0, posture: .pocket(yawDeg: 35, thighDeg: 25))],
                                        pauses: [.init(fromS: 8, toS: 16)]))
        let c = CarryModeClassifier()
        var sawStill = false
        var st = c.state
        for s in d.samples {
            st = c.process(s)
            let t = Double(s.tMs - CarrySim.t0) / 1000
            if t > 12 {
                XCTAssertEqual(st.mode, .still, "t=\(t)")
                sawStill = true
            }
        }
        XCTAssertTrue(sawStill)
        XCTAssertEqual(st.activeMode, .pocket)
    }

    /// 看屏 → 口袋：切换过程触发「操作手机」事件，几秒内判成口袋；全程模式切换次数有限（滞回起作用）
    func testClassifierDetectsSwitchAndHandledEvent() {
        let switchAt = 10.0
        let d = simulate(straightScript(durationS: 24, postures: [.init(fromS: 0, posture: .texting(tiltDeg: 40)),
                                                                   .init(fromS: switchAt, posture: .pocket(yawDeg: 35, thighDeg: 25))]))
        let c = CarryModeClassifier()
        var handledAt: [Double] = []
        var pocketAt: Double?
        var changes = 0
        var prev: CarryMode = .unknown
        for s in d.samples {
            let st = c.process(s)
            let t = Double(s.tMs - CarrySim.t0) / 1000
            if st.handled { handledAt.append(t) }
            if pocketAt == nil, st.mode == .pocket { pocketAt = t }
            if st.mode != prev, st.mode.isCarryPosture, prev.isCarryPosture { changes += 1 }
            if st.mode.isCarryPosture { prev = st.mode }
        }
        XCTAssertFalse(handledAt.isEmpty, "切换时应触发操作手机事件")
        XCTAssertTrue(handledAt.allSatisfy { $0 >= switchAt - 0.3 && $0 <= switchAt + 2.5 }, "事件时刻 \(handledAt)")
        XCTAssertNotNil(pocketAt)
        XCTAssertLessThan(pocketAt ?? .infinity, switchAt + 6, "切换后 6 s 内应判成口袋：\(pocketAt ?? -1)")
        XCTAssertLessThanOrEqual(changes, 2, "携带姿态来回跳了 \(changes) 次")
    }

    /// 稳定的口袋 / 摆臂走路不该触发「操作手机」：步频 1.4～2.2 Hz、大腿 / 手臂摆幅 15～40° 扫一遍，
    /// 一开始判出模式之后（> 5 s）一次事件都不许有（评审：1.5 Hz 慢走时每 2 s 误报一次，整圆重撒、判丢被一直压着）
    func testNoHandledEventsInSteadyCarryAcrossCadences() {
        var bad: [String] = []
        for hz in [1.4, 1.5, 1.6, 1.8, 2.0, 2.2] {
            for amp in [15.0, 25.0, 35.0, 40.0] {
                for posture in [CarryPosture.pocket(yawDeg: 35, thighDeg: amp), .swinging(armDeg: amp, wristYawDeg: 20)] {
                    var script = straightScript(durationS: 30, postures: [.init(fromS: 0, posture: posture)])
                    script.stepHz = hz
                    script.speedMS = 0.65 * hz
                    let d = simulate(script)
                    let c = CarryModeClassifier()
                    var n = 0
                    for s in d.samples where c.process(s).handled && Double(s.tMs - CarrySim.t0) / 1000 > 5 { n += 1 }
                    if n > 0 { bad.append("\(posture) @\(hz) Hz: \(n)") }
                }
            }
        }
        XCTAssertTrue(bad.isEmpty, "稳定携带误报操作手机：\(bad)")
    }

    /// HoldClassifier 的公开接口不变，静止时按倾角映射（原有行为），走动时映射携带模式
    func testHoldClassifierShellMapsCarryModes() {
        let d = simulate(straightScript(durationS: 10, postures: [.init(fromS: 0, posture: .pocket(yawDeg: 35, thighDeg: 25))]))
        let h = HoldClassifier()
        var p: HoldPosture = .unknown
        for s in d.samples { p = h.process(s) }
        XCTAssertEqual(p, .pocket)
        XCTAssertEqual(h.carryMode, .pocket)
        XCTAssertFalse(p.suitsCamera)
        XCTAssertEqual(HoldPosture(carry: .texting, tiltDeg: 10), .flat)
        XCTAssertEqual(HoldPosture(carry: .texting, tiltDeg: 45), .reading)
        XCTAssertEqual(HoldPosture(carry: .still, tiltDeg: 90), .upright)
        XCTAssertEqual(HoldPosture(carry: .still, tiltDeg: 160), .other)
        XCTAssertEqual(HoldPosture(carry: .calling, tiltDeg: 90), .calling)
        h.reset()
        XCTAssertEqual(h.carryMode, .unknown)
    }

    // MARK: - 计步

    /// 自适应计步：毫秒时间戳抖动（19/20/21 ms）不改变计数；慢走（1.0 s/步）之后接正常步频（0.55 s/步）每步都数上
    /// （评审：σ 窗按每个样本的 dt 改长度会被反复清空；步频锁的步周期卡在 1.1 s 时会一直只数一半）
    func testAdaptiveStepDetectorJitterAndCadenceChange() {
        /// 按给定的步周期序列生成 a_dyn（每步一个正弦周期，幅度 3 m/s²），返回 (样本, 真实步数)
        func run(periods: [Double], jitter: Bool) -> (steps: Int, truth: Int) {
            let det = FusionStepDetector()
            det.adaptive = true
            var t = 0.0, tMs: Int64 = 0, lastMs: Int64 = 0, steps = 0, k = 0
            var bounds: [Double] = []
            var acc = 0.0
            for p in periods { acc += p; bounds.append(acc) }
            while t < acc {
                let i = bounds.firstIndex { t < $0 } ?? bounds.count - 1
                let start = i == 0 ? 0 : bounds[i - 1]
                let ph = (t - start) / periods[i]
                let d = -3 * sin(2 * Double.pi * ph)
                let s = IMUSample(tMs: tMs, ax: 0, ay: 0, az: FusionMath.gravity + d, gx: 0, gy: 0, gz: 0, mx: 20, my: 0, mz: -40)
                let dt = k == 0 ? 0.02 : Double(tMs - lastMs) / 1000
                if det.update(sample: s, dt: dt, minStepIntervalMs: 250, maxStepLengthM: 1.0) != nil { steps += 1 }
                lastMs = tMs
                let step: Int64 = jitter ? [19, 20, 21, 20, 21, 19][k % 6] : 20
                tMs += step; t = Double(tMs) / 1000; k += 1
            }
            return (steps, periods.count)
        }
        let even = run(periods: Array(repeating: 0.55, count: 40), jitter: false)
        let jit = run(periods: Array(repeating: 0.55, count: 40), jitter: true)
        XCTAssertEqual(Double(jit.steps), Double(even.steps), accuracy: 1, "抖动：\(jit) 对 \(even)")
        XCTAssertEqual(Double(jit.steps), 40, accuracy: 2)
        let mixed = run(periods: Array(repeating: 1.0, count: 8) + Array(repeating: 0.55, count: 30), jitter: true)
        XCTAssertEqual(Double(mixed.steps), Double(mixed.truth), accuracy: 2, "慢走接正常步频：\(mixed)")
        let slowStart = run(periods: [1.2] + Array(repeating: 0.55, count: 30), jitter: false)
        XCTAssertEqual(Double(slowStart.steps), Double(slowStart.truth), accuracy: 2, "慢起步：\(slowStart)")
    }

    /// 自适应阈值 + 步频锁：大幅度（口袋）信号每步之后有一个 1.5 m/s² 的脚跟次峰，固定阈值会多计一倍，自适应不会；
    /// 小幅度（看屏）信号两者一样
    func testAdaptiveStepDetectorRejectsSecondaryPeaks() {
        /// 一个 0.7 s 的步周期：大谷 → 主峰 → 小谷 → 平 → 脚跟次峰（零均值，这样慢低通不会改变幅度；快低通会把窄峰压掉一些）
        func cycle(main: Double, bump: Double) -> [Double] {
            var v: [Double] = []
            for k in 0..<35 {
                let t = Double(k) * 0.02
                var d = 0.0
                if t < 0.15 { d = -0.8 * main * sin(Double.pi * t / 0.15) }
                else if t < 0.30 { d = main * sin(Double.pi * (t - 0.15) / 0.15) }
                else if t < 0.40 { d = -0.4 * main * sin(Double.pi * (t - 0.30) / 0.10) }
                else if t >= 0.50 { d = bump * sin(Double.pi * (t - 0.50) / 0.20) }
                v.append(d)
            }
            let mean = v.reduce(0, +) / Double(v.count)
            return v.map { $0 - mean }
        }
        func count(main: Double, bump: Double, adaptive: Bool) -> (steps: Int, truth: Int) {
            let det = FusionStepDetector()
            det.adaptive = adaptive
            let c = cycle(main: main, bump: bump)
            var steps = 0
            let cycles = 30
            for i in 0..<(cycles * c.count) {
                let s = IMUSample(tMs: Int64(i * 20), ax: 0, ay: 0, az: FusionMath.gravity + c[i % c.count], gx: 0, gy: 0, gz: 0, mx: 20, my: 0, mz: -40)
                if det.update(sample: s, dt: 0.02, minStepIntervalMs: 250, maxStepLengthM: 1.0) != nil { steps += 1 }
            }
            return (steps, cycles)
        }
        let legacyBig = count(main: 4.5, bump: 1.8, adaptive: false)
        let adaptiveBig = count(main: 4.5, bump: 1.8, adaptive: true)
        XCTAssertGreaterThan(Double(legacyBig.steps), Double(legacyBig.truth) * 1.5, "固定阈值应多计：\(legacyBig)")
        XCTAssertEqual(Double(adaptiveBig.steps), Double(adaptiveBig.truth), accuracy: 2, "自适应：\(adaptiveBig)")
        let legacySmall = count(main: 1.8, bump: 0, adaptive: false)
        let adaptiveSmall = count(main: 1.8, bump: 0, adaptive: true)
        XCTAssertEqual(legacySmall.steps, adaptiveSmall.steps)
        XCTAssertEqual(Double(legacySmall.steps), Double(legacySmall.truth), accuracy: 2)
        // 关着时默认值和以前一样
        XCTAssertFalse(FusionStepDetector().adaptive)
        XCTAssertEqual(FusionStepDetector().weinbergK, 0.45)
        XCTAssertEqual(StepDetectorTuning().peakMin, 0.7)
    }

    /// 自适应阈值下限 0.7：iPhone 端平看屏慢走的步峰小（这里滤波后 ≈ 0.85 m/s²，低于原来的下限 1.0），自适应要一步不漏，
    /// 固定阈值 1.0 数不到；手拿着站着不动的抖动（a_dyn 峰 ≈ 0.55，实测 P90 0.64）两者都不计成步
    func testAdaptiveStepFloorCountsLowAmplitudeWalking() {
        func cycle(main: Double) -> [Double] {
            var v: [Double] = []
            for k in 0..<45 {   // 0.9 s 一步（慢走）
                let t = Double(k) * 0.02
                var d = 0.0
                if t < 0.2 { d = -0.8 * main * sin(Double.pi * t / 0.2) }
                else if t < 0.4 { d = main * sin(Double.pi * (t - 0.2) / 0.2) }
                v.append(d)
            }
            let mean = v.reduce(0, +) / Double(v.count)
            return v.map { $0 - mean }
        }
        func count(_ signal: (Int) -> Double, samples: Int, adaptive: Bool) -> (steps: Int, maxDyn: Double) {
            let det = FusionStepDetector()
            det.adaptive = adaptive
            var steps = 0, maxDyn = 0.0
            for i in 0..<samples {
                let s = IMUSample(tMs: Int64(i * 20), ax: 0, ay: 0, az: FusionMath.gravity + signal(i), gx: 0, gy: 0, gz: 0, mx: 20, my: 0, mz: -40)
                if det.update(sample: s, dt: 0.02, minStepIntervalMs: 250, maxStepLengthM: 1.0) != nil { steps += 1 }
                if i > 150 { maxDyn = max(maxDyn, det.lastDyn) }
            }
            return (steps, maxDyn)
        }
        let c = cycle(main: 1.15)
        let cycles = 30
        let walkA = count({ c[$0 % c.count] }, samples: cycles * c.count, adaptive: true)
        let walkL = count({ c[$0 % c.count] }, samples: cycles * c.count, adaptive: false)
        XCTAssertLessThan(walkA.maxDyn, 1.0, "步峰应低于原下限：\(walkA)")
        XCTAssertGreaterThan(walkA.maxDyn, 0.7, "步峰应高于新下限：\(walkA)")
        XCTAssertEqual(Double(walkA.steps), Double(cycles), accuracy: 2, "自适应小步：\(walkA)")
        XCTAssertLessThan(walkL.steps, cycles / 3, "固定阈值数不到小步：\(walkL)")
        // 手抖：几个 1～4 Hz 的正弦叠加，峰 ≈ 0.5
        let still: (Int) -> Double = { i in
            let t = Double(i) * 0.02
            return 0.22 * sin(2 * Double.pi * 1.3 * t + 0.4) + 0.18 * sin(2 * Double.pi * 2.1 * t + 1.9) + 0.1 * sin(2 * Double.pi * 3.7 * t + 0.7)
        }
        let stillA = count(still, samples: 1500, adaptive: true)
        XCTAssertLessThan(stillA.maxDyn, 0.7, "\(stillA)")
        XCTAssertEqual(stillA.steps, 0, "站着手抖不计步：\(stillA)")
    }

    /// 分模式 K 表接管步长，在线标定回写、持久化恢复；关着时 K 不变
    func testPerModeStepLengthAndOnlineCalibration() {
        let d = simulate(straightScript(durationS: 12, postures: [.init(fromS: 0, posture: .pocket(yawDeg: 35, thighDeg: 25))]))
        var table = CarryMotionTable.placeholder
        var pocket = table[.pocket]
        pocket.stepLengthK = 0.37
        table[.pocket] = pocket
        let (engine, outs) = runEngine(d, motionOn: true) { $0.motion.table = table }
        XCTAssertEqual(engine.activeCarryMode, .pocket)
        XCTAssertEqual(engine.effectiveStepLengthK, 0.37, accuracy: 1e-9)
        XCTAssertEqual(outs.last!.0.carryMode, .pocket)
        // 默认 K 0.45 的引擎步长更长
        let (legacy, outsL) = runEngine(d, motionOn: false)
        XCTAssertEqual(legacy.effectiveStepLengthK, 0.45, accuracy: 1e-9)
        XCTAssertEqual(outsL.last!.0.carryMode, .unknown)
        XCTAssertEqual(outsL.last!.0.stepLengthM / outs.last!.0.stepLengthM, 0.45 / 0.37, accuracy: 0.15)
        // 在线标定：粒子滤波说步长比例中位 1.2 → 吸收一半 → K × 1.1
        var learned: (CarryMode, Double)?
        engine.onStepScaleLearned = { learned = ($0, $1) }
        let applied = engine.applyLearnedStepScale(1.2, for: .pocket)
        XCTAssertEqual(applied, 1.1, accuracy: 1e-9)
        XCTAssertEqual(engine.effectiveStepLengthK, 0.37 * 1.1, accuracy: 1e-9)
        XCTAssertEqual(learned?.0, .pocket)
        XCTAssertEqual(learned?.1 ?? 0, 1.1, accuracy: 1e-9)
        // 离谱的比例不吸收；限幅
        XCTAssertEqual(engine.applyLearnedStepScale(3, for: .pocket), 1)
        for _ in 0..<20 { _ = engine.applyLearnedStepScale(1.9, for: .pocket) }
        XCTAssertEqual(engine.learnedStepScales[.pocket]!, 1.7, accuracy: 1e-9)
        // 恢复持久化
        engine.setLearnedStepScales([.pocket: 0.9, .texting: 5])
        XCTAssertEqual(engine.learnedStepScales[.pocket], 0.9)
        XCTAssertNil(engine.learnedStepScales[.texting])
        XCTAssertEqual(engine.effectiveStepLengthK, 0.37 * 0.9, accuracy: 1e-9)
        // 关着时不吸收
        XCTAssertEqual(legacy.applyLearnedStepScale(1.2, for: .pocket), 1)
    }

    // MARK: - 引擎航向几何

    /// 看屏 → 竖持：两个模式的前向轴都是行走方向，轴切换按几何补偿，引擎航向全程 ≈ 行走航向，不需要重撒
    func testTextingToUprightKeepsWalkingHeading() {
        let d = simulate(straightScript(durationS: 24, postures: [.init(fromS: 0, posture: .texting(tiltDeg: 40)),
                                                                   .init(fromS: 10, posture: .upright(backDeg: 15))]))
        for motionOn in [false, true] {
            let (engine, outs) = runEngine(d, motionOn: motionOn)
            var maxErr = 0.0
            for (o, t) in outs {
                let tt = Double(o.tMs - CarrySim.t0) / 1000
                guard tt > 2, tt < 10 || tt > 12 else { continue }
                maxErr = max(maxErr, abs(Self.angleDiffDeg(o.headingRad, t.headingRad)))
            }
            XCTAssertLessThan(maxErr, 8, "motion=\(motionOn)：看屏→竖持航向最大偏差 \(maxErr)°")
            if motionOn {
                XCTAssertEqual(engine.activeCarryMode, .upright)
                let kinds = engine.carryEvents.map(\.kind)
                XCTAssertTrue(kinds.contains(.changed), "应有一次 texting→upright 的切换事件：\(kinds)")
                let ev = engine.carryEvents.first { $0.kind == .changed }!
                XCTAssertEqual(ev.from, .texting); XCTAssertEqual(ev.to, .upright)
                // 慢慢立起来（没有「操作手机」事件）：δ 没变（引擎前向轴按几何切换），只切参数、保留偏差
                XCTAssertTrue(ev.keepBias)
                XCTAssertEqual(ev.lostSuppressCm, 0)
            }
        }
    }

    /// 口袋：引擎航向 = 前向轴方位角，和行走航向差一个常数夹角 δ（这里 ≈ 35°），而且不随大腿摆动漂
    func testPocketHeadingOffsetIsConstant() {
        let d = simulate(straightScript(durationS: 20, postures: [.init(fromS: 0, posture: .pocket(yawDeg: 35, thighDeg: 25))]))
        let (_, outs) = runEngine(d, motionOn: true)
        // 起点航向是用户给的行走方向，所以一开始 δ 被吸收进了初值；测的是「稳定」：偏差的圆标准差小
        let offs = outs.filter { Double($0.0.tMs - CarrySim.t0) / 1000 > 3 }.map { Self.angleDiffDeg($0.0.headingRad, $0.1.headingRad) }
        XCTAssertLessThan(Self.circularStdDeg(offs), 6, "口袋里引擎航向相对行走方向应是常数，实际圆标准差 \(Self.circularStdDeg(offs))°")
    }

    /// 通话几何：手机接近竖直（后仰 25°）时前向轴 −z 指向侧面，切换后引擎航向偏 ≈ ±90°；
    /// 后仰 45° 时前向轴切回 +y、指向后方，偏 ≈ 180°。所以通话的先验是 ±90° / 180° 三峰（见 CarryMotionTable）。
    func testCallingHeadingGeometry() {
        for (tilt, expectedAbs) in [(25.0, 90.0), (45.0, 180.0)] {
            let d = simulate(straightScript(durationS: 20, postures: [.init(fromS: 0, posture: .texting(tiltDeg: 40)),
                                                                       .init(fromS: 8, posture: .calling(tiltDeg: tilt, rightEar: true, headTurnDeg: 0))]))
            let (_, outs) = runEngine(d, motionOn: true)
            let offs = outs.filter { Double($0.0.tMs - CarrySim.t0) / 1000 > 11 }.map { Self.angleDiffDeg($0.0.headingRad, $0.1.headingRad) }
            let mean = abs(Self.circularMeanDeg(offs))
            XCTAssertEqual(mean, expectedAbs, accuracy: 12, "后仰 \(tilt)°：通话时引擎航向偏差 \(mean)°")
            XCTAssertLessThan(Self.circularStdDeg(offs), 8)
        }
        XCTAssertEqual(CarryMotionTable.placeholder[.calling].headingCentersDeg, [90, -90, 180])
    }

    /// 摆臂：手腕偏航 ±20° 按步幅周期摆，步事件瞬间采样的航向抖得厉害；按一个步幅周期做圆平均之后抖动小得多
    func testSwingingStrideAverageReducesHeadingJitter() {
        let d = simulate(straightScript(durationS: 24, postures: [.init(fromS: 0, posture: .swinging(armDeg: 15, wristYawDeg: 20))]))
        func jitter(average: Bool) -> (std: Double, steps: Int, engine: FusionEngine) {
            let (engine, outs) = runEngine(d, motionOn: true) { $0.motion.strideAverageHeading = average }
            let offs = outs.filter { Double($0.0.tMs - CarrySim.t0) / 1000 > 4 }.map { Self.angleDiffDeg($0.0.headingRad, $0.1.headingRad) }
            return (Self.circularStdDeg(offs), outs.last!.0.stepCount, engine)
        }
        let inst = jitter(average: false), avg = jitter(average: true)
        XCTAssertEqual(avg.engine.activeCarryMode, .swinging)
        XCTAssertGreaterThan(inst.std, 8, "瞬时航向应明显抖动：\(inst.std)°")
        XCTAssertLessThan(avg.std, inst.std * 0.5, "步幅平均 \(avg.std)° vs 瞬时 \(inst.std)°")
        XCTAssertLessThan(avg.std, 6)
        // 24 s × 2 Hz = 48 步，摆臂的加速度更乱，允许 ±25%
        XCTAssertEqual(Double(avg.steps), 46, accuracy: 12, "摆臂计步 \(avg.steps)")
    }

    /// 默认配置：motion 关、分类器不跑、输出 carryMode = unknown、K 不变、事件为空
    func testMotionPathDisabledByDefault() {
        XCTAssertFalse(FusionConfig().motion.enabled)
        XCTAssertFalse(MagneticConfig().carryModeAdaptive)
        XCTAssertFalse(MagneticConfig.tracking(odometry: .pdr).carryModeAdaptive)
        let d = simulate(straightScript(durationS: 8, postures: [.init(fromS: 0, posture: .pocket(yawDeg: 35, thighDeg: 25))]))
        let (engine, outs) = runEngine(d, motionOn: false)
        XCTAssertEqual(engine.carryMode, .unknown)
        XCTAssertTrue(engine.carryEvents.isEmpty)
        XCTAssertTrue(outs.allSatisfy { $0.0.carryMode == .unknown })
        XCTAssertEqual(engine.effectiveStepLengthK, 0.45)
        // 外部给模式（App 自己的分类器）
        var cfg = FusionConfig(); cfg.motion.enabled = true; cfg.motion.internalClassifier = false
        let ext = FusionEngine(corridors: [], config: cfg)
        ext.setInitialPosition(.zero, headingRad: 0)
        ext.setCarryMode(.texting)
        _ = ext.process(d.samples[0])
        XCTAssertEqual(ext.activeCarryMode, .texting)
        XCTAssertEqual(ext.carryEvents.last?.kind, .initial)
        ext.setCarryMode(.pocket)
        _ = ext.process(d.samples[1])
        XCTAssertEqual(ext.carryEvents.last?.kind, .changed)
        XCTAssertNil(ext.carryEvents.last?.headingSpreadDeg, "口袋：整圆")
        ext.setCarryMode(.still)
        _ = ext.process(d.samples[2])
        XCTAssertEqual(ext.activeCarryMode, .pocket, "still 不改变携带姿态")
        XCTAssertEqual(ext.carryMode, .still)
    }

    // MARK: - 粒子滤波：重撒

    /// carryModeChanged：粒子位置一个都不动、估计不变；航向偏差撒开（整圆 / 双峰 / 保留原偏差）；步长比例撒开；
    /// 之后走 suppressLostCm 不判丢
    func testCarryModeChangedRespreadsWithoutMovingParticles() {
        var cfg = MagneticConfig.tracking(odometry: .pdr)
        cfg.carryModeAdaptive = true
        let loc = MagneticLocalizer(field: corridorField(), walkable: corridorWalkable(), config: cfg, seed: 3)
        loc.reset(start: Point2(300, 200), spreadCm: TrackingProfile.startSpreadCm)
        let before = loc.estimate(), spreadBefore = loc.weightedSpread()
        XCTAssertLessThan(spreadBefore.headingSpreadDeg, 15)
        loc.carryModeChanged(spreadDeg: nil, suppressLostCm: 1500)
        let after = loc.estimate(), spreadAfter = loc.weightedSpread()
        XCTAssertEqual(after.position.x, before.position.x, accuracy: 1e-9)
        XCTAssertEqual(after.position.y, before.position.y, accuracy: 1e-9)
        XCTAssertEqual(after.uncertaintyCm, before.uncertaintyCm, accuracy: 1e-9)
        XCTAssertGreaterThan(spreadAfter.headingSpreadDeg, 80, "整圆均匀后航向散布应很大")
        XCTAssertTrue(loc.lostSuppressed)
        XCTAssertEqual(loc.respreadCount, 1)
        // 双峰 ±90°：偏差集中在 ±90° 附近
        loc.carryModeChanged(spreadDeg: 10, centersDeg: [90, -90], suppressLostCm: 0)
        let biases = loc.headingBiasesForTesting().map { FusionMath.degrees($0) }
        let nearPlus = biases.filter { abs(Self.angleDiffDeg(FusionMath.radians($0), FusionMath.radians(90))) < 30 }.count
        let nearMinus = biases.filter { abs(Self.angleDiffDeg(FusionMath.radians($0), FusionMath.radians(-90))) < 30 }.count
        XCTAssertGreaterThan(nearPlus, biases.count / 3)
        XCTAssertGreaterThan(nearMinus, biases.count / 3)
        XCTAssertGreaterThan(nearPlus + nearMinus, biases.count * 9 / 10)
        // 保留原偏差只在附近撒开：中心仍在 ±90°
        loc.carryModeChanged(spreadDeg: 5, keepBias: true, suppressLostCm: 0)
        let kept = loc.headingBiasesForTesting().map { FusionMath.degrees($0) }
        XCTAssertGreaterThan(kept.filter { abs(abs(Self.angleDiffDeg(FusionMath.radians($0), 0)) - 90) < 25 }.count, kept.count * 9 / 10)
        // 保护期随走过的路耗尽（新建一个：上面那次 1500 cm 的保护期还没走完）
        let l2 = MagneticLocalizer(field: corridorField(), walkable: corridorWalkable(), config: cfg, seed: 3)
        l2.reset(start: Point2(300, 200), spreadCm: TrackingProfile.startSpreadCm)
        l2.carryModeChanged(spreadDeg: 10, suppressLostCm: 300)
        XCTAssertTrue(l2.lostSuppressed)
        for _ in 0..<7 { l2.step(delta: Point2(50, 0), feature: nil) }
        XCTAssertFalse(l2.lostSuppressed)
    }

    /// setCarryMode / apply：关着什么都不做；第一次告知只切参数；再换模式才重撒；视觉里程计不管；reset 后要重新告知
    func testSetCarryModeAndApplyFollowConfig() {
        let off = MagneticLocalizer(field: corridorField(), config: .tracking(odometry: .pdr), seed: 1)
        off.reset(start: Point2(300, 200), spreadCm: 50)
        XCTAssertFalse(off.setCarryMode(.pocket))
        XCTAssertEqual(off.carryMode, .unknown)
        XCTAssertEqual(off.respreadCount, 0)
        let w0 = off.config.featureWeights
        XCTAssertEqual(w0.0, 0.5); XCTAssertEqual(w0.1, 1.0)

        var cfg = MagneticConfig.tracking(odometry: .pdr)
        cfg.carryModeAdaptive = true
        let loc = MagneticLocalizer(field: corridorField(), config: cfg, seed: 1)
        loc.reset(start: Point2(300, 200), spreadCm: 50)
        XCTAssertFalse(loc.setCarryMode(.pocket), "第一次告知不重撒")
        XCTAssertEqual(loc.carryMode, .pocket)
        XCTAssertEqual(loc.config.featureWeights.0, 0.6)
        XCTAssertEqual(loc.config.observationSigmaFloorUT, 5)
        XCTAssertEqual(loc.config.headingBiasWalkDegPerM, 4)
        XCTAssertFalse(loc.setCarryMode(.still), "still 不是携带姿态")
        XCTAssertFalse(loc.setCarryMode(.pocket), "同一模式不重撒")
        XCTAssertTrue(loc.setCarryMode(.texting))
        XCTAssertEqual(loc.respreadCount, 1)
        XCTAssertEqual(loc.config.featureWeights.0, 0.5)
        XCTAssertTrue(loc.lostSuppressed)
        // 事件
        let p = CarryMotionTable.placeholder[.swinging]
        let ev = CarryMotionEvent(tMs: 0, kind: .changed, from: .texting, to: .swinging, headingSpreadDeg: p.headingSpreadDeg,
                                  headingCentersDeg: p.headingCentersDeg, keepBias: false, initialScaleSigma: p.initialScaleSigma,
                                  lostSuppressCm: p.lostSuppressCm)
        XCTAssertTrue(loc.apply(ev))
        XCTAssertEqual(loc.carryMode, .swinging)
        XCTAssertEqual(loc.config.featureWeights.0, 1.0)
        XCTAssertEqual(loc.respreadCount, 2)
        let initial = CarryMotionEvent(tMs: 0, kind: .initial, from: .unknown, to: .pocket, headingSpreadDeg: nil, headingCentersDeg: [0],
                                       keepBias: false, initialScaleSigma: 0.1, lostSuppressCm: 0)
        XCTAssertFalse(loc.apply(initial), "initial 只切参数、不重撒")
        XCTAssertEqual(loc.carryMode, .pocket)
        XCTAssertEqual(loc.respreadCount, 2)
        let handled = CarryMotionEvent(tMs: 0, kind: .handled, from: .pocket, to: .pocket, headingSpreadDeg: 30, headingCentersDeg: [0],
                                       keepBias: true, initialScaleSigma: 0.1, lostSuppressCm: 500)
        XCTAssertTrue(loc.apply(handled))
        XCTAssertEqual(loc.respreadCount, 3)
        // reset 后模式归零，再告知不重撒
        loc.reset(start: Point2(300, 200), spreadCm: 50)
        XCTAssertEqual(loc.carryMode, .unknown)
        XCTAssertFalse(loc.lostSuppressed)
        XCTAssertFalse(loc.setCarryMode(.pocket))
        // 视觉里程计：携带方式不影响位移，什么都不做
        var vio = MagneticConfig.tracking(odometry: .vio)
        vio.carryModeAdaptive = true
        let v = MagneticLocalizer(field: corridorField(), config: vio, seed: 1)
        v.reset(start: Point2(300, 200), spreadCm: 50)
        XCTAssertFalse(v.setCarryMode(.pocket))
        XCTAssertFalse(v.apply(ev))
        XCTAssertEqual(v.config.initialHeadingBiasSigmaDeg, 5)
        // 冷启动配置档默认不受影响
        XCTAssertFalse(MagneticConfig.liveColdStart(visualOdometry: false).carryModeAdaptive)
        XCTAssertEqual(TrackingProfile.motion(for: .pocket).headingSpreadDeg, nil)
        XCTAssertEqual(TrackingProfile.motion(for: .texting).headingSpreadDeg, 15)
    }

    /// 步长比例统计 / 吸收（在线标定 K 的另一半）
    func testScaleStatisticsAndAbsorb() {
        let loc = MagneticLocalizer(field: corridorField(), config: .tracking(odometry: .pdr), seed: 2)
        loc.reset(start: Point2(300, 200), spreadCm: 50)
        let s0 = loc.scaleStatistics()
        XCTAssertEqual(s0.median, 1, accuracy: 0.02)
        XCTAssertEqual(s0.sigma, 0.06, accuracy: 0.015)
        loc.absorbStepScale(1.25)
        let s1 = loc.scaleStatistics()
        XCTAssertEqual(s1.median, 0.8, accuracy: 0.02)
        loc.absorbStepScale(0)      // 离谱的不动
        XCTAssertEqual(loc.scaleStatistics().median, 0.8, accuracy: 0.02)
    }

    // MARK: - 整条流水线：合成 IMU → FusionEngine → MagneticFeature → MagneticLocalizer

    private struct PipelineRun {
        var errs: [(tMs: Int64, errCm: Double, converged: Bool, mode: CarryMode)] = []
        var respreads = 0
        var lost = 0
        var finalHeadingSpreadDeg = 0.0
        var teleportCm = 0.0          // 重撒那一帧估计位置相对上一帧的移动
        var events: [CarryMotionEvent] = []
        var suppressedWhileCold = false
        var calibrations = 0
        var finalK = 0.0
        func err(at tS: Double) -> Double? {
            errs.first { Double($0.tMs - CarrySim.t0) / 1000 >= tS }?.errCm
        }
        func maxErr(from a: Double, to b: Double) -> Double {
            errs.filter { let t = Double($0.tMs - CarrySim.t0) / 1000; return t >= a && t <= b }.map(\.errCm).max() ?? 0
        }
        var final: (errCm: Double, converged: Bool) { (errs.last?.errCm ?? .infinity, errs.last?.converged ?? false) }
        /// 每 2 s 一个误差（cm），诊断用
        var trajectory: String {
            var out: [String] = []
            var next = 0.0
            for e in errs {
                let t = Double(e.tMs - CarrySim.t0) / 1000
                if t >= next { out.append("\(Int(t))s:\(Int(e.errCm))\(e.converged ? "" : "?")"); next += 2 }
            }
            return out.joined(separator: " ")
        }
    }

    private func runPipeline(_ data: (samples: [IMUSample], truth: [CarryTruth]), motionOn: Bool, seed: UInt64 = 7,
                             coldStart: Bool = false, calibrateEveryCm: Double? = nil) -> PipelineRun {
        var fcfg = FusionConfig()
        fcfg.useMagneticHeading = false
        fcfg.useCorridorConstraint = false
        fcfg.motion.enabled = motionOn
        let engine = FusionEngine(corridors: [], config: fcfg)
        engine.setInitialPosition(data.truth[0].position, headingRad: data.truth[0].headingRad)
        var mcfg = MagneticConfig.tracking(odometry: .pdr)
        if coldStart {
            // App 的只靠地磁冷启动：不知道起点和朝向，收敛门打开、没定到不报位置
            mcfg = MagneticConfig.liveColdStart(visualOdometry: false)
            mcfg.applyColdStartGate()
            mcfg.uniformHeadingForInjection = true
        }
        mcfg.carryModeAdaptive = motionOn
        let loc = MagneticLocalizer(field: corridorField(), walkable: corridorWalkable(), config: mcfg, seed: seed)
        if coldStart { loc.reset(start: nil, headingUnknown: true) }
        else { loc.reset(start: data.truth[0].position, spreadCm: TrackingProfile.startSpreadCm) }
        var run = PipelineRun()
        var pendingRespread = false
        engine.onCarryEvent = { ev in
            run.events.append(ev)
            if loc.apply(ev) { pendingRespread = true }
        }
        let cal = StepScaleCalibrator()
        if let c = calibrateEveryCm { cal.everyCm = c; cal.learnFromPosterior = true }
        let ex = MagneticFeatureExtractor()
        var feature: MagneticFeature?
        var lastPos: Point2?
        var lastEst: Point2?
        for (s, t) in zip(data.samples, data.truth) {
            feature = ex.process(s) ?? feature
            guard let o = engine.process(s) else { continue }
            let delta = lastPos.map { o.position - $0 } ?? .zero
            lastPos = o.position
            let e = loc.step(delta: delta, feature: feature)
            if calibrateEveryCm != nil { cal.step(deltaCm: delta.distance(to: .zero), engine: engine, localizer: loc) }
            if pendingRespread, let le = lastEst {
                run.teleportCm = max(run.teleportCm, e.position.distance(to: le))
                pendingRespread = false
            }
            lastEst = e.position
            run.errs.append((o.tMs, e.position.distance(to: t.position), e.converged, o.carryMode))
            if loc.lostSuppressed && !loc.isConverged { run.suppressedWhileCold = true }
        }
        run.respreads = loc.respreadCount
        run.calibrations = cal.absorbed
        run.finalK = engine.effectiveStepLengthK
        run.lost = loc.lostCount
        run.finalHeadingSpreadDeg = loc.weightedSpread().headingSpreadDeg
        return run
    }

    /// 看屏 20 m 后放进口袋（δ ≈ 35°），再走 30 m：切换后几十米内位置找回、没判丢；重撒那一帧估计不瞬移。
    /// 对照：老路径（没有重撒）在同一剧本上的末端误差。
    func testPocketSwitchRecoversWithoutTeleport() {
        let switchAt = 20.0 / 1.3
        let script = straightScript(durationS: switchAt + 30 / 1.3 + 2,
                                    postures: [.init(fromS: 0, posture: .texting(tiltDeg: 40)),
                                               .init(fromS: switchAt, posture: .pocket(yawDeg: 35, thighDeg: 25))])
        let d = simulate(script)
        let r = runPipeline(d, motionOn: true)
        let legacy = runPipeline(d, motionOn: false)
        print("口袋切换：新路径 末端 \(Int(r.final.errCm)) cm 收敛 \(r.final.converged) 重撒 \(r.respreads) 判丢 \(r.lost) 航向散布 \(Int(r.finalHeadingSpreadDeg))°"
              + "；老路径 末端 \(Int(legacy.final.errCm)) cm 收敛 \(legacy.final.converged) 判丢 \(legacy.lost)")
        print("  新路径轨迹：" + r.trajectory)
        print("  老路径轨迹：" + legacy.trajectory)
        XCTAssertLessThan(r.err(at: switchAt - 1) ?? .infinity, 200, "切换前看屏跟踪应已收敛")
        XCTAssertGreaterThanOrEqual(r.respreads, 1, "切换应触发重撒")
        XCTAssertTrue(r.events.contains { $0.kind == .changed && $0.to == .pocket }, "应有 texting→pocket 事件：\(r.events.map { ($0.kind, $0.to) })")
        XCTAssertLessThan(r.teleportCm, 120, "重撒那一帧估计不该瞬移：\(r.teleportCm) cm")
        XCTAssertEqual(r.lost, 0, "重撒后的保护期内不该判丢")
        XCTAssertTrue(r.final.converged)
        XCTAssertLessThan(r.final.errCm, 300, "口袋里走 30 m 后误差 \(r.final.errCm) cm")
        XCTAssertLessThan(r.maxErr(from: switchAt + 12, to: script.durationS), 400, "切换 12 s 之后不该再有大误差")
        XCTAssertLessThan(r.finalHeadingSpreadDeg, 45, "航向偏差应重新收紧：\(r.finalHeadingSpreadDeg)°")
    }

    /// 看屏 → 口袋 → 再拿出来看屏（罗盘关）：拿出来之后不能按 δ≈0 的紧先验重撒（引擎航向翻转后已不等于前向轴方位角），
    /// 末端位置和航向都要找回（评审：texting→pocket→texting）
    func testTextingPocketTextingRoundTrip() {
        let a = 20.0 / 1.3, b = a + 15 / 1.3
        let script = straightScript(durationS: b + 20 / 1.3,
                                    postures: [.init(fromS: 0, posture: .texting(tiltDeg: 40)),
                                               .init(fromS: a, posture: .pocket(yawDeg: 35, thighDeg: 25)),
                                               .init(fromS: b, posture: .texting(tiltDeg: 40))])
        let d = simulate(script)
        let r = runPipeline(d, motionOn: true)
        print("看屏→口袋→看屏：末端 \(Int(r.final.errCm)) cm 收敛 \(r.final.converged) 重撒 \(r.respreads) 判丢 \(r.lost) 航向散布 \(Int(r.finalHeadingSpreadDeg))°")
        print("  轨迹：" + r.trajectory)
        // 拿出来之后的 changed（→ texting）保留偏差、不是 δ≈0 的 15° 紧先验
        let back = r.events.filter { $0.kind == .changed && $0.to == .texting && Double($0.tMs - CarrySim.t0) / 1000 > b - 1 }
        XCTAssertFalse(back.isEmpty, "应有 →texting 事件：\(r.events.map { ($0.kind, $0.to) })")
        XCTAssertTrue(back.allSatisfy { $0.keepBias || $0.headingSpreadDeg == nil }, "操作手机之后不能按紧先验重撒：\(r.events.map { (Double($0.tMs - CarrySim.t0) / 1000, $0.kind, $0.from, $0.to, $0.keepBias) })")
        XCTAssertEqual(r.lost, 0)
        XCTAssertTrue(r.final.converged)
        XCTAssertLessThan(r.final.errCm, 300, "末端误差 \(r.final.errCm) cm")
    }

    /// 只靠地磁的冷启动中途换携带方式（看屏 → 口袋，会有 handled / changed 事件）：不进「刚重撒」保护期，
    /// 收敛门照常起作用，报出来的位置（收敛后）不能是错的（> 5 m）
    func testColdStartCarryEventsDoNotForceWrongFix() {
        let switchAt = 8.0
        let script = straightScript(durationS: 50 / 1.3,
                                    postures: [.init(fromS: 0, posture: .texting(tiltDeg: 40)),
                                               .init(fromS: switchAt, posture: .pocket(yawDeg: 35, thighDeg: 25))])
        let d = simulate(script)
        for seed: UInt64 in [3, 7, 11] {
            let r = runPipeline(d, motionOn: true, seed: seed, coldStart: true)
            XCTAssertTrue(r.events.contains { $0.kind == .handled || $0.kind == .changed }, "应有携带事件")
            XCTAssertFalse(r.suppressedWhileCold, "冷启动没收敛时不该进保护期")
            let wrong = r.errs.filter { $0.converged && $0.errCm > 500 }
            XCTAssertTrue(wrong.isEmpty, "seed \(seed)：冷启动报了错位置 \(wrong.prefix(3).map { Int($0.errCm) }) cm")
        }
    }

    /// 步频 / 速度和 K=0.45 不匹配（每人步长不同）：1.6～2.2 Hz、速度 1.3 m/s 走 55 m 看屏，量末端误差；
    /// 打开在线 K 标定后误差不比不标定大，且 K 朝真实步长的方向走（评审：之前只在 2.0 Hz 正好匹配时测过）
    func testStrideMismatchGridWithOnlineCalibration() {
        var lines: [String] = []
        for hz in [1.6, 1.8, 2.2] {
            var script = straightScript(durationS: 55 / 1.3, postures: [.init(fromS: 0, posture: .texting(tiltDeg: 40))])
            script.stepHz = hz
            let d = simulate(script)
            let off = runPipeline(d, motionOn: true)
            let on = runPipeline(d, motionOn: true, calibrateEveryCm: 1500)
            lines.append("\(hz) Hz: 不标定 末端 \(Int(off.final.errCm)) cm / 标定 \(Int(on.final.errCm)) cm（\(on.calibrations) 次，K \(String(format: "%.3f", on.finalK))）")
            XCTAssertLessThanOrEqual(on.final.errCm, off.final.errCm + 100, "\(hz) Hz")
            if on.calibrations > 0 {
                // 步频低 → 真实步长（1.3/hz）比 K=0.45 给的长 → K 应该变大；步频高反之
                let truthStepM = 1.3 / hz
                XCTAssertEqual(on.finalK > 0.45, truthStepM > 0.65, "\(hz) Hz：K \(on.finalK)")
            }
        }
        print("步长失配网格：" + lines.joined(separator: "；"))
    }

    /// 视觉里程计标定 K：步频和 K 不匹配（真实步长 1.3 m/s ÷ 步频）时，喂同一段的「ARKit」位置（真值转个任意角度、平移，
    /// ARKit 坐标系和地图无关），K 朝真值方向走、走完 55 m 后推算的净位移比例比不标定时离 1 近得多
    func testVisualOdometryCalibrationLearnsStride() {
        for hz in [1.6, 2.2] {
            var script = straightScript(durationS: 55 / 1.3, postures: [.init(fromS: 0, posture: .texting(tiltDeg: 40))])
            script.stepHz = hz
            let d = simulate(script)
            // 不标定：推算净位移 / 真值净位移
            let (plain, outs0) = runEngine(d, motionOn: true)
            let ratio0 = outs0.last!.0.position.distance(to: outs0.first!.0.position)
                / outs0.last!.1.position.distance(to: outs0.first!.1.position)
            XCTAssertEqual(plain.activeCarryMode, .texting)
            // 标定：每个惯导输出配上当时的「ARKit」位置
            var cfg = FusionConfig()
            cfg.useMagneticHeading = false
            cfg.useCorridorConstraint = false
            cfg.motion.enabled = true
            let engine = FusionEngine(corridors: [], config: cfg)
            engine.setInitialPosition(d.truth[0].position, headingRad: d.truth[0].headingRad)
            var learned: [(CarryMode, Double)] = []
            engine.onStepScaleLearned = { learned.append(($0, $1)) }
            let cal = StepScaleCalibrator()
            let rot = 1.1, off = Point2(-3000, 700)
            for (smp, t) in zip(d.samples, d.truth) {
                guard let o = engine.process(smp) else { continue }
                let ar = Point2(t.position.x * cos(rot) - t.position.y * sin(rot) + off.x,
                                t.position.x * sin(rot) + t.position.y * cos(rot) + off.y)
                cal.observeVisualOdometry(tMs: o.tMs, ar: ar, trackingNormal: true, pdr: o.position, engine: engine)
            }
            let k = engine.learnedStepScales[.texting] ?? 1
            print("视觉里程计标定 \(hz) Hz：不标定 推算/真值 \(String(format: "%.3f", ratio0))，标定 \(cal.vioUpdates) 次，"
                  + "学到 \(String(format: "%.3f", k))（真值要 \(String(format: "%.3f", 1 / ratio0))），比值 \(cal.lastVIORatio ?? 0)")
            XCTAssertGreaterThanOrEqual(cal.vioUpdates, 2, "\(hz) Hz：55 m 至少该更新两次")
            XCTAssertEqual(learned.last?.0, .texting)
            // 方向对，而且离真值比 1 近一大截（每 20 m 吸收一半：两次之后剩 1/4）
            XCTAssertEqual(k > 1, ratio0 < 1, "\(hz) Hz：学到 \(k)，不标定的比例 \(ratio0)")
            XCTAssertLessThan(abs(k - 1 / ratio0), 0.45 * abs(1 - 1 / ratio0) + 0.02, "\(hz) Hz")
            XCTAssertEqual(engine.effectiveStepLengthK, CarryMotionTable.placeholder[.texting].stepLengthK * k, accuracy: 1e-9)
        }
    }

    /// 视觉里程计标定的门限：ARKit 跟踪不正常、惯导投影进通道、窗口里净位移比例离谱（漏步 / 惯导没在推）、
    /// 携带运动模型关着都不收；粒子后验默认不写进 K（`learnFromPosterior` 关）
    func testVisualOdometryCalibrationGating() {
        let d = simulate(straightScript(durationS: 6, postures: [.init(fromS: 0, posture: .texting(tiltDeg: 40))]))
        let (engine, _) = runEngine(d, motionOn: true)
        XCTAssertEqual(engine.activeCarryMode, .texting)
        // ARKit 1 m/s、惯导 0.8 m/s，每 100 ms 一次：比值 1.25
        func feed(_ cal: StepScaleCalibrator, seconds: Double, pdrSpeed: Double = 80, tracking: Bool = true) -> Int {
            var n = 0
            for i in 0..<Int(seconds * 10) {
                let t = Int64(i * 100)
                let s = Double(i) / 10
                if cal.observeVisualOdometry(tMs: t, ar: Point2(100 * s, 0), trackingNormal: tracking,
                                             pdr: Point2(0, pdrSpeed * s), engine: engine) != nil { n += 1 }
            }
            return n
        }
        // 跟踪不正常：不收
        let c0 = StepScaleCalibrator()
        XCTAssertEqual(feed(c0, seconds: 30, tracking: false), 0)
        XCTAssertNil(engine.learnedStepScales[.texting])
        // 正常：20 m 一批，比值 1.25，吸收一半 → 1.125
        let c1 = StepScaleCalibrator()
        XCTAssertEqual(feed(c1, seconds: 21), 1)
        XCTAssertEqual(c1.lastVIORatio ?? 0, 1.25, accuracy: 0.02)
        XCTAssertEqual(engine.learnedStepScales[.texting] ?? 0, 1.125, accuracy: 0.015)
        // 惯导几乎不动（漏步 / 没在推）：窗口比值离谱，整窗不要
        let c2 = StepScaleCalibrator()
        XCTAssertEqual(feed(c2, seconds: 40, pdrSpeed: 10), 0)
        XCTAssertEqual(engine.learnedStepScales[.texting] ?? 0, 1.125, accuracy: 0.015)
        // 惯导投影进通道：不收
        let c4 = StepScaleCalibrator()
        engine.config.useCorridorConstraint = true
        XCTAssertEqual(feed(c4, seconds: 30), 0)
        engine.config.useCorridorConstraint = false
        // 携带模型关着：不收
        let (legacy, _) = runEngine(d, motionOn: false)
        let c5 = StepScaleCalibrator()
        for i in 0..<300 {
            let s = Double(i) / 10
            XCTAssertNil(c5.observeVisualOdometry(tMs: Int64(i * 100), ar: Point2(100 * s, 0), trackingNormal: true,
                                                  pdr: Point2(80 * s, 0), engine: legacy))
        }
        // 粒子后验默认不写进 K
        XCTAssertFalse(StepScaleCalibrator().learnFromPosterior)
    }

    /// 一开始就在口袋里、起点和朝向已知：第一次判出模式不重撒，直接按口袋参数跟踪
    func testPocketFromStartTracksWithKnownHeading() {
        let script = straightScript(durationS: 30 / 1.3, postures: [.init(fromS: 0, posture: .pocket(yawDeg: 35, thighDeg: 25))])
        let d = simulate(script)
        let r = runPipeline(d, motionOn: true)
        XCTAssertEqual(r.respreads, 0, "第一次判出携带姿态不重撒")
        XCTAssertTrue(r.events.contains { $0.kind == .initial && $0.to == .pocket })
        XCTAssertEqual(r.lost, 0)
        XCTAssertTrue(r.final.converged)
        XCTAssertLessThan(r.final.errCm, 250, "口袋已知朝向跟踪末端误差 \(r.final.errCm) cm")
        XCTAssertLessThan(r.maxErr(from: 3, to: script.durationS), 400)
    }

    /// 看屏 → 贴耳通话（后仰 25°，右耳，头部转动 ±15°）：引擎航向偏 90°，三峰先验重撒后找回
    func testCallingSwitchRecovers() {
        let switchAt = 20.0 / 1.3
        let script = straightScript(durationS: switchAt + 30 / 1.3 + 2,
                                    postures: [.init(fromS: 0, posture: .texting(tiltDeg: 40)),
                                               .init(fromS: switchAt, posture: .calling(tiltDeg: 40, rightEar: true, headTurnDeg: 15))])
        let d = simulate(script)
        let r = runPipeline(d, motionOn: true)
        print("通话切换：末端 \(Int(r.final.errCm)) cm 收敛 \(r.final.converged) 重撒 \(r.respreads) 判丢 \(r.lost) 航向散布 \(Int(r.finalHeadingSpreadDeg))°")
        print("  轨迹：" + r.trajectory)
        XCTAssertTrue(r.events.contains { $0.kind == .changed && $0.to == .calling }, "应有 texting→calling 事件：\(r.events.map { ($0.kind, $0.to) })")
        XCTAssertLessThan(r.teleportCm, 120)
        XCTAssertEqual(r.lost, 0)
        XCTAssertTrue(r.final.converged)
        XCTAssertLessThan(r.final.errCm, 300, "通话里走 30 m 后误差 \(r.final.errCm) cm")
        XCTAssertLessThan(r.maxErr(from: switchAt + 12, to: script.durationS), 400)
    }

    /// 看屏 → 手握摆臂：δ 未知 + 周期抖动，整圆重撒 + 步幅平均 + 只信 |B| 之后找回
    func testSwingingSwitchRecovers() {
        let switchAt = 20.0 / 1.3
        let script = straightScript(durationS: switchAt + 30 / 1.3 + 2,
                                    postures: [.init(fromS: 0, posture: .texting(tiltDeg: 40)),
                                               .init(fromS: switchAt, posture: .swinging(armDeg: 15, wristYawDeg: 20))])
        let d = simulate(script)
        let r = runPipeline(d, motionOn: true)
        print("摆臂切换：末端 \(Int(r.final.errCm)) cm 收敛 \(r.final.converged) 重撒 \(r.respreads) 判丢 \(r.lost) 航向散布 \(Int(r.finalHeadingSpreadDeg))°")
        print("  轨迹：" + r.trajectory)
        XCTAssertTrue(r.events.contains { $0.kind == .changed && $0.to == .swinging }, "应有 texting→swinging 事件：\(r.events.map { ($0.kind, $0.to) })")
        XCTAssertLessThan(r.teleportCm, 120)
        XCTAssertEqual(r.lost, 0)
        XCTAssertTrue(r.final.converged)
        XCTAssertLessThan(r.final.errCm, 350, "摆臂里走 30 m 后误差 \(r.final.errCm) cm")
    }

    /// 老路径在纯看屏直走上照旧（回归守门）；新路径在同一剧本上不差
    func testTextingStraightWalkBothPaths() {
        let d = simulate(straightScript(durationS: 40 / 1.3, postures: [.init(fromS: 0, posture: .texting(tiltDeg: 40))]))
        for on in [false, true] {
            let r = runPipeline(d, motionOn: on)
            XCTAssertTrue(r.final.converged, "motion=\(on)")
            XCTAssertLessThan(r.final.errCm, 200, "motion=\(on)：末端误差 \(r.final.errCm) cm")
            XCTAssertEqual(r.lost, 0)
            XCTAssertEqual(r.respreads, 0)
        }
    }
}

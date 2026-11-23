import XCTest
@testable import HPASSKit

/// 评估器的真实计步路径（SessionEvaluator .pdrIMU / hpass-eval --motion pdr-imu）：
/// 测试会话只有 IMU（arkit_pose.csv 只有表头），运动来自 FusionEngine 的计步推算，配置和 App 实时定位页同一份（FusionEngine.live）。
final class EvalMotionTests: XCTestCase {
    /// 20 m × 16 m 的空地图（一块可走地面）
    private func bigMap() throws -> StoreMap {
        let json = """
        {"width": 2000, "height": 1600, "mapElementList": [], "floorPolygons": [[0, 0, 2000, 0, 2000, 1600, 0, 1600]]}
        """
        return try StoreDataLoader.loadMap(Data(json.utf8))
    }

    /// 建图：竖着来回扫 x = 200…1000（每 100 cm 一趟），y = 100…1500
    private var buildRoute: [Point2] {
        var w = [Point2(200, 100)]
        for (i, x) in stride(from: 200.0, through: 1000, by: 100).enumerated() {
            if i > 0 { w.append(Point2(x, w.last!.y)) }
            w.append(Point2(x, i % 2 == 0 ? 1500 : 100))
        }
        return w
    }

    /// 测试会话：手机平放、朝 +y 直走（1.8 Hz、峰峰约 4 m/s² → 约 0.62 m/步 ≈ 112 cm/s），磁场按真实位置取。
    /// 写 imu.csv（50 Hz）、只有表头的 arkit_pose.csv / anchors.csv、truth.csv（10 Hz）
    /// preroll：真值开始之前先录这么多秒「原地晃出步子」（像敲击、把手机放进口袋），这段位移不该推粒子
    /// prerollYawRad：预滚的前一半时间里手机原地转过这么多（平放，陀螺 gz），像敲完之后转身起步
    private func writeIMUSession(_ dir: URL, from p0: Point2, seconds: Double = 11, preroll: Double = 0,
                                 prerollYawRad: Double = 0) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let T0: Int64 = 1_700_000_100_000, speed = 112.0, g = 9.80665
        var imu = "t_ms,ax,ay,az,gx,gy,gz,mx,my,mz\n", truth = "t_ms,x_cm,y_cm\n"
        let n = Int(seconds * 50)
        if preroll > 0 {
            let f = SyntheticRoom.field(p0)
            for i in stride(from: Int(preroll * 50), to: 0, by: -1) {
                let az = g + 2.0 * sin(2 * Double.pi * 1.8 * Double(i) * 0.02)
                // 预滚的前一半时间匀速转 prerollYawRad
                let gz = Double(i) * 0.02 > preroll / 2 ? prerollYawRad / (preroll / 2) : 0
                imu += "\(T0 - Int64(i * 20)),0,0,\(az),0,0,\(gz),\(f.0),\(f.1),\(f.2)\n"
            }
        }
        for i in 0...n {
            let t = Double(i) * 0.02, tMs = T0 + Int64(i * 20)
            let p = Point2(p0.x, p0.y + speed * t)
            let f = SyntheticRoom.field(p)
            let az = g + 2.0 * sin(2 * Double.pi * 1.8 * t)
            imu += "\(tMs),0,0,\(az),0,0,0,\(f.0),\(f.1),\(f.2)\n"
            if i % 5 == 0 { truth += "\(tMs),\(p.x),\(p.y)\n" }
        }
        try imu.write(to: dir.appendingPathComponent("imu.csv"), atomically: true, encoding: .utf8)
        try truth.write(to: dir.appendingPathComponent("truth.csv"), atomically: true, encoding: .utf8)
        try "t_ms,x_m,y_m,z_m,qx,qy,qz,qw,tracking,limited_reason\n"
            .write(to: dir.appendingPathComponent("arkit_pose.csv"), atomically: true, encoding: .utf8)
    }

    private func setup() throws -> (StoreMap, SessionEvaluator.BuiltMaps, URL, URL) {
        let map = try bigMap()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("evalmotion_\(UUID().uuidString)")
        let b = root.appendingPathComponent("build1"), t = root.appendingPathComponent("test1")
        try SyntheticRoom.writeSession(b, waypoints: buildRoute)
        try writeIMUSession(t, from: Point2(550, 150))
        let built = try SessionEvaluator.buildMaps(sessions: [b], map: map)
        return (map, built, t, root)
    }

    func testPdrIMUTracksFromRealIMUWithoutPoses() throws {
        let (map, built, t, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let walk = SessionEvaluator.walkable(map)
        var track: [SessionEvaluator.TrackPoint] = []
        let rep = try SessionEvaluator.evaluate(dir: t, map: map, field: built.field, ble: nil, walkable: walk,
                                                oracleStart: true, motion: .pdrIMU, onTrack: { track.append($0) })
        XCTAssertGreaterThan(rep.points, 10)
        XCTAssertLessThan(rep.medianCm ?? .infinity, 150)
        XCTAssertGreaterThan(rep.pathM, 8)
        // 每个惯导输出（约 3 Hz）一行轨迹，参考点都在真值上
        XCTAssertGreaterThan(track.count, 20)
        XCTAssertTrue(track.allSatisfy { abs($0.reference.x - 550) < 1 })
        XCTAssertTrue(track.contains { $0.converged && $0.estimate != nil })
        // 诊断用的纯推算位置（hpass-eval --odo-out）：每行都有，从真值起点出发，合成会话里沿真值走
        XCTAssertTrue(track.allSatisfy { $0.odometry != nil })
        let o0 = try XCTUnwrap(track.first?.odometry), o1 = try XCTUnwrap(track.last?.odometry)
        XCTAssertLessThan(o0.distance(to: track.first!.reference), 1)
        XCTAssertLessThan(o1.distance(to: track.last!.reference), 150)

        // 老行为（位姿推粒子）：没有位姿就一步都不动、一个点都不出
        let old = try SessionEvaluator.evaluate(dir: t, map: map, field: built.field, ble: nil, walkable: walk, oracleStart: true)
        XCTAssertEqual(old.points, 0)
    }

    func testMotionBeforeReferenceStartIsIgnored() throws {
        let map = try bigMap()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("evalmotion_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let b = root.appendingPathComponent("build1"), t = root.appendingPathComponent("test1")
        try SyntheticRoom.writeSession(b, waypoints: buildRoute)
        try writeIMUSession(t, from: Point2(550, 150), preroll: 4)
        let built = try SessionEvaluator.buildMaps(sessions: [b], map: map)
        let rep = try SessionEvaluator.evaluate(dir: t, map: map, field: built.field, ble: nil,
                                                walkable: SessionEvaluator.walkable(map), oracleStart: true, motion: .pdrIMU)
        XCTAssertGreaterThan(rep.points, 10)
        XCTAssertLessThan(rep.medianCm ?? .infinity, 150)      // 不然起点就被推出去约 4 s × 1.1 m/s
    }

    /// 预滚里转了 90°（敲完转身起步）：起步朝向在第一个参考点重新设，预滚的偏航不能变成之后每一步的航向误差（评审）
    func testPrerollYawDoesNotBiasKnownStartHeading() throws {
        let map = try bigMap()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("evalmotion_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let b = root.appendingPathComponent("build1"), t = root.appendingPathComponent("test1")
        try SyntheticRoom.writeSession(b, waypoints: buildRoute)
        try writeIMUSession(t, from: Point2(550, 150), preroll: 4, prerollYawRad: Double.pi / 2)
        let built = try SessionEvaluator.buildMaps(sessions: [b], map: map)
        var track: [SessionEvaluator.TrackPoint] = []
        let rep = try SessionEvaluator.evaluate(dir: t, map: map, field: built.field, ble: nil,
                                                walkable: SessionEvaluator.walkable(map), oracleStart: true, motion: .pdrIMU,
                                                onTrack: { track.append($0) })
        XCTAssertGreaterThan(rep.points, 10)
        XCTAssertLessThan(rep.medianCm ?? .infinity, 150, "预滚的 90° 偏航带进来了")
        let last = try XCTUnwrap(track.last { $0.estimate != nil })
        XCTAssertLessThan(last.estimate!.distance(to: last.reference), 250)
    }

    /// 回放的惯导引擎不带通道约束（只当增量用；冷启动 / 朝向未知时绝对位置是随便给的），哪怕地图有通道
    func testReplayFusionHasNoCorridorConstraint() {
        let f = SessionEvaluator.replayFusion(start: Point2(100, 100), headingRad: 0, carryMotion: false)
        XCTAssertFalse(f.config.useCorridorConstraint)
        XCTAssertFalse(f.config.useMagneticHeading)
        XCTAssertFalse(f.config.motion.enabled)
        XCTAssertTrue(SessionEvaluator.replayFusion(start: .zero, headingRad: 0, carryMotion: true).config.motion.enabled)
    }

    /// --carry-motion / --stationary-freeze 的回放能跑通，手持看屏直走时不比老路径差多少
    func testPdrIMUWithCarryMotionAndFreeze() throws {
        let (map, built, t, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let walk = SessionEvaluator.walkable(map)
        var modes = Set<CarryMode>()
        let rep = try SessionEvaluator.evaluate(dir: t, map: map, field: built.field, ble: nil, walkable: walk,
                                                oracleStart: true, motion: .pdrIMU, carryMotion: true, stationaryFreeze: true,
                                                onTrack: { modes.insert($0.carryMode) })
        XCTAssertGreaterThan(rep.points, 10)
        XCTAssertLessThan(rep.medianCm ?? .infinity, 200)
        XCTAssertFalse(modes.subtracting([.unknown]).isEmpty, "携带模式应该判出来：\(modes)")
    }

    func testPdrIMUUnknownStartHeadingAndColdStartRun() throws {
        let (map, built, t, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let walk = SessionEvaluator.walkable(map)
        // 起步朝向未知（口袋 / 包）：不把真值航向给滤波器，照样能跑完、参考点照样计数
        let unk = try SessionEvaluator.evaluate(dir: t, map: map, field: built.field, ble: nil, walkable: walk,
                                                oracleStart: true, motion: .pdrIMU, startHeading: .unknown)
        XCTAssertGreaterThan(unk.refPoints, 10)
        // 冷启动：惯导从地图中心、朝向 0 起步，粒子全图找
        let cold = try SessionEvaluator.evaluate(dir: t, map: map, field: built.field, ble: nil, walkable: walk, motion: .pdrIMU)
        XCTAssertGreaterThan(cold.refPoints, 10)
    }

    func testTruthHeadingUsesFirstMetreAndAHalf() {
        let ref: [(tMs: Int64, p: Point2)] = [(0, Point2(0, 0)), (100, Point2(100, 0)), (200, Point2(200, 0))]
        XCTAssertEqual(SessionEvaluator.truthHeading(ref) ?? .nan, Double.pi / 2, accuracy: 1e-9)   // 朝 +x
        XCTAssertNil(SessionEvaluator.truthHeading(Array(ref.prefix(2))))                           // 走不出 1.5 m
    }

    /// 位姿（pose）和计步（odometryStep）走的是同一段：同样的位移、同样的种子，估计一模一样
    func testOdometryStepIsWhatPoseUses() throws {
        let (map, built, _, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let walk = SessionEvaluator.walkable(map)
        let a = ShadowLocalizer(field: built.field, walkable: walk, useRawMag: false, seed: 7)
        let b = ShadowLocalizer(field: built.field, walkable: walk, useRawMag: false, seed: 7)
        var lastA: MagneticEstimate?, lastB: MagneticEstimate?
        _ = a.pose(a: Point2(550, 150), normal: true, tMs: 0)
        for k in 1...300 {
            let p = Point2(550, 150 + Double(k) * 4)
            let f = SyntheticRoom.field(p)
            let s = IMUSample(tMs: Int64(k * 40), ax: 0, ay: 0, az: 9.81, gx: 0, gy: 0, gz: 0, mx: f.0, my: f.1, mz: f.2)
            a.imu(s); b.imu(s)
            if let e = a.pose(a: p, normal: true, tMs: Int64(k * 40)) { lastA = e }
            if let e = b.odometryStep(delta: Point2(0, 4), tMs: Int64(k * 40), a: p) { lastB = e }
        }
        XCTAssertNotNil(lastA)
        XCTAssertEqual(lastA?.position.x ?? .nan, lastB?.position.x ?? -1, accuracy: 1e-9)
        XCTAssertEqual(lastA?.position.y ?? .nan, lastB?.position.y ?? -1, accuracy: 1e-9)
    }

    func testLiveFusionConfigMatchesAppDefaults() {
        let c = FusionConfig.live(hasCorridors: false, compass: false)
        XCTAssertFalse(c.useCorridorConstraint)
        XCTAssertFalse(c.useMagneticHeading)
        XCTAssertEqual(c.stepLengthScale, 1)
        let d = FusionConfig.live(hasCorridors: true, compass: true, stepLengthScale: 0.9, declinationDeg: 30)
        XCTAssertTrue(d.useCorridorConstraint)
        XCTAssertTrue(d.useMagneticHeading)
        XCTAssertEqual(d.stepLengthScale, 0.9)
        XCTAssertEqual(d.magneticDeclinationDeg, 30)
        // 引擎：起点和朝向设好，可以直接出输出
        let f = FusionEngine.live(corridors: [], start: Point2(100, 200), headingRad: 0, compass: false)
        XCTAssertTrue(f.isInitialized)
    }
}

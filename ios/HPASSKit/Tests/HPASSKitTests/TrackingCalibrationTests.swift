import XCTest
@testable import HPASSKit

/// 跟踪似然的地图标定（TrackingCalibration）和「每个粒子自己估偏移」的似然（MagneticConfig.particleOffsetFilter / particleOffsetFromMap）。
final class TrackingCalibrationTests: XCTestCase {

    /// 两个方向都有米级起伏的磁场（单位 m），30 m 见方
    private func g(_ p: Point2) -> MagneticFeature {
        let x = p.x / 100, y = p.y / 100
        let bz = -42 + 6 * sin(0.9 * x + 0.3 * y) + 4 * sin(0.37 * x + 1.1 * y + 1) + 2 * sin(1.7 * x - 0.8 * y + 0.5)
        let bh = 24 + 5 * sin(0.6 * x + 0.7 * y + 2) + 3 * sin(1.3 * x - 0.4 * y)
        return MagneticFeature(total: (bz * bz + bh * bh).squareRoot(), vertical: bz, horizontal: bh)
    }

    private func field(_ f: (Point2) -> MagneticFeature, w: Double = 3000, h: Double = 3000) -> MagneticFieldMap {
        let cell = 50.0
        let cols = Int(w / cell), rows = Int(h / cell)
        var cells = [MagneticFeature?](), sig = [MagneticFeature?]()
        for j in 0..<rows {
            for i in 0..<cols {
                cells.append(f(Point2((Double(i) + 0.5) * cell, (Double(j) + 0.5) * cell)))
                sig.append(MagneticFeature(total: 0.5, vertical: 0.5, horizontal: 0.5))
            }
        }
        return MagneticFieldMap(widthCm: w, heightCm: h, cellCm: cell, cells: cells, sigmas: sig)
    }

    /// 留出会话：横竖各几条 25 m 的直线，每 50 cm 一个读数 = 真值场 + 会话整体偏移 + 慢漂（随机游走）+ 白噪声
    private func sequences(truth: (Point2) -> MagneticFeature, noiseUT: Double, seed: UInt64) -> [[TrackingCalibration.Sample]] {
        var rng = MagRNG(seed: seed)
        var out: [[TrackingCalibration.Sample]] = []
        for k in 0..<8 {
            let horizontal = k % 2 == 0
            let c = 300 + Double(k / 2) * 700
            var drift = MagneticFeature(total: 6, vertical: -9, horizontal: 4)
            var seq: [TrackingCalibration.Sample] = []
            for s in 0..<50 {
                let a = 250 + Double(s) * 50
                let p = horizontal ? Point2(a, c) : Point2(c, a)
                drift = drift + MagneticFeature(total: rng.normal() * 0.3, vertical: rng.normal() * 0.3, horizontal: rng.normal() * 0.3)
                let n = MagneticFeature(total: rng.normal() * noiseUT, vertical: rng.normal() * noiseUT, horizontal: rng.normal() * noiseUT)
                seq.append(.init(feature: truth(p) + drift + n, reference: p))
            }
            out.append(seq)
        }
        return out
    }

    /// 地图准、读数噪声和模型相符：标出的温度小（滤波器可以放心用）；读数噪声比模型大得多（模型过度自信）：温度明显变大
    func testCalibrationTracksModelMisfit() throws {
        let f = field(g)
        let clean = try XCTUnwrap(TrackingCalibration.calibrate(folds: [.init(field: f, sequences: sequences(truth: g, noiseUT: 1, seed: 3))]))
        XCTAssertEqual(clean.perDistance.map(\.distanceCm), TrackingCalibration.displacementsCm)
        XCTAssertTrue(clean.perDistance.allSatisfy { $0.meanLLRLower > 0 && $0.meanLLRLower < $0.meanLLR && $0.windows >= TrackingCalibration.minWindows })
        XCTAssertLessThanOrEqual(clean.temperature, TrackingCalibration.maxTemperature)
        XCTAssertGreaterThanOrEqual(clean.temperature, 1)
        // 参考轨迹本身差 1～2 m、沿路慢慢变（像公开数据集按稀疏路标插值的「真值」）：图在参考位置上和读数对不上，
        // 平移 d 的比较大半是噪声，模型过度自信 → 温度大得多（或者干脆标不出来）
        let shifted = sequences(truth: g, noiseUT: 1, seed: 3).map { seq in
            seq.enumerated().map { k, s in
                TrackingCalibration.Sample(feature: s.feature,
                                           reference: s.reference + Point2(150 * sin(Double(k) / 9), 120 * cos(Double(k) / 7)))
            }
        }
        let noisy = TrackingCalibration.calibrate(folds: [.init(field: f, sequences: shifted)])
        XCTAssertGreaterThan(noisy?.temperature ?? .infinity, clean.temperature * 2, "参考位置不准时温度没变大")
    }

    /// 图上没有米级信息（处处一样）：平移不改变似然，标不出来；序列太短（窗口不够）也标不出来
    func testUninformativeOrTooShortGivesNoCalibration() {
        let flat = field { _ in MagneticFeature(total: 48, vertical: -40, horizontal: 26) }
        XCTAssertNil(TrackingCalibration.calibrate(folds: [.init(field: flat, sequences: sequences(truth: g, noiseUT: 1, seed: 5))]))
        let short = sequences(truth: g, noiseUT: 1, seed: 5).map { Array($0.prefix(TrackingCalibration.burnInUpdates + 10)) }
        XCTAssertNil(TrackingCalibration.calibrate(folds: [.init(field: field(g), sequences: short)]))
        XCTAssertNil(TrackingCalibration.calibrate(folds: []))
    }

    /// 地图标定只在计步跟踪、温度不超过上限、地磁权重没被钉死时打开粒子偏移似然；显式开关不看地图
    func testParticleOffsetFromMapGating() {
        var f = field(g)
        func temp(_ cfg: MagneticConfig) -> Double? { MagneticLocalizer(field: f, config: cfg, seed: 1).particleOffsetTemperatureInUse }
        let pdr = MagneticConfig.tracking(odometry: .pdr)
        XCTAssertTrue(pdr.particleOffsetFromMap)
        XCTAssertFalse(pdr.particleOffsetFilter)
        XCTAssertNil(temp(pdr), "没标定的图照旧")
        f.trackingTemperature = 3.5
        XCTAssertEqual(temp(pdr), 3.5)
        XCTAssertNil(temp(.tracking(odometry: .vio)), "视觉里程计照旧")
        XCTAssertNil(temp(MagneticConfig()), "冷启动 / 默认配置照旧")
        var pinned = pdr
        pinned.pinnedConvergedMagWeight = 0
        XCTAssertNil(temp(pinned), "钉死地磁权重的配置档（Wi-Fi 冷启动）照旧")
        f.trackingTemperature = TrackingCalibration.maxTemperature + 1
        XCTAssertNil(temp(pdr), "温度超过上限：图上信息太少，照旧")
        var explicit = MagneticConfig.tracking(odometry: .vio)
        explicit.particleOffsetFilter = true
        explicit.particleOffsetTemperature = 2
        XCTAssertEqual(temp(explicit), 2)
        // 运动来源换成计步就打开、换回视觉里程计就关
        f.trackingTemperature = 3.5
        let loc = MagneticLocalizer(field: f, config: .tracking(odometry: .vio), seed: 1)
        XCTAssertNil(loc.particleOffsetTemperatureInUse)
        loc.setOdometry(.pdr)
        XCTAssertEqual(loc.particleOffsetTemperatureInUse, 3.5)
        loc.setOdometry(.vio)
        XCTAssertNil(loc.particleOffsetTemperatureInUse)
    }

    /// 步长偏大 10%（纯推算 25 m 后差 2.5 m）：地图标定过时粒子偏移似然把位置拉回来；同一张图不带标定（原来的似然）纠得慢得多。
    /// 偏移估计（粒子偏移的加权平均）沿路随机游走（每 50 cm 方差 16 µT²），会吸收几 µT 的局部地图差，只要求大致对。
    private func trackError(calibrated: Bool, switchOdometry: Bool = false) -> (errorCm: Double, offset: MagneticFeature?) {
        var f = field(g)
        if calibrated { f.trackingTemperature = 2.5 }
        let loc = MagneticLocalizer(field: f, config: .tracking(odometry: switchOdometry ? .vio : .pdr), seed: 11)
        var truth = Point2(200, 1500)
        loc.reset(start: truth, spreadCm: TrackingProfile.startSpreadCm)
        if switchOdometry { loc.setOdometry(.pdr) }
        var rng = MagRNG(seed: 7)
        let off = MagneticFeature(total: 5, vertical: -8, horizontal: 3)
        let step = Point2(25, 0)
        while truth.x < 2700 {
            truth = truth + step
            let n = MagneticFeature(total: rng.normal(), vertical: rng.normal(), horizontal: rng.normal())
            _ = loc.step(delta: step * 1.1, feature: g(truth) + off + n)
        }
        return (loc.estimate().position.distance(to: truth), loc.currentOffset)
    }

    func testCalibratedMapCorrectsScaleError() throws {
        let rb = trackError(calibrated: true)
        let old = trackError(calibrated: false)
        XCTAssertLessThan(rb.errorCm, 120, "标定过的图没纠回步长误差：\(rb.errorCm) cm")
        XCTAssertLessThan(rb.errorCm, old.errorCm * 0.6, "粒子偏移似然没比原来的好：\(rb.errorCm) vs \(old.errorCm) cm")
        let o = try XCTUnwrap(rb.offset)
        XCTAssertEqual(o.vertical, -8, accuracy: 6)
        XCTAssertEqual(o.total, 5, accuracy: 6)
        // 中途从视觉里程计换到计步：开关打开后从头估偏移，照样能纠
        XCTAssertLessThan(trackError(calibrated: true, switchOdometry: true).errorCm, 150)
    }
}

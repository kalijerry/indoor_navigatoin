import XCTest
@testable import HPASSKit

/// 报的位置稳不稳、报的不确定度诚不诚实：评估器的标定 / 跳点统计（LocalizationEvaluator → EvalReport → tools/lab/lab.py）
final class ReportRobustnessTests: XCTestCase {
    private func est(_ p: Point2, unc: Double, converged: Bool = true) -> MagneticEstimate {
        MagneticEstimate(position: p, uncertaintyCm: unc, confidence: 1, effectiveRatio: 1, updates: 1, converged: converged)
    }

    /// 相邻两个有把握的点之间估计 / 参考走过的路、> 3 m 的跳；没把握的点打断连续（不算跳，也不算路）；不确定度和误差一一对应
    func testEvaluatorPathRatioJumpsAndUncertainty() {
        let ev = LocalizationEvaluator()
        ev.add(estimate: est(Point2(0, 0), unc: 100), reference: Point2(0, 0))
        ev.add(estimate: est(Point2(0, 20), unc: 100), reference: Point2(0, 20))       // 跟着走 20 cm
        ev.add(estimate: est(Point2(0, 420), unc: .infinity), reference: Point2(0, 40)) // 跳 4 m，不确定度没报
        ev.add(estimate: est(Point2(0, 900), unc: 50, converged: false), reference: Point2(0, 60))   // 没把握：打断
        ev.add(estimate: est(Point2(0, 80), unc: 50), reference: Point2(0, 80))         // 重新开始，不算从 420 跳回来
        ev.add(estimate: est(Point2(0, 100), unc: 50), reference: Point2(0, 100))
        XCTAssertEqual(ev.errors.count, 5)
        XCTAssertEqual(ev.uncertainties, [100, 100, -1, 50, 50])
        XCTAssertEqual(ev.bigJumps, 1)
        XCTAssertEqual(ev.estPathCm, 20 + 400 + 20, accuracy: 1e-9)
        XCTAssertEqual(ev.refPathFixCm, 20 + 20 + 20, accuracy: 1e-9)
        XCTAssertEqual(ev.jumps, 1)
    }

    // MARK: - 报的不确定度（MagneticConfig.honestUncertainty / ReportedUncertainty）

    /// 沿 x 变化、不重复的磁场（同 TrackingProfileTests）
    private func g(_ xCm: Double) -> MagneticFeature {
        let x = xCm / 100
        let bz = -42 + 6 * sin(0.9 * x) + 4 * sin(0.37 * x + 1) + 2 * sin(1.7 * x + 0.5)
        let bh = 24 + 5 * sin(0.6 * x + 2) + 3 * sin(1.3 * x)
        return MagneticFeature(total: (bz * bz + bh * bh).squareRoot(), vertical: bz, horizontal: bh)
    }

    /// 60 m × 4 m 的走廊
    private func corridor() -> MagneticFieldMap {
        let w = 6000.0, h = 400.0, cell = 50.0
        var cells = [MagneticFeature?](), sig = [MagneticFeature?]()
        for _ in 0..<Int(h / cell) {
            for i in 0..<Int(w / cell) {
                cells.append(g((Double(i) + 0.5) * cell))
                sig.append(MagneticFeature(total: 0.5, vertical: 0.5, horizontal: 0.5))
            }
        }
        return MagneticFieldMap(widthCm: w, heightCm: h, cellCm: cell, cells: cells, sigmas: sig)
    }

    /// 跟踪档、实时冷启动档打开误差模型，按运动来源给步长离散；默认（老的冷启动 / 测试配置）不变
    func testHonestUncertaintyProfiles() {
        XCTAssertFalse(MagneticConfig().honestUncertainty)
        let pdr = MagneticConfig.tracking(odometry: .pdr), vio = MagneticConfig.tracking(odometry: .vio)
        XCTAssertTrue(pdr.honestUncertainty); XCTAssertTrue(vio.honestUncertainty)
        XCTAssertEqual(pdr.reportScaleSigma, ReportedUncertainty.pdrScaleSigma)
        XCTAssertEqual(vio.reportScaleSigma, ReportedUncertainty.vioScaleSigma)
        XCTAssertEqual(MagneticConfig.liveColdStart(visualOdometry: false).reportScaleSigma, ReportedUncertainty.pdrScaleSigma)
        XCTAssertEqual(MagneticConfig.liveColdStart(visualOdometry: true).reportScaleSigma, ReportedUncertainty.vioScaleSigma)
        XCTAssertTrue(MagneticConfig.liveColdStart(visualOdometry: false).honestUncertainty)
        // 运动来源中途换了：步长离散跟着换
        let loc = MagneticLocalizer(field: corridor(), config: vio, seed: 3)
        loc.reset(start: Point2(300, 200), spreadCm: TrackingProfile.startSpreadCm)
        loc.setOdometry(.pdr)
        XCTAssertEqual(loc.config.reportScaleSigma, ReportedUncertainty.pdrScaleSigma)
    }

    /// 只改报的数：同一种子、同一段路，打开 / 关掉误差模型，每一步的位置、收敛、置信度都一样；
    /// 关掉时报的就是簇内散布，打开时不小于簇内散布，而且不小于「步长散布缺口 × 已知起点之后走的路」
    func testHonestUncertaintyOnlyChangesReportedNumber() {
        let map = corridor()
        var off = MagneticConfig.tracking(odometry: .pdr)
        off.honestUncertainty = false
        var on = off
        on.honestUncertainty = true
        // 粒子不带步长散布：缺口就是整个 σ_真
        on.initialScaleSigma = 0; on.scaleWalkPerM = 0
        off.initialScaleSigma = 0; off.scaleWalkPerM = 0
        let a = MagneticLocalizer(field: map, config: off, seed: 7)
        let b = MagneticLocalizer(field: map, config: on, seed: 7)
        var truth = Point2(300, 200)
        a.reset(start: truth, spreadCm: TrackingProfile.startSpreadCm)
        b.reset(start: truth, spreadCm: TrackingProfile.startSpreadCm)
        XCTAssertEqual(b.sinceFixCm, 0)
        let step = Point2(25, 0)
        let lever = (map.widthCm * map.heightCm).squareRoot()
        var walked = 0.0
        for _ in 0..<100 {
            truth = truth + step
            let d = step * 1.08                    // 计步步长多 8%
            walked += d.length
            let ea = a.step(delta: d, feature: g(truth.x))
            let eb = b.step(delta: d, feature: g(truth.x))
            XCTAssertEqual(ea.position.x, eb.position.x, accuracy: 1e-9)
            XCTAssertEqual(ea.position.y, eb.position.y, accuracy: 1e-9)
            XCTAssertEqual(ea.converged, eb.converged)
            XCTAssertEqual(ea.confidence, eb.confidence, accuracy: 1e-12)
            XCTAssertEqual(ea.uncertaintyCm, ea.clusterUncertaintyCm ?? -1, accuracy: 1e-9)
            XCTAssertEqual(eb.clusterUncertaintyCm ?? -1, ea.uncertaintyCm, accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(eb.uncertaintyCm, ea.uncertaintyCm)
            XCTAssertEqual(b.sinceFixCm, walked, accuracy: 1e-6, "已知起点：一直累计走过的推算路程")
            XCTAssertGreaterThanOrEqual(eb.uncertaintyCm,
                                        ReportedUncertainty.pdrScaleSigma * min(walked, lever) - 1e-6)
        }
        // 封顶：走了 27 m，补回的那部分按地图外框边长（√(60 m × 4 m) ≈ 15.5 m）算
        XCTAssertGreaterThan(walked, lever)
        XCTAssertLessThan(b.estimate().uncertaintyCm, ReportedUncertainty.pdrScaleSigma * walked)
        b.reset(start: truth, spreadCm: TrackingProfile.startSpreadCm)
        XCTAssertEqual(b.sinceFixCm, 0, "重新给起点：从零算")
    }

    /// 粒子自己还留着够大的步长散布（≥ σ_真）时不补：报的就是全部粒子相对报的位置的散布（不小于簇内散布）
    func testNoModelTermWhileParticlesKeepScaleSpread() {
        let map = corridor()
        var c = MagneticConfig.tracking(odometry: .pdr)
        c.initialScaleSigma = 0.3; c.scaleWalkPerM = 0
        c.reportScaleSigma = 0.10
        var z = c
        z.reportScaleSigma = 0
        let a = MagneticLocalizer(field: map, config: c, seed: 4)
        let b = MagneticLocalizer(field: map, config: z, seed: 4)
        var truth = Point2(300, 200)
        a.reset(start: truth, spreadCm: TrackingProfile.startSpreadCm)
        b.reset(start: truth, spreadCm: TrackingProfile.startSpreadCm)
        let step = Point2(25, 0)
        for _ in 0..<8 {             // 刚出发，还没被磁场 / 墙收紧
            truth = truth + step
            let ea = a.step(delta: step, feature: g(truth.x)), eb = b.step(delta: step, feature: g(truth.x))
            XCTAssertEqual(ea.uncertaintyCm, eb.uncertaintyCm, accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(eb.uncertaintyCm, eb.clusterUncertaintyCm ?? .infinity)
        }
    }
}

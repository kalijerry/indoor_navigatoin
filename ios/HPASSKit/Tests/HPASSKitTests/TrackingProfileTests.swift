import XCTest
@testable import HPASSKit

/// 跟踪配置档（MagneticConfig.tracking）：已知起点时不远跳、丢了只在附近找回。
final class TrackingProfileTests: XCTestCase {

    /// 沿 x 变化的磁场（m 为单位），30 m 内不重复。
    private func g(_ xCm: Double) -> MagneticFeature {
        let x = xCm / 100
        let bz = -42 + 6 * sin(0.9 * x) + 4 * sin(0.37 * x + 1) + 2 * sin(1.7 * x + 0.5)
        let bh = 24 + 5 * sin(0.6 * x + 2) + 3 * sin(1.3 * x)
        return MagneticFeature(total: (bz * bz + bh * bh).squareRoot(), vertical: bz, horizontal: bh)
    }

    /// 60 m × 4 m 的走廊，磁场每 `period` cm 重复一次（默认 30 m：x 和 x + 30 m 完全一样，远处的「长得像」；nil = 不重复）。
    /// hole：第一段里这一段 x 范围没有磁场数据（没采过）。
    private func world(hole: ClosedRange<Double>? = nil, period: Double? = 3000) -> MagneticFieldMap {
        let w = 6000.0, h = 400.0, cell = 50.0
        let cols = Int(w / cell), rows = Int(h / cell)
        var cells = [MagneticFeature?](), sig = [MagneticFeature?]()
        for _ in 0..<rows {
            for i in 0..<cols {
                let x = (Double(i) + 0.5) * cell
                if let hl = hole, hl.contains(x) { cells.append(nil); sig.append(nil); continue }
                cells.append(g(period.map { x.truncatingRemainder(dividingBy: $0) } ?? x))
                sig.append(MagneticFeature(total: 0.5, vertical: 0.5, horizontal: 0.5))
            }
        }
        return MagneticFieldMap(widthCm: w, heightCm: h, cellCm: cell, cells: cells, sigmas: sig)
    }

    /// 计步：步长多 2%，航向偏 2°
    private func pdr(_ d: Point2) -> Point2 {
        let a = 2.0 * Double.pi / 180
        return Point2((d.x * cos(a) - d.y * sin(a)) * 1.02, (d.x * sin(a) + d.y * cos(a)) * 1.02)
    }

    func testDefaultsKeepOldBehaviour() {
        let c = MagneticConfig()
        XCTAssertEqual(c.convergedMagWeight, 1)
        XCTAssertFalse(c.coverageGatedMagWeight)
        XCTAssertTrue(c.zeroConfidenceOffMap)
        XCTAssertFalse(c.keepClusterRequiresNear)
        XCTAssertFalse(c.localRecovery)
        XCTAssertNil(c.localRecoveryGlobalAfterCm)
        XCTAssertNil(c.trackingOdometry)
        XCTAssertEqual(c.randomInjectionConverged, 0.003)
        // 似然标定的开关默认关：冷启动 / 私有场景的行为不变
        XCTAssertEqual(c.observationSigmaFloorUT, 1.5)
        XCTAssertEqual(c.likelihoodTemperature, 1.5)
        XCTAssertEqual(c.magneticCorrelationCm, 0)
        XCTAssertEqual(c.offsetWarmupUpdates, 0)
        XCTAssertEqual(c.featureWeights.0, 1.0); XCTAssertEqual(c.featureWeights.1, 1.0); XCTAssertEqual(c.featureWeights.2, 0.5)
    }

    /// 视觉里程计跟踪档和实时定位页原来的写法数值一致
    func testVIOProfileMatchesAppValues() {
        let c = MagneticConfig.tracking(odometry: .vio)
        XCTAssertEqual(c.initialHeadingBiasSigmaDeg, 5)
        XCTAssertEqual(c.headingBiasWalkDegPerM, 1)
        XCTAssertEqual(c.positionNoiseFraction, 0.04)
        XCTAssertEqual(c.initialScaleSigma, 0.03)
        XCTAssertEqual(c.scaleWalkPerM, 0.003)
        XCTAssertEqual(c.featureWeights.0, 0.5); XCTAssertEqual(c.featureWeights.1, 1.0); XCTAssertEqual(c.featureWeights.2, 0.25)
        XCTAssertEqual(c.jumpConfirmUpdates, 15)
        XCTAssertEqual(c.convergedPositionNoiseFraction, 0.03)
        XCTAssertTrue(c.hybridOffset)
        XCTAssertEqual(TrackingProfile.startSpreadCm, 50)
        let p = MagneticConfig.tracking(odometry: .pdr)
        XCTAssertEqual(p.initialHeadingBiasSigmaDeg, 10)
        XCTAssertEqual(MagneticConfig.tracking(odometry: .pdr, headingKnown: false).initialHeadingBiasSigmaDeg, 30)
        for x in [c, p] {
            XCTAssertEqual(x.randomInjectionConverged, 0)
            XCTAssertTrue(x.keepClusterRequiresNear)
            XCTAssertFalse(x.zeroConfidenceOffMap)
            XCTAssertTrue(x.localRecovery)
            XCTAssertTrue(x.coverageGatedMagWeight)
            XCTAssertLessThan(x.convergedMagWeight, 1)
            XCTAssertEqual(x.localRecoveryGlobalAfterCm, TrackingProfile.localRecoveryGlobalAfterCm)
            XCTAssertEqual(x.observationSigmaFloorUT, TrackingProfile.observationSigmaFloorUT)
            XCTAssertEqual(x.magneticCorrelationCm, TrackingProfile.magneticCorrelationCm)
            XCTAssertEqual(x.offsetWarmupUpdates, TrackingProfile.offsetWarmupUpdates)
            XCTAssertEqual(x.offsetMedianWindow, TrackingProfile.offsetMedianWindow)
            XCTAssertEqual(x.lostConfidence, TrackingProfile.lostConfidence)
            XCTAssertLessThan(x.lostConfidence, MagneticConfig().lostConfidence)
            XCTAssertEqual(x.likelihoodTemperature, 1.5)
        }
        XCTAssertEqual(c.trackingOdometry, .vio)
        XCTAssertEqual(p.trackingOdometry, .pdr)
    }

    /// 运动来源换了（视觉里程计没对齐 / 跟丢时计步在推）：setOdometry 换成对应那套参数；冷启动配置不受影响
    func testSetOdometrySwitchesProfile() {
        func odoFields(_ c: MagneticConfig) -> [Double] {
            [c.initialHeadingBiasSigmaDeg, c.headingBiasWalkDegPerM, c.positionNoiseFraction,
             c.initialScaleSigma, c.scaleWalkPerM, c.convergedMagWeight]
        }
        let vio = MagneticConfig.tracking(odometry: .vio), pdr = MagneticConfig.tracking(odometry: .pdr)
        XCTAssertNotEqual(odoFields(vio), odoFields(pdr))
        let loc = MagneticLocalizer(field: world(), config: vio, seed: 3)
        loc.reset(start: Point2(300, 200), spreadCm: TrackingProfile.startSpreadCm)
        loc.setOdometry(.pdr)
        XCTAssertEqual(loc.config.trackingOdometry, .pdr)
        XCTAssertEqual(odoFields(loc.config), odoFields(pdr))
        XCTAssertTrue(loc.config.localRecovery)                // 跟踪策略不变
        loc.setOdometry(.vio)
        XCTAssertEqual(odoFields(loc.config), odoFields(vio))
        // 不知道朝向的计步档：起始朝向 1σ 仍是 30°
        let unk = MagneticLocalizer(field: world(), config: .tracking(odometry: .vio, headingKnown: false), seed: 3)
        unk.setOdometry(.pdr)
        XCTAssertEqual(unk.config.initialHeadingBiasSigmaDeg, 30)
        // 冷启动配置（不是跟踪档）：什么都不变
        let cold = MagneticLocalizer(field: world(), seed: 3)
        let before = odoFields(cold.config)
        cold.setOdometry(.vio)
        XCTAssertNil(cold.config.trackingOdometry)
        XCTAssertEqual(odoFields(cold.config), before)
    }

    /// 已知起点，路上有一段 15 m 没采过磁场；30 m 外有一模一样、而且有数据的地方。
    /// 跟踪档：那一段靠推算走过去，估计不会跳到远处长得像的地方。
    func testNoFarJumpWhenFarLookAlikeExists() {
        let map = world(hole: 1000...2500)
        for odo in OdometrySource.allCases {
            let loc = MagneticLocalizer(field: map, config: .tracking(odometry: odo), seed: 11)
            var truth = Point2(300, 200)
            loc.reset(start: truth, spreadCm: TrackingProfile.startSpreadCm)
            var maxErr = 0.0
            let step = Point2(25, 0)
            while truth.x < 2800 {
                truth = truth + step
                let e = loc.step(delta: pdr(step), feature: g(truth.x))
                if e.converged { maxErr = max(maxErr, e.position.distance(to: truth)) }
                XCTAssertTrue(e.converged, "\(odo) 在 x = \(truth.x) 判丢了")
            }
            XCTAssertLessThan(maxErr, 300, "\(odo)：最大误差 \(Int(maxErr)) cm")
            XCTAssertEqual(loc.lostCount, 0)
        }
    }

    /// 已知起点，中途自己判丢（置信度持续低，这里直接调 loseTrack）：找回中心是按推算平移的最后可靠位置、半径有上限，
    /// 新粒子只撒在这个圆里（圆只管注入，不管已有粒子）；不跳到 30 m 外长得像的地方，走一段之后重新有把握，位置仍然对。
    func testLocalRecoveryAfterOwnLoss() {
        let map = world()
        let loc = MagneticLocalizer(field: map, config: .tracking(odometry: .pdr), seed: 5)
        var truth = Point2(300, 200)
        loc.reset(start: truth, spreadCm: TrackingProfile.startSpreadCm)
        let step = Point2(25, 0)
        for _ in 0..<12 { truth = truth + step; loc.step(delta: pdr(step), feature: g(truth.x)) }
        loc.loseTrack()
        XCTAssertNotNil(loc.localRecoveryCenter)
        var recovered = false
        var maxErr = 0.0
        while truth.x < 2200 {
            truth = truth + step
            let e = loc.step(delta: pdr(step), feature: g(truth.x))
            maxErr = max(maxErr, e.position.distance(to: truth))
            if let c = loc.localRecoveryCenter, let r = loc.localRecoveryRadiusCm {
                XCTAssertLessThan(c.distance(to: truth), 300, "找回中心离真值太远")
                XCTAssertLessThanOrEqual(r, MagneticConfig.tracking(odometry: .pdr).localRecoveryMaxCm)
            }
            if e.converged { recovered = true }
        }
        XCTAssertTrue(recovered, "走了 18 m 还没重新有把握")
        XCTAssertLessThan(maxErr, 1000, "找回期间跳到了别处：最大误差 \(Int(maxErr)) cm")
        let e = loc.estimate()
        XCTAssertTrue(e.converged)
        XCTAssertLessThan(e.position.distance(to: truth), 300)
    }

    /// 外部判定定错（蓝牙说离得很远 → declareLost）：不围着被否定的位置找。
    /// 起点给错 15 m、锁在错的地方；外部粗定位（同 BLEAssist：没把握时权重 1、注入 20%，有把握后权重 0.3）
    /// 把它拉回真实位置。
    func testExternalLostRecoversFromWrongStart() {
        let map = world(period: nil)
        let loc = MagneticLocalizer(field: map, config: .tracking(odometry: .pdr), seed: 9)
        var truth = Point2(500, 200)
        loc.reset(start: truth + Point2(1500, 0), spreadCm: TrackingProfile.startSpreadCm)
        let step = Point2(25, 0)
        for _ in 0..<20 { truth = truth + step; loc.step(delta: pdr(step), feature: g(truth.x)) }
        XCTAssertGreaterThan(loc.estimate().position.distance(to: truth), 1000, "前提：锁在了错的地方")
        loc.declareLost()
        XCTAssertNil(loc.localRecoveryCenter, "外部判定定错后不该围着被否定的位置找")
        var e = loc.estimate()
        for k in 0..<120 {
            truth = truth + step
            if k % 4 == 0 {
                let conv = loc.isConverged
                loc.applyPositionPrior(truth + Point2(100, -50), sigmaCm: 400, weight: conv ? 0.3 : 1, injectFraction: conv ? 0 : 0.2)
            }
            e = loc.step(delta: pdr(step), feature: g(truth.x))
            if !loc.isConverged { XCTAssertNil(loc.localRecoveryCenter) }
        }
        XCTAssertTrue(e.converged, "走了 30 m 还没重新有把握")
        XCTAssertLessThan(e.position.distance(to: truth), 300, "没找回：误差 \(Int(e.position.distance(to: truth))) cm")
    }

    /// 自己判丢之后在附近一直没找回（这里用 convergenceBlocked 拦着不让重新收敛）：
    /// 走满 localRecoveryGlobalAfterCm 就改回全图找，不会永远围着一个可能是错的位置找。
    func testLocalRecoveryFallsBackToGlobal() {
        let loc = MagneticLocalizer(field: world(period: nil), config: .tracking(odometry: .pdr), seed: 4)
        var truth = Point2(500, 200)
        loc.reset(start: truth, spreadCm: TrackingProfile.startSpreadCm)
        var step = Point2(25, 0)
        for _ in 0..<8 { truth = truth + step; loc.step(delta: pdr(step), feature: g(truth.x)) }
        loc.loseTrack()
        loc.convergenceBlocked = true
        XCTAssertNotNil(loc.localRecoveryCenter)
        var walked = 0.0
        var fallbackAt: Double?
        for _ in 0..<400 {
            if truth.x > 5000 { step = Point2(-25, 0) } else if truth.x < 400 { step = Point2(25, 0) }
            truth = truth + step
            let d = pdr(step)
            walked += d.length
            loc.step(delta: d, feature: g(truth.x))
            if fallbackAt == nil && loc.localRecoveryCenter == nil { fallbackAt = walked }
        }
        let lim = TrackingProfile.localRecoveryGlobalAfterCm
        XCTAssertEqual(loc.globalFallbackCount, 1)
        XCTAssertNotNil(fallbackAt)
        XCTAssertGreaterThanOrEqual(fallbackAt ?? 0, lim - 1)
        XCTAssertLessThan(fallbackAt ?? .infinity, lim + 100)
        XCTAssertNil(loc.localRecoveryCenter)
    }

    /// 定到之后远处（30 m 外、磁场一模一样）突然长出一个更重的簇（这里直接把 95% 的粒子挪过去）：
    /// 远跳要连续确认 jumpConfirmUpdates 次，确认期间原来的簇很轻也不判丢，估计不提前跳过去。
    func testFarClusterNeedsFullConfirmation() {
        let cfg = MagneticConfig.tracking(odometry: .pdr)
        let loc = MagneticLocalizer(field: world(), config: cfg, seed: 7)
        var truth = Point2(300, 200)
        loc.reset(start: truth, spreadCm: TrackingProfile.startSpreadCm)
        let step = Point2(25, 0)
        for _ in 0..<12 { truth = truth + step; loc.step(delta: pdr(step), feature: g(truth.x)) }
        XCTAssertTrue(loc.isConverged)
        loc.moveParticlesForTesting(fraction: 0.95, to: loc.estimate().position + Point2(3000, 0), spreadCm: 30)
        // 每 2 步一次观测更新：确认满之前的 jumpConfirmUpdates − 1 次更新里都不能跳、不能判丢
        for k in 0..<(2 * (cfg.jumpConfirmUpdates - 1)) {
            truth = truth + step
            let e = loc.step(delta: pdr(step), feature: g(truth.x))
            XCTAssertTrue(e.converged, "第 \(k) 步判丢了（判丢后估计直接取远处的簇，绕过了确认）")
            XCTAssertLessThan(e.position.distance(to: truth), 300, "第 \(k) 步提前跳到了远处")
        }
        XCTAssertEqual(loc.lostCount, 0)
    }

    /// 稳健偏移估计：已知起点时先按起伏比，攒够 offsetWarmupUpdates 次更新才给整体偏移；
    /// 偏移取中位数，偶尔的离群读数（+40 µT）不把它带偏。
    func testRobustOffsetWaitsForWindowAndIgnoresOutliers() {
        let cfg = MagneticConfig.tracking(odometry: .pdr)
        let loc = MagneticLocalizer(field: world(period: nil), config: cfg, seed: 21)
        var truth = Point2(300, 200)
        loc.reset(start: truth, spreadCm: TrackingProfile.startSpreadCm)
        let off = MagneticFeature(total: 3, vertical: -5, horizontal: 2)
        let step = Point2(25, 0)
        var k = 0
        var firstOffsetAt: Int?
        while truth.x < 4500 {
            truth = truth + step
            k += 1
            var f = g(truth.x) + off
            if k % 14 == 0 { f = f + MagneticFeature(total: 40, vertical: 40, horizontal: 40) }
            let e = loc.step(delta: pdr(step), feature: f)
            if firstOffsetAt == nil, loc.currentOffset != nil { firstOffsetAt = e.updates }
            if firstOffsetAt == nil { XCTAssertLessThan(e.updates, cfg.offsetWarmupUpdates, "攒够之前就给了偏移") }
        }
        XCTAssertEqual(firstOffsetAt, cfg.offsetWarmupUpdates)
        let o = loc.currentOffset!
        XCTAssertEqual(o.total, off.total, accuracy: 1.5)
        XCTAssertEqual(o.vertical, off.vertical, accuracy: 1.5)
        XCTAssertEqual(o.horizontal, off.horizontal, accuracy: 1.5)
        XCTAssertLessThan(loc.estimate().position.distance(to: truth), 300)
        // 原有行为（offsetWarmupUpdates = 0）：第一次更新就给偏移
        var old = cfg
        old.offsetWarmupUpdates = 0
        let l2 = MagneticLocalizer(field: world(period: nil), config: old, seed: 21)
        l2.reset(start: Point2(300, 200), spreadCm: TrackingProfile.startSpreadCm)
        var t2 = Point2(300, 200)
        for _ in 0..<6 { t2 = t2 + step; l2.step(delta: pdr(step), feature: g(t2.x) + off) }
        XCTAssertNotNil(l2.currentOffset)
        XCTAssertLessThan(l2.estimate().updates, cfg.offsetWarmupUpdates)
    }

    /// 地磁残差的相关长度：同样的读数，按 6 m 才算一次独立观测时，一次更新后的粒子权重平得多（有效粒子比例高）；
    /// 0 = 原有行为
    func testMagneticCorrelationLengthSoftensUpdate() {
        func ratio(_ corr: Double) -> Double {
            var cfg = MagneticConfig.tracking(odometry: .pdr)
            cfg.magneticCorrelationCm = corr
            cfg.observationSigmaFloorUT = 1.5
            cfg.hybridOffset = false          // 按绝对值比：第一次更新就有信息（起伏模式第一次的残差恒为 0）
            let loc = MagneticLocalizer(field: world(period: nil), config: cfg, seed: 2)
            loc.reset(start: Point2(1000, 200), spreadCm: 300)
            return loc.step(delta: Point2(50, 0), feature: g(1050)).effectiveRatio
        }
        let independent = ratio(0), correlated = ratio(600)
        XCTAssertGreaterThan(correlated, independent + 0.1, "相关长度没有让更新变软：\(independent) → \(correlated)")
        XCTAssertEqual(ratio(25), independent, accuracy: 1e-9, "相关长度短于一次更新的距离时等于原有行为")
    }

    /// --oracle-start（已知起点）跟踪从不用冷启动收敛门：就算命令行覆盖打开了它也关掉，其余覆盖照样生效。
    func testOracleTrackingConfigNeverUsesColdStartGate() {
        for odo in [OdometrySource.pdr, .vio] {
            let cfg = SessionEvaluator.oracleTrackingConfig(odometry: odo) { c in
                c.applyColdStartGate()
                c.coldMinPathCm = 9000
                c.jumpConfirmUpdates = 7
            }
            XCTAssertFalse(cfg.coldStartGateEnabled)
            XCTAssertEqual(cfg.coldMinStreak, MagneticConfig().coldMinStreak)
            XCTAssertEqual(cfg.jumpConfirmUpdates, 7)
            XCTAssertEqual(cfg.trackingOdometry, odo)
        }
    }

    /// 跟踪档的「丢了」门限：只有地磁时 0.1；用过外部位置先验（蓝牙 / 区域观测）之后照旧 0.2。
    func testLostConfidenceTightensAfterExternalPrior() {
        let cfg = MagneticConfig.tracking(odometry: .pdr)
        XCTAssertEqual(cfg.lostConfidenceWithExternalPrior, TrackingProfile.lostConfidenceWithExternalPrior)
        XCTAssertGreaterThan(TrackingProfile.lostConfidenceWithExternalPrior, TrackingProfile.lostConfidence)
        XCTAssertNil(MagneticConfig().lostConfidenceWithExternalPrior)
        let loc = MagneticLocalizer(field: world(), config: cfg, seed: 3)
        loc.reset(start: Point2(500, 200), spreadCm: TrackingProfile.startSpreadCm)
        XCTAssertEqual(loc.effectiveLostConfidence, TrackingProfile.lostConfidence)
        loc.applyPositionPrior(Point2(500, 200), sigmaCm: 400, weight: 0.5)
        XCTAssertEqual(loc.effectiveLostConfidence, TrackingProfile.lostConfidenceWithExternalPrior)
        loc.reset(start: Point2(500, 200), spreadCm: TrackingProfile.startSpreadCm)
        XCTAssertEqual(loc.effectiveLostConfidence, TrackingProfile.lostConfidence)
        // 不是跟踪档：没有单独的门限，用过先验也不变
        let d = MagneticLocalizer(field: world(), config: MagneticConfig(), seed: 3)
        d.reset(start: Point2(500, 200))
        d.applyPositionPrior(Point2(500, 200), sigmaCm: 400, weight: 0.5)
        XCTAssertEqual(d.effectiveLostConfidence, MagneticConfig().lostConfidence)
    }

    /// App 冷启动配置档（MagneticEngine.makeLocalizer，start == nil）：只靠地磁不报位置；
    /// 评估的冷启动（ShadowLocalizer）用视觉里程计这一套，只有「只靠地磁报不报」不同（--no-mag-only-cold-fix 改成 App 的）。
    func testLiveColdStartProfile() {
        let v = MagneticConfig.liveColdStart(visualOdometry: true)
        let p = MagneticConfig.liveColdStart(visualOdometry: false)
        for c in [v, p] {
            XCTAssertFalse(c.magOnlyColdStartReports)
            XCTAssertTrue(c.hybridOffset)
            XCTAssertEqual(c.initialHeadingBiasSigmaDeg, 30)
            XCTAssertNil(c.trackingOdometry)
            XCTAssertFalse(c.coldStartGateEnabled)
        }
        XCTAssertEqual(v.jumpConfirmUpdates, 15)
        XCTAssertEqual(v.convergedPositionNoiseFraction, 0.03)
        XCTAssertEqual(v.featureWeights.0, 0.5)
        XCTAssertEqual(p.jumpConfirmUpdates, MagneticConfig().jumpConfirmUpdates)

        let sh = ShadowLocalizer(field: world(), walkable: nil, useRawMag: false).localizer.config
        XCTAssertTrue(sh.magOnlyColdStartReports)
        XCTAssertEqual(sh.initialHeadingBiasSigmaDeg, v.initialHeadingBiasSigmaDeg)
        XCTAssertEqual(sh.jumpConfirmUpdates, v.jumpConfirmUpdates)
        XCTAssertEqual(sh.convergedPositionNoiseFraction, v.convergedPositionNoiseFraction)
        XCTAssertEqual(sh.hybridOffset, v.hybridOffset)
        XCTAssertEqual([sh.featureWeights.0, sh.featureWeights.1, sh.featureWeights.2],
                       [v.featureWeights.0, v.featureWeights.1, v.featureWeights.2])
        let app = ShadowLocalizer(field: world(), walkable: nil, useRawMag: false,
                                  configure: { $0.magOnlyColdStartReports = false }).localizer
        XCTAssertTrue(app.magOnlyColdStartSuppressed)
    }

    /// 小场地（办公室 / 房间，没有蓝牙标签）只靠地磁的冷启动也报位置；大场地、面积不知道时照旧不报。
    func testLiveColdStartSmallVenueReportsMagOnly() {
        let office = MagneticConfig.liveColdStart(visualOdometry: false, mapAreaM2: 231)
        XCTAssertTrue(office.magOnlyColdStartReports)
        XCTAssertTrue(MagneticConfig.liveColdStart(visualOdometry: false, mapAreaM2: 1000).magOnlyColdStartReports)
        XCTAssertFalse(MagneticConfig.liveColdStart(visualOdometry: false, mapAreaM2: 4613).magOnlyColdStartReports)
        XCTAssertFalse(MagneticConfig.liveColdStart(visualOdometry: false, mapAreaM2: nil).magOnlyColdStartReports)
        XCTAssertFalse(MagneticConfig.liveColdStart(visualOdometry: false, mapAreaM2: 0).magOnlyColdStartReports)
        // 其余参数和大场地一样
        let big = MagneticConfig.liveColdStart(visualOdometry: false)
        XCTAssertEqual(office.hybridOffset, big.hybridOffset)
        XCTAssertEqual(office.initialHeadingBiasSigmaDeg, big.initialHeadingBiasSigmaDeg)
        XCTAssertEqual(office.jumpConfirmUpdates, big.jumpConfirmUpdates)

        let l = MagneticLocalizer(field: world(), config: office, seed: 5)
        l.reset(start: nil, headingUnknown: true)
        XCTAssertFalse(l.magOnlyColdStartSuppressed)
    }

    /// 小场地的冷启动搜索更强（SmallMapColdStart）：粒子更多、定到之后后台挑战者接着搜；大场地 / 面积不知道时照旧。
    /// 评估的冷启动（ShadowLocalizer）传了地图面积就用同一套，不传（采集时的影子定位）照旧。
    func testLiveColdStartSmallVenueSearch() {
        let office = MagneticConfig.liveColdStart(visualOdometry: false, mapAreaM2: 300)
        XCTAssertEqual(office.coldStartParticleCount, SmallMapColdStart.particleCount)
        XCTAssertTrue(office.coldChallenger)
        XCTAssertEqual(office.coldChallengerParticleCount, SmallMapColdStart.challengerParticleCount)
        XCTAssertEqual(SmallMapColdStart.challengerParticleCount, MagneticConfig().coldStartParticleCount)
        XCTAssertEqual(office.particleCount, MagneticConfig().particleCount)
        for big in [MagneticConfig.liveColdStart(visualOdometry: false, mapAreaM2: 4613),
                    MagneticConfig.liveColdStart(visualOdometry: true, mapAreaM2: nil), MagneticConfig()] {
            XCTAssertEqual(big.coldStartParticleCount, MagneticConfig().coldStartParticleCount)
            XCTAssertFalse(big.coldChallenger)
        }
        XCTAssertTrue(ShadowLocalizer(field: world(), walkable: nil, useRawMag: false, mapAreaM2: 240).localizer.config.coldChallenger)
        XCTAssertFalse(ShadowLocalizer(field: world(), walkable: nil, useRawMag: false).localizer.config.coldChallenger)
        XCTAssertFalse(ShadowLocalizer(field: world(), walkable: nil, useRawMag: false, mapAreaM2: 4613).localizer.config.coldChallenger)
    }

    /// 冷启动挑战者：只靠地磁冷启动定到之后整团粒子锁到了错的地方（这里直接把粒子挪到 20 m 外），
    /// 粒子权重是相对的，主滤波器自己照样「有把握」；后台挑战者从零搜到对的地方，在同一段观测上证据压过主滤波器，
    /// 换过去，估计回到真值附近。
    func testColdChallengerReplacesWrongLock() {
        let map = world(period: nil)
        var cfg = MagneticConfig.liveColdStart(visualOdometry: false, mapAreaM2: 240)
        cfg.coldStartParticleCount = 4000
        cfg.coldChallengerParticleCount = 4000
        let loc = MagneticLocalizer(field: map, config: cfg, seed: 3)
        loc.reset(start: nil, headingUnknown: true)
        var truth = Point2(400, 200)
        var dir = 1.0
        var moved = false, lockedWrong = false
        var lastErr = Double.infinity
        for _ in 0..<1600 {
            if truth.x > 5600 { dir = -1 } else if truth.x < 400 { dir = 1 }
            let step = Point2(25 * dir, 0)
            truth = truth + step
            let e = loc.step(delta: pdr(step), feature: g(truth.x))
            if e.converged && !moved {
                XCTAssertTrue(loc.challengerActive, "只靠地磁冷启动定到之后挑战者就该在后台搜")
                // 锁错：整团粒子挪到 20 m 外（航向偏差、步长比例不变）
                loc.moveParticlesForTesting(fraction: 1, to: Point2(truth.x < 3000 ? truth.x + 2000 : truth.x - 2000, 200), spreadCm: 40)
                moved = true
                continue
            }
            if moved && e.converged && e.position.distance(to: truth) > 1000 { lockedWrong = true }
            if e.converged { lastErr = e.position.distance(to: truth) }
            if loc.challengerSwaps > 0 && lastErr < 200 { break }
        }
        XCTAssertTrue(moved, "冷启动该定到")
        XCTAssertTrue(lockedWrong, "挪走之后主滤波器先锁在错的地方")
        XCTAssertGreaterThanOrEqual(loc.challengerSwaps, 1)
        XCTAssertLessThan(lastErr, 200, "换成挑战者之后应回到真值附近，误差 \(Int(lastErr)) cm")
    }

    /// 挑战者只在「只靠地磁的冷启动」里跑：已知起点、用过外部位置先验（蓝牙等）、没打开时都不跑。
    func testColdChallengerOnlyForMagOnlyColdStart() {
        let map = world(period: nil)
        var cfg = MagneticConfig.liveColdStart(visualOdometry: false, mapAreaM2: 240)
        cfg.coldStartParticleCount = 3000
        cfg.coldChallengerParticleCount = 3000
        // 走 50 m（x 400 → 5400 cm），留在 60 m 走廊里：走出地图后收敛状态取决于浮点细节，macOS / Linux 会不一样
        func walk(_ l: MagneticLocalizer, prior: Bool = false) {
            var truth = Point2(400, 200)
            for k in 0..<200 {
                truth = truth + Point2(25, 0)
                if prior && k % 4 == 0 { l.applyPositionPrior(truth, sigmaCm: 300, weight: 1) }
                l.step(delta: pdr(Point2(25, 0)), feature: g(truth.x))
            }
        }
        let known = MagneticLocalizer(field: map, config: cfg, seed: 4)
        known.reset(start: Point2(400, 200), spreadCm: 50)
        walk(known)
        XCTAssertFalse(known.challengerActive)
        let ble = MagneticLocalizer(field: map, config: cfg, seed: 4)
        ble.reset(start: nil, headingUnknown: true)
        walk(ble, prior: true)
        XCTAssertTrue(ble.isConverged)
        XCTAssertFalse(ble.challengerActive)
        var off = cfg
        off.coldChallenger = false
        let plain = MagneticLocalizer(field: map, config: off, seed: 4)
        plain.reset(start: nil, headingUnknown: true)
        walk(plain)
        XCTAssertTrue(plain.isConverged)
        XCTAssertFalse(plain.challengerActive)
        XCTAssertEqual(plain.challengerSwaps, 0)
    }

    /// App 冷启动时能解除「只靠地磁不报」的外部先验都会标 externalPriorApplied：
    /// 蓝牙粗定位（applyPositionPrior）、标签范围（applyTagRanges）、贴近标签 / 货架标识牌（applyRegion）。
    func testLiveColdStartPriorsLiftSuppression() {
        func fresh() -> MagneticLocalizer {
            let l = MagneticLocalizer(field: world(), config: .liveColdStart(visualOdometry: false), seed: 5)
            l.reset(start: nil, headingUnknown: true)
            XCTAssertTrue(l.magOnlyColdStartSuppressed)
            return l
        }
        let c = Point2(1500, 200)
        let a = fresh()
        a.applyPositionPrior(c, sigmaCm: 400, weight: 1)
        XCTAssertFalse(a.magOnlyColdStartSuppressed)
        let b = fresh()
        b.applyTagRanges([(position: c, rangeCm: 300)])
        XCTAssertFalse(b.magOnlyColdStartSuppressed)
        let r = fresh()
        _ = r.applyRegion(distance: { max(0, $0.distance(to: c) - 250) }, sample: { c })
        XCTAssertFalse(r.magOnlyColdStartSuppressed)
    }
}

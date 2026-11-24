import XCTest
@testable import HPASSKit

/// 外部审查报告第一阶段的正确性问题 NAV-001～005：每个先复现原来的错误行为，再验证修复。
final class NavCorrectnessTests: XCTestCase {

    // MARK: - NAV-001 地图几何指纹

    private func baseMap() -> StoreMap {
        var m = StoreMap(width: 1000, height: 800,
                         shelves: [ShelfRect(code: "Shelf-001", x: 300, y: 300, width: 400, height: 60, rotation: 0)],
                         crosses: [CrossSegment(code: "C1", a: Point2(100, 100), b: Point2(900, 100), lineWidth: 120),
                                   CrossSegment(code: "C2", a: Point2(900, 100), b: Point2(900, 700), lineWidth: 120)],
                         others: [(shapeType: "MapWall", x: 500, y: 400, width: 600, height: 12, rotation: 0),
                                  (shapeType: "MapDoor", x: 300, y: 400, width: 90, height: 12, rotation: 0)])
        m.units = [MapUnit(id: "A", polygon: [Point2(0, 0), Point2(1000, 0), Point2(1000, 400), Point2(0, 400)]),
                   MapUnit(id: "B", polygon: [Point2(0, 400), Point2(1000, 400), Point2(1000, 800), Point2(0, 800)])]
        return m
    }

    /// 原来各处缓存的键（MagMapStore / MagneticEngine.navigate）：数量 + id
    private func oldKeys(_ m: StoreMap) -> (crosses: Int, room: String, nav: String) {
        let units = m.roomUnits.filter { $0.isWalkable && $0.polygon.count >= 3 }
        return (m.crosses.count,
                "\(units.map(\.id).joined(separator: ","))|\(m.doors.count)|\(m.walls.count)|\(m.width)x\(m.height)",
                "\(m.shelves.count)/\(m.crosses.count)")
    }

    func testGeometryHashStableForSameGeometry() {
        XCTAssertEqual(baseMap().geometryHash, baseMap().geometryHash)
        var m = baseMap()
        m.shelves[0].x += 1e-6       // 浮点噪声不算变化
        XCTAssertEqual(m.geometryHash, baseMap().geometryHash)
    }

    func testGeometryHashChangesWhenGeometryMovesButCountsDoNot() {
        let base = baseMap()
        var edits: [(String, StoreMap)] = []
        var m = base; m.shelves[0].x += 200; edits.append(("挪货架", m))
        m = base; m.shelves[0].rotation = 90; edits.append(("转货架", m))
        m = base; m.others[1].x = 700; edits.append(("挪门", m))
        m = base; m.others[0].y = 420; edits.append(("挪墙", m))
        m = base; m.crosses[1].b = Point2(100, 700); edits.append(("改通道方向", m))
        m = base; m.crosses[0].lineWidth = 200; edits.append(("改通道宽度", m))
        m = base; m.units[0].polygon[2] = Point2(1000, 450); edits.append(("改房间多边形", m))
        m = base; m.originOffsetCm = Point2(50, 0); edits.append(("平移原点", m))
        m = base; m.arAlign = MapARTransform(pRef: .zero, aRef: .zero, phi: 0.1); edits.append(("改 AR 变换", m))
        for (name, e) in edits {
            // 复现：原来的键（数量 / id）完全没变 → 旧缓存继续用
            XCTAssertEqual(oldKeys(e).crosses, oldKeys(base).crosses, name)
            XCTAssertEqual(oldKeys(e).room, oldKeys(base).room, name)
            XCTAssertEqual(oldKeys(e).nav, oldKeys(base).nav, name)
            // 修复：几何指纹变了
            XCTAssertNotEqual(e.geometryHash, base.geometryHash, name)
        }
    }

    /// 挪了货架、数量不变：按新几何建的规划器给出不同的路线 —— 缓存键必须跟着变，否则导航用旧路
    func testMovedShelfChangesPlannedRouteWhileOldNavKeyDoesNot() {
        let crosses = [CrossSegment(code: "H0", a: Point2(100, 100), b: Point2(900, 100), lineWidth: 100),
                       CrossSegment(code: "H1", a: Point2(100, 500), b: Point2(900, 500), lineWidth: 100),
                       CrossSegment(code: "V0", a: Point2(100, 100), b: Point2(100, 500), lineWidth: 100),
                       CrossSegment(code: "V1", a: Point2(900, 100), b: Point2(900, 500), lineWidth: 100)]
        let a = StoreMap(width: 1000, height: 600,
                         shelves: [ShelfRect(code: "S", x: 500, y: 160, width: 300, height: 60, rotation: 0)], crosses: crosses)
        var b = a
        b.shelves[0].y = 440                                      // 货架挪到下面那条通道边上
        XCTAssertEqual(oldKeys(a).nav, oldKeys(b).nav)
        XCTAssertNotEqual(a.geometryHash, b.geometryHash)
        let target = Point2(500, b.shelves[0].y)
        let ra = RoutePlanner(map: a).plan(from: Point2(100, 300), targets: [Point2(500, 160)])!
        let rb = RoutePlanner(map: b).plan(from: Point2(100, 300), targets: [target])!
        XCTAssertEqual(ra.targetPoints.first!.y, 100, accuracy: 1)
        XCTAssertEqual(rb.targetPoints.first!.y, 500, accuracy: 1)
    }

    /// 定位进行中地图改了（走廊尽头新加了一面墙）：粒子滤波换上新可走区域，之后不能再穿过去；
    /// 原来定位器在开始时拿走可走区域，一直用旧的
    func testRunningLocalizerPicksUpNewGeometry() {
        let field = Self.emptyField(w: 3000, h: 400)
        let open = WalkableMap(crosses: [CrossSegment(code: "C", a: Point2(0, 200), b: Point2(3000, 200), lineWidth: 300)],
                               widthCm: 3000, heightCm: 400)
        // 新地图：走廊只到 x = 1200
        let short = WalkableMap(crosses: [CrossSegment(code: "C", a: Point2(0, 200), b: Point2(1200, 200), lineWidth: 300)],
                                widthCm: 3000, heightCm: 400)
        var cfg = MagneticConfig()
        cfg.initialHeadingBiasSigmaDeg = 0; cfg.headingBiasWalkDegPerM = 0; cfg.initialScaleSigma = 0; cfg.scaleWalkPerM = 0
        func run(replace: Bool) -> MagneticEstimate {
            let loc = MagneticLocalizer(field: field, walkable: open, config: cfg, seed: 4)
            loc.reset(start: Point2(400, 200), spreadCm: 30)
            for _ in 0..<10 { loc.step(delta: Point2(50, 0), feature: nil) }      // 走到 x ≈ 900
            if replace { loc.replaceGeometry(walkable: short, raycaster: nil) }
            var e = loc.estimate()
            for _ in 0..<20 { e = loc.step(delta: Point2(50, 0), feature: nil) }  // 再往前 10 m
            return e
        }
        XCTAssertGreaterThan(run(replace: false).position.x, 1500, "复现：旧可走区域，穿过新墙")
        let e = run(replace: true)
        XCTAssertLessThanOrEqual(e.position.x, 1400, "新墙挡住（走廊端头 1200 + 半宽 150 + 一格）")
        XCTAssertTrue(short.isWalkable(e.position))
    }

    /// 换几何时落进新障碍物的粒子挪到最近的可走处
    func testReplaceGeometryMovesParticlesOutOfNewObstacles() {
        let field = Self.emptyField(w: 3000, h: 400)
        let open = WalkableMap(crosses: [CrossSegment(code: "C", a: Point2(0, 200), b: Point2(3000, 200), lineWidth: 300)],
                               widthCm: 3000, heightCm: 400)
        let short = WalkableMap(crosses: [CrossSegment(code: "C", a: Point2(0, 200), b: Point2(1200, 200), lineWidth: 300)],
                                widthCm: 3000, heightCm: 400)
        let loc = MagneticLocalizer(field: field, walkable: open, config: MagneticConfig(), seed: 4)
        loc.reset(start: Point2(1280, 200), spreadCm: 30)
        loc.replaceGeometry(walkable: short, raycaster: nil)
        XCTAssertTrue(short.isWalkable(loc.estimate().position))
        XCTAssertEqual(loc.walkable?.walkableCellCount, short.walkableCellCount)
    }

    // MARK: - NAV-002 到达判定

    /// 两条平行通道 y = 100 / y = 300，中间一排货架（y 170～230，x 150～650），右端 x = 800 纵向通道连通
    private func aislePlanner() -> RoutePlanner {
        RoutePlanner(shelves: [ShelfRect(code: "Shelf-001", x: 400, y: 200, width: 500, height: 60, rotation: 0)],
                     crosses: [CrossSegment(code: "A", a: Point2(50, 100), b: Point2(800, 100), lineWidth: 100),
                               CrossSegment(code: "B", a: Point2(50, 300), b: Point2(800, 300), lineWidth: 100),
                               CrossSegment(code: "V", a: Point2(800, 100), b: Point2(800, 300), lineWidth: 100)])
    }

    private func fix(_ p: Point2, t: Int64, unc: Double = 80, q: FixQuality = .reliable) -> LocalizationFix {
        LocalizationFix(position: p, timestampMs: t, uncertaintyCm: unc, quality: q, source: .magnetic)
    }

    /// 连续送 n 次（每 400 ms 一次），返回最后的判定
    private func feed(_ policy: inout ArrivalPolicy, _ nav: NavigationSession, _ pts: [Point2],
                      unc: Double = 80, q: FixQuality = .reliable, t0: Int64 = 0) -> ArrivalPolicy.Reason {
        var r = ArrivalPolicy.Reason.confirming
        for (k, p) in pts.enumerated() {
            let f = fix(p, t: t0 + Int64(k) * 400, unc: unc, q: q)
            guard let h = nav.onFix(f) else { return .noTarget }
            r = policy.evaluate(fix: f, hint: h)
            if r == .arrived { return r }
        }
        return r
    }

    private func startNav(_ planner: RoutePlanner, target: Point2, from: Point2) -> NavigationSession {
        let s = NavigationSession(planner: planner)
        XCTAssertNotNil(s.start(targets: [target], from: from))
        return s
    }

    func testArrivesWhenReallyAtTarget() {
        let pl = aislePlanner()
        let nav = startNav(pl, target: Point2(300, 175), from: Point2(700, 100))   // 货架上靠 A 通道一侧的商品
        XCTAssertEqual(nav.route!.targetPoints.first!.y, 100, accuracy: 1, "目标吸附到 A 通道")
        var policy = ArrivalPolicy(lineClear: pl.isLineClear)
        let here = Array(repeating: Point2(310, 100), count: 4)
        XCTAssertEqual(feed(&policy, nav, here), .arrived)
    }

    func testSingleFixNearTargetIsNotEnough() {
        let pl = aislePlanner()
        let nav = startNav(pl, target: Point2(300, 175), from: Point2(700, 100))
        var policy = ArrivalPolicy(lineClear: pl.isLineClear)
        XCTAssertEqual(feed(&policy, nav, [Point2(310, 100)]), .confirming)
    }

    /// 人站在货架背面（B 通道一侧），投影到路线终点 → 原来的规则（剩余 ≤ 120 cm）当场宣布到达
    func testBehindShelfDoesNotArrive() {
        let pl = aislePlanner()
        let nav = startNav(pl, target: Point2(300, 175), from: Point2(700, 100))
        let behind = Point2(350, 235)                     // 货架另一侧，紧贴货架背面（货架 y 170～230）
        let h = nav.onFix(fix(behind, t: 0))!
        XCTAssertLessThanOrEqual(h.remainingDistance, 120, "复现：原规则会判到达")
        XCTAssertLessThanOrEqual(behind.distance(to: Point2(300, 100)), NavInstruction.arriveCm)
        var policy = ArrivalPolicy(lineClear: pl.isLineClear)
        let r = feed(&policy, nav, Array(repeating: behind, count: 6), t0: 400)
        XCTAssertEqual(r, .blocked)
    }

    func testLargeUncertaintyDoesNotArrive() {
        let pl = aislePlanner()
        let nav = startNav(pl, target: Point2(300, 175), from: Point2(700, 100))
        var policy = ArrivalPolicy(lineClear: pl.isLineClear)
        XCTAssertEqual(feed(&policy, nav, Array(repeating: Point2(300, 100), count: 6), unc: 500), .uncertain)
    }

    func testUnreliableQualityDoesNotArrive() {
        let pl = aislePlanner()
        for q in [FixQuality.searching, .coarse, .degraded, .lost] {
            let nav = startNav(pl, target: Point2(300, 175), from: Point2(700, 100))
            var policy = ArrivalPolicy(lineClear: pl.isLineClear)
            XCTAssertEqual(feed(&policy, nav, Array(repeating: Point2(300, 100), count: 6), q: q), .quality(q), "\(q)")
        }
    }

    /// 瞬间跳点：在目标和远处之间来回跳，永远凑不满连续确认
    func testJumpingFixesDoNotArrive() {
        let pl = aislePlanner()
        let nav = startNav(pl, target: Point2(300, 175), from: Point2(700, 100))
        var policy = ArrivalPolicy(lineClear: pl.isLineClear)
        var pts: [Point2] = []
        for _ in 0..<5 { pts.append(Point2(300, 100)); pts.append(Point2(700, 100)) }
        XCTAssertNotEqual(feed(&policy, nav, pts), .arrived)
    }

    /// 规划器给的退化路线（没有有效目标 → 单点路线，剩余 0）：原规则当场到达
    func testDegenerateRouteWithoutTargetNeverArrives() {
        let pl = aislePlanner()
        let r = pl.plan(from: Point2(300, 100), targets: [])!
        let h = pl.hint(for: Point2(300, 100), on: r)
        XCTAssertEqual(h.remainingDistance, 0, "复现：原规则会判到达")
        var policy = ArrivalPolicy(lineClear: pl.isLineClear)
        for k in 0..<5 {
            XCTAssertEqual(policy.evaluate(fix: fix(Point2(300, 100), t: Int64(k) * 400), hint: h), .noTarget)
        }
    }

    /// 不可达目标（通道图上不连通，没有栅格兜底）：路线里没有目标点，不到达
    func testUnreachableTargetNeverArrives() {
        let pl = RoutePlanner(shelves: [],
                              crosses: [CrossSegment(code: "A", a: Point2(0, 100), b: Point2(400, 100), lineWidth: 100),
                                        CrossSegment(code: "Z", a: Point2(800, 600), b: Point2(900, 600), lineWidth: 100)])
        let r = pl.plan(from: Point2(100, 100), targets: [Point2(850, 600)])!
        XCTAssertTrue(r.targetPoints.isEmpty)
        XCTAssertFalse(r.unreachableTargets.isEmpty)
        let h = pl.hint(for: Point2(100, 100), on: r)
        var policy = ArrivalPolicy(lineClear: pl.isLineClear)
        for k in 0..<5 {
            XCTAssertEqual(policy.evaluate(fix: fix(Point2(100, 100), t: Int64(k) * 400), hint: h), .noTarget)
        }
    }

    /// 隔墙：房间图里目标在墙另一边（直线 1 m，没有门）
    func testAcrossWallDoesNotArrive() throws {
        let m = try RoomGraphTests.office()
        guard let w = WalkableMap(roomsOf: m) else { return XCTFail("房间图") }
        let pl = RoutePlanner(map: m, walkable: w)
        // 找一对直线距离 ≤ 120 cm、都可走、但不经门换房间的点
        var pair: (Point2, Point2)?
        outer: for y in stride(from: 25.0, to: m.height, by: 50) {
            for x in stride(from: 25.0, to: m.width, by: 50) {
                let a = Point2(x, y), b = Point2(x, y + 100)
                if w.isWalkable(a), w.isWalkable(b), w.rooms!.crossesWithoutDoor(from: a, to: b) { pair = (a, b); break outer }
            }
        }
        guard let (a, b) = pair else { return XCTFail("测试地图里应该有隔墙的两点") }
        XCTAssertFalse(pl.isLineClear(from: a, to: b))
        let route = Route(nodes: [RouteNode(point: Point2(b.x + 300, b.y)),
                                  RouteNode(point: b, isTarget: true, distanceFromStart: 300)], length: 300)
        var h = pl.hint(for: a, on: route)
        h.distanceToRoute = 0; h.remainingDistance = 0   // 投影落在终点（就算投影没问题也要挡住）
        var policy = ArrivalPolicy(lineClear: pl.isLineClear)
        for k in 0..<5 {
            XCTAssertEqual(policy.evaluate(fix: fix(a, t: Int64(k) * 400), hint: h), .blocked)
        }
    }

    // MARK: - NAV-003 后验航向

    private static func emptyField(w: Double, h: Double) -> MagneticFieldMap {
        let cell = 50.0
        let cols = Int((w / cell).rounded(.up)), rows = Int((h / cell).rounded(.up))
        return MagneticFieldMap(widthCm: w, heightCm: h, cellCm: cell,
                                cells: [MagneticFeature?](repeating: nil, count: cols * rows),
                                sigmas: [MagneticFeature?](repeating: nil, count: cols * rows))
    }

    /// 计步航向固定偏 +20°，人沿窄走廊 +x 走（真航向 90°）：走廊墙把偏差不对的粒子挡掉，位置被修正；
    /// 修正后的航向也要跟着回到 ~90°，而不是继续报计步的 110°。
    func testPosteriorHeadingCorrectsFixedHeadingBias() {
        let walk = WalkableMap(crosses: [CrossSegment(code: "C", a: Point2(0, 200), b: Point2(6000, 200), lineWidth: 100)],
                               widthCm: 6000, heightCm: 400)
        var cfg = MagneticConfig()
        cfg.initialHeadingBiasSigmaDeg = 25
        cfg.headingBiasWalkDegPerM = 0.5
        cfg.initialScaleSigma = 0
        cfg.scaleWalkPerM = 0
        let loc = MagneticLocalizer(field: Self.emptyField(w: 6000, h: 400), walkable: walk, config: cfg, seed: 7)
        loc.reset(start: Point2(200, 200), spreadCm: 30)
        let pdrHeading = (90.0 + 20) * Double.pi / 180
        let d = Point2(sin(pdrHeading), cos(pdrHeading)) * 50
        var e = loc.estimate()
        for _ in 0..<60 { e = loc.step(delta: d, feature: nil) }           // 30 m
        // 位置被走廊修正：还在走廊中线附近，且确实往 +x 走了
        XCTAssertEqual(e.position.y, 200, accuracy: 60)
        XCTAssertGreaterThan(e.position.x, 2000)
        // 复现：直接用计步航向，箭头偏 20°
        XCTAssertEqual(pdrHeading * 180 / Double.pi, 110, accuracy: 1e-9)
        // 修复：后验航向偏差 ≈ +20°，修正后 ≈ 90°
        let b = try! XCTUnwrap(e.headingBiasRad)
        XCTAssertEqual(b * 180 / Double.pi, 20, accuracy: 6)
        let h = try! XCTUnwrap(e.correctedHeading(pdrHeadingRad: pdrHeading))
        XCTAssertEqual(h * 180 / Double.pi, 90, accuracy: 6)
        XCTAssertFalse(e.headingMultimodal)
    }

    /// 符号约定：修正后的航向 = 粒子实际推着走的方向（θ − b），不是 θ + b
    func testCorrectedHeadingMatchesParticleMotionDirection() {
        var cfg = MagneticConfig()
        cfg.initialScaleSigma = 0; cfg.scaleWalkPerM = 0; cfg.headingBiasWalkDegPerM = 0
        cfg.positionNoiseFraction = 0; cfg.positionNoiseFloorCm = 0; cfg.convergedPositionNoiseFraction = 0
        let loc = MagneticLocalizer(field: Self.emptyField(w: 4000, h: 4000), config: cfg, seed: 2)
        loc.reset(start: Point2(2000, 2000), spreadCm: 1)
        loc.carryModeChanged(spreadDeg: 1, centersDeg: [30], suppressLostCm: 0)   // 偏差集中在 +30°
        let theta = 0.3
        let before = loc.estimate().position
        let e = loc.step(delta: Point2(sin(theta), cos(theta)) * 100, feature: nil)
        let mv = e.position - before
        let moved = atan2(mv.x, mv.y)                       // FusionTypes 约定：atan2(dx, dy)
        let h = try! XCTUnwrap(e.correctedHeading(pdrHeadingRad: theta))
        var diff = abs(h - (moved < 0 ? moved + 2 * Double.pi : moved))
        diff = min(diff, 2 * Double.pi - diff)
        XCTAssertLessThan(diff * 180 / Double.pi, 2)
        XCTAssertEqual(e.headingBiasRad! * 180 / Double.pi, 30, accuracy: 2)
    }

    /// 航向多峰（±90° 两个假设）或整圆不确定：不给精确航向
    func testUncertainHeadingGivesNoArrow() {
        let loc = MagneticLocalizer(field: Self.emptyField(w: 2000, h: 2000), config: MagneticConfig(), seed: 5)
        loc.reset(start: Point2(1000, 1000), spreadCm: 50)
        loc.carryModeChanged(spreadDeg: 8, centersDeg: [90, -90], suppressLostCm: 0)
        var e = loc.estimate()
        XCTAssertTrue(e.headingMultimodal)
        XCTAssertNil(e.correctedHeading(pdrHeadingRad: 1))
        loc.carryModeChanged(spreadDeg: nil, suppressLostCm: 0)
        e = loc.estimate()
        XCTAssertGreaterThan(e.headingBiasSigmaRad!, MagneticEstimate.maxHeadingSigmaRad)
        XCTAssertNil(e.correctedHeading(pdrHeadingRad: 1))
        var cls = FixQualityClassifier()
        XCTAssertNil(LocalizationFix.from(e, timestampMs: 0, pdrHeadingRad: 1, classifier: &cls).headingRad)
    }

    // MARK: - NAV-004 定位质量

    func testClassifierStates() {
        var c = FixQualityClassifier()
        XCTAssertEqual(c.classify(position: Point2(0, 0), timestampMs: 0, uncertaintyCm: 100, converged: false), .searching)
        XCTAssertEqual(c.classify(position: Point2(0, 0), timestampMs: 100, uncertaintyCm: 1200, converged: true), .coarse)
        XCTAssertEqual(c.classify(position: Point2(0, 0), timestampMs: 200, uncertaintyCm: 100, converged: true, roomOnly: true), .coarse)
        XCTAssertEqual(c.classify(position: Point2(0, 0), timestampMs: 300, uncertaintyCm: 100, converged: true), .reliable)
        XCTAssertEqual(c.classify(position: Point2(0, 0), timestampMs: 400, uncertaintyCm: 700, converged: true), .degraded)
        XCTAssertEqual(c.classify(position: Point2(800, 0), timestampMs: 500, uncertaintyCm: 100, converged: true), .degraded, "跳点")
        XCTAssertEqual(c.classify(position: Point2(820, 0), timestampMs: 600, uncertaintyCm: 100, converged: true), .reliable)
        XCTAssertEqual(c.classify(position: Point2(820, 0), timestampMs: 700, uncertaintyCm: 100, converged: false), .lost)
    }

    /// 网格通道：(100,100) 出发去 (900,500)，先沿 y=100 向右，在 x=900 右转
    private func gridNav() -> NavigationSession {
        var cfg = RoutePlannerConfig()
        cfg.offRouteDistanceCm = 300
        cfg.offRouteConfirmUpdates = 3
        let cs = [CrossSegment(code: "H0", a: Point2(100, 100), b: Point2(900, 100), lineWidth: 200),
                  CrossSegment(code: "H1", a: Point2(100, 500), b: Point2(900, 500), lineWidth: 200),
                  CrossSegment(code: "V0", a: Point2(100, 100), b: Point2(100, 500), lineWidth: 200),
                  CrossSegment(code: "V1", a: Point2(900, 100), b: Point2(900, 500), lineWidth: 200)]
        let s = NavigationSession(planner: RoutePlanner(shelves: [], crosses: cs, config: cfg))
        s.start(targets: [Point2(900, 500)], from: Point2(150, 100))
        return s
    }

    func testCoarseAndSearchingFixesGiveNoTurnInstructions() {
        let nav = gridNav()
        let near = Point2(800, 100)                          // 离右转 100 cm
        XCTAssertNotEqual(nav.onFix(fix(near, t: 0)).map(\.direction), .straight, "reliable：出转向")
        for q in [FixQuality.coarse, .searching, .lost] {
            let h = nav.onFix(fix(near, t: 0, q: q))!
            XCTAssertEqual(h.direction, .straight, "\(q)")
            XCTAssertEqual(h.quality, q)
            XCTAssertFalse(NavInstruction.text(h).contains("转"), "\(q)：\(NavInstruction.text(h))")
        }
        let d = nav.onFix(fix(near, t: 0, q: .degraded))!
        XCTAssertNotEqual(d.direction, .straight, "degraded 照常出转向")
    }

    /// degraded / coarse 时脱线也不重新规划；reliable 连续脱线才换路
    func testDegradedFixesDoNotReplan() {
        let nav = gridNav()
        let route0 = nav.route!
        let far = Point2(100, 500)                            // 离当前路线 400 cm
        for k in 0..<6 {
            let h = nav.onFix(fix(far, t: Int64(k) * 400, q: .degraded))!
            XCTAssertFalse(h.isOffRoute)
        }
        XCTAssertEqual(nav.route!.points, route0.points, "degraded 不换路")
        for k in 0..<3 { nav.onFix(fix(far, t: 4000 + Int64(k) * 400)) }
        XCTAssertNotEqual(nav.route!.points, route0.points, "reliable 连续脱线才重新规划")
    }

    /// 还没路线（开始导航时没位置）时，没定到的位置不触发规划
    func testSearchingFixDoesNotPlan() {
        let nav = NavigationSession(planner: aislePlanner())
        nav.start(targets: [Point2(300, 175)], from: nil)
        XCTAssertNil(nav.onFix(fix(Point2(700, 100), t: 0, q: .searching)))
        XCTAssertNil(nav.route)
        XCTAssertNotNil(nav.onFix(fix(Point2(700, 100), t: 400)))
        XCTAssertNotNil(nav.route)
    }

    // MARK: - NAV-005 过期磁场观测

    private let f1 = MagneticFeature(total: 45, vertical: 40, horizontal: 20)
    private let f2 = MagneticFeature(total: 50, vertical: 42, horizontal: 27)

    /// 复现：原来「直接拿最新特征」的做法，磁力计停了以后每个 IMU 样本都还拿到同一个旧特征
    func testStaleFeatureNotReusedAfterSensorStops() {
        var latest: MagneticFeature? = nil                    // 原来 App 里的 pipe.latest
        var gate = MagObservationGate()
        latest = f1; gate.offer(f1, tMs: 1000)
        var oldUses = 0, newUses = 0
        for t in stride(from: Int64(1010), through: 3000, by: 10) {   // 磁力计 1000 ms 之后停了，IMU 照常 100 Hz
            if latest != nil { oldUses += 1 }
            if gate.current(at: t) != nil { newUses += 1 }
        }
        XCTAssertEqual(oldUses, 200, "复现：旧特征被当成 2 秒的新证据")
        XCTAssertEqual(newUses, 10, "修复：只在 100 ms 内用")
        XCTAssertGreaterThan(gate.staleCount, 0)
    }

    func testOutOfOrderAndDuplicateObservationsRejected() {
        var gate = MagObservationGate()
        XCTAssertTrue(gate.offer(f1, tMs: 1000))
        XCTAssertFalse(gate.offer(f2, tMs: 990), "乱序")
        XCTAssertFalse(gate.offer(f2, tMs: 1000), "重复时间戳")
        XCTAssertEqual(gate.current(at: 1010), f1)
        XCTAssertEqual(gate.rejectedOutOfOrder, 2)
        XCTAssertEqual(gate.latest?.sequence, 1)
    }

    /// 后台恢复：中间断了很久，恢复后的第一个新样本立刻能用；时钟错位（特征比 IMU 新太多）不用
    func testBackgroundResumeAndClockSkew() {
        var gate = MagObservationGate()
        gate.offer(f1, tMs: 1000)
        XCTAssertNil(gate.current(at: 60_000), "后台 1 分钟：旧特征作废")
        gate.offer(f2, tMs: 60_005)
        XCTAssertEqual(gate.current(at: 60_010), f2)
        XCTAssertNil(gate.current(at: 59_000), "特征比 IMU 新 1 s：时间戳乱了，不用")
    }
}

import Foundation
import XCTest
@testable import HPASSKit

/// 办公室房间约束（RoomGraph）：合成的「两间办公室 + 走廊 + 两扇门」地图，全部是合成数据（cm，y 向下）。
///
///     y 100 ┌──────── A ────────┐┌──────── B ────────┐
///           │  (100…500)        ││  (510…910)        │      A、B 之间是墙（x = 505），没有门
///     y 400 └────[门 A]─────────┘└────[门 B]─────────┘      门 A 中心 (300, 405)、门 B 中心 (710, 405)，宽 90
///     y 410 ┌──────────────── 走廊 C ──────────────────┐
///     y 560 └──────────────────────────────────────────┘
final class RoomGraphTests: XCTestCase {

    // MARK: 合成地图

    /// 房间扫描风格：单元之间留 10 cm 墙缝，墙是 MapWall（10 cm 厚），门 14 cm 厚。imdf = true 时是 IMDF 风格：
    /// 单元贴着（没有墙缝）、没有墙、门是 MapOpening，并且不写 units（只有 floorPolygons）。
    /// abWall = false：A、B 之间那面墙没扫到（开放式办公区被切成两个单元），abWallGapCm > 0：墙在中间留一道这么宽的缝。
    static func officeJSON(imdf: Bool = false, abWall: Bool = true, abWallGapCm: Double = 0) -> Data {
        let gap = imdf ? 0.0 : 5.0
        func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [Double] { [x0, y0, x1, y0, x1, y1, x0, y1] }
        let a = rect(100, 100, 505 - gap, 405 - gap)
        let b = rect(505 + gap, 100, 910, 405 - gap)
        let c = rect(100, 405 + gap, 910, 560)
        var elements: [[String: Any]] = []
        if !imdf {
            func wall(_ x: Double, _ y: Double, _ w: Double, _ rot: Double) {
                elements.append(["shapeType": "MapWall", "x": x, "y": y, "width": w, "height": 10, "rotation": rot, "heightCm": 260])
            }
            wall(505, 100, 820, 0)          // 北外墙
            wall(505, 405, 820, 0)          // 房间 / 走廊之间（门嵌在这面墙里）
            wall(505, 565, 820, 0)          // 南外墙
            if abWall && abWallGapCm <= 0 {
                wall(505, 250, 310, 90)     // A、B 之间
            } else if abWall {              // 中间留缝：上下两段
                let half = (310 - abWallGapCm) / 2
                wall(505, 95 + half / 2, half, 90)
                wall(505, 405 - half / 2, half, 90)
            }
            wall(95, 330, 470, 90)          // 西外墙
            wall(915, 330, 470, 90)         // 东外墙
            // 一张桌子（Konva 左上角）：A 里 (150…250, 150…200)
            elements.append(["shapeType": "MapShelf", "code": "Room-table-1", "x": 150, "y": 150, "width": 100, "height": 50,
                             "rotation": 0, "heightCm": 75])
        }
        let doorType = imdf ? "MapOpening" : "MapDoor"
        elements.append(["shapeType": doorType, "x": 300, "y": 405, "width": 90, "height": 14, "rotation": 0])
        elements.append(["shapeType": doorType, "x": 710, "y": 405, "width": 90, "height": 14, "rotation": 180])
        var root: [String: Any] = ["width": 1010, "height": 660, "floorName": "合成办公室", "mapElementList": elements,
                                   "floorPolygons": [a, b, c]]
        if !imdf {
            root["units"] = [["id": "A", "category": "room", "polygon": a],
                             ["id": "B", "category": "room", "polygon": b],
                             ["id": "C", "category": "walkway", "polygon": c]]
        }
        return try! JSONSerialization.data(withJSONObject: root)
    }

    static func office(imdf: Bool = false, abWall: Bool = true, abWallGapCm: Double = 0) throws -> StoreMap {
        try StoreDataLoader.loadMap(officeJSON(imdf: imdf, abWall: abWall, abWallGapCm: abWallGapCm))
    }

    /// 没有任何磁场数据的场（只测运动约束）
    static func emptyField(_ m: StoreMap) -> MagneticFieldMap {
        let cell = 50.0
        let cols = Int((m.width / cell).rounded(.up)), rows = Int((m.height / cell).rounded(.up))
        return MagneticFieldMap(widthCm: m.width, heightCm: m.height, cellCm: cell,
                                cells: [MagneticFeature?](repeating: nil, count: cols * rows),
                                sigmas: [MagneticFeature?](repeating: nil, count: cols * rows))
    }

    /// 确定性的运动模型（航向、步长不随机），位置噪声照常
    static func config(rooms: Bool) -> MagneticConfig {
        var c = MagneticConfig()
        c.initialHeadingBiasSigmaDeg = 0
        c.headingBiasWalkDegPerM = 0
        c.initialScaleSigma = 0
        c.scaleWalkPerM = 0
        c.roomConstraints = rooms
        c.reportRoom = true
        return c
    }

    /// 按折线走，每步 20 cm
    @discardableResult
    static func walk(_ loc: MagneticLocalizer, _ pts: [Point2]) -> MagneticEstimate {
        var e = loc.estimate()
        for k in 1..<pts.count {
            let d = pts[k] - pts[k - 1]
            let n = max(Int((d.length / 20).rounded(.up)), 1)
            for _ in 0..<n { e = loc.step(delta: d * (1 / Double(n)), feature: nil) }
        }
        return e
    }

    // MARK: 地图解析 / 栅格

    func testLoaderParsesUnitsWallsDoors() throws {
        let m = try Self.office()
        XCTAssertEqual(m.units.map(\.id), ["A", "B", "C"])
        XCTAssertEqual(m.units[2].category, "walkway")
        XCTAssertEqual(m.walls.count, 6)
        XCTAssertEqual(m.doors.count, 2)
        XCTAssertEqual(m.doors[0].center, Point2(300, 405))
        XCTAssertEqual(m.doors[0].thickness, 14)
        // IMDF 风格：没有 units → 每块地面一个 room（F1…），没有墙，开口算门
        let i = try Self.office(imdf: true)
        XCTAssertTrue(i.units.isEmpty)
        XCTAssertEqual(i.roomUnits.map(\.id), ["F1", "F2", "F3"])
        XCTAssertTrue(i.walls.isEmpty)
        XCTAssertEqual(i.doors.count, 2)
    }

    func testRoomRasterWallsDoorsAndAdjacency() throws {
        let g = try XCTUnwrap(RoomGraph(map: try Self.office()))
        XCTAssertEqual(g.roomId(at: Point2(400, 300)), "A")
        XCTAssertEqual(g.roomId(at: Point2(700, 250)), "B")
        XCTAssertEqual(g.roomId(at: Point2(600, 480)), "C")
        XCTAssertFalse(g.isOpen(Point2(505, 250)))                     // A、B 之间的墙
        XCTAssertFalse(g.isOpen(Point2(150, 405)))                     // 房间 / 走廊之间的墙（门以外）
        XCTAssertFalse(g.isOpen(Point2(200, 175)))                     // 桌子
        XCTAssertTrue(g.isOpen(Point2(300, 405)))                      // 门洞压过墙
        XCTAssertEqual(g.doorIndex(at: Point2(300, 405)), 0)
        XCTAssertEqual(g.doorIndex(at: Point2(710, 390)), 1)
        let ia = 0, ib = 1, ic = 2
        XCTAssertEqual(g.doorRooms, [[ia, ic], [ib, ic]])
        XCTAssertEqual(g.neighbours(ofRoom: ia), [ic])
        XCTAssertEqual(g.neighbours(ofRoom: ic), [ia, ib])
        XCTAssertEqual(g.neighbours(ofRoom: ib), [ic])

        XCTAssertFalse(g.crossesWithoutDoor(from: Point2(300, 330), to: Point2(300, 480)))   // 穿门
        XCTAssertTrue(g.crossesWithoutDoor(from: Point2(150, 330), to: Point2(150, 480)))    // 穿墙
        XCTAssertTrue(g.crossesWithoutDoor(from: Point2(450, 250), to: Point2(560, 250)))    // A → B
        XCTAssertFalse(g.crossesWithoutDoor(from: Point2(150, 250), to: Point2(450, 350)))   // 同一个房间里

        let w = WalkableMap(rooms: g)
        XCTAssertTrue(w.isSegmentClear(from: Point2(300, 330), to: Point2(300, 480)))
        XCTAssertFalse(w.isSegmentClear(from: Point2(150, 330), to: Point2(150, 480)))
        XCTAssertFalse(w.isSegmentClear(from: Point2(450, 250), to: Point2(560, 250)))
    }

    /// 房间扫描把一片开放空间切成两个单元、分界上没有墙：分界当隐形门，A ↔ B 直接走过去不算穿墙。
    /// 2026-11 办公室 R3 / R4 就是这样，旧规则把跟着人的粒子全挡掉。
    func testOpenSeamWithoutWallConnectsRooms() throws {
        let g = try XCTUnwrap(RoomGraph(map: try Self.office(abWall: false)))
        XCTAssertEqual(g.openSeams, 1)
        XCTAssertEqual(g.doors.count, 2)
        XCTAssertEqual(g.doorRooms.count, 3)
        XCTAssertEqual(g.doorRooms[2], [0, 1])
        XCTAssertFalse(g.crossesWithoutDoor(from: Point2(450, 250), to: Point2(560, 250)))   // A → B：没墙，能过
        XCTAssertTrue(g.crossesWithoutDoor(from: Point2(150, 330), to: Point2(150, 480)))    // 有墙的地方照样挡
        XCTAssertEqual(g.neighbours(ofRoom: 0), [1, 2])
        // 关掉开关 = 原来的规则
        var cfg = RoomGraph.Config()
        cfg.openSeams = false
        let old = try XCTUnwrap(RoomGraph(map: try Self.office(abWall: false), config: cfg))
        XCTAssertEqual(old.openSeams, 0)
        XCTAssertTrue(old.crossesWithoutDoor(from: Point2(450, 250), to: Point2(560, 250)))
    }

    /// 墙上一道比 minOpenSeamCm 窄的缝（墙段没对齐）不当门；够宽的缝当门
    func testShortWallGapIsNotAnOpening() throws {
        let narrow = try XCTUnwrap(RoomGraph(map: try Self.office(abWallGapCm: 30)))
        XCTAssertEqual(narrow.openSeams, 0)
        XCTAssertTrue(narrow.crossesWithoutDoor(from: Point2(450, 250), to: Point2(560, 250)))
        let wide = try XCTUnwrap(RoomGraph(map: try Self.office(abWallGapCm: 150)))
        XCTAssertEqual(wide.openSeams, 1)
        XCTAssertFalse(wide.crossesWithoutDoor(from: Point2(450, 250), to: Point2(560, 250)))
    }

    /// IMDF 风格的地图：单元贴着、没有墙，可走区域本身挡不住，只有房间规则挡。
    func testImdfStyleRoomsTouchAndOnlyDoorRuleSeparates() throws {
        let w = try XCTUnwrap(WalkableMap(roomsOf: try Self.office(imdf: true)))
        let g = try XCTUnwrap(w.rooms)
        XCTAssertEqual(g.roomId(at: Point2(150, 390)), "F1")
        XCTAssertEqual(g.roomId(at: Point2(150, 420)), "F3")
        XCTAssertTrue(w.isSegmentClear(from: Point2(150, 330), to: Point2(150, 480)))        // 没有墙
        XCTAssertTrue(g.crossesWithoutDoor(from: Point2(150, 330), to: Point2(150, 480)))    // 但换房间没经过门
        XCTAssertFalse(g.crossesWithoutDoor(from: Point2(300, 330), to: Point2(300, 480)))   // 开口（14 cm 厚）也打通到两侧
        XCTAssertFalse(g.crossesWithoutDoor(from: Point2(710, 390), to: Point2(710, 420)))
        XCTAssertEqual(g.doorRooms, [[0, 2], [1, 2]])
    }

    /// 门 A 只连 A 和走廊：从 A 经门 A 斜着一步直接进 B 不算合法（门不连 B）。
    func testDoorMustConnectBothRooms() throws {
        let g = try XCTUnwrap(RoomGraph(map: try Self.office(imdf: true)))
        // 门 A 的门洞格里有 A、C；从门 A 的 A 侧到 B（同一行，跨过 A/B 边界，中途碰到的门是门 A）
        XCTAssertTrue(g.crossesWithoutDoor(from: Point2(330, 395), to: Point2(560, 395)))
    }

    /// 房间里没有通道走向先验
    func testNoAisleHeadingPriorInRooms() throws {
        let w = try XCTUnwrap(WalkableMap(roomsOf: try Self.office()))
        for j in 0..<w.rows {
            for i in 0..<w.cols {
                XCTAssertNil(w.axisAngle(at: Point2((Double(i) + 0.5) * w.cellCm, (Double(j) + 0.5) * w.cellCm)))
            }
        }
    }

    // MARK: 粒子

    /// 贴着 A、B 之间的墙一直往东走：粒子留在 A（两种地图都一样）。
    /// IMDF 风格的地图没有墙，不开房间约束时粒子会直接走进 B（对照）。
    func testParticlesDoNotCrossWalls() throws {
        for imdf in [false, true] {
            let m = try Self.office(imdf: imdf)
            let w = try XCTUnwrap(WalkableMap(roomsOf: m))
            let loc = MagneticLocalizer(field: Self.emptyField(m), walkable: w, config: Self.config(rooms: true), seed: 3)
            loc.reset(start: Point2(400, 250), spreadCm: 20)
            let aId = imdf ? "F1" : "A"
            let e = Self.walk(loc, [Point2(400, 250), Point2(800, 250)])
            XCTAssertEqual(e.roomId, aId, "imdf=\(imdf)")
            XCTAssertGreaterThan(e.roomMass, 0.99, "imdf=\(imdf)")
            XCTAssertLessThan(loc.particleMean.x, 505, "imdf=\(imdf)")
            XCTAssertFalse(e.roomOnly)
            // 往南直冲墙（门以外）：留在 A
            let loc2 = MagneticLocalizer(field: Self.emptyField(m), walkable: w, config: Self.config(rooms: true), seed: 4)
            loc2.reset(start: Point2(150, 300), spreadCm: 15)
            let e2 = Self.walk(loc2, [Point2(150, 300), Point2(150, 520)])
            XCTAssertEqual(e2.roomId, aId, "imdf=\(imdf)")
            XCTAssertGreaterThan(e2.roomMass, 0.99, "imdf=\(imdf)")
        }
        // 对照：IMDF 风格、不开房间约束 → 走进 B
        let m = try Self.office(imdf: true)
        let w = try XCTUnwrap(WalkableMap(roomsOf: m))
        let loc = MagneticLocalizer(field: Self.emptyField(m), walkable: w, config: Self.config(rooms: false), seed: 3)
        loc.reset(start: Point2(400, 250), spreadCm: 20)
        let e = Self.walk(loc, [Point2(400, 250), Point2(800, 250)])
        XCTAssertEqual(e.roomId, "F2")
    }

    /// A → 门 A → 走廊 → 门 B → B：门能走过去，最后在 B，房间置信度高。
    func testDoorPassageReachesOtherRoom() throws {
        for imdf in [false, true] {
            let m = try Self.office(imdf: imdf)
            let w = try XCTUnwrap(WalkableMap(roomsOf: m))
            let loc = MagneticLocalizer(field: Self.emptyField(m), walkable: w, config: Self.config(rooms: true), seed: 7)
            loc.reset(start: Point2(300, 250), spreadCm: 10)
            let mid = Self.walk(loc, [Point2(300, 250), Point2(300, 485)])
            XCTAssertEqual(mid.roomId, imdf ? "F3" : "C", "imdf=\(imdf)")
            let e = Self.walk(loc, [Point2(300, 485), Point2(710, 485), Point2(710, 250)])
            XCTAssertEqual(e.roomId, imdf ? "F2" : "B", "imdf=\(imdf)")
            XCTAssertGreaterThan(e.roomMass, 0.7, "imdf=\(imdf)")
            XCTAssertFalse(e.roomOnly)
            XCTAssertLessThan(e.position.distance(to: Point2(710, 250)), 60, "imdf=\(imdf) \(e.position)")
        }
    }

    /// roomMass = 全部粒子里落在估计房间的权重占比；不够 0.7 时只报房间级。
    func testRoomIdAndRoomMass() throws {
        let m = try Self.office()
        let w = try XCTUnwrap(WalkableMap(roomsOf: m))
        let loc = MagneticLocalizer(field: Self.emptyField(m), walkable: w, config: Self.config(rooms: true), seed: 9)
        loc.reset(start: Point2(600, 485), spreadCm: 20)
        var e = loc.estimate()
        XCTAssertEqual(e.roomId, "C")
        XCTAssertEqual(e.roomMass, 1, accuracy: 1e-9)
        XCTAssertFalse(e.roomOnly)
        // 四成粒子挪到 A 里（离走廊的簇够远）：估计仍在走廊，房间置信度 ≈ 0.6 → 只报房间级
        loc.moveParticlesForTesting(fraction: 0.4, to: Point2(200, 250), spreadCm: 20)
        e = loc.estimate()
        XCTAssertEqual(e.roomId, "C")
        XCTAssertEqual(e.roomMass, 0.6, accuracy: 0.01)
        XCTAssertTrue(e.roomOnly)
        // 不打开 reportRoom：没有房间字段
        var c = Self.config(rooms: true)
        c.reportRoom = false
        let loc2 = MagneticLocalizer(field: Self.emptyField(m), walkable: w, config: c, seed: 9)
        loc2.reset(start: Point2(600, 485), spreadCm: 20)
        XCTAssertNil(loc2.estimate().roomId)
        XCTAssertEqual(loc2.estimate().roomMass, 0)
        // 默认全关
        let d = MagneticConfig()
        XCTAssertFalse(d.roomConstraints)
        XCTAssertFalse(d.reportRoom)
        XCTAssertFalse(d.stationaryFreeze)
    }

    // MARK: 静止冻结

    func testStationaryFreezeDetectorTiming() {
        var d = StationaryFreezeDetector()
        XCTAssertNil(d.update(tMs: 0, still: true, stepCount: 0))
        XCTAssertNil(d.update(tMs: 19_900, still: true, stepCount: 0))
        XCTAssertEqual(d.update(tMs: 20_000, still: true, stepCount: 0), .freeze)
        XCTAssertNil(d.update(tMs: 25_000, still: true, stepCount: 0))
        // 坐着挪椅子、换坐姿：长时间「不静止」、偶尔一两步伪步，都不解冻（评审：这正是要冻住的时候）
        for k in 0..<100 { XCTAssertNil(d.update(tMs: 25_100 + Int64(k) * 100, still: false, stepCount: 0)) }
        XCTAssertNil(d.update(tMs: 35_200, still: false, stepCount: 1))
        XCTAssertNil(d.update(tMs: 35_800, still: false, stepCount: 2))
        XCTAssertNil(d.update(tMs: 38_000, still: false, stepCount: 2))
        XCTAssertTrue(d.frozen)
        // 起身走：连续三步、间隔像走路 → 解冻，那串步从第一步算起
        XCTAssertNil(d.update(tMs: 40_000, still: false, stepCount: 3))
        XCTAssertNil(d.update(tMs: 40_550, still: false, stepCount: 4))
        XCTAssertEqual(d.update(tMs: 41_100, still: false, stepCount: 5), .release)
        XCTAssertEqual(d.releaseWalkStartMs, 40_000)
        XCTAssertFalse(d.frozen)
        // 静止被打断要重新计时
        XCTAssertNil(d.update(tMs: 50_000, still: true, stepCount: 5))
        XCTAssertNil(d.update(tMs: 65_000, still: false, stepCount: 5))
        XCTAssertNil(d.update(tMs: 66_000, still: true, stepCount: 5))
        XCTAssertNil(d.update(tMs: 85_000, still: true, stepCount: 5))
        XCTAssertEqual(d.update(tMs: 86_000, still: true, stepCount: 5), .freeze)
        // 没有步数：退回「不静止持续 releaseAfterS」
        var n = StationaryFreezeDetector()
        XCTAssertNil(n.update(tMs: 0, still: true))
        XCTAssertEqual(n.update(tMs: 20_000, still: true), .freeze)
        XCTAssertNil(n.update(tMs: 21_000, still: false))
        XCTAssertNil(n.update(tMs: 24_900, still: false))
        XCTAssertEqual(n.update(tMs: 25_000, still: false), .release)
        XCTAssertNil(n.releaseWalkStartMs)
        // 不在房间里不冻结
        var o = StationaryFreezeDetector()
        XCTAssertNil(o.update(tMs: 0, still: true, inRoom: false))
        XCTAssertNil(o.update(tMs: 30_000, still: true, inRoom: false))
    }

    func testStationaryFreezeShrinksHoldsAndReleases() throws {
        let m = try Self.office()
        let w = try XCTUnwrap(WalkableMap(roomsOf: m))
        var c = Self.config(rooms: true)
        c.stationaryFreeze = true
        let loc = MagneticLocalizer(field: Self.emptyField(m), walkable: w, config: c, seed: 11)
        loc.reset(start: Point2(350, 300), spreadCm: 60)
        let c0 = loc.estimate().position
        XCTAssertGreaterThan(loc.weightedSpread(around: c0), 60)
        var det = StationaryFreezeDetector()
        var events: [StationaryFreezeDetector.Event] = []
        for k in 0...210 {          // 21 s 静止，10 Hz
            if let ev = loc.feedStationary(&det, tMs: Int64(k * 100), still: true, stepCount: 0) { events.append(ev) }
        }
        XCTAssertEqual(events, [.freeze])
        XCTAssertTrue(loc.stationaryFrozen)
        let c1 = loc.estimate().position
        // 收拢是向各自房间的中心（少数撒进走廊的粒子留在走廊、不穿墙进 A），所以相对估计点的散布比 50 cm 略大
        XCTAssertLessThanOrEqual(loc.weightedSpread(around: c1), 65)
        XCTAssertEqual(loc.estimate().roomId, "A")
        // 冻结期间（坐着挪动）的伪步不推粒子，也不解冻
        for k in 0..<10 {
            loc.feedStationary(&det, tMs: 21_100 + Int64(k) * 100, still: false, stepCount: k < 5 ? 0 : 1)
            loc.step(delta: Point2(30, 0), feature: nil)
        }
        XCTAssertTrue(loc.stationaryFrozen)
        XCTAssertLessThan(loc.estimate().position.distance(to: c1), 1)
        // 起身走三步（每步 −x 60 cm）：第三步解冻，三步的位移都补上，散布放大 1.5 倍
        let before = loc.weightedSpread(around: c1)
        var ev: StationaryFreezeDetector.Event?
        for k in 0..<3 {
            ev = loc.feedStationary(&det, tMs: 30_000 + Int64(k) * 550, still: false, stepCount: 2 + k)
            loc.step(delta: Point2(k < 2 ? -60 : 0, 0), feature: nil)
        }
        XCTAssertEqual(ev, .release)
        XCTAssertFalse(loc.stationaryFrozen)
        XCTAssertLessThan(loc.estimate().position.x, c1.x - 90, "起身头几步的位移应补推：\(loc.estimate().position) 对 \(c1)")
        XCTAssertEqual(loc.weightedSpread(around: loc.estimate().position), before * 1.5, accuracy: before * 0.3)

        // 开关关着：什么都不做
        let off = MagneticLocalizer(field: Self.emptyField(m), walkable: w, config: Self.config(rooms: true), seed: 11)
        off.reset(start: Point2(350, 300), spreadCm: 60)
        XCTAssertFalse(off.freezeStationary())
        XCTAssertFalse(off.stationaryFrozen)
    }

    /// 粒子在桌子两边（坐在桌边）：加权平均点落在桌子里。冻结后粒子和估计都不能在桌子里，解冻后还能走
    func testStationaryFreezeAroundFurnitureStaysWalkable() throws {
        let m = try Self.office()
        let w = try XCTUnwrap(WalkableMap(roomsOf: m))
        var c = Self.config(rooms: true)
        c.stationaryFreeze = true
        let loc = MagneticLocalizer(field: Self.emptyField(m), walkable: w, config: c, seed: 5)
        loc.reset(start: Point2(200, 122), spreadCm: 4)
        loc.moveParticlesForTesting(fraction: 0.5, to: Point2(200, 232), spreadCm: 4)
        XCTAssertFalse(w.isWalkable(Point2(200, 177)), "桌子本体不可走（前提）")
        XCTAssertTrue(loc.freezeStationary())
        let e = loc.estimate()
        XCTAssertTrue(w.isWalkable(e.position) || e.position.distance(to: Point2(200, 177)) > 40,
                      "冻结后的估计点不该在桌子里：\(e.position)")
        XCTAssertNil(w.rooms?.roomIndex(at: Point2(200, 175)), "桌子里的格子不算在房间里")
        loc.releaseStationaryFreeze()
        let p0 = loc.estimate().position
        for _ in 0..<5 { loc.step(delta: Point2(-20, 0), feature: nil) }
        XCTAssertLessThan(loc.estimate().position.x, p0.x - 50, "解冻后应该还能走（没卡在桌子里）")
    }

    /// 房间之争（六成在走廊、四成在 A）：不冻结，免得把它硬判成一个房间
    func testStationaryFreezeRefusesAmbiguousRoom() throws {
        let m = try Self.office()
        let w = try XCTUnwrap(WalkableMap(roomsOf: m))
        var c = Self.config(rooms: true)
        c.stationaryFreeze = true
        let loc = MagneticLocalizer(field: Self.emptyField(m), walkable: w, config: c, seed: 9)
        loc.reset(start: Point2(600, 485), spreadCm: 20)
        loc.moveParticlesForTesting(fraction: 0.4, to: Point2(200, 250), spreadCm: 20)
        XCTAssertFalse(loc.freezeStationary())
        XCTAssertFalse(loc.stationaryFrozen)
        let e = loc.estimate()
        XCTAssertEqual(e.roomId, "C")
        XCTAssertEqual(e.roomRunnerUpId, "A")
        XCTAssertEqual(e.roomRunnerUpMass, 0.4, accuracy: 0.06)
    }

    /// 报的房间是权重最多的房间，不是加权平均点所在的房间（平均点落在第三个房间时尤其）
    func testRoomIdIsHeaviestRoomNotMeanPoint() throws {
        let m = try Self.office()
        let w = try XCTUnwrap(WalkableMap(roomsOf: m))
        let loc = MagneticLocalizer(field: Self.emptyField(m), walkable: w, config: Self.config(rooms: true), seed: 9)
        loc.reset(start: Point2(300, 150), spreadCm: 10)
        loc.moveParticlesForTesting(fraction: 0.45, to: Point2(880, 540), spreadCm: 5)
        let e = loc.estimate()
        XCTAssertEqual(e.roomId, "A")
        XCTAssertEqual(e.roomMass, 0.55, accuracy: 0.03)
        XCTAssertTrue(e.roomOnly)
        XCTAssertEqual(e.roomRunnerUpId, "C")
    }

    // MARK: 房间扫描 → map.json → 房间图

    /// RoomMapBuilder（多房间扫描）的输出里有 RoomGraph 要的全部东西：单元多边形、门、墙；
    /// 墙只有 10 cm 厚、门只有 14 cm 厚（比 25 cm 的格子薄），栅格上照样连续 / 打通。
    func testRoomMapBuilderOutputFeedsRoomGraph() throws {
        // ARKit (x, z)，米：A (0…4, 0…3)、B (4…8, 0…3)、走廊 C (0…8, 3…4.5)，墙线在 x = 4、z = 3
        var inp = RoomMapBuilder.Input()
        func wall(_ cx: Double, _ cz: Double, _ len: Double, _ yaw: Double) -> RoomMapBuilder.Item {
            .init(category: "wall", center: Point2(cx, cz), width: len, depth: 0, height: 2.6, yaw: yaw)
        }
        inp.walls = [wall(4, 0, 8, 0), wall(4, 3, 8, 0), wall(4, 4.5, 8, 0), wall(4, 1.5, 3, .pi / 2),
                     wall(0, 2.25, 4.5, .pi / 2), wall(8, 2.25, 4.5, .pi / 2)]
        inp.doors = [.init(category: "door", center: Point2(2, 3), width: 0.9, depth: 0, height: 2.1, yaw: 0),
                     .init(category: "door", center: Point2(6, 3), width: 0.9, depth: 0, height: 2.1, yaw: .pi)]
        inp.objects = [.init(category: "table", center: Point2(1, 1), width: 1.2, depth: 0.6, height: 0.75, yaw: 0)]
        inp.rooms = [.init(id: "A", floor: [Point2(0, 0), Point2(4, 0), Point2(4, 3), Point2(0, 3)]),
                     .init(id: "B", floor: [Point2(4, 0), Point2(8, 0), Point2(8, 3), Point2(4, 3)]),
                     .init(id: "C", floor: [Point2(0, 3), Point2(8, 3), Point2(8, 4.5), Point2(0, 4.5)], category: "walkway")]
        let (_, map) = try RoomMapBuilder.build(inp, name: "合成办公室")
        XCTAssertEqual(map.units.map(\.id), ["A", "B", "C"])
        XCTAssertEqual(map.walls.count, 6)
        XCTAssertEqual(map.doors.count, 2)
        XCTAssertEqual(map.floor.count, 3)
        let t = try XCTUnwrap(map.arAlign)
        func P(_ x: Double, _ z: Double) -> Point2 { t.toMap(Point2(x * 100, z * 100)) }
        let w = try XCTUnwrap(WalkableMap(roomsOf: map))
        let g = try XCTUnwrap(w.rooms)
        XCTAssertEqual(g.roomId(at: P(3, 1.5)), "A")
        XCTAssertEqual(g.roomId(at: P(5, 1.5)), "B")
        XCTAssertEqual(g.roomId(at: P(4, 4)), "C")
        XCTAssertEqual(g.doorRooms, [[0, 2], [1, 2]])
        // 房间多边形贴着（共用墙线），只有墙挡
        XCTAssertFalse(w.isSegmentClear(from: P(3.6, 1.5), to: P(4.4, 1.5)))         // A ↔ B 穿墙
        XCTAssertFalse(w.isSegmentClear(from: P(1, 2.6), to: P(1, 3.4)))             // A ↔ C 门以外
        XCTAssertTrue(w.isSegmentClear(from: P(2, 2.5), to: P(2, 3.5)))              // 门 A
        XCTAssertFalse(g.crossesWithoutDoor(from: P(2, 2.5), to: P(2, 3.5)))
        XCTAssertTrue(w.isSegmentClear(from: P(6, 2.5), to: P(6, 3.5)))              // 门 B
        XCTAssertFalse(w.isWalkable(P(1, 1)))                                         // 桌子
        // 斜着扫一遍墙：x = 4 这面墙上每 5 cm 一段都过不去
        var z = 0.1
        while z < 2.9 {
            XCTAssertFalse(w.isSegmentClear(from: P(3.7, z), to: P(4.3, z + 0.2)), "z = \(z)")
            z += 0.05
        }
    }
}

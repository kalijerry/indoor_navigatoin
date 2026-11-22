import Foundation

/// 办公室这类「房间 + 走廊 + 门」地图的房间约束：把单元多边形栅格化成房间编号，墙挡住，门洞打通。
///
/// 输入（都是地图坐标，cm）：
/// - 单元（map.json `units`；没有时用 `floorPolygons`，见 `StoreMap.roomUnits`）：可走的单元各有一个房间编号，
///   不可走的单元（structure、shaft…）和 `obstaclePolygons` 挡住；
/// - 墙（MapWall）：挡住。房间扫描的墙只有约 10 cm 厚，比格子还薄，所以厚度方向每边放宽 `wallMarginCm`，保证墙在栅格上是连续的一条；
/// - 门 / 开口（MapDoor、MapOpening）：门矩形沿墙方向是门宽，垂直墙方向放宽到 `doorDepthCm`，
///   覆盖的格子打通（压过墙），记成门洞格，连接两侧的房间。IMDF 的开口就是单元边界上的一条线段，同样处理；
/// - 家具（MapShelf）：四周放宽 `furnitureMarginCm` 后挡住（放宽的部分不压门洞）。
///
/// 定位用它做两件事：粒子一步从一个房间走到另一个房间、中途没经过连接这两个房间的门洞，就算穿墙（见
/// `MagneticConfig.roomConstraints`）；估计结果带房间编号和房间置信度（见 `MagneticConfig.reportRoom`）。
/// IMDF 地图没有墙，相邻单元直接贴着，墙只能靠这条「不经门不能换房间」的规则。
public final class RoomGraph {
    public struct Config {
        public var cellCm: Double = 25
        public var furnitureMarginCm: Double = 15
        /// 墙矩形四周放宽（cm）。≥ 0.75 格时斜墙在栅格上也不会出现对角缝
        public var wallMarginCm: Double = 20
        /// 门洞垂直墙方向的总深度（cm）：打通墙缝，并伸进两侧房间各约一半
        public var doorDepthCm: Double = 80
        /// 门洞沿墙方向每边收窄（cm，门框）
        public var doorInsetCm: Double = 0
        /// 有墙的地图里，没有墙的房间分界当隐形门（见 init 第 7 步）
        public var openSeams = true
        /// 隐形门最短多长（cm）：比这短的缝当成墙角没对齐
        public var minOpenSeamCm: Double = 60
        public init() {}
    }

    public let config: Config
    public let widthCm: Double
    public let heightCm: Double
    public let cellCm: Double
    public let cols: Int
    public let rows: Int
    /// 有房间编号的单元（可走单元，按输入顺序），房间编号 = 下标
    public let rooms: [MapUnit]
    /// 每扇门 / 开口连接的房间编号（升序；地图边上的门可能只连一个房间）
    public private(set) var doorRooms: [[Int]] = []
    public let doors: [MapRect]

    private var label: [Int32]       // 房间编号，-1 = 不在任何房间里（墙缝、地图外、不可走单元）
    private var door: [Int32]        // 门编号，-1 = 不是门洞
    private var open: [Bool]         // 能走

    public init(units: [MapUnit], doors: [MapRect], walls: [MapRect], obstacles: [ShelfRect],
                obstaclePolygons: [[Point2]] = [], widthCm: Double, heightCm: Double, config: Config = .init()) {
        precondition(widthCm > 0 && heightCm > 0 && config.cellCm > 0)
        self.config = config
        self.widthCm = widthCm
        self.heightCm = heightCm
        cellCm = config.cellCm
        cols = Int((widthCm / cellCm).rounded(.up))
        rows = Int((heightCm / cellCm).rounded(.up))
        let n = cols * rows
        label = [Int32](repeating: -1, count: n)
        door = [Int32](repeating: -1, count: n)
        open = [Bool](repeating: false, count: n)
        let walkUnits = units.filter { $0.polygon.count >= 3 && $0.isWalkable }
        rooms = walkUnits
        self.doors = doors

        // 1. 房间：格心在多边形里（重叠时先到先得）
        for (r, u) in walkUnits.enumerated() {
            forCells(in: bbox(u.polygon)) { k, p in
                if label[k] < 0, pointInPolygon(p, u.polygon) { label[k] = Int32(r); open[k] = true }
            }
        }
        // 2. 不可走单元、obstaclePolygons
        let blockPolys = units.filter { $0.polygon.count >= 3 && !$0.isWalkable }.map(\.polygon) + obstaclePolygons.filter { $0.count >= 3 }
        for poly in blockPolys {
            forCells(in: bbox(poly)) { k, p in
                if pointInPolygon(p, poly) { open[k] = false; label[k] = -1 }
            }
        }
        // 3. 墙
        for w in walls {
            forCells(in: rectBox(w.center, w.width / 2 + config.wallMarginCm, w.thickness / 2 + config.wallMarginCm, w.rotationDeg)) { k, p in
                if pointInRotatedRect(p, center: w.center, width: w.width, height: w.thickness,
                                      rotationDeg: w.rotationDeg, margin: config.wallMarginCm) { open[k] = false }
            }
        }
        // 4. 门洞：压过墙
        let minHalf = cellCm * 0.5 + 0.01
        for (d, dr) in doors.enumerated() {
            let hw = max(dr.width / 2 - config.doorInsetCm, minHalf)
            let hd = max(dr.thickness, config.doorDepthCm) / 2
            forCells(in: rectBox(dr.center, hw, hd, dr.rotationDeg)) { k, p in
                if pointInRotatedRect(p, center: dr.center, width: 2 * hw, height: 2 * hd, rotationDeg: dr.rotationDeg) {
                    open[k] = true
                    door[k] = Int32(d)
                }
            }
        }
        // 5. 家具：本体总是挡；放宽的边不压门洞
        let fm = config.furnitureMarginCm
        for o in obstacles {
            let r = o.rotation * Double.pi / 180
            let hw = o.width / 2 + fm, hh = o.height / 2 + fm
            let ex = abs(cos(r)) * hw + abs(sin(r)) * hh, ey = abs(sin(r)) * hw + abs(cos(r)) * hh
            let c = Point2(o.x, o.y)
            forCells(in: (c.x - ex, c.x + ex, c.y - ey, c.y + ey)) { k, p in
                guard open[k], pointInRotatedRect(p, center: c, width: o.width, height: o.height, rotationDeg: o.rotation, margin: fm) else { return }
                if door[k] < 0 || pointInRotatedRect(p, center: c, width: o.width, height: o.height, rotationDeg: o.rotation) { open[k] = false }
            }
        }
        // 6. 每扇门连接哪些房间：门洞格的房间编号；不到两个时在门矩形外再放宽两格找
        var dr: [[Int]] = []
        for (d, dd) in doors.enumerated() {
            var s = Set<Int>()
            let hw = max(dd.width / 2 - config.doorInsetCm, minHalf)
            let hd = max(dd.thickness, config.doorDepthCm) / 2
            forCells(in: rectBox(dd.center, hw, hd, dd.rotationDeg)) { k, _ in
                if door[k] == Int32(d), label[k] >= 0 { s.insert(Int(label[k])) }
            }
            if s.count < 2 {
                let ext = hd + 2 * cellCm
                forCells(in: rectBox(dd.center, hw, ext, dd.rotationDeg)) { k, p in
                    if label[k] >= 0, pointInRotatedRect(p, center: dd.center, width: 2 * hw, height: 2 * ext, rotationDeg: dd.rotationDeg) {
                        s.insert(Int(label[k]))
                    }
                }
            }
            dr.append(s.sorted())
        }
        doorRooms = dr
        // 7. 没有墙的房间分界（开放式办公区）：房间扫描把一片开放空间切成了两个单元，分界上却没有墙也没有门。
        //    有墙的地图（房间扫描）里，能不能过去由墙说了算：分界上两侧都能走的格子连成一段（≥ minOpenSeamCm）就当一扇
        //    隐形的门。IMDF 地图没有墙、单元直接贴着，那里仍然只能经门换房间（不加隐形门）。
        //    2026-11 办公室：R3 / R4 分界没有墙，人每天从那里走过，旧规则把跟着人的粒子全挡掉了（留一法回放误差 1.2 m → 4 m）。
        if config.openSeams && !walls.isEmpty {
            var seam = [Int32](repeating: -1, count: n)          // 分界格所属的房间对（下标进 pairs）
            var pairs: [[Int]] = []
            func pairId(_ a: Int, _ b: Int) -> Int32 {
                let p = [min(a, b), max(a, b)]
                if let i = pairs.firstIndex(of: p) { return Int32(i) }
                pairs.append(p)
                return Int32(pairs.count - 1)
            }
            for j in 0..<rows {
                for i in 0..<cols {
                    let k = j * cols + i
                    guard open[k], label[k] >= 0, door[k] < 0 else { continue }
                    for (di, dj) in [(1, 0), (0, 1)] {
                        let i2 = i + di, j2 = j + dj
                        guard i2 < cols, j2 < rows else { continue }
                        let k2 = j2 * cols + i2
                        guard open[k2], label[k2] >= 0, label[k2] != label[k], door[k2] < 0 else { continue }
                        let pid = pairId(Int(label[k]), Int(label[k2]))
                        seam[k] = pid
                        seam[k2] = pid
                    }
                }
            }
            // 同一房间对的分界格按 8 邻接连成段，够长的一段 = 一扇隐形门
            let minCells = max(Int((config.minOpenSeamCm / cellCm).rounded(.up)), 1)
            var visited = [Bool](repeating: false, count: n)
            for k0 in 0..<n where seam[k0] >= 0 && !visited[k0] {
                var comp = [k0], q = [k0]
                visited[k0] = true
                while let k = q.popLast() {
                    let i = k % cols, j = k / cols
                    for dj in -1...1 {
                        for di in -1...1 {
                            let i2 = i + di, j2 = j + dj
                            guard i2 >= 0, i2 < cols, j2 >= 0, j2 < rows else { continue }
                            let k2 = j2 * cols + i2
                            if !visited[k2], seam[k2] == seam[k0] { visited[k2] = true; comp.append(k2); q.append(k2) }
                        }
                    }
                }
                // 段长：分界两侧各一排格子，按格数的一半算
                guard (comp.count + 1) / 2 >= minCells else { continue }
                let id = Int32(dr.count)
                dr.append(pairs[Int(seam[k0])])
                for k in comp { door[k] = id }
                openSeams += 1
            }
            doorRooms = dr
        }
    }

    /// 第 7 步加的隐形门（没有墙的房间分界）有几段；它们在 `doorRooms` 里排在真门后面（下标 ≥ `doors.count`）
    public private(set) var openSeams = 0

    /// 从地图建：单元用 `roomUnits`，门 = MapDoor + MapOpening，墙 = MapWall，家具 = 实体货架（房间扫描的家具）。
    /// 没有任何单元时返回 nil（场地通道地图不用房间约束）。
    public convenience init?(map: StoreMap, config: Config = .init()) {
        let units = map.roomUnits
        guard units.contains(where: { $0.isWalkable && $0.polygon.count >= 3 }) else { return nil }
        self.init(units: units, doors: map.doors, walls: map.walls, obstacles: map.physicalShelves,
                  obstaclePolygons: map.obstacleFloor, widthCm: map.width, heightCm: map.height, config: config)
    }

    // MARK: 查询

    func index(_ p: Point2) -> Int? {
        guard p.x >= 0, p.y >= 0, p.x.isFinite, p.y.isFinite else { return nil }
        let i = Int(p.x / cellCm), j = Int(p.y / cellCm)
        guard i < cols, j < rows else { return nil }
        return j * cols + i
    }

    /// 第 k 格能不能走
    public func isOpen(index k: Int) -> Bool { k >= 0 && k < open.count && open[k] }
    public func isOpen(_ p: Point2) -> Bool { index(p).map { open[$0] } ?? false }

    /// p 所在格的房间编号（rooms 下标）；墙缝、地图外、不可走单元返回 nil
    public func roomIndex(at p: Point2) -> Int? {
        // 墙、家具挡住的格子（open = false）不算在房间里：墙 / 家具那几步没清 label（门的连通、最近房间还要用它）
        guard let k = index(p), label[k] >= 0, open[k] else { return nil }
        return Int(label[k])
    }

    /// p 所在格的房间 id（map.json 单元 id）
    public func roomId(at p: Point2) -> String? { roomIndex(at: p).map { rooms[$0].id } }

    /// p 所在格是哪扇门的门洞（doors 下标）
    public func doorIndex(at p: Point2) -> Int? {
        guard let k = index(p), door[k] >= 0 else { return nil }
        return Int(door[k])
    }

    /// p 所在房间；p 在墙缝 / 门洞中间没有房间编号时，取 radiusCm 内格心最近的有房间编号的格子
    public func nearestRoomIndex(to p: Point2, radiusCm: Double) -> Int? {
        if let r = roomIndex(at: p) { return r }
        guard let k0 = index(Point2(min(max(p.x, 0), widthCm - 1), min(max(p.y, 0), heightCm - 1))) else { return nil }
        let i0 = k0 % cols, j0 = k0 / cols, rr = Int((radiusCm / cellCm).rounded(.up))
        var best: Int?, bd = radiusCm
        for dj in -rr...rr {
            for di in -rr...rr {
                let i = i0 + di, j = j0 + dj
                guard i >= 0, i < cols, j >= 0, j < rows else { continue }
                let k = j * cols + i
                guard label[k] >= 0, open[k] else { continue }
                let d = Point2((Double(i) + 0.5) * cellCm, (Double(j) + 0.5) * cellCm).distance(to: p)
                if d < bd { bd = d; best = Int(label[k]) }
            }
        }
        return best
    }

    /// 和房间 r 有门相通的房间编号（升序）
    public func neighbours(ofRoom r: Int) -> [Int] {
        var s = Set<Int>()
        for d in doorRooms where d.contains(r) { for x in d where x != r { s.insert(x) } }
        return s.sorted()
    }

    /// 从 a 直线走到 b，是否「换了房间却没经过连接这两个房间的门洞」。
    ///
    /// 每 1/4 格取一个点。每次房间编号变化（中间没编号的墙缝 / 门洞格跳过），要求从上一个房间的最后一个点
    /// 到新房间的第一个点之间（含两端）碰到过一个门洞格，而且那扇门连着这两个房间（只连一个房间的门不挑）。
    public func crossesWithoutDoor(from a: Point2, to b: Point2) -> Bool {
        guard let ka = index(a) else { return false }
        var last = Int(label[ka])
        var seen: [Int32] = door[ka] >= 0 ? [door[ka]] : []
        let d = a.distance(to: b)
        let n = max(Int((d / (cellCm * 0.25)).rounded(.up)), 1)
        var prevK = ka
        for s in 1...n {
            let t = Double(s) / Double(n)
            guard let k = index(Point2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)) else { continue }
            if k == prevK { continue }
            prevK = k
            let r = Int(label[k]), dk = door[k]
            if dk >= 0 && !seen.contains(dk) { seen.append(dk) }
            guard r >= 0 else { continue }
            if last >= 0 && r != last {
                let ok = seen.contains { dd in
                    let rs = doorRooms[Int(dd)]
                    return rs.count < 2 || (rs.contains(last) && rs.contains(r))
                }
                if !ok { return true }
            }
            last = r
            seen = dk >= 0 ? [dk] : []
        }
        return false
    }

    // MARK: 内部

    private func bbox(_ poly: [Point2]) -> (Double, Double, Double, Double) {
        (poly.map(\.x).min()!, poly.map(\.x).max()!, poly.map(\.y).min()!, poly.map(\.y).max()!)
    }

    /// 旋转矩形（中心、半长 hw、半宽 hh、角度）的外包框
    private func rectBox(_ c: Point2, _ hw: Double, _ hh: Double, _ rotDeg: Double) -> (Double, Double, Double, Double) {
        let r = rotDeg * Double.pi / 180
        let ex = abs(cos(r)) * hw + abs(sin(r)) * hh, ey = abs(sin(r)) * hw + abs(cos(r)) * hh
        return (c.x - ex, c.x + ex, c.y - ey, c.y + ey)
    }

    /// 对格心落在外包框里的格子（裁到地图内）调用 body(k, 格心)
    private func forCells(in box: (Double, Double, Double, Double), _ body: (Int, Point2) -> Void) {
        let (minX, maxX, minY, maxY) = box
        guard minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite,
              maxX >= -cellCm, maxY >= -cellCm, minX <= widthCm + cellCm, minY <= heightCm + cellCm else { return }
        let i0 = max(Int((max(minX, 0) / cellCm).rounded(.down)) - 1, 0), i1 = min(Int((min(maxX, widthCm) / cellCm).rounded(.up)) + 1, cols - 1)
        let j0 = max(Int((max(minY, 0) / cellCm).rounded(.down)) - 1, 0), j1 = min(Int((min(maxY, heightCm) / cellCm).rounded(.up)) + 1, rows - 1)
        guard i0 <= i1, j0 <= j1 else { return }
        for j in j0...j1 {
            for i in i0...i1 { body(j * cols + i, Point2((Double(i) + 0.5) * cellCm, (Double(j) + 0.5) * cellCm)) }
        }
    }
}

import Foundation

/// 室内路径规划器。
///
/// 流程：
/// 1. **建图**：通道中心线 → 端点 + 交点切分 → 无向加权图（RouteGraph.build）。
/// 2. **目标吸附**：商品点按货架朝向法线投影到“货架正对的那条通道”（snapToAisle）。
/// 3. **多目标排序**：图上最近邻（贪心 TSP 启发式）+ 2-opt 改进。
/// 4. **分段搜索**：逐段 A*（欧氏启发式 + 转弯惩罚）后拼接。
/// 5. **化简**：删除近似共线的中间折点（目标点永不删除）。
///
/// 坐标约定见 RouteGeometry.swift 顶部：屏幕坐标系，+x 右、+y 下，单位 cm，正角度 = 右转。
public final class RoutePlanner {

    public let config: RoutePlannerConfig
    private let shelves: [ShelfRect]
    private let crosses: [CrossSegment]
    private let baseGraph: RouteGraph
    /// 栅格 A* 兜底（通道图缺失 / 目标在图上不可达时用）；nil = 不兜底
    private let grid: GridRouter?

    public convenience init(map: StoreMap, walkable: WalkableMap? = nil, config: RoutePlannerConfig = .init()) {
        self.init(shelves: map.shelves, crosses: map.crosses, walkable: walkable, config: config)
    }

    public init(shelves: [ShelfRect], crosses: [CrossSegment], walkable: WalkableMap? = nil,
                config: RoutePlannerConfig = .init()) {
        self.grid = walkable.map { GridRouter(walkable: $0) }
        let validShelves = shelves.filter {
            $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.height.isFinite && $0.rotation.isFinite
        }
        let validCrosses = crosses.filter {
            $0.a.x.isFinite && $0.a.y.isFinite && $0.b.x.isFinite && $0.b.y.isFinite
        }
        self.config = config
        self.shelves = validShelves
        self.crosses = validCrosses
        self.baseGraph = RouteGraph.build(crosses: validCrosses,
                                          tolerance: config.junctionToleranceCm)
    }

    /// 仅供测试 / 调试：基础图的节点与无向边数量。
    var graphNodeCount: Int { baseGraph.nodes.count }
    var graphEdgeCount: Int { baseGraph.edgeCount }

    private var mergeTolerance: Double { max(config.junctionToleranceCm, 1.0) }
    /// 判定“点在货架上”时的外扩量：标签坐标常落在货架外沿
    private var shelfMargin: Double { max(config.junctionToleranceCm, 1.0) }

    // MARK: - 货架几何

    /// 货架四角，多边形顺序。
    public func shelfVertices(_ s: ShelfRect) -> [Point2] {
        RouteGeometry.rectCorners(center: Point2(s.x, s.y),
                                  width: s.width, height: s.height,
                                  rotationDeg: s.rotation)
    }

    /// 把一个（可能落在货架上的）点吸附到可行走通道。
    ///
    /// - 若点落在某个货架内（含外扩 margin）：沿货架**朝向法线**双向各打一条射线
    ///   （长边面向通道，所以法线 = 短轴方向）。只有命中通道的一侧才是正确的一侧；
    ///   两侧都命中时取更近的一侧。随后把点垂直投影到命中的那条通道上。
    /// - 否则（或两侧都没命中）：退化为“垂距最近的通道”。
    ///
    /// 这样做的意义：最近的通道完全可能在货架**另一侧**，直接取最近通道会让顾客
    /// 站在货架背面。rotation 为 0/90/180/270 和任意角度都走同一套代码。
    public func snapToAisle(_ p: Point2) -> Point2 {
        guard p.x.isFinite, p.y.isFinite else { return p }
        guard !crosses.isEmpty else { return p }
        if let shelf = containingShelf(p),
           let q = projectAlongFacingNormal(p, shelf: shelf) {
            return q
        }
        return nearestAislePoint(p) ?? p
    }

    /// a → b 的直线是否不穿货架、不穿墙（到达判定用：人在货架背面 / 隔壁房间时，离目标直线很近但隔着东西）。
    /// 每 10 cm 检查一次是否落在货架里（货架略往里收 2 cm，贴着货架边站不算穿过）；
    /// 有可走栅格时，两端都在可走格上才检查一路可走，带房间图时不经门换房间算穿墙。
    public func isLineClear(from a: Point2, to b: Point2) -> Bool {
        guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { return false }
        let d = a.distance(to: b)
        let n = max(Int(d / 10), 1)
        for k in 0...n {
            let t = Double(k) / Double(n)
            let p = Point2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
            for s in shelves where s.width > 0 && s.height > 0 {
                if RouteGeometry.rectContains(p, center: Point2(s.x, s.y), width: s.width, height: s.height,
                                              rotationDeg: s.rotation, margin: -2) { return false }
            }
        }
        if let w = grid?.walkable {
            if w.isWalkable(a) && w.isWalkable(b) && !w.isSegmentClear(from: a, to: b) { return false }
            if let g = w.rooms, g.crossesWithoutDoor(from: a, to: b) { return false }
        }
        return true
    }

    /// 包含该点的货架；多个重叠时取面积较小者（更“贴身”的那个），完全相同则取先出现的。
    private func containingShelf(_ p: Point2) -> ShelfRect? {
        var best: ShelfRect? = nil
        var bestArea = Double.greatestFiniteMagnitude
        for s in shelves where s.width > 0 && s.height > 0 {
            guard RouteGeometry.rectContains(p, center: Point2(s.x, s.y),
                                             width: s.width, height: s.height,
                                             rotationDeg: s.rotation,
                                             margin: shelfMargin) else { continue }
            let area = s.width * s.height
            if area < bestArea {
                bestArea = area
                best = s
            }
        }
        return best
    }

    /// 沿货架朝向法线投影。两侧都不命中通道时返回 nil。
    private func projectAlongFacingNormal(_ p: Point2, shelf s: ShelfRect) -> Point2? {
        let axes = RouteGeometry.rectAxes(rotationDeg: s.rotation)
        // 长边朝向通道 ⇒ 朝向法线 = 短轴方向。
        // width 沿 u、height 沿 v：width ≥ height 时长边沿 u，其法线为 ±v；反之为 ±u。
        let normal = s.width >= s.height ? axes.v : axes.u

        var bestT = Double.greatestFiniteMagnitude
        var bestPoint: Point2? = nil
        for sign in [1.0, -1.0] {
            let dir = normal * sign
            var hitT = Double.greatestFiniteMagnitude
            var hitIndex = -1
            for (i, c) in crosses.enumerated() {
                guard let t = RouteGeometry.rayHit(p, dir, c.a, c.b) else { continue }
                if t < hitT - 1e-9 {
                    hitT = t
                    hitIndex = i
                }
            }
            guard hitIndex >= 0, hitIndex < crosses.count else { continue }
            if hitT < bestT - 1e-9 {
                bestT = hitT
                let c = crosses[hitIndex]
                bestPoint = RouteGeometry.project(p, onto: c.a, c.b).point
            }
        }
        return bestPoint
    }

    /// 垂距最近的通道点。
    private func nearestAislePoint(_ p: Point2) -> Point2? {
        var bestD = Double.greatestFiniteMagnitude
        var best: Point2? = nil
        for c in crosses {
            let pr = RouteGeometry.project(p, onto: c.a, c.b)
            if pr.distance < bestD - 1e-9 {
                bestD = pr.distance
                best = pr.point
            }
        }
        return best
    }

    // MARK: - 规划

    /// 规划一条从 start 出发、依次经过所有目标的路线。
    ///
    /// 目标会先去重（按 junctionTolerance 量化）并截断到 maxTargets；
    /// 不可达的目标进入 Route.unreachableTargets，其余目标继续规划。
    /// 没有任何通道时返回 nil；没有有效目标时返回只含起点的单点路线。
    public func plan(from start: Point2, targets: [Point2]) -> Route? {
        let r = planOnGraph(from: start, targets: targets)
        // 兜底：只有一个目标，通道图给不出路线（没有通道 / 起终点不连通）时走栅格
        guard grid != nil, targets.count == 1 else { return r }
        if let r, !r.targetPoints.isEmpty { return r }
        return planOnGrid(from: start, to: targets[0]) ?? r
    }

    /// 栅格 A* 路线（兜底）。起终点不在可走格上时先吸附。
    func planOnGrid(from start: Point2, to target: Point2) -> Route? {
        guard let grid, let pts = grid.path(from: start, to: target), !pts.isEmpty else { return nil }
        var raw: [(point: Point2, isTarget: Bool)] = pts.map { (point: $0, isTarget: false) }
        raw[raw.count - 1].isTarget = true
        return makeRoute(from: raw)
    }

    private func planOnGraph(from start: Point2, targets: [Point2]) -> Route? {
        guard start.x.isFinite, start.y.isFinite else { return nil }
        guard !crosses.isEmpty else { return nil }

        // 1) 目标去重 + 数量上限
        let cap = max(config.maxTargets, 0)
        var seen = Set<RouteCellKey>()
        var wanted: [Point2] = []
        for t in targets {
            guard wanted.count < cap else { break }
            guard t.x.isFinite, t.y.isFinite else { continue }
            let key = RoutePlanner.quantKey(t, step: max(config.junctionToleranceCm, 0.5))
            if seen.contains(key) { continue }
            seen.insert(key)
            wanted.append(t)
        }

        var graph = baseGraph
        let snappedStart = nearestAislePoint(start) ?? start
        guard let startNode = graph.insertPoint(snappedStart, maxDistance: .greatestFiniteMagnitude) else {
            return nil
        }
        if wanted.isEmpty {
            return makeRoute(from: [(point: graph.nodes[startNode], isTarget: false)])
        }

        // 2) 目标吸附并插入图
        var unreachable: [Point2] = []
        var targetNodes: [Int] = []
        var originalOf: [Int: Point2] = [:]
        var usedNodes = Set<Int>()
        for t in wanted {
            let snapped = snapToAisle(t)
            guard let n = graph.insertPoint(snapped, maxDistance: .greatestFiniteMagnitude) else {
                unreachable.append(t)
                continue
            }
            if usedNodes.contains(n) { continue }      // 多个目标吸附到同一个通道点
            usedNodes.insert(n)
            targetNodes.append(n)
            originalOf[n] = t
        }
        if targetNodes.isEmpty {
            var r = makeRoute(from: [(point: graph.nodes[startNode], isTarget: false)])
            r.unreachableTargets = unreachable
            return r
        }

        // 3) 两两最短距离（每个关键点一次 Dijkstra）；顺便判可达性
        let keyNodes = [startNode] + targetNodes
        let count = keyNodes.count
        var dist = [[Double]](repeating: [Double](repeating: .infinity, count: count), count: count)
        for (i, n) in keyNodes.enumerated() {
            let d = graph.dijkstra(from: n)
            for (j, m) in keyNodes.enumerated() {
                dist[i][j] = (m >= 0 && m < d.count) ? d[m] : .infinity
            }
        }

        var candidates: [Int] = []
        for j in 1..<count {
            if dist[0][j].isFinite {
                candidates.append(j)
            } else if let p = originalOf[keyNodes[j]] {
                unreachable.append(p)
            }
        }

        // 4) 最近邻排序（贪心 TSP 启发式：每次去“当前点图上最近的未访问目标”）
        var order: [Int] = []
        var remaining = candidates
        var cur = 0
        while !remaining.isEmpty {
            var bestK = -1
            var bestD = Double.infinity
            for (k, j) in remaining.enumerated() where dist[cur][j].isFinite {
                if dist[cur][j] < bestD - 1e-9 {   // 严格小于 ⇒ 并列取下标更小者，结果确定
                    bestD = dist[cur][j]
                    bestK = k
                }
            }
            if bestK < 0 { break }
            cur = remaining[bestK]
            order.append(cur)
            remaining.remove(at: bestK)
        }
        for j in remaining {
            if let p = originalOf[keyNodes[j]] { unreachable.append(p) }
        }

        // 5) 2-opt 改进（开放路径，起点固定；距离矩阵对称，反转区间合法）
        var seq: [Int] = [0] + order
        if seq.count >= 4 {
            var pass = 0
            var improved = true
            while improved && pass < 50 {       // 迭代上限，保证终止
                improved = false
                pass += 1
                var i = 1
                while i < seq.count - 1 {
                    var j = i + 1
                    while j < seq.count {
                        let tail = j + 1 < seq.count
                        let before = dist[seq[i - 1]][seq[i]] + (tail ? dist[seq[j]][seq[j + 1]] : 0)
                        let after = dist[seq[i - 1]][seq[j]] + (tail ? dist[seq[i]][seq[j + 1]] : 0)
                        if before.isFinite && after.isFinite && after < before - 1e-6 {
                            seq[i...j].reverse()
                            improved = true
                        }
                        j += 1
                    }
                    i += 1
                }
            }
        }

        // 6) 逐段 A* 并拼接
        var pathPoints: [(point: Point2, isTarget: Bool)] = [(point: graph.nodes[startNode], isTarget: false)]
        var current = keyNodes[seq[0]]
        if seq.count > 1 {
            for k in 1..<seq.count {
                let goal = keyNodes[seq[k]]
                if goal == current {
                    if !pathPoints.isEmpty { pathPoints[pathPoints.count - 1].isTarget = true }
                    continue
                }
                guard let leg = graph.aStar(from: current, to: goal,
                                            turnPenalty: config.turnPenaltyCm,
                                            turnAngleDeg: config.turnPenaltyAngleDeg),
                      leg.path.count >= 2 else {
                    if let p = originalOf[goal] { unreachable.append(p) }
                    continue
                }
                for idx in leg.path.dropFirst() where idx >= 0 && idx < graph.nodes.count {
                    pathPoints.append((point: graph.nodes[idx], isTarget: false))
                }
                if !pathPoints.isEmpty { pathPoints[pathPoints.count - 1].isTarget = true }
                current = goal
            }
        }

        var route = makeRoute(from: pathPoints)
        route.unreachableTargets = unreachable
        return route
    }

    /// 带稳定性（迟滞）的更新。
    ///
    /// 策略，按顺序判断：
    /// 1. `lastRoute` 为 nil 或点数 < 2 → 直接重规划。**目标集合变化时调用方应传 nil。**
    /// 2. 保护性检查：旧路线上仍存在的目标若已不在新目标集合里 → 重规划。
    /// 3. 把位置投影到旧路线；横向偏离 > offRouteDistanceCm（脱线）→ 重规划。
    /// 4. 否则**裁剪**旧路线：丢掉已走过的部分，新路线起点 = 投影垂足。
    /// 5. 仅当“以剩余目标重新规划的结果”比旧方案（横向偏离 + 裁剪后长度）短
    ///    replanLengthDeltaCm 以上时才替换。
    ///
    /// 这样每秒调用也不会抖动：正常前进时只会不断裁剪同一条折线。
    /// 沿路线小幅后退时投影会截断到路线起点，仍然沿用旧路线；
    /// 后退幅度大到超过 offRouteDistanceCm 时按第 3 步当作脱线重规划。
    public func update(location: Point2, targets: [Point2], lastRoute: Route?) -> Route? {
        guard location.x.isFinite, location.y.isFinite else { return lastRoute }
        guard let last = lastRoute, last.nodes.count >= 2 else {
            return plan(from: location, targets: targets)
        }

        // 2) 目标集合是否仍然覆盖旧路线上的目标
        let snappedTargets = targets.map { snapToAisle($0) }
        let tol = mergeTolerance
        for n in last.nodes where n.isTarget {
            let stillWanted = snappedTargets.contains { $0.distance(to: n.point) <= tol }
                // 栅格兜底的路线终点是吸附到可走格的，不是吸附到通道的
                || (grid != nil && targets.contains { $0.distance(to: n.point) <= (grid?.snapRadiusCm ?? 0) })
            if !stillWanted {
                return plan(from: location, targets: targets) ?? last
            }
        }

        // 3) 脱线
        let pr = RouteGeometry.project(location, onRoute: last)
        if pr.distance > config.offRouteDistanceCm {
            return plan(from: location, targets: targets) ?? last
        }

        // 4) 裁剪
        let trimmed = trim(last, at: pr)
        guard trimmed.nodes.count >= 2 else {
            return plan(from: location, targets: targets) ?? trimmed
        }

        // 5) 只在明显更优时替换。
        //    比较时把“先走回路线”的横向距离算进旧方案，两者才可比。
        let trimmedCost = pr.distance + trimmed.length
        let remainingTargets = trimmed.nodes.filter { $0.isTarget }.map { $0.point }
        if !remainingTargets.isEmpty,
           let fresh = plan(from: location, targets: remainingTargets),
           fresh.nodes.count >= 2,
           fresh.length + config.replanLengthDeltaCm < trimmedCost {
            var out = fresh
            out.unreachableTargets = RoutePlanner.merge(fresh.unreachableTargets,
                                                       last.unreachableTargets,
                                                       tolerance: tol)
            return out
        }
        return trimmed
    }

    /// 裁掉投影点之前的已走路段。
    private func trim(_ route: Route, at pr: RouteProjection) -> Route {
        guard route.nodes.count >= 2 else { return route }
        var pts: [(point: Point2, isTarget: Bool)] = [(point: pr.point, isTarget: false)]
        let from = min(max(pr.segmentIndex + 1, 0), route.nodes.count - 1)
        for k in from..<route.nodes.count {
            pts.append((point: route.nodes[k].point, isTarget: route.nodes[k].isTarget))
        }
        var r = makeRoute(from: pts)
        r.unreachableTargets = route.unreachableTargets
        return r
    }

    // MARK: - 导航播报

    /// 由当前位置生成播报信息。
    ///
    /// 位置投影到折线（最近线段，距离并列取下标更小的），由此得到里程、横向偏离、
    /// 剩余距离、到下一转弯 / 下一目标的距离；转弯在 hintWindowCm 以内才播报，
    /// 否则 direction = .straight。
    public func hint(for location: Point2, on route: Route) -> NavHint {
        guard route.nodes.count >= 2 else {
            let d = route.nodes.first.map { location.distance(to: $0.point) } ?? 0
            return NavHint(route: route,
                           direction: .straight,
                           alongDistance: 0,
                           distanceToRoute: d,
                           remainingDistance: 0,
                           distanceToNextTurn: nil,
                           distanceToNextTarget: nil,
                           isOffRoute: d > config.offRouteDistanceCm)
        }

        let pr = RouteGeometry.project(location, onRoute: route)
        let remaining = max(route.length - pr.chainage, 0)

        var nextTurn: RouteTurn? = nil
        for t in route.turns where t.chainage > pr.chainage + 1e-6 {
            nextTurn = t
            break
        }
        let toTurn = nextTurn.map { max($0.chainage - pr.chainage, 0) }

        var toTarget: Double? = nil
        for n in route.nodes where n.isTarget && n.distanceFromStart >= pr.chainage - 1e-6 {
            toTarget = max(n.distanceFromStart - pr.chainage, 0)
            break
        }

        var dir = TurnDirection.straight
        if let t = nextTurn, let d = toTurn, d <= config.hintWindowCm {
            dir = t.direction
        }

        return NavHint(route: route,
                       direction: dir,
                       alongDistance: pr.chainage,
                       distanceToRoute: pr.distance,
                       remainingDistance: remaining,
                       distanceToNextTurn: toTurn,
                       distanceToNextTarget: toTarget,
                       isOffRoute: pr.distance > config.offRouteDistanceCm)
    }

    // MARK: - 组装 / 化简

    /// 由点序列生成 Route：去重 → 共线化简 → 累计里程 → 转弯表。
    ///
    /// 共线化简是 Douglas–Peucker 的退化形式（逐点判断对前后连线的垂距），
    /// 容差 collinearToleranceCm，**目标点和首尾点永不删除**。
    func makeRoute(from raw: [(point: Point2, isTarget: Bool)]) -> Route {
        // 相邻重复点合并（目标标记取并）
        var pts: [(point: Point2, isTarget: Bool)] = []
        for p in raw {
            guard p.point.x.isFinite, p.point.y.isFinite else { continue }
            if let last = pts.last, last.point.distance(to: p.point) <= 1e-6 {
                if p.isTarget { pts[pts.count - 1].isTarget = true }
                continue
            }
            pts.append(p)
        }
        guard !pts.isEmpty else { return Route() }

        if pts.count > 2 {
            var out: [(point: Point2, isTarget: Bool)] = [pts[0]]
            var i = 1
            while i < pts.count - 1 {
                let prev = out[out.count - 1].point
                let cur = pts[i]
                let next = pts[i + 1].point
                if !cur.isTarget,
                   RouteGeometry.distance(cur.point, toSegment: prev, next) <= config.collinearToleranceCm {
                    i += 1
                    continue
                }
                out.append(cur)
                i += 1
            }
            out.append(pts[pts.count - 1])
            pts = out
        }

        var nodes: [RouteNode] = []
        var acc = 0.0
        for (i, p) in pts.enumerated() {
            if i > 0 { acc += pts[i - 1].point.distance(to: p.point) }
            nodes.append(RouteNode(point: p.point, isTarget: p.isTarget, distanceFromStart: acc))
        }

        var turns: [RouteTurn] = []
        if nodes.count >= 3 {
            for i in 1..<(nodes.count - 1) {
                let v1 = nodes[i].point - nodes[i - 1].point
                let v2 = nodes[i + 1].point - nodes[i].point
                let ang = RouteGeometry.signedTurnDeg(v1, v2)
                let dir = classify(ang)
                if dir == .straight { continue }
                turns.append(RouteTurn(nodeIndex: i,
                                       chainage: nodes[i].distanceFromStart,
                                       angleDeg: ang,
                                       direction: dir))
            }
        }
        return Route(nodes: nodes, length: acc, turns: turns, unreachableTargets: [])
    }

    /// 转角 → 转向。屏幕坐标下正角度 = 右转。
    private func classify(_ angleDeg: Double) -> TurnDirection {
        let a = abs(angleDeg)
        if a > config.uturnThresholdDeg { return .uturn }
        if a < config.turnThresholdDeg { return .straight }
        return angleDeg > 0 ? .right : .left
    }

    // MARK: - 杂项

    /// 坐标量化成整数键：Double 不能当作可靠的相等哈希键，所以按 step 量化后再比较。
    private static func quantKey(_ p: Point2, step: Double) -> RouteCellKey {
        let s = step.isFinite && step > 1e-6 ? step : 1e-6
        func q(_ v: Double) -> Int64 {
            guard v.isFinite else { return 0 }
            return Int64(min(max((v / s).rounded(), -1e15), 1e15))
        }
        return RouteCellKey(ix: q(p.x), iy: q(p.y))
    }

    private static func merge(_ a: [Point2], _ b: [Point2], tolerance: Double) -> [Point2] {
        var out = a
        for p in b where !out.contains(where: { $0.distance(to: p) <= tolerance }) {
            out.append(p)
        }
        return out
    }
}

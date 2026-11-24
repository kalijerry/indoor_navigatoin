import Foundation

/// 把任意位置吸附到一条已有路线上（给地图上的小人用）。
public enum RouteSnapper {
    /// 返回位置在路线折线上的垂足；横向偏离超过 maxDistance 时返回 nil。
    public static func snap(_ p: Point2, to route: Route, maxDistance: Double = 500) -> Point2? {
        guard !route.nodes.isEmpty else { return nil }
        guard p.x.isFinite, p.y.isFinite else { return nil }
        let pr = RouteGeometry.project(p, onRoute: route)
        return pr.distance <= maxDistance ? pr.point : nil
    }
}

/// 一次导航会话：持有目标列表与当前路线，位置每次更新时产出播报信息。
///
/// 目标列表只能通过 start 设置；此时强制全新规划（update 的 lastRoute 传 nil）。
/// 之后每次 onLocation 都走迟滞逻辑（见 RoutePlanner.update 的说明），
/// 正常前进时只会裁剪同一条折线，不会每秒换一条路。
public final class NavigationSession {

    private let planner: RoutePlanner

    public private(set) var targets: [Point2] = []
    public private(set) var route: Route? = nil
    /// 最近一次收到的位置
    public private(set) var lastLocation: Point2? = nil
    /// 连续脱线的定位更新次数
    public private(set) var offRouteCount = 0

    public init(planner: RoutePlanner) {
        self.planner = planner
    }

    /// 是否处于导航中（还有目标）。
    public var isActive: Bool { !targets.isEmpty }

    /// 开始导航。location 为 nil 时只记下目标，等第一个定位结果再规划。
    @discardableResult
    public func start(targets: [Point2], from location: Point2?) -> NavHint? {
        self.targets = targets
        self.route = nil
        self.lastLocation = location
        guard !targets.isEmpty, let loc = location else { return nil }
        guard let r = planner.update(location: loc, targets: targets, lastRoute: nil) else { return nil }
        self.route = r
        return planner.hint(for: loc, on: r)
    }

    /// 试算一条路线但不改变会话状态（用于“预览”）。
    public func preview(targets: [Point2], from location: Point2) -> Route? {
        planner.plan(from: location, targets: targets)
    }

    /// 收到新定位。返回最新播报；未在导航中返回 nil。
    @discardableResult
    public func onLocation(_ p: Point2) -> NavHint? {
        guard isActive else { return nil }
        guard p.x.isFinite, p.y.isFinite else { return nil }
        lastLocation = p
        if let cur = route, cur.nodes.count >= 2 {
            if RouteGeometry.project(p, onRoute: cur).distance > planner.config.offRouteDistanceCm {
                offRouteCount += 1
                // 还没连续脱线够次数：先沿用旧路线（hint 里 isOffRoute 已置位）
                if offRouteCount < planner.config.offRouteConfirmUpdates { return planner.hint(for: p, on: cur) }
            } else {
                offRouteCount = 0
            }
        }
        offRouteCount = 0
        guard let r = planner.update(location: p, targets: targets, lastRoute: route) else { return nil }
        route = r
        return planner.hint(for: p, on: r)
    }

    /// 收到带质量的定位（NAV-004）。按 `FixQuality` 决定行为：
    /// - reliable：同 `onLocation`（正常逐段、脱线确认后重新规划）；
    /// - degraded：沿用当前路线出播报（含转向），但不累计脱线、不重新规划——跳点 / 不确定度偏大时别来回换路；
    /// - coarse：只在当前路线上算剩余距离，不出转向、不重新规划；
    /// - searching / lost：暂停，不出转向、不重新规划（还没有路线时也不规划）。
    /// 路线还没规划（start 时没有位置）且质量不是 reliable：不规划，返回 nil。
    @discardableResult
    public func onFix(_ fix: LocalizationFix) -> NavHint? {
        guard isActive else { return nil }
        let p = fix.position
        guard p.x.isFinite, p.y.isFinite else { return nil }
        if fix.quality == .reliable {
            guard var h = onLocation(p) else { return nil }
            h.quality = .reliable
            return h
        }
        guard let cur = route else { return nil }
        lastLocation = p
        var h = planner.hint(for: p, on: cur)
        h.quality = fix.quality
        if !fix.quality.allowsTurnInstructions { h.direction = .straight }
        // 不确定的位置不触发「偏离路线」：脱线计数也不往上加
        h.isOffRoute = false
        return h
    }

    /// 结束导航并清空状态。
    public func stop() {
        targets = []
        route = nil
        lastLocation = nil
        offRouteCount = 0
    }
}

import Foundation

/// 把 NavHint 变成一句中文导航提示。
public enum NavInstruction {

    public struct Shelf {
        /// 例如 "082-20"
        public var name: String
        public var center: Point2
        public init(name: String, center: Point2) { self.name = name; self.center = center }
    }

    /// 离终点多近算到达（cm）
    public static let arriveCm = 150.0

    /// 货架在沿最后一段路线走时的哪一侧（屏幕坐标，正转角 = 右）。正前方 / 正后方 / 贴着路线时 nil。
    public static func shelfSide(route: Route, shelfCenter c: Point2) -> TurnDirection? {
        guard route.nodes.count >= 2 else { return nil }
        let end = route.nodes[route.nodes.count - 1].point
        let from = route.nodes[route.nodes.count - 2].point
        let walk = end - from
        let toShelf = c - end
        guard walk.length > 1e-6, toShelf.length > 5 else { return nil }
        let a = RouteGeometry.signedTurnDeg(walk, toShelf)
        if abs(a) < 15 || abs(a) > 165 { return nil }
        return a > 0 ? .right : .left
    }

    /// 里程文字："12 m"；不足 1 m 写 "不到 1 m"。
    public static func meters(_ cm: Double) -> String {
        let m = cm / 100
        return m < 1 ? "不到 1 m" : "\(Int(m.rounded())) m"
    }

    /// 下一个转弯（相对现在的距离）。
    public static func nextTurn(_ h: NavHint) -> (direction: TurnDirection, distanceCm: Double)? {
        for t in h.route.turns where t.chainage > h.alongDistance + 1e-6 {
            return (t.direction, t.chainage - h.alongDistance)
        }
        return nil
    }

    public static func text(_ h: NavHint, shelf: Shelf? = nil) -> String {
        let remain = h.remainingDistance
        let side = shelf.flatMap { shelfSide(route: h.route, shelfCenter: $0.center) }
        let sideText = side == .left ? "左手边" : (side == .right ? "右手边" : "前方")
        let name = shelf.map { "货架 \($0.name)" } ?? "目标"
        // 定位质量不够（NAV-004）：不出转向、不说到了
        if h.quality.pausesNavigation { return "正在确认位置，请稍候" }
        if h.quality == .coarse { return "位置还不太准，先朝目标方向走，还有约 \(meters(remain))" }
        if h.isOffRoute { return "偏离了路线，正在重新规划" }
        if remain <= arriveCm && h.quality == .reliable {
            return shelf == nil ? "已到达目标" : "到了，\(name)在\(sideText)"
        }
        // 离终点太近的转弯不播，免得和到达提示重复
        if let t = nextTurn(h), remain - t.distanceCm > 100 {
            let dir: String
            switch t.direction {
            case .left: dir = "左转"
            case .right: dir = "右转"
            case .uturn: dir = "掉头"
            case .straight: dir = "直行"
            }
            let verb = t.distanceCm <= 300 ? dir : dir + "进入通道"
            return "前方 \(meters(t.distanceCm)) \(verb)，还有 \(meters(remain))"
        }
        if shelf != nil, remain <= 1500 {
            return "目标在\(sideText)\(name)，还有 \(meters(remain))"
        }
        return "直行 \(meters(remain))到达目标"
    }
}

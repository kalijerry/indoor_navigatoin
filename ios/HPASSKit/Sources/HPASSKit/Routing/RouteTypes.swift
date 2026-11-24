import Foundation

// 本文件只放公开数据类型。几何约定见 RouteGeometry.swift 顶部注释：
// 屏幕坐标系，+x 右、+y 下，单位 cm；带符号转角为正 = 右转。

/// 转向。
public enum TurnDirection: String {
    case straight
    case left
    case right
    case uturn
}

/// 路线上的一个折点。
public struct RouteNode: Hashable {
    /// 位置（cm）
    public var point: Point2
    /// 是否为导航目标（商品所在通道点）
    public var isTarget: Bool
    /// 自起点的累计里程（cm）
    public var distanceFromStart: Double

    public init(point: Point2, isTarget: Bool = false, distanceFromStart: Double = 0) {
        self.point = point
        self.isTarget = isTarget
        self.distanceFromStart = distanceFromStart
    }
}

/// 一次转向。只收录**非直行**的折点。
public struct RouteTurn {
    /// 对应 Route.nodes 的下标
    public var nodeIndex: Int
    /// 该折点的里程（cm）
    public var chainage: Double
    /// 带符号转角（度），正 = 右转
    public var angleDeg: Double
    public var direction: TurnDirection

    public init(nodeIndex: Int, chainage: Double, angleDeg: Double, direction: TurnDirection) {
        self.nodeIndex = nodeIndex
        self.chainage = chainage
        self.angleDeg = angleDeg
        self.direction = direction
    }
}

/// 一条完整路线（已做共线化简）。
public struct Route {
    public var nodes: [RouteNode]
    /// 折线总长（cm），不含转弯惩罚
    public var length: Double
    public var turns: [RouteTurn]
    /// 图上不可达、已被跳过的目标（原始坐标，未吸附）
    public var unreachableTargets: [Point2]

    public init(nodes: [RouteNode] = [], length: Double = 0,
                turns: [RouteTurn] = [], unreachableTargets: [Point2] = []) {
        self.nodes = nodes
        self.length = length
        self.turns = turns
        self.unreachableTargets = unreachableTargets
    }

    public var points: [Point2] { nodes.map { $0.point } }

    /// 按经过顺序排列的目标点。
    public var targetPoints: [Point2] { nodes.filter { $0.isTarget }.map { $0.point } }
}

/// 一次导航播报所需的全部信息。
public struct NavHint {
    public var route: Route
    /// 现在该做什么（窗口外一律 .straight）
    public var direction: TurnDirection
    /// 投影点的里程（cm）
    public var alongDistance: Double
    /// 横向偏离路线的距离（cm）
    public var distanceToRoute: Double
    /// 剩余里程（cm）
    public var remainingDistance: Double
    /// 到下一个转弯的距离（cm），后面没有转弯时为 nil
    public var distanceToNextTurn: Double?
    /// 到下一个目标的距离（cm），后面没有目标时为 nil
    public var distanceToNextTarget: Double?
    public var isOffRoute: Bool
    /// 产生这条播报的定位质量（`NavigationSession.onFix`；`onLocation` 当 reliable）。
    /// 不是 reliable / degraded 时 direction 一律 .straight，界面不该出转向。
    public var quality: FixQuality = .reliable

    public init(route: Route,
                direction: TurnDirection,
                alongDistance: Double,
                distanceToRoute: Double,
                remainingDistance: Double,
                distanceToNextTurn: Double?,
                distanceToNextTarget: Double?,
                isOffRoute: Bool) {
        self.route = route
        self.direction = direction
        self.alongDistance = alongDistance
        self.distanceToRoute = distanceToRoute
        self.remainingDistance = remainingDistance
        self.distanceToNextTurn = distanceToNextTurn
        self.distanceToNextTarget = distanceToNextTarget
        self.isOffRoute = isOffRoute
    }
}

/// 规划器参数。长度单位均为 cm，角度单位均为度。
public struct RoutePlannerConfig {
    /// |转角| 小于该值视为直行
    public var turnThresholdDeg: Double = 45
    /// |转角| 大于该值视为掉头
    public var uturnThresholdDeg: Double = 135
    /// 每个“算作转弯”的折点在搜索代价中追加的惩罚
    public var turnPenaltyCm: Double = 200
    /// 折点 |转角| 超过该值才算一次转弯（用于惩罚计数）
    public var turnPenaltyAngleDeg: Double = 25
    /// 单次规划的目标数上限
    public var maxTargets: Int = 50
    /// 距转弯多近才播报
    public var hintWindowCm: Double = 200
    /// 横向偏离超过该值视为脱线
    public var offRouteDistanceCm: Double = 500
    /// 连续多少次定位更新都脱线才重新规划（定位偶尔抖一下不要换路线）
    public var offRouteConfirmUpdates: Int = 1
    /// 新路线至少要比“裁剪后的旧路线”短这么多才替换
    public var replanLengthDeltaCm: Double = 500
    /// 节点合并 / 交点判定容差
    public var junctionToleranceCm: Double = 1.0
    /// 共线化简容差：中间点偏离前后连线不超过该值即删除（非严格相等）
    public var collinearToleranceCm: Double = 1.0

    public init() {}
}

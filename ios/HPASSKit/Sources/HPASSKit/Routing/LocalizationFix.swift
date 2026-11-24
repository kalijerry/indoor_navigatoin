import Foundation

// MARK: - 定位质量（NAV-004）

/// 一次定位结果的质量。导航按它决定怎么用这个位置（见 `NavigationSession.onFix`）：
///
/// | 质量 | 导航行为 |
/// |---|---|
/// | searching | 还没定到：不出转向、不重新规划、不判到达 |
/// | coarse    | 只知道大概（只认房间 / 不确定度很大）：只报大致方向和剩余距离，不出转向、不重新规划、不判到达 |
/// | reliable  | 正常逐段导航 |
/// | degraded  | 刚跳点 / 不确定度偏大：沿用当前路线、照常出转向，但不因为「脱线」重新规划，不判到达 |
/// | lost      | 定到过又丢了：暂停（同 searching），等重新定位 |
public enum FixQuality: String, CaseIterable {
    case searching
    case coarse
    case reliable
    case degraded
    case lost

    /// 能不能出逐段转向
    public var allowsTurnInstructions: Bool { self == .reliable || self == .degraded }
    /// 能不能因为脱线重新规划
    public var allowsReplan: Bool { self == .reliable }
    /// 导航暂停（不出任何指令，只提示正在定位）
    public var pausesNavigation: Bool { self == .searching || self == .lost }
}

/// 位置的来源
public enum PositionSource: String {
    case magnetic       // 地磁粒子滤波
    case pdr            // 纯计步推算（没有磁场图）
    case visual         // 视觉重定位
    case fingerprint    // 蓝牙 / Wi-Fi 指纹
    case manual         // 用户手动点的
    case unknown
}

/// 定位模块交给导航的统一结果：位置 + 航向 + 不确定度 + 质量。
public struct LocalizationFix {
    public var position: Point2
    public var timestampMs: Int64
    /// 地图系航向（`FusionTypes` 约定：0 = +y，dx = L·sinθ、dy = L·cosθ）。航向不可信时为 nil
    public var headingRad: Double?
    public var headingUncertaintyRad: Double?
    /// 1σ 位置不确定度（cm）
    public var uncertaintyCm: Double
    /// 0...1
    public var confidence: Double
    public var floorId: String?
    public var roomId: String?
    public var quality: FixQuality
    public var source: PositionSource

    public init(position: Point2, timestampMs: Int64, headingRad: Double? = nil, headingUncertaintyRad: Double? = nil,
                uncertaintyCm: Double, confidence: Double = 1, floorId: String? = nil, roomId: String? = nil,
                quality: FixQuality, source: PositionSource = .unknown) {
        self.position = position
        self.timestampMs = timestampMs
        self.headingRad = headingRad
        self.headingUncertaintyRad = headingUncertaintyRad
        self.uncertaintyCm = uncertaintyCm
        self.confidence = confidence
        self.floorId = floorId
        self.roomId = roomId
        self.quality = quality
        self.source = source
    }
}

/// 由定位器的输出判定 `FixQuality`。有状态：要知道之前是否定到过（区分 searching / lost）和上一个位置（跳点）。
public struct FixQualityClassifier {
    public struct Config {
        /// 不确定度不超过它才算 reliable（cm）
        public var reliableMaxUncertaintyCm: Double = 500
        /// 不确定度超过它只算 coarse（cm）
        public var coarseMinUncertaintyCm: Double = 1000
        /// 两次定位间隔不超过 `jumpWindowMs` 却跳了这么远：这一次算 degraded（cm）
        public var jumpCm: Double = 400
        public var jumpWindowMs: Int64 = 2000
        public init() {}
    }

    public var config: Config
    public private(set) var hadReliable = false
    private var last: (p: Point2, t: Int64)?

    public init(config: Config = .init()) { self.config = config }

    public mutating func reset() {
        hadReliable = false
        last = nil
    }

    /// - converged: 定位器认为已经定到（冷启动收敛 / 已知起点跟踪）。false 时不出位置级的导航。
    /// - roomOnly: 只认得出房间、点位不可信
    public mutating func classify(position p: Point2, timestampMs t: Int64, uncertaintyCm u: Double,
                                  converged: Bool, roomOnly: Bool = false) -> FixQuality {
        defer { last = (p, t) }
        guard p.x.isFinite, p.y.isFinite, u.isFinite else { return hadReliable ? .lost : .searching }
        guard converged else { return hadReliable ? .lost : .searching }
        if roomOnly || u > config.coarseMinUncertaintyCm { return .coarse }
        if let l = last, t - l.t <= config.jumpWindowMs, t >= l.t, l.p.distance(to: p) > config.jumpCm {
            return .degraded
        }
        if u > config.reliableMaxUncertaintyCm { return .degraded }
        hadReliable = true
        return .reliable
    }
}

extension LocalizationFix {
    /// 地磁定位器的估计 → 导航用的定位结果。`pdrHeadingRad` 是融合（计步）航向；粒子的后验航向偏差
    /// 可信时用修正后的航向（见 `MagneticEstimate.correctedHeading`），否则 headingRad = nil。
    public static func from(_ e: MagneticEstimate, timestampMs: Int64, pdrHeadingRad: Double?,
                            classifier: inout FixQualityClassifier, source: PositionSource = .magnetic) -> LocalizationFix {
        let q = classifier.classify(position: e.position, timestampMs: timestampMs, uncertaintyCm: e.uncertaintyCm,
                                    converged: e.converged, roomOnly: e.roomOnly)
        let h = pdrHeadingRad.flatMap { e.correctedHeading(pdrHeadingRad: $0) }
        return LocalizationFix(position: e.position, timestampMs: timestampMs, headingRad: h,
                               headingUncertaintyRad: h == nil ? nil : e.headingBiasSigmaRad,
                               uncertaintyCm: e.uncertaintyCm, confidence: e.confidence, roomId: e.roomId,
                               quality: q, source: source)
    }
}

// MARK: - 到达判定（NAV-002）

/// 到达判定。原来只看「投影到路线上的剩余里程 ≤ 120 cm」一次：人在货架另一侧 / 隔壁房间，投影照样落在终点附近；
/// 定位跳一下、不确定度 5 m 时也会宣布到达，导航随即停掉。
///
/// 现在要**同时**满足，并且连续 `requiredConsecutive` 次、持续 `minDwellMs` 以上：
/// 1. 路线上还有目标点（不可达目标 / 退化的单点路线没有目标，永远不到达）；
/// 2. 定位质量 reliable，不确定度 ≤ `maxUncertaintyCm`；
/// 3. 到目标点的**直线距离** ≤ `arriveCm`，横向偏离路线 ≤ `maxLateralCm`，沿路线剩余 ≤ `maxRemainingCm`；
/// 4. 到目标点的直线不穿货架、不穿墙（`lineClear`，通常是 `RoutePlanner.isLineClear`）——货架背面不算到；
/// 5. 和上一次比没有瞬间跳点（> `maxJumpCm` 清零重数）。
public struct ArrivalPolicy {
    public struct Config {
        public var arriveCm: Double = NavInstruction.arriveCm
        public var maxLateralCm: Double = 150
        public var maxRemainingCm: Double = 250
        public var maxUncertaintyCm: Double = 350
        public var requiredConsecutive: Int = 3
        public var minDwellMs: Int64 = 800
        public var maxJumpCm: Double = 300
        public init() {}
    }

    /// 为什么还没算到达（诊断 / 测试用）
    public enum Reason: Equatable {
        case arrived
        case noTarget
        case quality(FixQuality)
        case uncertain
        case tooFar
        case offRoute
        case blocked
        case jump
        case confirming
    }

    public var config: Config
    /// a → b 直线是否通畅（不穿货架 / 墙）；nil = 不查
    public var lineClear: ((Point2, Point2) -> Bool)?
    private var streak = 0
    private var streakStartMs: Int64 = 0
    private var last: Point2?

    public init(config: Config = .init(), lineClear: ((Point2, Point2) -> Bool)? = nil) {
        self.config = config
        self.lineClear = lineClear
    }

    public mutating func reset() {
        streak = 0
        streakStartMs = 0
        last = nil
    }

    /// 送一次定位 + 当前播报，返回判定。`.arrived` 才算到。
    public mutating func evaluate(fix: LocalizationFix, hint: NavHint) -> Reason {
        let r = check(fix: fix, hint: hint)
        last = fix.position
        guard r == nil else { streak = 0; return r! }
        if streak == 0 { streakStartMs = fix.timestampMs }
        streak += 1
        if streak >= config.requiredConsecutive && fix.timestampMs - streakStartMs >= config.minDwellMs { return .arrived }
        return .confirming
    }

    private func check(fix: LocalizationFix, hint: NavHint) -> Reason? {
        guard let goal = hint.route.nodes.last(where: { $0.isTarget })?.point else { return .noTarget }
        guard fix.quality == .reliable else { return .quality(fix.quality) }
        guard fix.uncertaintyCm.isFinite, fix.uncertaintyCm <= config.maxUncertaintyCm else { return .uncertain }
        if let l = last, l.distance(to: fix.position) > config.maxJumpCm { return .jump }
        let p = fix.position
        guard p.distance(to: goal) <= config.arriveCm, hint.remainingDistance <= config.maxRemainingCm else { return .tooFar }
        guard hint.distanceToRoute <= config.maxLateralCm else { return .offRoute }
        if let lc = lineClear, !lc(p, goal) { return .blocked }
        return nil
    }
}

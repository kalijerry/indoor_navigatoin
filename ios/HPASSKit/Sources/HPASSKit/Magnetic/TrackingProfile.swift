import Foundation

/// 运动（里程计）来源：决定跟踪时粒子要撒多开、地磁该占多少分量。
public enum OdometrySource: String, CaseIterable {
    /// 视觉里程计（ARKit 等）：位移和航向都很准，一路漂移不到 1%
    case vio
    /// 计步（PDR）：步长、航向误差都大得多
    case pdr
}

/// 「已知起点」跟踪用的配置档。实时定位页（MagneticEngine.makeLocalizer，有起点时）和评估的已知起点分支
/// （SessionEvaluator.evaluate，oracleStart）用同一份，基准量到的就是产品的行为。
///
/// 跟踪和冷启动是两回事：冷启动要在全图找，跟踪时位置本来就知道，地磁只该做小修正。所以跟踪档：
/// - 定到之后不在全图注入随机粒子（`randomInjectionConverged = 0`），远处长得像的地方没有机会「接管」。
///   代价：只用地磁时，起点给错 / 锁到了长得像的地方，地磁自己纠不回来，要靠外部（蓝牙 declareLost、
///   区域观测、用户重新指起点）。公开数据集的移植上量过：留千分之一的全图注入，计步 P90 5.9 → 9.5 m，
///   视觉里程计 4.8 → 5.7 m；而起点错 15 m 的合成走廊里走 300 m 也只有 2/8 次找回，不值；
/// - 原来的簇快没了也不立刻切到远处的簇（`keepClusterRequiresNear`），远跳一律要连续确认 15 次，确认期间不判丢；
/// - 估计点落在没采过磁场的格子上不算「丢了」（`zeroConfidenceOffMap = false`）：那里本来就该纯推算；
/// - 自己丢了（置信度持续低）先在最后一次可靠位置附近找回（`localRecovery`）：半径随丢了之后走过的路变大，
///   新粒子只撒在圆里，不罚没数据的粒子；走了 `localRecoveryGlobalAfterCm` 还没找回就改回全图找。
///   外部判定定错（区域观测 declareLost）直接全图找，不围着被否定的位置找；
/// - 运动来源中途变了（视觉里程计没对齐 / 跟丢时计步顶上），调用方用 `MagneticLocalizer.setOdometry` 换参数；
/// - 定到之后地磁只占一部分（`convergedMagWeight`），并按粒子落在有数据格子上的权重比例再打折
///   （`coverageGatedMagWeight`）：一段没采过的路上完全靠推算；
/// - 地磁似然按实测残差标定（`TrackingProfile.observationSigmaFloorUT` / `magneticCorrelationCm`），
///   整体偏移不用单次读数估，攒够一段再取中位数（`offsetWarmupUpdates`）；
/// - 蓝牙只做软约束（`bleSoftTracking`，底图学过本场地标签范围时；人工打点的标签表底图照旧硬约束）：
///   有上限的软范围约束，不挡收敛；持续对不上先局部找回，找回后蓝牙还是不认再升级成全图找。
///
/// 数值在公开数据集的 Python 移植上挑的（见 PR 描述），不按单条测试轨迹调。
public enum TrackingProfile {
    /// 已知起点时粒子撒开的 1σ（cm）。
    public static let startSpreadCm: Double = 50
    /// 自己丢了之后走了这么远（cm）还没在附近找回，就改回全图找
    public static let localRecoveryGlobalAfterCm: Double = 6000

    // 地磁似然标定。数值来自公开数据集的实测残差（hpass-eval --residuals + tools/bench/mag_residuals.py：会话每 50 cm 的读数
    // 和「全局解偏移的融合图」在真值位置的值比，扣掉每条会话的整体偏移），不是按定位结果调的。
    // 用的是留出的数据：建图会话两折交叉（一半建图、另一半当测试，44 + 48 条会话），不用 Lab 打分的测试会话：
    // - 残差按 Student-t（ν = 4）拟合的尺度 3.7～4.5 µT，而地图格子自己的标准差中位才 1 µT；
    //   原来的 1.5 µT 下限让 21～30% 的读数落在 3σ 以外（t 分布应该是 5.5%），4 µT 时 5～8%；
    // - 残差沿路的积分相关长度约 11～15 次更新（5.5～7.5 m）：地图误差、偏移误差都是成片的，每 50 cm 一次的更新远不是独立的；
    // - 用开头一次读数估整体偏移，误差中位 3～4 µT、P90 8～14 µT；攒 20 次（10 m）取中位数，降到中位 1.5～1.9 µT。
    // （Lab 的测试会话上量的是 t 尺度 5 µT、相关长度 6～8.5 m，结论一样；Lab 结果对下限 4 / 5 µT、相关长度 3～10 m 都不敏感。）
    /// 观测噪声下限（µT），和地图格子的标准差合成
    public static let observationSigmaFloorUT: Double = 4
    /// 地磁残差的相关长度（cm）：走这么远才算一次独立的地磁观测
    public static let magneticCorrelationCm: Double = 600
    /// 定到之后攒这么多次更新的残差再估整体偏移（中位数），之后用最近 `offsetMedianWindow` 次的中位数慢慢跟
    public static let offsetWarmupUpdates = 20
    public static let offsetMedianWindow = 60
    /// 跟踪时的「丢了」置信度门限（全局默认 0.2）。置信度 = 簇质量 × (1 − 不确定度 / confidenceScaleCm)；
    /// 地磁按相关长度变软之后粒子云如实地宽了，0.2 会在位置其实没错的路段频繁判丢（Lab：误差中位 0.8 m 时 16% 的时间
    /// 不报位置，App 里就是位置冻住）。0.1 时公开基准覆盖 94～100%，错定 ≤ 1%（计步）。
    public static let lostConfidence: Double = 0.1
    /// 用过外部位置先验（蓝牙 / 区域观测）之后的「丢了」门限：照旧 0.2。有蓝牙时判丢 → 局部找回 / 蓝牙拉回很快，
    /// 而门限放宽到 0.1 会让锁错的位置多显示很久（Lab public/pdr/track-mag-radio：0.1 时错定 8.9%、P90 4.1 m，
    /// 0.2 时 4.4%、3.0 m，覆盖 99% → 92%；0.12 / 0.14 / 0.16 在中间，单调）。
    public static let lostConfidenceWithExternalPrior: Double = 0.2

    /// 分携带模式的运动 / 观测参数（航向偏差先验、随机游走、步长比例 σ、K、步内航向噪声、特征权重、噪声下限）。
    /// 现在是 `CarryMotionTable.placeholder`：**每个数值都待自采 iPhone 双机数据标定**，RIDI / NILoc 派生的数字已作废。
    /// 只在 `MagneticConfig.carryModeAdaptive` 打开时起作用（`MagneticLocalizer.setCarryMode` / `apply`）。
    public static func motion(for mode: CarryMode) -> CarryMotionParameters { CarryMotionTable.placeholder[mode] }
}

public extension MagneticConfig {
    /// 按携带模式改地磁观测和运动随机游走参数（来自 `carryTable`）。只在 `carryModeAdaptive` 打开、模式是携带姿态、
    /// 运动来源不是视觉里程计（视觉里程计的位移和航向与携带方式无关）时才改；返回是否改了。
    /// 不动 `initialHeadingBiasSigmaDeg`：航向偏差的重撒由 `MagneticLocalizer.carryModeChanged` 按事件来。
    @discardableResult
    mutating func applyCarryMode(_ mode: CarryMode) -> Bool {
        guard carryModeAdaptive, mode.isCarryPosture, trackingOdometry != .vio else { return false }
        let p = carryTable[mode]
        headingBiasWalkDegPerM = p.headingBiasWalkDegPerM
        initialScaleSigma = p.initialScaleSigma
        featureWeights = p.featureWeights
        observationSigmaFloorUT = p.observationSigmaFloorUT
        return true
    }
}

public extension MagneticConfig {
    /// 已知起点的跟踪配置档。
    /// - Parameters:
    ///   - odometry: 运动来源。
    ///   - headingKnown: 起始朝向是否知道（用户在屏幕上指过 / 面朝下一个点位）。不知道时调用方 reset 时要传 headingUnknown。
    static func tracking(odometry: OdometrySource, headingKnown: Bool = true) -> MagneticConfig {
        var c = MagneticConfig()
        c.trackingHeadingKnown = headingKnown
        // 混合偏移：没定到按起伏找，定到后估出整体偏移再按绝对值比（每次读数的整体水平会差 10～16 µT）
        c.hybridOffset = true
        // 以垂直分量 Bz 为主：人掉头时手机偏置的估计误差会让 Bh 和 |B| 的误差反过来，Bz 不受影响
        c.featureWeights = (0.5, 1.0, 0.25)
        // 远跳要连续确认 15 次（约 7.5 m）；收敛后粒子噪声小，不会沿「长得像」的通道滑走
        c.jumpConfirmUpdates = 15
        c.convergedPositionNoiseFraction = 0.03
        c.trackingOdometry = odometry
        c.setOdometryParameters(odometry)
        // 跟踪策略
        c.randomInjectionConverged = 0
        c.keepClusterRequiresNear = true
        c.zeroConfidenceOffMap = false
        c.localRecovery = true
        c.localRecoveryGlobalAfterCm = TrackingProfile.localRecoveryGlobalAfterCm
        c.coverageGatedMagWeight = true
        // 似然标定（只在跟踪档里；冷启动和全局默认值不变）
        c.observationSigmaFloorUT = TrackingProfile.observationSigmaFloorUT
        c.magneticCorrelationCm = TrackingProfile.magneticCorrelationCm
        c.offsetWarmupUpdates = TrackingProfile.offsetWarmupUpdates
        c.offsetMedianWindow = TrackingProfile.offsetMedianWindow
        c.lostConfidence = TrackingProfile.lostConfidence
        c.lostConfidenceWithExternalPrior = TrackingProfile.lostConfidenceWithExternalPrior
        c.bleSoftTracking = true
        return c
    }

    /// 跟踪档换运动来源（只改和运动来源有关的那几项）。不是跟踪档时什么都不做。
    mutating func applyTrackingOdometry(_ odometry: OdometrySource) {
        guard trackingOdometry != nil else { return }
        trackingOdometry = odometry
        setOdometryParameters(odometry)
    }

    private mutating func setOdometryParameters(_ odometry: OdometrySource) {
        let d = MagneticConfig()
        switch odometry {
        case .vio:
            // 视觉里程计的位移和航向都比计步准得多，粒子不用撒那么开
            initialHeadingBiasSigmaDeg = 5
            headingBiasWalkDegPerM = 1
            positionNoiseFraction = 0.04
            initialScaleSigma = 0.03
            scaleWalkPerM = 0.003
            // 推算本身已经很准（公开数据集：中位 0.3 m），地磁只做很小的修正
            convergedMagWeight = pinnedConvergedMagWeight ?? 0.1
        case .pdr:
            // 起始朝向来自「面朝下一个点位」/ 在屏幕上指，比视觉里程计粗：8～10°
            initialHeadingBiasSigmaDeg = trackingHeadingKnown ? 10 : 30
            headingBiasWalkDegPerM = d.headingBiasWalkDegPerM
            positionNoiseFraction = d.positionNoiseFraction
            // 步长比例先验照旧 1 + N(0, 0.06)。实测（hpass-eval --odo-out 的纯推算和真值比，调参开发集）每条会话的步长比例
            // 跨设备在 0.83（ILC 安卓）～ 1.1～1.4（iPhone）之间，但把先验放宽（对数正态 σ 0.1～0.2、或 10～35% 的宽尾）
            // 是有赢有输的交换：ILC 真实计步错定 30% → 15%，自采商场留一法误差中位 2.8 m → 3.3～5.6 m（10～20 个种子，越宽越差，
            // 加粒子不改善），公开计步（public/pdr）覆盖掉 5～9 个点。试过的设置没有一个两边都不输，所以不改。
            // 同样试过、更差的：转弯时按 0.2 × 转角额外撒航向、簇半径 4 m、朝向未知时等航向收拢再报。
            initialScaleSigma = d.initialScaleSigma
            scaleWalkPerM = d.scaleWalkPerM
            convergedMagWeight = pinnedConvergedMagWeight ?? 0.2
        }
    }
}

public extension MagneticConfig {
    /// 实时定位页「未知起点」冷启动的配置档（MagneticEngine.makeLocalizer，start == nil）。评估的冷启动
    /// （ShadowLocalizer）用视觉里程计这一套为底，所以 Lab 冷启动场景量到的就是 App 的配置。
    ///
    /// 产品决定：只靠地磁冷启动不报位置（`magOnlyColdStartReports = false`）。公开商场楼层上只靠地磁冷启动的错定
    /// 91～100%（Lab public/pdr/cold-mag-search），宁可不报，等外部位置先验（蓝牙粗定位 / 标签范围 / 贴近标签 /
    /// 货架标识牌，都会标 `MagneticLocalizer.externalPriorApplied`）或用户在图上指起点。
    ///
    /// 例外：小场地（地图外框面积 ≤ `magOnlyColdStartMaxAreaM2`，办公室 / 房间）只靠地磁也报位置。
    /// 办公室没有蓝牙标签、也没有货架标识牌，按上面的规则就永远定不到；商场的错定来自几千平米里
    /// 十几米的磁场序列能对上很多处，几百平米的房间里长得像的地方少得多。收敛门、远跳确认照旧。
    /// 小场地报只靠地磁的定位，所以搜索也加强（见 `SmallMapColdStart`）：粒子更多，定到之后后台挑战者接着搜（`coldChallenger`）。
    /// - Parameters:
    ///   - visualOdometry: 视觉里程计在推粒子（ARKit 可用且打开了）。
    ///   - mapAreaM2: 地图外框面积（m²）；nil = 不知道，按大场地处理（不报）。
    static func liveColdStart(visualOdometry: Bool, mapAreaM2: Double? = nil) -> MagneticConfig {
        var c = MagneticConfig()
        // 冷启动时航向只来自罗盘，偏差可能很大
        c.initialHeadingBiasSigmaDeg = 30
        if visualOdometry {
            // 视觉里程计时：
            // - 以垂直分量 Bz 为主：人掉头时，手机偏置的估计误差会让水平分量 Bh 和总强度 |B| 的误差反过来，Bz 不受影响；
            // - 跳到远处另一个簇要连续确认 15 次（约 7.5 m）：视觉里程计一路漂移不到 1%，地磁只该做小修正；
            // - 收敛后粒子噪声调小，不会沿着「长得像」的通道滑走。
            c.featureWeights = (0.5, 1.0, 0.25)
            c.jumpConfirmUpdates = 15
            c.convergedPositionNoiseFraction = 0.03
        }
        // 每次读数的整体水平会差 10～16 µT（磁力计偏置估计不同）：没定到按起伏找，定到后估出偏移再按绝对值比
        c.hybridOffset = true
        c.magOnlyColdStartReports = magOnlyColdStartAllowed(mapAreaM2: mapAreaM2)
        if magOnlyColdStartAllowed(mapAreaM2: mapAreaM2) {
            c.coldStartParticleCount = SmallMapColdStart.particleCount
            c.coldChallenger = true
            c.coldChallengerParticleCount = SmallMapColdStart.challengerParticleCount
        }
        return c
    }

    /// 只靠地磁冷启动也报位置的地图面积上限（m²，地图外框）。办公室 / 房间几百平米，商场楼层几千平米。
    static let magOnlyColdStartMaxAreaM2: Double = 1000

    /// 这张地图上只靠地磁的冷启动报不报位置（见 `liveColdStart`）。
    static func magOnlyColdStartAllowed(mapAreaM2: Double?) -> Bool {
        guard let a = mapAreaM2, a > 0 else { return false }
        return a <= magOnlyColdStartMaxAreaM2
    }
}

/// 小场地（`MagneticConfig.magOnlyColdStartAllowed`：办公室 / 房间）只靠地磁冷启动的搜索设置。
///
/// 冷启动不知道位置、航向，也不知道这次计步的步长比例，粒子要盖住 位置 × 航向 × 步长比例 四维。
/// 实测计步的距离比例离 1 很远、而且每次不一样（公开 ILC 真实 IMU 手持：计步距离 / 真值 1.05～1.29；
/// 自采办公室 iPhone 建图会话 0.36～0.92），按 1 ± 6% 撒的 6000 个粒子在几百平米里经常没有一个落在对的假设附近，
/// 于是锁到长得像的地方；粒子权重是相对的，整团锁错之后自己判不了丢。
/// - 粒子数：合成办公室（public/sim-office-phone，步长偏短 0.82）冷启动错定 6000 → 12000 → 24000 → 48000 个粒子
///   65% → 52% → 42% → 37%（拐点在 24000；48000 再翻倍只多 5 个点）。只在找位置时用，定到之后照旧缩到 `particleCount`；
/// - 挑战者（`MagneticConfig.coldChallenger`）：定到之后后台用常规冷启动的粒子数从零接着搜，另一个假设在同一段新观测上
///   证据压过主滤波器（对数贝叶斯因子 ≥ ln 100）就换过去：合成办公室错定再 42% → 30%（ln 20 / ln 100 / ln 1000：
///   26% / 30% / 28%，比较窗口 10 m / 20 m 一样）。
/// 大场地不用：只靠地磁不报位置（商场上 24000 个粒子也还是 90% 错定），蓝牙 / Wi-Fi 先验在缩小范围。
public enum SmallMapColdStart {
    /// 冷启动（找位置时）的粒子数
    public static let particleCount = 24000
    /// 挑战者搜索时的粒子数（常规冷启动的数目：挑战者一直在后台跑，算力按常规冷启动给）
    public static let challengerParticleCount = MagneticConfig().coldStartParticleCount
}

/// Wi-Fi 冷启动（只有 Android 能扫 Wi-Fi；评估 `--wifi`，场景 public/pdr/cold-wifi）：
/// 第一次 Wi-Fi 指纹定位当起点，粒子按 N(定位, `seedSpreadCm`) 撒开、朝向整圆均匀；之后每次扫描给一个重尾（Student-t）
/// 的位置观测；粒子的位置散布小于 `reportSpreadCm`、航向散布小于 `reportHeadingSpreadDeg` 才报位置
/// （宁可不报，也不报一个没把握的），报了之后散布涨到 `holdSpreadCm` 以上才停（不在门限附近来回闪）。
///
/// 地磁：滤波器以跟踪档为底（只在局部，不在全图找），但地磁权重 `magneticWeight` 目前是 0。
/// 公开数据集上量过：定到之后再按 0.02～1 的权重用地磁（混合偏移 / 只比起伏两种都试过），中位、P90、错定都变差——
/// 单次 Wi-Fi 定位的误差在一段路上是成片偏的（同一段路连续十几次偏同一个方向），地磁跟踪从偏了几米的位置出发
/// 会锁到旁边长得像的地方。所以现在是「Wi-Fi + 计步」，地磁这一路留着接口（权重调成正数就用上）。
public enum WiFiColdStartProfile {
    /// kNN 的 k
    public static let neighbours = 5
    /// 起点撒开的 1σ（cm）：单次 Wi-Fi 定位中位误差约 4.5 m、P90 约 9 m
    public static let seedSpreadCm: Double = 800
    /// 每次扫描的位置观测 σ（cm）和 Student-t 的自由度
    public static let priorSigmaCm: Double = 500
    public static let priorNu: Double = 3
    /// 粒子位置散布（cm）小于这个、航向散布（度）小于这个才开始报位置
    public static let reportSpreadCm: Double = 300
    public static let reportHeadingSpreadDeg: Double = 20
    /// 已经在报位置时，位置散布涨到这个（cm）以上才停
    public static let holdSpreadCm: Double = 350
    /// 定到之后地磁的权重（MagneticConfig.convergedMagWeight）。0 = 不用地磁，原因见上
    public static let magneticWeight: Double = 0
    /// 连续 `reseedAfterFixes` 次 Wi-Fi 定位都离粒子加权平均超过这么远（cm，3σ），就按这几次的平均重新撒粒子
    /// （第一次定位是离群值时，跟踪档自己不判丢、不注入，拉不回来）
    public static let reseedDistanceCm: Double = 1500
    public static let reseedAfterFixes = 3
}

public extension MagneticConfig {
    /// Wi-Fi 冷启动配置档：跟踪档（不知道朝向）为底，Wi-Fi 一直在给全局位置，所以
    /// - 自己不判丢（不做局部找回 / 全图找）：报不报位置只看粒子散布，Wi-Fi 会把跑偏的粒子拉回来；
    /// - 重采样注入的粒子朝向也在整圆上均匀（位姿坐标系和地图的夹角完全不知道）；
    /// - 地磁权重见 `WiFiColdStartProfile.magneticWeight`。
    static func wifiColdStart(odometry: OdometrySource) -> MagneticConfig {
        var c = MagneticConfig.tracking(odometry: odometry, headingKnown: false)
        c.lostUpdates = Int.max
        c.localRecovery = false
        c.uniformHeadingForInjection = true
        c.convergedMagWeight = WiFiColdStartProfile.magneticWeight
        c.pinnedConvergedMagWeight = WiFiColdStartProfile.magneticWeight
        return c
    }
}

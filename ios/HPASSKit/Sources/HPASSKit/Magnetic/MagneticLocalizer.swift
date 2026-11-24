import Foundation

// 地磁定位：粒子滤波。
//
// 运动模型：惯导（FusionEngine 的位移增量，cm）。每个粒子带一个航向偏差和一个步长比例，
//          用来吸收惯导的航向漂移和步长误差。
// 观测模型：粒子位置处地图里的 (|B|, Bz, Bh) 与实测特征比较，重尾似然（Student-t，ν = 4），
//          只在累计走过一段距离之后才更新一次，避免站着不动时权重被越压越窄。
// 通道约束：（可选）粒子必须在通道里走，不能穿货架；单一走向的通道里，行走方向应沿通道轴线。
// 冷启动：  没有起点时在可走区域均匀撒粒子，收敛后缩到较少的粒子数。

public struct MagneticConfig {
    /// 按场景调地磁权重（见 MagneticLocalizer.magneticWeight）：磁场图稀、走得还短、磁场平、和标签对不上时，
    /// 地磁似然打折，交给标签 / 通道 / 运动去定，免得地磁把位置带偏（公开数据集上「只用地磁比纯推算还差」）
    public var adaptiveMagWeight = false
    public var magWeightFloor = 0.15
    /// 已知起点或收敛之后用的粒子数。
    public var particleCount = 1500
    /// 冷启动（没有起点）时用的粒子数，收敛后自动缩到 `particleCount`。
    public var coldStartParticleCount = 6000
    /// 收敛判据：簇内不确定度小于该值（cm）、置信度大于 `convergedConfidence`，连续 3 次更新。
    public var convergedUncertaintyCm: Double = 200
    public var convergedConfidence: Double = 0.6
    /// 丢失判据：已经收敛之后，置信度低于 `lostConfidence`、或不确定度超过 `lostUncertaintyCm`，
    /// 连续 `lostUpdates` 次更新，就认为丢了（`converged` 变回 false），要重新收敛才恢复。
    public var lostConfidence: Double = 0.2
    /// 用过外部位置先验（蓝牙粗定位 / 标签范围 / 区域观测，见 `MagneticLocalizer.externalPriorApplied`）之后的丢失置信度门限。
    /// nil = 同 `lostConfidence`。跟踪档用：只有地磁时门限放宽（不然位置没错也频繁判丢），有蓝牙时判丢之后蓝牙能很快把它拉回来，
    /// 门限放宽只会让锁错的位置多显示一会儿，所以照旧 0.2（见 `TrackingProfile.lostConfidenceWithExternalPrior`）。
    public var lostConfidenceWithExternalPrior: Double?
    public var lostUncertaintyCm: Double = 600
    public var lostUpdates: Int = 4
    /// 不知道朝向（冷启动，或只知道位置不知道朝向）时，每个粒子的航向偏差在整圆上均匀取值，
    /// 靠通道走向和磁场匹配把它挑出来；不依赖罗盘或「地图朝向」。
    public var uniformHeadingWhenUnknown = true
    /// 重采样时注入的随机粒子：航向未知时航向偏差也在整圆上均匀取值（false = 沿用 N(0, `initialHeadingBiasSigmaDeg`)）。
    /// 默认关，保持原有冷启动行为；由需要的配置档显式打开。
    public var uniformHeadingForInjection = false

    /// 累计位移达到多少 cm 才做一次观测更新。
    public var updateDistanceCm: Double = 50
    /// 每走 1 cm 附加的位置噪声比例，外加一个固定底噪（cm）。
    public var positionNoiseFraction: Double = 0.08
    /// 收敛之后用的位置噪声比例（nil = 同上）。运动模型很准（视觉里程计）时调小，粒子不会沿通道「滑」到别处。
    public var convergedPositionNoiseFraction: Double?
    public var positionNoiseFloorCm: Double = 2
    /// 冷启动时每个粒子的航向偏差 1σ（度）；以及每走 1 m 的随机游走（度）。
    public var initialHeadingBiasSigmaDeg: Double = 12
    public var headingBiasWalkDegPerM: Double = 2
    /// 步长比例的初始 1σ 与每走 1 m 的随机游走。
    public var initialScaleSigma: Double = 0.06
    public var scaleWalkPerM: Double = 0.005

    /// 观测噪声下限（µT），与地图格子的标准差合成。
    public var observationSigmaFloorUT: Double = 1.5
    /// 只比「起伏」不比「绝对值」：读数和地图各减去最近一段路的平均再比。
    /// 实测两次采集同一处的磁场起伏很像（相关 0.78），但整体差 10～16 µT（手机磁力计偏置每次估得不一样），
    /// 按绝对值比就对不上。打开后整体偏移被抵消掉。
    public var offsetInvariant = false
    /// 混合模式：没定到时按「起伏」找（不怕整体偏移），定到之后估出这次的整体偏移、改回按绝对值比（更准），
    /// 偏移在定位过程中慢慢跟踪。优先于 offsetInvariant。
    public var hybridOffset = false
    /// 定到之后偏移跟踪的速度（每次更新）
    public var offsetTrackRate = 0.03
    /// 稳健偏移估计（混合模式）：定到之后先继续按「起伏」比，攒够这么多次更新的残差（读数 − 认定位置的地图值）
    /// 再取各分量的中位数当偏移；之后偏移 = 最近 `offsetMedianWindow` 次残差的中位数（慢、且不怕个别离群）。
    /// 0 = 原有行为（刚定到时用一次读数估偏移，之后按 `offsetTrackRate` 指数跟踪）。
    public var offsetWarmupUpdates = 0
    public var offsetMedianWindow = 60
    /// 「最近一段路」有多长：按观测更新次数算的指数平均（每次约 20 cm，40 次约 8 m）
    public var offsetWindowUpdates: Double = 40
    /// 起伏模式下绝对值还占多少分量（0 = 完全不看绝对值）；绝对值那一项的标准差加上 offsetSlackUT
    public var absoluteWeight: Double = 0
    public var offsetSlackUT: Double = 12
    /// 总强度、垂直分量、水平分量的权重（Bh 与前两者相关，权重低一些）。
    public var featureWeights: (Double, Double, Double) = (1.0, 1.0, 0.5)
    /// 对数似然除以这个温度，抵消特征之间的相关性造成的过度自信。
    public var likelihoodTemperature: Double = 1.5
    /// 地磁残差的相关长度（cm）：相邻观测更新（每 `updateDistanceCm` 一次）的「读数 − 地图」残差高度相关
    /// （地图误差、偏移误差都是成片的），走这么远才算一次独立观测。地磁似然再除以 max(1, 相关长度 / updateDistanceCm)。
    /// 只作用于地磁，不影响横向距离等其他观测。0 = 原有行为（每次更新都当独立的）。
    public var magneticCorrelationCm: Double = 0
    /// 每个粒子自己估整体偏移（Rao-Blackwell）：「读数 − 粒子处地图」= 偏移 b + 白噪声，b 沿路随机游走，
    /// 每个粒子带一个 b 的估计（三个分量），方差 P 全体共用（只取决于更新节拍）。似然看新息 ν = 残差 − b̂（t4，方差 P + q + R + 格子方差），
    /// 再用 ν 更新 b̂（卡尔曼增益，|ν| 截到 3σ）。打开后：不用全局偏移（hybridOffset 的预热 / 中位数）、不按相关长度折算、
    /// 不乘 `convergedMagWeight`（配置档钉死的除外），强度只由温度定。false = 原有行为（地图标定过时见 `particleOffsetFromMap`）。
    /// 为什么：实测残差（扣会话整体偏移后）沿路高度相关、慢慢漂（相邻 50 cm 相关 0.94～0.96），原来按「每 12 次更新算一次独立观测」
    /// 整体打折，地图很准时（合成小场地）也只用到百分之一的信息；偏移随机游走把慢漂的部分吸收掉，只用局部的起伏比，
    /// 不用打那么大的折。
    public var particleOffsetFilter = false
    /// 计步跟踪时，地图带了跟踪似然标定（`MagneticFieldMap.trackingTemperature` ≤ `TrackingCalibration.maxTemperature`）
    /// 就自动用「每个粒子自己估偏移」，温度取地图标定的值。只在跟踪档、运动来源是计步、地磁权重没被配置档钉死时；
    /// 视觉里程计（推算本来就准）、冷启动、没标定的图照旧。
    public var particleOffsetFromMap = false
    /// 偏移随机游走每次更新（`updateDistanceCm`）的方差 q（µT²），按实际走过的距离折算
    public var particleOffsetWalkVarUT2: Double = 16
    /// 白噪声方差 R（µT²），和格子方差相加
    public var particleOffsetWhiteVarUT2: Double = 9
    /// 对数似然除以的温度（含特征之间的相关；不再乘 `likelihoodTemperature`、不按相关长度折算）。
    /// 只给 `particleOffsetFilter` 用；`particleOffsetFromMap` 用地图标定的温度
    public var particleOffsetTemperature: Double = 2.4
    /// 粒子所在位置没有地图数据时的对数似然惩罚。要比「在对的地方但读数有点对不上」重得多，
    /// 否则粒子会跑到没采集过的地方去（实测：−4 时估计会跳到一百多米外）。
    public var missingDataPenalty: Double = -20
    /// 步长比例的上下限。计步在手机竖拿时可能少算三成，所以给足范围。
    public var scaleRange: ClosedRange<Double> = 0.6...1.7

    /// 通道约束：新位置不在可走区域、或中途穿过货架时的对数惩罚。
    public var blockedPenalty: Double = -4
    /// 整步撞墙时贴墙滑（先只走 x，再只走 y，按地图坐标轴），滑得过去就不原地不动。false = 原有行为。
    /// 产品（跟踪配置档）不打开：只在公开基准上量过（和不滑差不多），斜的货架 / 走廊上按坐标轴滑不合适，自采数据也没量过；
    /// 评估用 hpass-eval --wall-slide 打开对比。
    public var wallSlide = false
    /// 贴墙滑过去的粒子的对数惩罚（比原地不动轻：方向偏了一点，但不是穿墙）。
    public var wallSlidePenalty: Double = -1
    /// 房间约束（办公室地图，可走区域要用 `WalkableMap(roomsOf:)` / `WalkableMap(units:doors:walls:obstacles:)` 建，带 `rooms`）：
    /// 粒子一步换了房间却没经过连接两个房间的门洞，就当穿墙：原地不动，扣 `blockedPenalty` 之外再扣 `roomCrossingPenalty`；
    /// 重采样抖动跨了房间也退回来源粒子。false = 原有行为（墙缝本来就不可走，但 IMDF 地图相邻单元贴着，没有这条就能直接穿过去）。
    public var roomConstraints = false
    /// 不经门换房间的额外对数惩罚（在 `blockedPenalty` 之外）。占位值（待自采 iPhone 双机数据标定）
    public var roomCrossingPenalty: Double = -4
    /// 估计结果带房间：`MagneticEstimate.roomId`、`roomMass`、`roomOnly`。false 时这几个字段为 nil / 0 / false
    public var reportRoom = false
    /// 房间置信度（roomMass）低于这个值时只报房间级（`MagneticEstimate.roomOnly`），UI 不画点。占位值（待自采 iPhone 双机数据标定）
    public var roomPointMassThreshold: Double = 0.7
    /// 静止冻结（见 `StationaryFreezeDetector`、`MagneticLocalizer.freezeStationary`）：在房间里静止够久就把粒子收拢、
    /// 冻结期间不推粒子（坐着时的伪步不推）；起身后散布放大。false 时 freezeStationary 什么都不做
    public var stationaryFreeze = false
    /// 冻结时粒子散布（加权 RMS，cm）收拢到不超过这个值。占位值（待自采 iPhone 双机数据标定）
    public var stationaryFreezeSpreadCm: Double = 50
    /// 解冻（起身）时粒子散布放大倍数。占位值（待自采 iPhone 双机数据标定）
    public var stationaryReleaseSpreadFactor: Double = 1.5
    /// 权重最多的房间占比至少这么多才冻结（不然冻结会把房间之争定死）。占位值（待自采 iPhone 双机数据标定）
    public var stationaryFreezeMinRoomMass: Double = 0.7
    /// 通道走向先验的标准差（度）。行走方向偏离通道轴线越多，扣分越多。
    public var corridorHeadingSigmaDeg: Double = 22
    /// 走向先验的整体强度，0 关闭。
    public var corridorHeadingWeight: Double = 1.0

    /// 横向距离（深度相机量到的左右货架距离）观测的权重，0 = 不用。需要设置 `raycaster`。
    public var lateralWeight: Double = 0
    /// 横向距离观测的 1σ（cm），再加上距离的 15%。
    public var lateralSigmaCm: Double = 35
    /// 超过这个距离的墙不参与比较（深度相机量程之外）。
    public var lateralMaxCm: Double = 450

    /// 已收敛后，估计位置想跳到 `jumpGateCm` 以外的另一个簇，要连续 `jumpConfirmUpdates` 次更新都指向那里才切换；
    /// 期间继续跟着原来的簇走。防止一两次读数异常（比如系统重新校准磁力计）就把位置甩到别处。
    public var jumpGateCm: Double = 300
    public var jumpConfirmUpdates: Int = 6
    /// 原来的簇权重占比低于这个值，就不再坚持，立刻切换。
    public var keepClusterMinMass: Double = 0.12
    /// 已收敛时注入随机粒子的比例（没收敛时用 `randomInjection`）。
    public var randomInjectionConverged: Double = 0.003

    /// 有效粒子数低于 N × 该比例时重采样。
    public var resampleThreshold: Double = 0.5
    /// 重采样后的位置抖动（cm），以及注入的随机粒子比例（用于跟丢后重新找回）。
    public var roughenCm: Double = 6
    public var randomInjection: Double = 0.02
    /// 估计位置取「最重粒子周围这个半径内」的加权平均，避免多峰时平均到两个峰中间。
    public var clusterRadiusCm: Double = 250
    /// 置信度的参考尺度：不确定度达到该值时置信度归零（cm）。
    public var confidenceScaleCm: Double = 400

    // MARK: 跟踪策略（默认全是原有行为；跟踪配置档 `MagneticConfig.tracking` 打开）

    /// 已收敛后地磁似然乘的权重（adaptiveMagWeight 打开时不用这个）。1 = 原有行为。
    public var convergedMagWeight: Double = 1
    /// 已收敛时，地磁似然再乘 g = clamp((有数据粒子的权重占比 − 0.5) / 0.4, 0, 1)：
    /// 粒子大多落在没采过磁场的格子上时，这一段完全靠推算，不让少数「有数据」的粒子把权重抢走。
    public var coverageGatedMagWeight = false
    /// 估计点落在没有磁场数据的格子上时置信度归零（于是持续几次就判丢）。跟踪时关掉：没采过的地方本来就该纯推算。
    public var zeroConfidenceOffMap = true
    /// 原来的簇权重占比低于 `keepClusterMinMass` 时立刻切换——只在新簇离得近（≤ 2 × `jumpGateCm`）时这样做；
    /// 远处的簇照样要连续 `jumpConfirmUpdates` 次确认，确认期间原来的簇权重低也不算「走向丢失」
    /// （否则判丢之后估计直接取最重的簇，等于绕过了确认）。false = 原有行为（不管远近都立刻切）。
    public var keepClusterRequiresNear = false
    /// 已知起点开始的定位自己丢了（置信度持续低）：只在最后一次可靠位置（按推算一路平移）附近找回，
    /// 半径 = `localRecoveryBaseCm` + `localRecoveryPerCm` × 丢了之后走过的路（上限 `localRecoveryMaxCm`）。
    /// 这个圆只限制「注入的新粒子撒在哪」：已有的粒子不拉回圆里、也不因为在圆外扣分（公开数据集的移植上量过：
    /// 圆外扣分让 P90 变差，丢了的时候真实位置常常就在圆外的那部分粒子里），估计和重新收敛照样看全部粒子。
    /// 找回期间没有磁场数据的粒子不罚（不用 missingDataPenalty）。
    /// 外部判定定错（declareLost，例如蓝牙说离得很远）不走局部找回：最后的「可靠位置」正是被否定的那个，直接全图找。
    /// 丢了之后走了 `localRecoveryGlobalAfterCm` 还没找回，也改回全图找（起点 / 最后的可靠位置本身可能就是错的）。
    /// false = 原有行为（全图重新找）。冷启动（没有起点）不受影响。
    public var localRecovery = false
    public var localRecoveryBaseCm: Double = 300
    public var localRecoveryPerCm: Double = 0.2
    public var localRecoveryMaxCm: Double = 3000
    /// nil = 一直局部找回
    public var localRecoveryGlobalAfterCm: Double?

    // MARK: 冷启动收敛门（默认全是原有行为；`applyColdStartGate()` 打开）
    //
    // 只在冷启动（reset 没给起点）、还没收敛、并且还没用过任何外部位置先验（蓝牙粗定位 / 标签范围 / 区域观测）时生效。
    // 只靠地磁找位置时，走了十几米的磁场序列在大楼层里往往能对上好几处，过早宣布定到就是「很自信地定错」；
    // 这几道门让滤波器宁可先不报位置。已知起点（跟踪）从不受影响。

    /// 找位置（冷启动或丢了之后重新找）至少走了这么远（cm）才允许宣布定到。0 = 不限制。
    public var coldMinPathCm: Double = 0
    /// 最重的簇的权重 ÷ 离它 `coldModeSeparationCm` 以外最重的另一个簇的权重，至少这么大才允许定到。0 = 不看。
    public var coldModeRatio: Double = 0
    public var coldModeSeparationCm: Double = 500
    /// 冷启动时要连续几次更新都满足收敛条件（原有行为 3 次）。
    public var coldMinStreak: Int = 3
    /// 有效粒子数 / 总粒子数至少这么大才允许定到（粒子太少撑着的「峰」不可信）。0 = 不看。
    public var coldMinEffectiveRatio: Double = 0
    /// 收敛门起作用时地磁似然用的温度（0 = 同 `likelihoodTemperature`）。
    public var coldSearchTemperature: Double = 0
    /// 只靠地磁的冷启动报不报位置（产品决定，不是收敛判据）。false：冷启动（reset 没给起点）之后、还没用过任何外部位置先验
    /// （蓝牙粗定位 / 标签范围 / 区域观测）之前，一律不宣布定到，等外部先验或用户指起点。默认 true（原有行为）。
    /// 公开商场楼层上量过：只靠地磁冷启动，各种收敛门（走够路、峰够突出、连续更多次、有效粒子）组合下错定都还有 91～100%，
    /// 十几米的磁场序列在八千多平米的楼层里能对上很多处。hpass-eval `--no-mag-only-cold-fix`。
    public var magOnlyColdStartReports = true
    // MARK: 冷启动挑战者（默认关；小场地的 `liveColdStart` 打开）
    //
    // 只靠地磁冷启动定到之后，后台再跑一个从零开始的冷启动搜索（挑战者）。粒子滤波的权重是相对的：
    // 整团粒子都锁在错的地方时，归一化之后它照样「很有把握」，自己判不了丢；随机注入的零星新粒子在
    // 位置 × 航向 × 步长比例里几乎碰不到对的假设。挑战者也定到了、而且离主滤波器的位置远（两个不同的假设）时，
    // 两边在接下来同一段观测上比证据（每次观测更新的 log Σ w·L，同一套似然），对数贝叶斯因子超过门限就换成挑战者的粒子；
    // 主滤波器先到门限、或比满一个窗口都没分出胜负，就留主滤波器（维持现状），挑战者从零重新搜。
    // 挑战者定到的位置离主滤波器很近 = 印证，也从零重新搜。用过外部位置先验（蓝牙 / 区域观测）或已知起点时不跑。

    /// 打开冷启动挑战者
    public var coldChallenger = false
    /// 一轮比证据最多比多少次观测更新（每次约 `updateDistanceCm`）
    public var coldChallengerWindowUpdates = 20
    /// 对数贝叶斯因子门限（任何一方领先这么多就判胜负）
    public var coldChallengerLogBayesFactor: Double = log(100)
    /// 挑战者定到的位置离主滤波器超过这么远（cm）才算另一个假设
    public var coldChallengerSeparationCm: Double = 500
    /// 挑战者搜索时的粒子数（nil = 同 `coldStartParticleCount`）
    public var coldChallengerParticleCount: Int?

    /// 报的不确定度（`MagneticEstimate.uncertaintyCm`）用误差模型（`ReportedUncertainty`：全部粒子相对报的位置的散布，
    /// 加上粒子步长比例散布塌缩后补回的那部分推算误差），不用簇内散布。只改报的数，位置、收敛 / 丢失判定都不变
    /// （内部照旧用簇内散布，见 `MagneticEstimate.clusterUncertaintyCm`）。false = 原有行为。跟踪档、实时冷启动档打开
    public var honestUncertainty = false
    /// 误差模型里「这次推算的步长比例真实有多不准」（1σ，见 `ReportedUncertainty`）：计步 0.10、视觉里程计 0.02，配置档按运动来源给
    public var reportScaleSigma: Double = ReportedUncertainty.pdrScaleSigma

    /// 跟踪配置档的运动来源（nil = 不是跟踪档）。运动来源中途变了（视觉里程计没对齐 / 跟丢时计步顶上）
    /// 用 `MagneticLocalizer.setOdometry` 换成对应那一套参数。
    public var trackingOdometry: OdometrySource?
    public var trackingHeadingKnown = true
    /// 配置档钉死的定到后地磁权重：`setOdometry` 换运动来源时不覆盖（Wi-Fi 冷启动档钉成 0）。nil = 按运动来源给
    public var pinnedConvergedMagWeight: Double?
    /// 已知起点开始的跟踪里，蓝牙（BLEAssist）只做软约束，而且只在蓝牙底图学过本场地标签范围时
    /// （`BLEAssist.supportsSoftTracking`；人工打点的标签位置表合成的底图没有，照旧用硬约束）：
    /// 有上限的软范围约束（见下；`bleSoftRangeWeight = 0` 时改用宽位置先验 σ ≥ `bleSoftPriorSigmaCm`、权重 `bleSoftPriorWeight`）；
    /// 不挡收敛；蓝牙持续对不上时先只触发局部找回（`declareLost(local: true)`），找回后蓝牙还是不认就升级成全图找
    /// （`BLEAssist.softEscalateAfter`）。
    /// false = 原有行为（标签范围硬约束、对不上 / 不在采集区域就判丢全图找、挡收敛）。冷启动不受影响（学到的范围只在软约束里用）。
    public var bleSoftTracking = false
    public var bleSoftPriorSigmaCm: Double = 700
    public var bleSoftPriorWeight: Double = 0.2
    /// 软约束时、底图学过本场地标签范围（`BLEFingerprintMap.learnedRanges`）：每片强标签一个有上限的软范围约束
    /// 代替上面的宽位置先验。超出学到的 P90 范围才罚（σ `bleSoftRangeSigmaCm`），每片每次最多罚 `bleSoftRangeCapLog`，
    /// 整体乘 `bleSoftRangeWeight`（0 = 不用，一律用宽位置先验）。
    public var bleSoftRangeWeight: Double = 1
    public var bleSoftRangeSigmaCm: Double = 300
    public var bleSoftRangeCapLog: Double = 1
    /// 软约束时蓝牙持续对不上是否触发局部找回（false = 只给先验，从不判丢）
    public var bleSoftLocalRecovery = true

    // MARK: 携带模式（默认关：原有行为）

    /// 按携带模式切换分模式参数（`carryTable`），携带姿态变了就按新模式的先验重撒航向偏差 / 步长比例、粒子位置不动、
    /// 之后走一段不判丢（`MagneticLocalizer.setCarryMode` / `apply(_:)`）。只对计步运动来源有意义。
    public var carryModeAdaptive = false
    /// 分模式参数表（占位值，待自采 iPhone 双机数据标定；见 `CarryMotionTable.placeholder`）。
    public var carryTable = CarryMotionTable.placeholder

    public init() {}

    /// 打开冷启动收敛门（推荐值见 `ColdStartGate`）：只用地磁冷启动时宁可不报位置，也不报错的。
    public mutating func applyColdStartGate() {
        coldMinPathCm = ColdStartGate.minPathCm
        coldModeRatio = ColdStartGate.modeRatio
        coldMinStreak = ColdStartGate.minStreak
        coldMinEffectiveRatio = ColdStartGate.minEffectiveRatio
        coldSearchTemperature = ColdStartGate.searchTemperature
    }

    /// 关掉冷启动收敛门（恢复原有行为）。
    public mutating func clearColdStartGate() {
        let d = MagneticConfig()
        coldMinPathCm = d.coldMinPathCm
        coldModeRatio = d.coldModeRatio
        coldMinStreak = d.coldMinStreak
        coldMinEffectiveRatio = d.coldMinEffectiveRatio
        coldSearchTemperature = d.coldSearchTemperature
    }

    /// 冷启动收敛门是否打开（任何一道门不是原有行为）
    public var coldStartGateEnabled: Bool {
        let d = MagneticConfig()
        return coldMinPathCm != d.coldMinPathCm || coldModeRatio != d.coldModeRatio
            || coldMinStreak != d.coldMinStreak || coldMinEffectiveRatio != d.coldMinEffectiveRatio
            || coldSearchTemperature != d.coldSearchTemperature
    }
}

/// 冷启动收敛门的推荐值（见 `MagneticConfig.applyColdStartGate`）。
public enum ColdStartGate {
    public static let minPathCm: Double = 4000
    public static let modeRatio: Double = 5
    public static let minStreak = 10
    public static let minEffectiveRatio: Double = 0.2
    public static let searchTemperature: Double = 0
}

public struct MagneticEstimate {
    /// 位置，cm，地图系。
    public var position: Point2
    /// 报的 1σ 位置不确定度（cm，均方根半径 √(σx² + σy²)）。`MagneticConfig.honestUncertainty` 打开时是误差模型
    /// （`ReportedUncertainty`），否则是最重粒子簇的簇内散布（原有行为）。
    public var uncertaintyCm: Double
    /// 0...1。簇内权重占比 × (1 − 不确定度 / 参考尺度)。
    public var confidence: Double
    /// 有效粒子数 / 总粒子数。
    public var effectiveRatio: Double
    /// 已经做过几次观测更新。
    public var updates: Int
    /// 是否已经收敛（冷启动时从 false 变 true）。
    public var converged: Bool
    /// 估计点所在的房间（map.json 单元 id）。没有房间图或没打开 `MagneticConfig.reportRoom` 时为 nil
    public var roomId: String? = nil
    /// 房间置信度：全部粒子里落在 `roomId` 这个房间的权重占比（0...1）
    public var roomMass: Double = 0
    /// 房间置信度不够（< `MagneticConfig.roomPointMassThreshold`）：只报房间级，不画点
    public var roomOnly: Bool = false
    /// 权重第二多的房间和它的权重占比（两个房间势均力敌时界面可以都提）
    public var roomRunnerUpId: String? = nil
    public var roomRunnerUpMass: Double = 0
    /// 最重粒子簇的簇内散布（cm，收敛 / 丢失判定用的那个数；nil = 和 uncertaintyCm 相同）
    public var clusterUncertaintyCm: Double? = nil
    /// 主簇（`clusterRadiusCm` 以内）粒子航向偏差的加权圆周均值（rad，(−π, π]，NAV-003）。
    /// 粒子推算方向 = 计步位移按 `bias` 逆时针旋转（见 predict）；没有粒子时 nil
    public var headingBiasRad: Double? = nil
    /// 主簇航向偏差的圆周标准差 √(−2 ln R)（rad）
    public var headingBiasSigmaRad: Double? = nil
    /// 主簇里航向偏差有两个以上相隔 ≥ 90° 的峰（第二峰权重 ≥ 20%）：航向有多个假设，不该给精确箭头
    public var headingMultimodal: Bool = false

    /// 航向不确定度超过它就不出修正后的航向（rad）
    public static let maxHeadingSigmaRad: Double = 30 * Double.pi / 180

    /// 计步航向（`FusionTypes` 约定：0 = 地图 +y，dx = L·sinθ、dy = L·cosθ）按粒子后验修正后的航向。
    ///
    /// 粒子把计步位移 (L·sinθ, L·cosθ) 按 bias 做标准旋转 (x·cos b − y·sin b, x·sin b + y·cos b)，
    /// 结果 = (L·sin(θ − b), L·cos(θ − b))：所以修正后的航向是 **θ − b**，不是 θ + b。
    /// 航向偏差散布 > `maxHeadingSigmaRad` 或多峰时返回 nil（不给假的精确箭头）。
    public func correctedHeading(pdrHeadingRad: Double) -> Double? {
        guard let b = headingBiasRad, let sd = headingBiasSigmaRad, pdrHeadingRad.isFinite,
              sd <= Self.maxHeadingSigmaRad, !headingMultimodal else { return nil }
        var h = (pdrHeadingRad - b).truncatingRemainder(dividingBy: 2 * Double.pi)
        if h < 0 { h += 2 * Double.pi }
        return h
    }
}

/// 报的不确定度的误差模型（`MagneticConfig.honestUncertainty`）。
///
/// 簇内散布当 1σ 太自信（Lab：真实计步跟踪 误差 / 1σ 的中位 2.4，自采办公室留一法 1.2、门店 3.8～5，二维高斯应是 0.83）：
/// 1. 簇半径 2.5 m 截断：簇内散布最大也就 1.5～1.8 m，多峰时其余的峰不算；
/// 2. 粒子的步长比例散布会塌：通道 / 墙把「走得太远」的粒子不断挡掉、重采样，步长比例的加权标准差从先验的 0.06
///    掉到 0.01～0.03，粒子云沿走向的散布跟着变窄——但滤波器其实学不到步长（真实步长比例偏 1 的 0.1～0.2 在先验 2σ 外），
///    塌了的时候误差反而最大（开发集：步长散布 < 0.04 的点误差中位 5～10 m，簇内散布才 0.5～1 m）。
/// 所以报的 1σ² = 全部粒子相对报的位置的均方距离 + (√(σ_真² − σ_粒子²)₊ · min(L, 地图外框边长))²：
/// σ_真 = 这次推算的步长比例真实有多不准（`MagneticConfig.reportScaleSigma`：计步 0.10 = 实测同一台 iPhone 各次的离散，
/// 设备之间的偏差 0.84～1.18 更大；视觉里程计 0.02），σ_粒子 = 粒子步长比例的加权标准差，
/// L = 上一次定位依据（已知起点、收敛、换成挑战者）之后走过的推算路程。粒子还留着这么大的步长散布时第二项为 0（散布本身就诚实）；
/// 塌了多少就补回多少。地图外框边长封顶：误差不会比场地还大，小房间里墙不断把沿走向的误差「卡」回去。
/// 标定只用开发集（公开 ILC 建图会话两折交叉的真实计步回放、另一套种子的合成办公室 / 两间房 / 冷启动），不用 Lab 打分的测试会话：
/// 开发集 误差 / 1σ 的中位（目标 0.83，见 docs/lab-ci.md），σ_真 = 0.08 / 0.10 / 0.12：真实计步 1.22 / 1.08 / 0.98、
/// 合成办公室 1.15 / 0.92 / 0.78、合成办公室冷启动 1.25 / 1.16 / 1.09；封顶改成 0.5 / 2 倍边长时差别不大（办公室 1.3 / 0.6 是两头）。
/// 合成的「无偏」漂移（public/pdr、public/vio：起点就是真值、尺度误差零均值）本来就偏保守（0.3～0.7），这里只会更保守。
/// 计算量：每次对外报位置（step / estimate()）多扫一遍粒子（N 次 exp，和找簇的那一遍同量级，远小于似然更新；
/// 内部的收敛 / 丢失判定、挑战者比较不算这个数）。
public enum ReportedUncertainty {
    /// 计步的步长比例真实离散（1σ）
    public static let pdrScaleSigma: Double = 0.10
    /// 视觉里程计的尺度离散（1σ）
    public static let vioScaleSigma: Double = 0.02
}

/// 可复现的随机数（测试要求结果稳定）。
struct MagRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func normal() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

/// 非线程安全，与其他 HPASSKit 对象一样要在同一串行队列上使用。
public final class MagneticLocalizer {
    public var config: MagneticConfig
    public let field: MagneticFieldMap
    /// 可走区域。nil 表示整张地图都能走（10×10 m 测试区）。定位中途地图几何变了用 `replaceGeometry` 换
    public private(set) var walkable: WalkableMap?
    /// 货架射线投射，用于横向距离观测。
    public var raycaster: ShelfRaycaster?

    private var rng: MagRNG
    private var xs: [Double] = []
    private var ys: [Double] = []
    private var bias: [Double] = []     // 航向偏差，弧度
    private var scale: [Double] = []    // 步长比例
    private var logw: [Double] = []
    /// 起伏模式：每个粒子沿自己走过的路，地图值的指数平均；读数的指数平均（NaN = 还没有）
    private var ema0: [Double] = [], ema1: [Double] = [], ema2: [Double] = []
    /// 每个粒子自己的偏移估计（`particleOffsetFilter`；NaN = 还没有），和共用的方差 P（nil = 还没开始）
    private var off0: [Double] = [], off1: [Double] = [], off2: [Double] = []
    private var offP: (Double, Double, Double)?
    /// 上一次更新有没有用「每个粒子自己估偏移」（运动来源中途换了时开关会变，变了就把两边的偏移状态清掉）
    private var particleOffsetWasActive = false

    /// 这次更新用不用「每个粒子自己估偏移」：用的话返回温度
    var particleOffsetTemperatureInUse: Double? {
        if config.particleOffsetFilter { return max(config.particleOffsetTemperature, 1e-6) }
        guard config.particleOffsetFromMap, config.trackingOdometry == .pdr, config.pinnedConvergedMagWeight == nil,
              let t = field.trackingTemperature, t <= TrackingCalibration.maxTemperature else { return nil }
        return max(t, 1)
    }
    private var obsEma: (Double, Double, Double)?
    /// 混合模式：这次读数相对地图的整体偏移（定到之后才有）
    private var offsetEst: MagneticFeature?
    /// 稳健偏移估计攒的残差（offsetWarmupUpdates > 0 时）
    private var offsetResiduals: [MagneticFeature] = []
    public var currentOffset: MagneticFeature? { offsetEst }
    /// 粒子的加权平均位置（测试用）
    var particleMean: Point2 {
        let m = logw.max() ?? 0
        var w = 0.0, x = 0.0, y = 0.0
        for i in xs.indices { let e = exp(logw[i] - m); w += e; x += e * xs[i]; y += e * ys[i] }
        return w > 0 ? Point2(x / w, y / w) : Point2(0, 0)
    }

    private var travelledCm = 0.0
    private var featureSum = MagneticFeature(total: 0, vertical: 0, horizontal: 0)
    private var featureCount = 0
    private var trustSum = 0.0
    private var latLeftSum = 0.0, latLeftN = 0
    private var latRightSum = 0.0, latRightN = 0
    private var latHeadingSin = 0.0, latHeadingCos = 0.0, latN = 0
    private var updateCount = 0
    private var lastEffectiveRatio = 1.0
    private var coldStart = false
    private var convergedStreak = 0
    private var hasConverged = false
    private var lowStreak = 0
    private var firstUpdateDone = false
    private var headingUnknown = false
    /// 有磁场数据（并且能走）的格子中心，冷启动撒点和跟丢后注入粒子都只在这里面。
    private var mappedCells: [Point2] = []
    /// 当前认定的位置（簇中心）。跳到远处另一个簇需要连续确认。
    private var committed: Point2?
    private var switchStreak = 0
    /// 收敛判定要求「簇的移动和实际走的一致」：上次更新时的簇中心，以及之后累计的平均位移。
    private var lastCenter: Point2?
    private var motionSinceUpdate = Point2.zero
    /// 这次是从已知起点开始的（reset 给了 start）
    public private(set) var startedFromPrior = false
    /// 局部找回：最后一次可靠位置（丢了之后按粒子平均位移一路平移）和之后走过的路
    private var lastGoodFix: Point2?
    private var sinceGoodCm = 0.0
    /// 正在局部找回（已知起点开始、现在没把握、打开了 localRecovery）
    private var recoveringLocally: Bool { config.localRecovery && startedFromPrior && !hasConverged && lastGoodFix != nil }
    /// 局部找回的半径（cm）
    public var localRecoveryRadiusCm: Double? {
        guard recoveringLocally else { return nil }
        return min(config.localRecoveryBaseCm + config.localRecoveryPerCm * sinceGoodCm, config.localRecoveryMaxCm)
    }
    /// 局部找回的中心（只读，测试 / 调试用）
    public var localRecoveryCenter: Point2? { recoveringLocally ? lastGoodFix : nil }
    /// 局部找回没找到、改回全图找的次数
    public private(set) var globalFallbackCount = 0
    /// 正在为远处的簇做跳转确认（keepClusterRequiresNear），这次更新不算「走向丢失」
    private var holdingAgainstFar = false
    /// reset 之后用过外部位置先验（蓝牙粗定位、标签范围、区域观测）。冷启动收敛门只在没用过时生效
    public private(set) var externalPriorApplied = false
    /// 这一轮找位置（冷启动或丢了之后）走过的路（cm），冷启动收敛门的「至少走多远」用
    public private(set) var searchPathCm = 0.0
    /// 冷启动收敛门现在是否在起作用（冷启动、没收敛、没用过外部先验、配置打开了）
    public var coldStartGateActive: Bool {
        coldStart && !hasConverged && !externalPriorApplied && config.coldStartGateEnabled
    }
    /// 现在用的丢失置信度门限（用过外部位置先验之后可以不同，见 `MagneticConfig.lostConfidenceWithExternalPrior`）
    public var effectiveLostConfidence: Double {
        externalPriorApplied ? (config.lostConfidenceWithExternalPrior ?? config.lostConfidence) : config.lostConfidence
    }
    /// 现在是「只靠地磁的冷启动、按配置不报位置」（`MagneticConfig.magOnlyColdStartReports = false`）
    public var magOnlyColdStartSuppressed: Bool {
        !config.magOnlyColdStartReports && coldStart && !hasConverged && !externalPriorApplied
    }

    // MARK: 携带模式

    /// 当前携带模式（`setCarryMode` / `apply` 给的；reset 后回到 unknown，调用方要重新告知）。
    public private(set) var carryMode: CarryMode = .unknown
    /// 携带模式重撒之后还剩多远（cm）不判丢。
    private var lostSuppressRemainingCm = 0.0
    /// 正处在「刚重撒、不判丢」的保护期。
    public var lostSuppressed: Bool { lostSuppressRemainingCm > 0 }
    /// 重撒过几次（诊断 / 测试）。
    public private(set) var respreadCount = 0

    /// 携带模式变了 / 「操作手机」事件：每个粒子的航向偏差和步长比例重新撒开，**粒子位置不动**（不是全图找回），
    /// 之后走 `suppressLostCm` 不判丢（航向整圆撒开后置信度必然先掉，等走一段磁场把航向挑出来）。
    /// 扩展自 `setOdometry` 的做法（来源变了按初始 σ 再撒开），区别是这里可以整圆、多峰、也可以不保留原偏差：
    /// - `spreadDeg` nil：整圆均匀（夹角完全未知：口袋 / 包 / 摆臂）；
    /// - 否则偏差 = (keepBias ? 原偏差 : 0) + 随机选一个 `centersDeg` 里的中心 + N(0, spreadDeg)（通话 ±90° 双峰）；
    /// - 步长比例在原值附近再撒 N(0, scaleSigma ?? config.initialScaleSigma)。
    /// 冷启动（没收敛）时只重撒航向偏差 / 步长比例，**不进**「刚重撒」保护期：保护期里地磁按找位置的强度、不按残差相关长度折算，
    /// 冷启动收敛门的温度是带着这个折算调的，冷启动时进保护期会过度自信地错定（评审；违反「只靠地磁冷启动不报错位置」）。
    public func carryModeChanged(spreadDeg: Double?, centersDeg: [Double] = [0], scaleSigma: Double? = nil,
                                 keepBias: Bool = false, suppressLostCm: Double = 1500) {
        guard !xs.isEmpty else { return }
        let centers = centersDeg.isEmpty ? [0.0] : centersDeg
        let ss = scaleSigma ?? config.initialScaleSigma
        for i in 0..<xs.count {
            if let sd = spreadDeg {
                let c = centers[min(Int(rng.uniform() * Double(centers.count)), centers.count - 1)] * Double.pi / 180
                bias[i] = (keepBias ? bias[i] : 0) + c + rng.normal() * sd * Double.pi / 180
            } else {
                bias[i] = (rng.uniform() * 2 - 1) * Double.pi
            }
            scale[i] = min(max(scale[i] + rng.normal() * ss, config.scaleRange.lowerBound), config.scaleRange.upperBound)
        }
        if !(coldStart && !hasConverged) {
            lostSuppressRemainingCm = max(lostSuppressRemainingCm, max(suppressLostCm, 0))
        }
        lowStreak = 0
        respreadCount += 1
    }

    /// 告知携带模式（App 自己的分类器，或 FusionEngine 的事件）。`config.carryModeAdaptive` 关着、不是携带姿态、
    /// 或运动来源是视觉里程计时什么都不做。切分模式参数；`respread` 且携带姿态真的变了（上一个也是携带姿态）才重撒。
    /// 第一次告知不重撒：起点 / 上一轮的航向先验还有效。返回是否重撒了。
    @discardableResult
    public func setCarryMode(_ mode: CarryMode, respread: Bool = true) -> Bool {
        guard config.carryModeAdaptive, mode.isCarryPosture else { return false }
        challenger?.setCarryMode(mode, respread: respread)
        let prev = carryMode
        carryMode = mode
        guard config.applyCarryMode(mode) else { return false }
        guard respread, prev.isCarryPosture, prev != mode else { return false }
        let p = config.carryTable[mode]
        carryModeChanged(spreadDeg: p.headingSpreadDeg, centersDeg: p.headingCentersDeg, scaleSigma: p.initialScaleSigma,
                         keepBias: false, suppressLostCm: p.lostSuppressCm)
        return true
    }

    /// 吃 FusionEngine 的携带模式事件：initial 只切参数；changed 按新模式先验重撒；handled 在原偏差附近撒开。
    /// `config.carryModeAdaptive` 关着或运动来源是视觉里程计时什么都不做。返回是否重撒了。
    @discardableResult
    public func apply(_ ev: CarryMotionEvent) -> Bool {
        guard config.carryModeAdaptive, config.trackingOdometry != .vio else { return false }
        challenger.map { _ = $0.apply(ev) }
        switch ev.kind {
        case .initial:
            return setCarryMode(ev.to, respread: false)
        case .changed:
            _ = setCarryMode(ev.to, respread: false)
            carryModeChanged(spreadDeg: ev.headingSpreadDeg, centersDeg: ev.headingCentersDeg, scaleSigma: ev.initialScaleSigma,
                             keepBias: ev.keepBias, suppressLostCm: ev.lostSuppressCm)
            return true
        case .handled:
            guard carryMode.isCarryPosture || ev.to.isCarryPosture else { return false }
            if carryMode != ev.to { _ = setCarryMode(ev.to, respread: false) }
            carryModeChanged(spreadDeg: ev.headingSpreadDeg, centersDeg: ev.headingCentersDeg, scaleSigma: ev.initialScaleSigma,
                             keepBias: ev.keepBias, suppressLostCm: ev.lostSuppressCm)
            return true
        }
    }

    /// 粒子步长比例的加权中位数和加权标准差（在线标定步长 K 用：收敛后走一段，中位数回写当前模式的 K）。
    public func scaleStatistics() -> (median: Double, sigma: Double) {
        guard !xs.isEmpty else { return (1, 0) }
        let mx = logw.max() ?? 0
        var total = 0.0, mean = 0.0
        for i in xs.indices { let w = exp(logw[i] - mx); total += w; mean += w * scale[i] }
        guard total > 0 else { return (1, 0) }
        mean /= total
        var acc = 0.0, med = scale[0]
        for i in scale.indices.sorted(by: { scale[$0] < scale[$1] }) {
            acc += exp(logw[i] - mx)
            if acc >= total / 2 { med = scale[i]; break }
        }
        var v = 0.0
        for i in xs.indices { let w = exp(logw[i] - mx); v += w * (scale[i] - mean) * (scale[i] - mean) }
        return (med, (v / total).squareRoot())
    }

    /// 步长 K 吸收了 `factor` 之后，把每个粒子的步长比例除以同一个 factor：净位移不变，比例回到 1 附近。
    public func absorbStepScale(_ factor: Double) {
        guard factor.isFinite, factor > 0.3, factor < 3 else { return }
        challenger?.absorbStepScale(factor)
        for i in scale.indices {
            scale[i] = min(max(scale[i] / factor, config.scaleRange.lowerBound), config.scaleRange.upperBound)
        }
    }

    public init(field: MagneticFieldMap, walkable: WalkableMap? = nil,
                config: MagneticConfig = .init(), seed: UInt64 = 1) {
        self.field = field
        self.walkable = walkable
        self.config = config
        self.rng = MagRNG(seed: seed)
        challengerSeed = seed &* 0xD1B5_4A32_D192_ED03 &+ 1
        mappedCells = Self.mappedCells(field: field, walkable: walkable)
        reset(start: nil)
    }

    private static func mappedCells(field: MagneticFieldMap, walkable: WalkableMap?) -> [Point2] {
        var out: [Point2] = []
        for j in 0..<field.rows {
            for i in 0..<field.cols {
                let c = Point2((Double(i) + 0.5) * field.cellCm, (Double(j) + 0.5) * field.cellCm)
                guard field.sample(at: c) != nil else { continue }
                if let w = walkable, !w.isWalkable(c) { continue }
                out.append(c)
            }
        }
        return out
    }

    /// 定位中途地图几何变了（挪了货架 / 墙 / 门、改了通道，NAV-001）：换成新的可走区域和射线模型，不重新开始。
    /// 冷启动撒粒子的范围按新可走区域重算；落进新障碍物里的粒子挪到 2 m 内最近的可走处，挪不了的大幅降权。
    /// 后台挑战者一起换。
    public func replaceGeometry(walkable w: WalkableMap?, raycaster rc: ShelfRaycaster?) {
        walkable = w
        raycaster = rc
        mappedCells = Self.mappedCells(field: field, walkable: w)
        if let w {
            for i in xs.indices {
                let p = Point2(xs[i], ys[i])
                guard !w.isWalkable(p) else { continue }
                if let q = w.nearestWalkable(to: p, radiusCm: 200) {
                    xs[i] = q.x; ys[i] = q.y
                } else {
                    logw[i] -= 20
                }
            }
            normalize()
        }
        challenger?.replaceGeometry(walkable: w, raycaster: rc)
    }

    /// 有磁场数据的面积（m²），冷启动只在这里面找。
    public var mappedAreaM2: Double { Double(mappedCells.count) * field.cellCm * field.cellCm / 10_000 }

    private func randomPosition() -> Point2 { randomPositionWithAnchor().point }

    /// 随机位置，外加一个保证可走的「锚点」（选中的有数据格子中心；没有时为 nil）。
    /// 格内偏移最多半格，可能落到通道外，调用方可以退回锚点。
    private func randomPositionWithAnchor() -> (point: Point2, anchor: Point2?) {
        // 只在有磁场数据的地方找：没采集过的地方本来就没法用地磁定位
        if !mappedCells.isEmpty {
            let c = mappedCells[min(Int(rng.uniform() * Double(mappedCells.count)), mappedCells.count - 1)]
            let h = field.cellCm / 2
            return (Point2(c.x + (rng.uniform() * 2 - 1) * h, c.y + (rng.uniform() * 2 - 1) * h), c)
        }
        if let w = walkable, let p = w.randomPoint(u1: rng.uniform(), u2: rng.uniform(), u3: rng.uniform()) {
            return (p, p)
        }
        return (Point2(rng.uniform() * field.widthCm, rng.uniform() * field.heightCm), nil)
    }

    /// 重新开始。start 为 nil 时在可走区域（没有通道信息就是整张图）均匀撒点；
    /// 否则以 start 为中心，spreadCm 为 1σ。
    ///
    /// - Parameter headingUnknown: 位置已知但朝向不知道（或冷启动）。此时粒子的航向偏差在整圆上均匀取值。
    /// - Parameter priorFraction: 朝向不知道时，有一部分粒子仍按惯导给的方向（偏差 1σ = `initialHeadingBiasSigmaDeg`），
    ///   其余在整圆上均匀。惯导方向来自罗盘 + 地图朝向时设 0.5 左右；完全没有参考时设 0。
    /// - Parameter walkableTries: 给了 start 时，撒到不可走区域的粒子重新抽几次（0 = 原有行为：直接挪到 3 m 内最近的可走点）。
    ///   撒得很开（例如 Wi-Fi 粗定位，σ 8 m）时用：挪到最近可走点会把粒子堆在通道边上。
    public func reset(start: Point2?, spreadCm: Double = 150, headingUnknown: Bool = false, priorFraction: Double = 0,
                      walkableTries: Int = 0) {
        pathSinceResetCm = start == nil ? 0 : 3000     // 已知起点：不用等走够路
        sinceFixCm = 0
        stationaryFrozen = false
        frozenBuffer.removeAll()
        recentTotals = []
        magneticWeight = 1
        coldStart = start == nil
        self.headingUnknown = (start == nil || headingUnknown) && config.uniformHeadingWhenUnknown
        firstUpdateDone = false
        lowStreak = 0
        let n = max(coldStart ? config.coldStartParticleCount : config.particleCount, 10)
        xs = [Double](repeating: 0, count: n)
        ys = xs
        bias = xs
        scale = [Double](repeating: 1, count: n)
        ema0 = [Double](repeating: .nan, count: n); ema1 = ema0; ema2 = ema0
        off0 = ema0; off1 = ema0; off2 = ema0
        offP = nil
        particleOffsetWasActive = false
        obsEma = nil
        offsetEst = nil
        offsetResiduals.removeAll()
        logw = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var p: Point2
            if let s = start {
                p = Point2(s.x + rng.normal() * spreadCm, s.y + rng.normal() * spreadCm)
                if let w = walkable {
                    var k = 0
                    while k < walkableTries && !w.isWalkable(p) {
                        p = Point2(s.x + rng.normal() * spreadCm, s.y + rng.normal() * spreadCm)
                        k += 1
                    }
                    if !w.isWalkable(p) { p = w.nearestWalkable(to: p, radiusCm: 300) ?? s }
                }
            } else {
                p = randomPosition()
            }
            xs[i] = min(max(p.x, 0), field.widthCm)
            ys[i] = min(max(p.y, 0), field.heightCm)
            let usePrior = !self.headingUnknown || Double(i) < Double(n) * min(max(priorFraction, 0), 1)
            bias[i] = usePrior ? rng.normal() * config.initialHeadingBiasSigmaDeg * Double.pi / 180
                               : (rng.uniform() * 2 - 1) * Double.pi
            scale[i] = 1 + rng.normal() * config.initialScaleSigma
        }
        travelledCm = 0
        featureSum = MagneticFeature(total: 0, vertical: 0, horizontal: 0)
        featureCount = 0
        trustSum = 0
        committed = start
        startedFromPrior = start != nil
        lastGoodFix = start
        sinceGoodCm = 0
        switchStreak = 0
        holdingAgainstFar = false
        lastCenter = nil
        motionSinceUpdate = .zero
        clearLateral()
        updateCount = 0
        lastEffectiveRatio = 1
        convergedStreak = 0
        hasConverged = !coldStart
        externalPriorApplied = false
        searchPathCm = 0
        carryMode = .unknown
        lostSuppressRemainingCm = 0
        challenger = nil
        duelLogRatio = 0
        duelUpdates = 0
    }

    /// 是否已经收敛（有把握）
    public var isConverged: Bool { hasConverged }

    /// 外部判断「现在不在采集过的区域」（例如听到的标签大多不在指纹里）时设为 true：不允许收敛，
    /// 宁可不显示位置，也不在别处「定」一个错的。
    public var convergenceBlocked = false
    /// 有标签约束时（BLEAssist 设）：没有磁场数据的地方不罚。全场只有一小部分采过磁场，重罚会把粒子都推到
    /// 采过的地方，人在没采过的地方时就会「先漂到别处、走几步再被标签拉回来」；标签全场都有，交给标签定。
    public var missingDataPenaltyOverride: Double?
    /// 外部（BLEAssist）给的：当前位置落在几成强标签的范围里；nil = 不知道
    public var externalAgreement: Double?
    /// 当前地磁权重（0…1，adaptiveMagWeight 打开时才变），和它的各项因子（调试 / 日志用）
    public private(set) var magneticWeight = 1.0
    public private(set) var magWeightFactors: (coverage: Double, path: Double, info: Double, agree: Double) = (1, 1, 1, 1)
    private var pathSinceResetCm = 0.0
    /// 上一次定位依据（reset 给了起点、收敛、换成挑战者）之后走过的推算路程（cm），报的不确定度用（见 `ReportedUncertainty`）
    public private(set) var sinceFixCm = 0.0
    private var recentTotals: [Double] = []
    private var weightUpdates = 0

    /// 外部判断「定错了」（例如蓝牙粗定位持续离得很远）：退回没把握的状态，重新找。
    /// 粒子不清空，靠后面的观测和外部粗定位把它们拉回去。
    /// 不做局部找回：最后一次可靠位置就是刚被否定的那个，围着它找等于往回拉。
    /// - Parameter local: true 且是已知起点开始、打开了 localRecovery 时，只在最后一次可靠位置附近找回（和自己丢了一样），
    ///   不全图找；用于外部证据（跟踪时的蓝牙）只说明「不太对」、但不足以否定整个跟踪的情况。
    public func declareLost(local: Bool) {
        guard local, config.localRecovery, startedFromPrior, hasConverged else { declareLost(); return }
        let fix = lastGoodFix ?? committed
        loseTrack()
        lastGoodFix = fix
        sinceGoodCm = 0
    }

    public func declareLost() {
        pathSinceResetCm = 0
        searchPathCm = 0
        recentTotals = []
        hasConverged = false
        convergedStreak = 0
        committed = nil
        switchStreak = 0
        holdingAgainstFar = false
        lastGoodFix = nil
        sinceGoodCm = 0
    }

    /// 运动来源换了（视觉里程计 ↔ 计步）：跟踪配置档换成对应的参数，粒子的航向偏差 / 步长比例按新来源的初始 1σ
    /// 再撒开一些（两路的误差互不相关，之前学到的偏差不能直接沿用）。不是跟踪档（冷启动）或来源没变时什么都不做。
    public func setOdometry(_ o: OdometrySource) {
        guard let cur = config.trackingOdometry, cur != o else { return }
        config.applyTrackingOdometry(o)
        let hs = config.initialHeadingBiasSigmaDeg * Double.pi / 180
        for i in 0..<xs.count {
            bias[i] += rng.normal() * hs
            scale[i] = min(max(scale[i] + rng.normal() * config.initialScaleSigma, config.scaleRange.lowerBound),
                           config.scaleRange.upperBound)
        }
    }

    /// 外部给的「粗位置」（蓝牙指纹）：每个粒子按离 `center` 的距离加权（高斯，σ = sigmaCm）。
    /// 还没收敛时再把权重最低的一部分粒子换成撒在 `center` 附近的新粒子（朝向全方向），冷启动几秒就能圈到对的区域。
    /// - Parameter weight: 0...1，收敛后应该给小一点（只当约束，不抢地磁的主导）。
    public func applyPositionPrior(_ center: Point2, sigmaCm: Double, weight: Double, injectFraction: Double = 0) {
        guard !xs.isEmpty, sigmaCm > 0, weight > 0 else { return }
        externalPriorApplied = true
        let s2 = 2 * sigmaCm * sigmaCm
        for i in 0..<xs.count {
            let dx = xs[i] - center.x, dy = ys[i] - center.y
            logw[i] += weight * -(dx * dx + dy * dy) / s2
        }
        if !hasConverged && injectFraction > 0 {
            let m = Int(Double(xs.count) * min(injectFraction, 0.5))
            let order = logw.indices.sorted { logw[$0] < logw[$1] }
            let floorW = logw.max() ?? 0
            for k in order.prefix(m) {
                var p = Point2(center.x + rng.normal() * sigmaCm, center.y + rng.normal() * sigmaCm)
                if let w = walkable, !w.isWalkable(p) { p = w.nearestWalkable(to: p, radiusCm: 300) ?? p }
                xs[k] = min(max(p.x, 0), field.widthCm)
                ys[k] = min(max(p.y, 0), field.heightCm)
                bias[k] = headingUnknown ? (rng.uniform() * 2 - 1) * Double.pi : rng.normal() * config.initialHeadingBiasSigmaDeg * Double.pi / 180
                scale[k] = 1 + rng.normal() * config.initialScaleSigma
                logw[k] = floorW - 2          // 新粒子先给一个中等偏低的权重，靠后面的地磁观测说话
                if k < ema0.count { ema0[k] = .nan; ema1[k] = .nan; ema2[k] = .nan }
                if k < off0.count { off0[k] = .nan; off1[k] = .nan; off2[k] = .nan }
            }
        }
        normalize()
    }

    /// 重尾的「粗位置」观测（Wi-Fi 指纹等，偶尔偏很远）：每个粒子按离 `center` 的距离加 Student-t 对数似然
    /// −(ν+1)/2 · ln(1 + (d/σ)²/ν) × weight。比高斯（applyPositionPrior）宽容：一次离谱的粗定位不会把对的粒子全压掉。
    /// 有效粒子数低了就重采样（不等下一次地磁更新）。
    public func applyRobustPositionPrior(_ center: Point2, sigmaCm: Double, nu: Double = 3, weight: Double = 1) {
        guard !xs.isEmpty, sigmaCm > 0, nu > 0, weight > 0 else { return }
        let inv = 1 / (sigmaCm * sigmaCm * nu), k = weight * (nu + 1) / 2
        for i in 0..<xs.count {
            let dx = xs[i] - center.x, dy = ys[i] - center.y
            logw[i] -= k * log(1 + (dx * dx + dy * dy) * inv)
        }
        normalize()
        lastEffectiveRatio = effectiveCount() / Double(xs.count)
        if lastEffectiveRatio < config.resampleThreshold { resample(to: xs.count) }
    }

    /// 全部粒子的加权平均位置、位置散布（cm，√(σx² + σy²)）和航向偏差的圆周标准差（度），不分簇。
    public func weightedSpread() -> (mean: Point2, spreadCm: Double, headingSpreadDeg: Double) {
        guard !xs.isEmpty else { return (.zero, .infinity, 180) }
        let mx = logw.max() ?? 0
        var sw = 0.0, sx = 0.0, sy = 0.0, sc = 0.0, ss = 0.0
        for i in xs.indices {
            let w = exp(logw[i] - mx)
            sw += w; sx += w * xs[i]; sy += w * ys[i]; sc += w * cos(bias[i]); ss += w * sin(bias[i])
        }
        let m = Point2(sx / sw, sy / sw)
        var v = 0.0
        for i in xs.indices {
            let w = exp(logw[i] - mx), dx = xs[i] - m.x, dy = ys[i] - m.y
            v += w * (dx * dx + dy * dy)
        }
        // 圆周标准差 √(−2 ln R)，R = 平均合向量长度
        let r = min(max((sc * sc + ss * ss).squareRoot() / sw, 1e-12), 1)
        return (m, (v / sw).squareRoot(), (-2 * log(r)).squareRoot() * 180 / Double.pi)
    }

    /// 航向偏差的加权直方图（整圆分 `bins` 格，第 k 格 = [−180° + k·360°/bins, …)，和为 1）。诊断用（hpass-eval --diag-out）
    public func headingBiasHistogram(bins: Int = 12) -> [Double] {
        let nb = max(bins, 1)
        var h = [Double](repeating: 0, count: nb)
        guard !xs.isEmpty else { return h }
        let mx = logw.max() ?? 0
        var tot = 0.0
        for i in xs.indices {
            let w = exp(logw[i] - mx)
            var a = bias[i].truncatingRemainder(dividingBy: 2 * Double.pi)
            if a < -Double.pi { a += 2 * Double.pi } else if a >= Double.pi { a -= 2 * Double.pi }
            h[min(Int((a + Double.pi) / (2 * Double.pi) * Double(nb)), nb - 1)] += w
            tot += w
        }
        return tot > 0 ? h.map { $0 / tot } : h
    }

    /// 标签范围约束：每片听到的标签都要求「人在它 rangeCm 以内」（按信号强弱定，实测 P90：−75 dBm 2.5 m、
    /// −80 3.2 m、−85 5 m、−90 8 m）。磁场平缓的地方几处长得像，粒子会被拉到别处；附近没有这片标签的位置直接被压下去。
    /// 每片标签的惩罚有上限 capLog（标签表个别位置不对、反射，不至于一片就把正确的位置否掉）。
    /// 还没定到时，把一部分最差的粒子撒到最强那片标签的范围里。
    public func applyTagRanges(_ tags: [(position: Point2, rangeCm: Double)], sigmaCm: Double = 150, capLog: Double = 3,
                               weight: Double = 1, injectFraction: Double = 0) {
        guard !xs.isEmpty, !tags.isEmpty, weight > 0 else { return }
        externalPriorApplied = true
        let s2 = 2 * sigmaCm * sigmaCm
        for i in 0..<xs.count {
            var pen = 0.0
            for t in tags {
                let d = ((xs[i] - t.position.x) * (xs[i] - t.position.x) + (ys[i] - t.position.y) * (ys[i] - t.position.y)).squareRoot()
                let e = d - t.rangeCm
                if e > 0 { pen += min(e * e / s2, capLog) }
            }
            logw[i] -= weight * pen
        }
        if !hasConverged && injectFraction > 0, let best = tags.min(by: { $0.rangeCm < $1.rangeCm }) {
            let m = Int(Double(xs.count) * min(injectFraction, 0.5))
            let order = logw.indices.sorted { logw[$0] < logw[$1] }
            let floorW = logw.max() ?? 0
            for k in order.prefix(m) {
                let a = rng.uniform() * 2 * Double.pi, r = best.rangeCm * rng.uniform().squareRoot()
                var p = Point2(best.position.x + cos(a) * r, best.position.y + sin(a) * r)
                if let w = walkable, !w.isWalkable(p) { p = w.nearestWalkable(to: p, radiusCm: 300) ?? p }
                xs[k] = min(max(p.x, 0), field.widthCm)
                ys[k] = min(max(p.y, 0), field.heightCm)
                bias[k] = headingUnknown ? (rng.uniform() * 2 - 1) * Double.pi : rng.normal() * config.initialHeadingBiasSigmaDeg * Double.pi / 180
                scale[k] = 1 + rng.normal() * config.initialScaleSigma
                logw[k] = floorW - 2
                if k < ema0.count { ema0[k] = .nan; ema1[k] = .nan; ema2[k] = .nan }
                if k < off0.count { off0[k] = .nan; off1[k] = .nan; off2[k] = .nan }
            }
        }
        normalize()
    }

    /// 确定的区域观测（读到货架标签、手机贴近蓝牙标签）：区域外的粒子按离区域的距离重罚（上限 capLog），
    /// 并把一部分最差的粒子撒进区域。已经定到、但当前估计离区域超过 relocateCm：说明定错了，先退回没把握，再多撒一些。
    /// - distance: 点到区域的距离（区域内为 0）；sample: 在区域里随机取一点
    /// - Returns: 是否判定为定错并重新定位
    @discardableResult
    public func applyRegion(distance: (Point2) -> Double, sample: () -> Point2, sigmaCm: Double = 80, capLog: Double = 12,
                            injectFraction: Double = 0.3, relocateCm: Double = 300) -> Bool {
        guard !xs.isEmpty else { return false }
        externalPriorApplied = true
        var wsum = 0.0, mx = 0.0, my = 0.0
        let mw = logw.max() ?? 0
        for i in xs.indices { let w = exp(logw[i] - mw); wsum += w; mx += w * xs[i]; my += w * ys[i] }
        let mean = Point2(mx / max(wsum, 1e-12), my / max(wsum, 1e-12))
        var relocated = false
        if hasConverged && distance(mean) > relocateCm { declareLost(); relocated = true }
        let s2 = 2 * sigmaCm * sigmaCm
        for i in xs.indices {
            let d = distance(Point2(xs[i], ys[i]))
            if d > 0 { logw[i] -= min(d * d / s2, capLog) }
        }
        let frac = hasConverged ? 0 : (relocated ? max(injectFraction, 0.5) : injectFraction)
        if frac > 0 {
            let m = Int(Double(xs.count) * min(frac, 0.6))
            let order = logw.indices.sorted { logw[$0] < logw[$1] }
            let top = logw.max() ?? 0
            for k in order.prefix(m) {
                var p = sample()
                if let w = walkable, !w.isWalkable(p) { p = w.nearestWalkable(to: p, radiusCm: 200) ?? p }
                xs[k] = min(max(p.x, 0), field.widthCm)
                ys[k] = min(max(p.y, 0), field.heightCm)
                bias[k] = headingUnknown ? (rng.uniform() * 2 - 1) * Double.pi : rng.normal() * config.initialHeadingBiasSigmaDeg * Double.pi / 180
                scale[k] = 1 + rng.normal() * config.initialScaleSigma
                logw[k] = top - 1
                if k < ema0.count { ema0[k] = .nan; ema1[k] = .nan; ema2[k] = .nan }
                if k < off0.count { off0[k] = .nan; off1[k] = .nan; off2[k] = .nan }
            }
        }
        normalize()
        return relocated
    }

    /// 送入一次惯导位移增量（cm，地图系）和这段时间内最新的磁场特征，返回当前估计。
    ///
    /// - Parameter trust: 这一刻磁场读数可信度 0...1（见 `MagneticTrustMonitor`）。
    ///   可信度低时观测更新的权重按比例缩小，为 0 时这段读数完全不参与；位置预测不受影响。
    @discardableResult
    public func step(delta: Point2, feature: MagneticFeature?, trust: Double = 1,
                     lateral: LateralObservation? = nil) -> MagneticEstimate {
        if stationaryFrozen {
            frozenBuffer.append((stationaryClockMs, delta))
            if frozenBuffer.count > 600 { frozenBuffer.removeFirst(frozenBuffer.count - 600) }
        }
        let dist = stationaryFrozen ? 0 : delta.length
        let updatesBefore = updateCount
        if let l = lateral {
            if let v = l.leftCm { latLeftSum += v; latLeftN += 1 }
            if let v = l.rightCm { latRightSum += v; latRightN += 1 }
            latHeadingSin += sin(l.headingRad); latHeadingCos += cos(l.headingRad); latN += 1
        }
        if dist > 0 {
            predict(delta: delta, dist: dist)
            // 认定的位置跟着粒子的平均位移走
            if let c = committed { committed = c + meanMotion }
            motionSinceUpdate = motionSinceUpdate + meanMotion
            if config.localRecovery && startedFromPrior {
                // 有把握（且没在走向丢失）时记下可靠位置；否则让它跟着推算走，并累计走过的路
                if hasConverged && lowStreak == 0, let c = committed {
                    lastGoodFix = c
                    sinceGoodCm = 0
                } else if let g = lastGoodFix {
                    lastGoodFix = g + meanMotion
                    sinceGoodCm += dist
                    // 走了这么远还没找回：最后的可靠位置本身可能就是错的（起点给错 / 早就锁错），改回全图找
                    if !hasConverged, let lim = config.localRecoveryGlobalAfterCm, sinceGoodCm >= lim {
                        lastGoodFix = nil
                        sinceGoodCm = 0
                        globalFallbackCount += 1
                    }
                }
            }
        }

        travelledCm += dist
        sinceFixCm += dist
        if let f = feature {
            let t = min(max(trust, 0), 1)
            featureSum = featureSum + f * t
            trustSum += t
            featureCount += 1
        }
        // 冷启动时站着不动也要先做一次观测更新：把「全图任何地方」缩小到「磁场长这样的地方」，走起来才有的放矢
        let firstDue = coldStart && !firstUpdateDone && featureCount >= 3
        let due = travelledCm >= config.updateDistanceCm || firstDue
        if due, config.lateralWeight > 0, raycaster != nil, latN > 0 {
            updateLateral()
        }
        if due, featureCount > 0 {
            if firstDue { firstUpdateDone = true }
            // 特征按可信度加权平均；整体似然再乘以平均可信度
            if trustSum > 1e-6 {
                update(feature: featureSum * (1 / trustSum), trust: trustSum / Double(featureCount))
            }
            travelledCm = 0
            featureSum = MagneticFeature(total: 0, vertical: 0, horizontal: 0)
            featureCount = 0
            trustSum = 0
        }
        if due { clearLateral() }
        if config.coldChallenger || challenger != nil {
            runChallenger(delta: stationaryFrozen ? .zero : delta, feature: feature, trust: trust, mainUpdated: updateCount != updatesBefore)
        }
        return estimate()
    }

    private func clearLateral() {
        latLeftSum = 0; latLeftN = 0; latRightSum = 0; latRightN = 0
        latHeadingSin = 0; latHeadingCos = 0; latN = 0
    }

    /// 横向距离观测：每个粒子在自己位置、自己的行进方向上射线投射，与实测的左右距离比较。
    private func updateLateral() {
        guard let rc = raycaster else { return }
        let left = latLeftN > 0 ? latLeftSum / Double(latLeftN) : nil
        let right = latRightN > 0 ? latRightSum / Double(latRightN) : nil
        guard left != nil || right != nil else { return }
        let heading = atan2(latHeadingSin, latHeadingCos)
        let maxCm = config.lateralMaxCm
        let nu = 4.0
        func t(_ d2: Double) -> Double { -(nu + 1) / 2 * log(1 + d2 / nu) }
        func side(_ measured: Double?, _ predicted: Double?) -> Double {
            switch (measured, predicted) {
            case let (m?, p?):
                let sigma = config.lateralSigmaCm + 0.15 * p
                let d = (m - p) / sigma
                return t(d * d)
            case (_?, nil): return -2           // 实测有墙，模型里这个位置前方没墙
            case (nil, let p?): return p < maxCm * 0.7 ? -1 : 0   // 模型里该有墙，实测没看到（可能被视野挡了，轻罚）
            default: return 0
            }
        }
        for i in 0..<xs.count {
            let h = heading + bias[i]
            let (pl, pr) = rc.lateral(from: Point2(xs[i], ys[i]), headingRad: h, maxCm: maxCm)
            logw[i] += config.lateralWeight * (side(left, pl) + side(right, pr)) / config.likelihoodTemperature
        }
        normalize()
        let neff = effectiveCount()
        lastEffectiveRatio = neff / Double(xs.count)
        if lastEffectiveRatio < config.resampleThreshold { resample(to: xs.count) }
    }

    // MARK: 预测

    private var meanMotion = Point2.zero

    /// 房间约束打开且可走区域带房间图时的房间图
    private var roomGraph: RoomGraph? { config.roomConstraints ? walkable?.rooms : nil }

    private func predict(delta: Point2, dist: Double) {
        pathSinceResetCm += dist
        if !hasConverged { searchPathCm += dist }
        if lostSuppressRemainingCm > 0 { lostSuppressRemainingCm = max(0, lostSuppressRemainingCm - dist) }
        var mx = 0.0, my = 0.0, mw = 0.0
        let distM = dist / 100
        let frac = hasConverged ? (config.convergedPositionNoiseFraction ?? config.positionNoiseFraction) : config.positionNoiseFraction
        let posSigma = frac * dist + config.positionNoiseFloorCm
        let biasWalk = config.headingBiasWalkDegPerM * Double.pi / 180 * distM.squareRoot()
        let scaleWalk = config.scaleWalkPerM * distM.squareRoot()
        let hs = config.corridorHeadingSigmaDeg * Double.pi / 180
        let useHeading = config.corridorHeadingWeight > 0 && dist >= 10
        for i in 0..<xs.count {
            bias[i] += rng.normal() * biasWalk
            scale[i] = min(max(scale[i] + rng.normal() * scaleWalk, config.scaleRange.lowerBound), config.scaleRange.upperBound)
            let c = cos(bias[i]), s = sin(bias[i])
            let dx = (delta.x * c - delta.y * s) * scale[i]
            let dy = (delta.x * s + delta.y * c) * scale[i]
            let old = Point2(xs[i], ys[i])
            var nx = old.x + dx + rng.normal() * posSigma
            var ny = old.y + dy + rng.normal() * posSigma
            if nx < 0 || nx > field.widthCm || ny < 0 || ny > field.heightCm {
                nx = min(max(nx, 0), field.widthCm)
                ny = min(max(ny, 0), field.heightCm)
                logw[i] -= 2           // 撞墙：扣分
            }
            var np = Point2(nx, ny)
            if let w = walkable {
                if !w.isWalkable(np) || !w.isSegmentClear(from: old, to: np) {
                    // 贴墙滑：整步走不过去时先试只走 x、再试只走 y（人沿墙 / 店铺边走，推算的方向偏了一点）
                    let slide = config.wallSlide
                        ? [Point2(np.x, old.y), Point2(old.x, np.y)].first { $0 != old && w.isWalkable($0) && w.isSegmentClear(from: old, to: $0) }
                        : nil
                    if let sp = slide, !(roomGraph?.crossesWithoutDoor(from: old, to: sp) ?? false) {
                        np = sp
                        logw[i] += config.wallSlidePenalty
                    } else {
                        np = old                      // 不能穿货架：原地不动并扣分
                        logw[i] += config.blockedPenalty
                    }
                } else if let g = roomGraph, g.crossesWithoutDoor(from: old, to: np) {
                    np = old                          // 不经门换房间：当穿墙，原地不动，再多扣一笔
                    logw[i] += config.blockedPenalty + config.roomCrossingPenalty
                } else if useHeading, let ax = w.axisAngle(at: np) {
                    // 行走方向相对通道轴线的夹角（模 π：沿轴线正反两个方向都可以）
                    let walk = atan2(dy, dx)
                    var d = abs(walk - ax).truncatingRemainder(dividingBy: Double.pi)
                    d = min(d, Double.pi - d)
                    logw[i] -= config.corridorHeadingWeight * 0.5 * (d / hs) * (d / hs)
                }
            }
            let w = exp(logw[i])
            mx += (np.x - old.x) * w; my += (np.y - old.y) * w; mw += w
            xs[i] = np.x
            ys[i] = np.y
        }
        meanMotion = mw > 0 ? Point2(mx / mw, my / mw) : delta
    }

    // MARK: 观测更新

    private func update(feature f: MagneticFeature, trust: Double = 1) {
        let nu = 4.0
        let w = config.featureWeights
        let floor2 = config.observationSigmaFloorUT * config.observationSigmaFloorUT
        func t(_ d2: Double) -> Double { -(nu + 1) / 2 * log(1 + d2 / nu) }

        // 没有地图数据的粒子：
        // - 还没收敛（冷启动）时重罚，免得定到没采集过的地方；
        // - 已经收敛后不奖不罚（给有数据粒子的平均似然），否则路上一个数据空洞就会把整团粒子「赶」回别处有数据的地方
        var lls = [Double?](repeating: nil, count: xs.count)
        var sumLL = 0.0, sumW = 0.0
        let a = 1 / max(config.offsetWindowUpdates, 1)
        let poTemp = particleOffsetTemperatureInUse
        if (poTemp != nil) != particleOffsetWasActive {
            // 开关变了（计步 ↔ 视觉里程计）：粒子偏移从头估；关掉时原来的偏移估计（offsetEst）留着，起伏平均从头攒
            off0 = [Double](repeating: .nan, count: xs.count); off1 = off0; off2 = off0
            offP = nil
            if poTemp == nil {
                ema0 = off0; ema1 = off0; ema2 = off0
                obsEma = nil
                offsetResiduals.removeAll()
            }
            particleOffsetWasActive = poTemp != nil
        }
        let usesEma = (config.offsetInvariant || config.hybridOffset) && poTemp == nil
        // 读数沿路的平均（原始读数）
        if usesEma {
            if let o = obsEma { obsEma = (o.0 + a * (f.total - o.0), o.1 + a * (f.vertical - o.1), o.2 + a * (f.horizontal - o.2)) }
            else { obsEma = (f.total, f.vertical, f.horizontal) }
        }
        // 混合模式：没定到 / 丢了 → 按起伏找；刚定到 → 偏移 = 读数平均 − 粒子沿路地图平均（按权重）；之后按绝对值比
        if config.hybridOffset && poTemp == nil {
            if !hasConverged {
                offsetEst = nil
                offsetResiduals.removeAll()
            } else if offsetEst == nil, config.offsetWarmupUpdates <= 0, let o = obsEma {
                var w0 = 0.0, s0 = 0.0, s1 = 0.0, s2 = 0.0
                let mx = logw.max() ?? 0
                for i in 0..<xs.count where !ema0[i].isNaN {
                    let wi = exp(logw[i] - mx); w0 += wi; s0 += wi * ema0[i]; s1 += wi * ema1[i]; s2 += wi * ema2[i]
                }
                if w0 > 0 { offsetEst = MagneticFeature(total: o.0 - s0 / w0, vertical: o.1 - s1 / w0, horizontal: o.2 - s2 / w0) }
            }
        }
        if config.adaptiveMagWeight { updateMagWeight(f) }
        // 携带模式刚重撒（航向偏差重新未知）：虽然还报位置，但证据权重按「找位置」给满，不打跟踪时的折扣，
        // 不然整圆撒开的航向要走很远才挑得出来
        let reacquiring = lostSuppressRemainingCm > 0 && hasConverged && !coldStartGateActive
        let mw = config.adaptiveMagWeight ? magneticWeight : (hasConverged && !reacquiring ? config.convergedMagWeight : 1)
        let rel = config.hybridOffset ? offsetEst == nil : config.offsetInvariant
        let fAbs = offsetEst.map { f - $0 } ?? f
        let slack2 = config.offsetSlackUT * config.offsetSlackUT
        // 冷启动收敛门起作用时（只靠地磁找位置）可以用更高的温度：相邻几次读数高度相关，按独立算会过度自信，
        // 峰的权重比就量不准。再按残差相关长度折算（跟踪档；0 = 原有行为）
        let baseTemp = coldStartGateActive && config.coldSearchTemperature > 0 ? config.coldSearchTemperature : config.likelihoodTemperature
        // 相关长度折算是给稳定跟踪用的（地图误差成片）；携带模式刚重撒时是在几米到几十米外的假设之间挑，
        // 残差差别大、彼此独立，按「找位置」的强度更新，不然走反的那团粒子要几十米才死
        let corrFactor = reacquiring ? 1 : max(config.magneticCorrelationCm / max(config.updateDistanceCm, 1), 1)
        let temp = baseTemp * corrFactor
        if let poTemp {
            // 强度全由温度定（标定量的就是「权重 1 / 温度」）：不乘 convergedMagWeight，配置档钉死的权重（Wi-Fi 冷启动档的 0）照乘
            let pw = config.adaptiveMagWeight || config.pinnedConvergedMagWeight != nil ? mw : 1
            particleOffsetLikelihoods(f, weight: pw * trust / poTemp, lls: &lls, sumLL: &sumLL, sumW: &sumW)
        } else {
            for i in 0..<xs.count {
                guard let m = field.sample(at: Point2(xs[i], ys[i])) else { continue }
                let v0 = m.sigma.total * m.sigma.total + floor2
                let v1 = m.sigma.vertical * m.sigma.vertical + floor2
                let v2 = m.sigma.horizontal * m.sigma.horizontal + floor2
                if usesEma {
                    // 粒子沿自己的路累积地图的平均；新粒子（NaN）从当前值开始
                    if ema0[i].isNaN { ema0[i] = m.mean.total; ema1[i] = m.mean.vertical; ema2[i] = m.mean.horizontal }
                    else {
                        ema0[i] += a * (m.mean.total - ema0[i]); ema1[i] += a * (m.mean.vertical - ema1[i]); ema2[i] += a * (m.mean.horizontal - ema2[i])
                    }
                }
                var ll: Double
                if rel, let o = obsEma {
                    let r0 = (f.total - o.0) - (m.mean.total - ema0[i])
                    let r1 = (f.vertical - o.1) - (m.mean.vertical - ema1[i])
                    let r2 = (f.horizontal - o.2) - (m.mean.horizontal - ema2[i])
                    ll = w.0 * t(r0 * r0 / v0) + w.1 * t(r1 * r1 / v1) + w.2 * t(r2 * r2 / v2)
                    if config.absoluteWeight > 0 {
                        let d0 = f.total - m.mean.total, d1 = f.vertical - m.mean.vertical, d2 = f.horizontal - m.mean.horizontal
                        ll += config.absoluteWeight * (w.0 * t(d0 * d0 / (v0 + slack2)) + w.1 * t(d1 * d1 / (v1 + slack2)) + w.2 * t(d2 * d2 / (v2 + slack2)))
                    }
                    ll *= mw * trust / temp
                } else {
                    let d0 = fAbs.total - m.mean.total, d1 = fAbs.vertical - m.mean.vertical, d2 = fAbs.horizontal - m.mean.horizontal
                    ll = mw * trust * (w.0 * t(d0 * d0 / v0) + w.1 * t(d1 * d1 / v1) + w.2 * t(d2 * d2 / v2)) / temp
                }
                lls[i] = ll
                let pw = exp(logw[i])
                sumLL += pw * ll
                sumW += pw
            }
        }
        var neutral = sumW > 0 ? sumLL / sumW : 0
        // 覆盖门：已收敛时按「有数据粒子的权重占比」给地磁打折，大多落在没采过的地方时完全靠推算
        var gate = 1.0
        if config.coverageGatedMagWeight && hasConverged {
            var total = 0.0
            for v in logw { total += exp(v) }
            let share = total > 0 ? sumW / total : 0
            gate = min(max((share - 0.5) / 0.4, 0), 1)
            neutral *= gate
        }
        // 局部找回时没有数据的粒子也不罚（和已收敛时一样给平均值）：找回范围本来就只在附近
        // 没数据的罚分代替的是一次地磁观测，按同一个相关长度折算（不然地磁变软之后它相对重了 corrFactor 倍）。
        // 撞墙 / 走向这些运动约束不折算：它们是地图的物理约束，不是地磁证据
        let missing = (hasConverged || recoveringLocally) ? neutral : (missingDataPenaltyOverride ?? config.missingDataPenalty) / corrFactor
        for i in 0..<xs.count {
            if let ll = lls[i] {
                logw[i] += ll * gate
            } else {
                logw[i] += missing
            }
        }
        lastLogEvidence = normalize()
        // 混合模式：定到之后慢慢跟踪偏移（读数 − 地图在当前位置的值）
        if poTemp != nil {
            offsetEst = weightedParticleOffset()
        } else if config.hybridOffset, config.offsetWarmupUpdates > 0 {
            updateRobustOffset(f)
        } else if config.hybridOffset, let off = offsetEst, let c = committed ?? lastCenter, let m = field.sample(at: c) {
            let r = config.offsetTrackRate
            offsetEst = MagneticFeature(total: off.total + r * ((f.total - m.mean.total) - off.total),
                                        vertical: off.vertical + r * ((f.vertical - m.mean.vertical) - off.vertical),
                                        horizontal: off.horizontal + r * ((f.horizontal - m.mean.horizontal) - off.horizontal))
        }
        updateCount += 1
        let neff = effectiveCount()
        lastEffectiveRatio = neff / Double(xs.count)
        if lastEffectiveRatio < config.resampleThreshold { resample(to: xs.count) }
        decideCluster()
        checkConvergence()
    }

    /// 稳健偏移估计：定到之后每次更新记一条残差（读数 − 认定位置的地图值），攒够 `offsetWarmupUpdates` 条再给偏移，
    /// 偏移取最近 `offsetMedianWindow` 条的逐分量中位数。没定到 / 丢了时清空（回到按起伏找）。
    private func updateRobustOffset(_ f: MagneticFeature) {
        guard hasConverged else { offsetResiduals.removeAll(); offsetEst = nil; return }
        guard let c = committed ?? lastCenter, let m = field.sample(at: c) else { return }
        offsetResiduals.append(f - m.mean)
        let win = max(config.offsetMedianWindow, config.offsetWarmupUpdates, 1)
        if offsetResiduals.count > win { offsetResiduals.removeFirst(offsetResiduals.count - win) }
        guard offsetResiduals.count >= config.offsetWarmupUpdates else { return }
        func med(_ k: KeyPath<MagneticFeature, Double>) -> Double {
            let v = offsetResiduals.map { $0[keyPath: k] }.sorted()
            return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
        }
        offsetEst = MagneticFeature(total: med(\.total), vertical: med(\.vertical), horizontal: med(\.horizontal))
    }

    /// 每个粒子自己估偏移（`particleOffsetFilter` / `particleOffsetFromMap`）：残差 r = 读数 − 粒子处地图，新息 ν = r − b̂，
    /// 似然 t4(ν² / S)（S = P + q + R + 格子方差，三个分量按 featureWeights 加权）× weight（已除温度）；再用 ν 更新 b̂。
    /// 单个分量的算法和地图标定共用（`ParticleOffsetModel`）。
    /// 还没有偏移估计的粒子（刚撒 / 注入的）：b̂ 取它自己的残差，这一次给其余粒子的平均似然（对它的偏移还一无所知，不奖不罚）。
    /// 没有地图数据的粒子 lls 留 nil（由调用方按原规则处理），b̂ 不动。
    /// 计算量：每个粒子每次更新多 3 次乘加和 3 个 Double 的状态（1500 粒子 = 36 KB），和原来的地图插值相比可以忽略。
    private func particleOffsetLikelihoods(_ f: MagneticFeature, weight: Double, lls: inout [Double?],
                                           sumLL: inout Double, sumW: inout Double) {
        let w = config.featureWeights
        let r = max(config.particleOffsetWhiteVarUT2, 1e-6)
        // 随机游走按这次更新实际走过的路折算（更新间隔 ≥ updateDistanceCm）
        let q = max(config.particleOffsetWalkVarUT2, 0) * max(travelledCm / max(config.updateDistanceCm, 1), 1)
        let prior = offP.map { ($0.0 + q, $0.1 + q, $0.2 + q) }
        let k = weight
        func comp(_ res: Double, _ b: inout Double, _ pm: Double, _ s: Double, _ wc: Double) -> Double {
            wc * ParticleOffsetModel.component(residual: res, offset: &b, priorVar: pm, whiteVar: r, cellSigma: s)
        }
        var fresh: [Int] = []
        for i in 0..<xs.count {
            guard let m = field.sample(at: Point2(xs[i], ys[i])) else { continue }
            let r0 = f.total - m.mean.total, r1 = f.vertical - m.mean.vertical, r2 = f.horizontal - m.mean.horizontal
            guard let pm = prior, !off0[i].isNaN else {
                off0[i] = r0; off1[i] = r1; off2[i] = r2
                fresh.append(i)
                continue
            }
            let ll = k * (comp(r0, &off0[i], pm.0, m.sigma.total, w.0) + comp(r1, &off1[i], pm.1, m.sigma.vertical, w.1)
                          + comp(r2, &off2[i], pm.2, m.sigma.horizontal, w.2))
            lls[i] = ll
            let pw = exp(logw[i])
            sumLL += pw * ll
            sumW += pw
        }
        let avg = sumW > 0 ? sumLL / sumW : 0
        for i in fresh {
            lls[i] = avg
            let pw = exp(logw[i])
            sumLL += pw * avg
            sumW += pw
        }
        // 共用方差：卡尔曼更新（只按 R，不含各粒子的格子方差）；第一次 = R（新粒子的偏移就是它自己的残差）
        offP = prior.map { (ParticleOffsetModel.posterior(priorVar: $0.0, whiteVar: r), ParticleOffsetModel.posterior(priorVar: $0.1, whiteVar: r),
                            ParticleOffsetModel.posterior(priorVar: $0.2, whiteVar: r)) } ?? (r, r, r)
    }

    /// 粒子偏移估计的加权平均（每个粒子自己估偏移时；`currentOffset`，以及换回原来的似然时接着用）
    private func weightedParticleOffset() -> MagneticFeature? {
        let mx = logw.max() ?? 0
        var sw = 0.0, s0 = 0.0, s1 = 0.0, s2 = 0.0
        for i in 0..<xs.count where i < off0.count && !off0[i].isNaN {
            let wi = exp(logw[i] - mx)
            sw += wi; s0 += wi * off0[i]; s1 += wi * off1[i]; s2 += wi * off2[i]
        }
        return sw > 0 ? MagneticFeature(total: s0 / sw, vertical: s1 / sw, horizontal: s2 / sw) : nil
    }

    /// 决定认定哪个簇：离当前认定位置近就直接跟；远的另一个簇要连续确认几次才切过去。
    private func decideCluster() {
        holdingAgainstFar = false
        let best = cluster(from: nil)
        guard hasConverged, let c = committed else { committed = best.center; switchStreak = 0; return }
        // 携带模式刚重撒：位置本来就在重新挑，不走远跳的 15 次确认（那是给稳定跟踪防「长得像」用的），
        // 但也不每次都跳到最重的簇（两团粒子势均力敌时估计会来回闪）：另一团明显更重才换过去
        if lostSuppressRemainingCm > 0 {
            switchStreak = 0
            if best.center.distance(to: c) <= config.jumpGateCm { committed = best.center; return }
            let mine = cluster(from: c)
            committed = (best.mass > max(1.5 * mine.mass, 0.4) || mine.mass < config.keepClusterMinMass) ? best.center : mine.center
            return
        }
        if best.center.distance(to: c) <= config.jumpGateCm {
            committed = best.center
            switchStreak = 0
            return
        }
        let mine = cluster(from: c)
        // 跟踪策略：只有新簇离得近才「立刻切」，远处的簇照样要连续确认
        let near = !config.keepClusterRequiresNear || best.center.distance(to: c) <= 2 * config.jumpGateCm
        if mine.mass < config.keepClusterMinMass && near {
            committed = best.center                 // 原来的簇已经快没了，不再坚持
            switchStreak = 0
            return
        }
        switchStreak += 1
        if switchStreak >= config.jumpConfirmUpdates {
            committed = best.center
            switchStreak = 0
        } else {
            committed = mine.center
            // 原来的簇已经很轻、远处的簇还在确认：这几次不算「走向丢失」，否则判丢后估计直接取远处的簇，绕过确认
            if config.keepClusterRequiresNear && mine.mass < config.keepClusterMinMass { holdingAgainstFar = true }
        }
    }

    /// 收敛与丢失：
    /// - 没收敛：连续几次更新都落在一个小簇里就算收敛，冷启动时同时把粒子数缩到 `particleCount`；
    /// - 已收敛：置信度持续很低（走进没采过的地方、磁场对不上）就算丢失，`converged` 变回 false。
    private func checkConvergence() {
        let e = estimate(reportingUncertainty: false)
        // 簇中心应当按实际走的方向和距离移动；凑巧在别处匹配上的「簇」会忽东忽西，不算
        let consistent = lastCenter.map { ($0 + motionSinceUpdate).distance(to: e.position) <= 100 } ?? false
        lastCenter = e.position
        motionSinceUpdate = .zero
        let unc = e.clusterUncertaintyCm ?? e.uncertaintyCm
        let good = unc <= config.convergedUncertaintyCm && e.confidence >= config.convergedConfidence
            && !convergenceBlocked
        if !hasConverged {
            if magOnlyColdStartSuppressed { convergedStreak = 0; return }
            let gated = coldStartGateActive
            let pass = good && consistent && (!gated || coldGatePasses(e))
            convergedStreak = pass ? convergedStreak + 1 : 0
            if convergedStreak >= (gated ? max(config.coldMinStreak, 1) : 3) {
                hasConverged = true
                lowStreak = 0
                sinceFixCm = 0
                if coldStart && xs.count > config.particleCount { resample(to: config.particleCount) }
            }
            return
        }
        if holdingAgainstFar { return }       // 远跳确认期间：丢失计数不动（远跳要么确认、要么原来的簇恢复）
        if lostSuppressRemainingCm > 0 { lowStreak = 0; return }   // 携带模式刚重撒：航向整圆撒开后置信度必然先掉，不算丢
        let bad = e.confidence < effectiveLostConfidence || unc > config.lostUncertaintyCm
        lowStreak = bad ? lowStreak + 1 : 0
        if lowStreak >= config.lostUpdates { loseTrack() }
    }

    /// 冷启动收敛门（只在 `coldStartGateActive` 时调用）：走够了路、粒子不是少数几个撑着、
    /// 最重的簇明显压过远处的第二个簇。
    private func coldGatePasses(_ e: MagneticEstimate) -> Bool {
        if searchPathCm < config.coldMinPathCm { return false }
        if lastEffectiveRatio < config.coldMinEffectiveRatio { return false }
        if config.coldModeRatio > 0 {
            let best = cluster(from: nil)
            let other = secondModeMass(awayFrom: best.center, separationCm: config.coldModeSeparationCm)
            if best.mass < config.coldModeRatio * other { return false }
        }
        return true
    }

    /// 离 `c` 超过 separationCm 的最重的 2 m 方块为种子做均值漂移，返回那个簇的权重占比（没有返回 0）。
    func secondModeMass(awayFrom c: Point2, separationCm: Double) -> Double {
        let n = xs.count
        let mx = logw.max() ?? 0
        var mass: [Int: Double] = [:], sumX: [Int: Double] = [:], sumY: [Int: Double] = [:]
        let bin = 200.0
        for i in 0..<n {
            let w = exp(logw[i] - mx)
            let k = Int(ys[i] / bin) * 100_000 + Int(xs[i] / bin)
            mass[k, default: 0] += w
            sumX[k, default: 0] += w * xs[i]
            sumY[k, default: 0] += w * ys[i]
        }
        // 按权重从大到小，取第一个中心离 c 够远的方块（权重相同时按键排序，结果不依赖字典顺序）
        let order = mass.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        for (k, m) in order where m > 0 {
            let p = Point2(sumX[k]! / m, sumY[k]! / m)
            if p.distance(to: c) > separationCm { return cluster(from: p).mass }
        }
        return 0
    }

    /// 自己判定丢了（置信度持续低）：退回没把握的状态；已知起点开始时保留最后一次可靠位置做局部找回。
    func loseTrack() {
        searchPathCm = 0
        hasConverged = false
        convergedStreak = 0
        lowStreak = 0
        holdingAgainstFar = false
        lostCount += 1
    }

    /// 测试用：每个粒子的航向偏差（rad）。
    func headingBiasesForTesting() -> [Double] { bias }

    /// 测试用：把权重最低的一部分粒子挪到 `center` 附近（航向偏差、步长比例不变），模拟远处长出一个簇。
    func moveParticlesForTesting(fraction: Double, to center: Point2, spreadCm: Double) {
        let m = Int(Double(xs.count) * min(max(fraction, 0), 1))
        let order = logw.indices.sorted { logw[$0] < logw[$1] }
        for k in order.prefix(m) {
            xs[k] = min(max(center.x + rng.normal() * spreadCm, 0), field.widthCm)
            ys[k] = min(max(center.y + rng.normal() * spreadCm, 0), field.heightCm)
        }
    }

    /// 累计丢失过几次。
    public private(set) var lostCount = 0

    // MARK: 冷启动挑战者（见 `MagneticConfig.coldChallenger`）

    /// 后台的冷启动搜索（只在打开了 coldChallenger、只靠地磁冷启动定到之后才有）
    private var challenger: MagneticLocalizer?
    private var duelLogRatio = 0.0
    private var duelUpdates = 0
    /// 挑战者的随机种子（不动主滤波器自己的随机数序列：没换过时和不开挑战者的结果一样）
    private var challengerSeed: UInt64 = 0
    /// 换成挑战者的次数 / 比过证据的轮数（诊断、测试）
    public private(set) var challengerSwaps = 0
    public private(set) var challengerDuels = 0
    /// 挑战者正在后台搜
    public var challengerActive: Bool { challenger != nil }
    /// 最近一次观测更新的对数证据 log Σ w·L（含上次归一化之后运动约束的扣分），比证据用
    public private(set) var lastLogEvidence = 0.0

    /// 挑战者该不该跑：冷启动、已定到、没用过外部位置先验
    private var challengerEligible: Bool {
        config.coldChallenger && coldStart && !startedFromPrior && hasConverged && !externalPriorApplied
    }

    /// 从零开始一轮后台搜索。观测更新的节拍对齐主滤波器（走过的路、攒的特征照抄），两边在同一时刻、同一段读数上更新
    private func spawnChallenger() {
        var c = config
        c.coldChallenger = false
        if let n = config.coldChallengerParticleCount { c.coldStartParticleCount = n }
        challengerSeed &+= 0x9E37_79B9_7F4A_7C15
        let ch = challenger ?? MagneticLocalizer(field: field, walkable: walkable, config: c, seed: challengerSeed)
        ch.config = c
        ch.reset(start: nil, headingUnknown: true)
        ch.carryMode = carryMode
        ch.travelledCm = travelledCm
        ch.featureSum = featureSum
        ch.featureCount = featureCount
        ch.trustSum = trustSum
        ch.firstUpdateDone = true
        challenger = ch
        duelLogRatio = 0
        duelUpdates = 0
    }

    /// 主滤波器这一步之后：挑战者走同一步；定到了就在同一段观测上和主滤波器比证据
    private func runChallenger(delta: Point2, feature: MagneticFeature?, trust: Double, mainUpdated: Bool) {
        guard challengerEligible else {
            challenger = nil
            duelLogRatio = 0
            duelUpdates = 0
            return
        }
        guard let ch = challenger else { spawnChallenger(); return }
        let cu = ch.updateCount
        ch.step(delta: delta, feature: feature, trust: trust)
        guard ch.hasConverged else { duelLogRatio = 0; duelUpdates = 0; return }
        if ch.estimate(reportingUncertainty: false).position.distance(to: estimate(reportingUncertainty: false).position) <= config.coldChallengerSeparationCm {
            spawnChallenger()           // 印证了主滤波器：重新从零搜
            return
        }
        guard mainUpdated, ch.updateCount != cu else { return }
        if duelUpdates == 0 { challengerDuels += 1 }
        duelLogRatio += ch.lastLogEvidence - lastLogEvidence
        duelUpdates += 1
        if duelLogRatio >= config.coldChallengerLogBayesFactor && !stationaryFrozen {
            adopt(ch)
            challengerSwaps += 1
            spawnChallenger()
        } else if duelLogRatio <= -config.coldChallengerLogBayesFactor || duelUpdates >= config.coldChallengerWindowUpdates {
            spawnChallenger()
        }
    }

    /// 换成挑战者的粒子和匹配状态（仍是「冷启动后已定到」；携带模式、静止冻结、找回这些主滤波器自己的状态不动）
    private func adopt(_ o: MagneticLocalizer) {
        xs = o.xs; ys = o.ys; bias = o.bias; scale = o.scale; logw = o.logw
        ema0 = o.ema0; ema1 = o.ema1; ema2 = o.ema2
        off0 = o.off0; off1 = o.off1; off2 = o.off2
        offP = o.offP
        particleOffsetWasActive = o.particleOffsetWasActive
        obsEma = o.obsEma
        offsetEst = o.offsetEst
        offsetResiduals = o.offsetResiduals
        committed = o.committed
        lastCenter = o.lastCenter
        motionSinceUpdate = o.motionSinceUpdate
        meanMotion = o.meanMotion
        lastEffectiveRatio = o.lastEffectiveRatio
        recentTotals = o.recentTotals
        sinceFixCm = o.sinceFixCm
        switchStreak = 0
        holdingAgainstFar = false
        lowStreak = 0
    }

    /// 减去最大值再归一到 Σw = 1（对数域），防止下溢。
    /// 按场景算地磁权重（每 5 次观测更新一次）。找位置时用下面四项相乘，已经定到时基本全给（见函数末尾）：
    /// - 磁场图密度：粒子加权中心 4 m 内有数据的格子比例（< 20% 几乎不用地磁，≥ 70% 全用）；
    /// - 走过的路：冷启动后走得越长，磁场序列越有区分度（< 5 m 只给一半，20 m 后全给）；
    /// - 磁场起伏：最近约 20 次读数 |B| 的标准差（< 1 µT 很平、匹配不出东西 → 打折）；
    /// - 标签一致：当前位置落在几成强标签范围里（≤ 30% 只给三成）。
    private func updateMagWeight(_ f: MagneticFeature) {
        recentTotals.append(f.total)
        if recentTotals.count > 20 { recentTotals.removeFirst(recentTotals.count - 20) }
        weightUpdates += 1
        guard weightUpdates % 5 == 0 || magneticWeight == 1 && weightUpdates < 5 else { return }
        // 加权中心
        let mx = logw.max() ?? 0
        var sw = 0.0, cx = 0.0, cy = 0.0
        for i in xs.indices { let w = exp(logw[i] - mx); sw += w; cx += w * xs[i]; cy += w * ys[i] }
        let c = Point2(cx / max(sw, 1e-12), cy / max(sw, 1e-12))
        var n = 0, cov = 0
        for gx in stride(from: -400.0, through: 400, by: 100) {
            for gy in stride(from: -400.0, through: 400, by: 100) where gx * gx + gy * gy <= 160_000 {
                let p = Point2(c.x + gx, c.y + gy)
                if let w = walkable, !w.isWalkable(p) { continue }
                n += 1
                if field.sample(at: p) != nil { cov += 1 }
            }
        }
        let coverage = n > 0 ? Double(cov) / Double(n) : 0
        let fCov = min(max((coverage - 0.2) / 0.5, 0), 1)
        let fPath = min(1, 0.5 + pathSinceResetCm / 4000)
        var fInfo = 1.0
        if recentTotals.count >= 10 {
            let m = recentTotals.reduce(0, +) / Double(recentTotals.count)
            let sd = (recentTotals.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(recentTotals.count)).squareRoot()
            fInfo = min(1, 0.4 + sd / 2.5)
        }
        let fAgree = externalAgreement.map { min(max(($0 - 0.3) / 0.4, 0), 1) * 0.7 + 0.3 } ?? 1
        magWeightFactors = (fCov, fPath, fInfo, fAgree)
        if hasConverged {
            // 已经定到（跟踪）：地磁跟踪很准（实测 0.7～1.1 m），全权给地磁；只有和标签明显对不上才打折
            magneticWeight = max(0.5, fAgree)
        } else {
            // 找位置（冷启动 / 丢了）：地磁容易被长得像的地方带偏，按场景打折，让标签 / 通道 / 运动先把范围定下来
            magneticWeight = max(config.magWeightFloor, fCov * fPath * fInfo * fAgree)
        }
    }

    /// 返回归一化前的 log Σ w（上次归一化之后各项似然 / 扣分的对数证据）；权重全是 −∞ 时返回 −∞
    @discardableResult
    private func normalize() -> Double {
        guard let mx = logw.max(), mx.isFinite else {
            logw = [Double](repeating: 0, count: logw.count)
            return -.infinity
        }
        var sum = 0.0
        for v in logw { sum += exp(v - mx) }
        let shift = mx + log(sum)
        for i in 0..<logw.count { logw[i] -= shift }
        return shift
    }

    private func effectiveCount() -> Double {
        var s2 = 0.0
        for v in logw { let w = exp(v); s2 += w * w }
        return s2 > 0 ? 1 / s2 : 0
    }

    /// 系统重采样到 m 个粒子 + 位置抖动 + 少量随机粒子（跟丢后能重新找回）。
    private func resample(to m: Int) {
        let n = xs.count
        var cum = [Double](repeating: 0, count: n)
        var acc = 0.0
        for i in 0..<n { acc += exp(logw[i]); cum[i] = acc }
        let step = acc / Double(m)
        var u = rng.uniform() * step
        var nx = [Double](repeating: 0, count: m), ny = nx, nb = nx, ns = nx
        var e0 = [Double](repeating: .nan, count: m), e1 = e0, e2 = e0
        var o0 = e0, o1 = e0, o2 = e0
        var src = [Int](repeating: 0, count: m)  // 每个新粒子的重采样来源下标；注入粒子为 -1
        var anchor = [Point2?](repeating: nil, count: m)  // 注入粒子的可走锚点
        var j = 0
        for i in 0..<m {
            while j < n - 1 && cum[j] < u { j += 1 }
            nx[i] = xs[j] + rng.normal() * config.roughenCm
            ny[i] = ys[j] + rng.normal() * config.roughenCm
            nb[i] = bias[j]
            ns[i] = scale[j]
            if j < ema0.count { e0[i] = ema0[j]; e1[i] = ema1[j]; e2[i] = ema2[j] }
            if j < off0.count { o0[i] = off0[j]; o1[i] = off1[j]; o2[i] = off2[j] }
            src[i] = j
            u += step
        }
        let inject = Int(Double(m) * (hasConverged ? config.randomInjectionConverged : config.randomInjection))
        // 局部找回：注入粒子只撒在最后一次可靠位置附近的圆里，不在全图找
        let localCenter = localRecoveryCenter, localR = localRecoveryRadiusCm ?? 0
        for k in 0..<inject {
            let i = m - 1 - k
            let pa: (point: Point2, anchor: Point2?)
            if let c = localCenter {
                let ang = rng.uniform() * 2 * Double.pi, r = localR * rng.uniform().squareRoot()
                let q = Point2(c.x + cos(ang) * r, c.y + sin(ang) * r)
                // 锚点只在落到不可走区域时才用：最近的可走点，找不到就退回中心
                let off = walkable.map { !$0.isWalkable(q) } ?? false
                pa = (q, off ? (walkable?.nearestWalkable(to: q, radiusCm: 300) ?? c) : c)
            } else {
                pa = randomPositionWithAnchor()
            }
            let p = pa.point, a = pa.anchor
            nx[i] = p.x
            ny[i] = p.y
            src[i] = -1
            anchor[i] = a
            nb[i] = headingUnknown && config.uniformHeadingForInjection ? (rng.uniform() * 2 - 1) * Double.pi : rng.normal() * config.initialHeadingBiasSigmaDeg * Double.pi / 180
            ns[i] = 1 + rng.normal() * config.initialScaleSigma
            e0[i] = .nan; e1[i] = .nan; e2[i] = .nan
            o0[i] = .nan; o1[i] = .nan; o2[i] = .nan
        }
        for i in 0..<m {
            var p = Point2(min(max(nx[i], 0), field.widthCm), min(max(ny[i], 0), field.heightCm))
            if let w = walkable, !w.isWalkable(p) {
                if src[i] >= 0 {
                    // 抖动后落到不可走区域：退回它的重采样来源粒子的位置（不是旧数组里同下标的无关粒子）
                    p = Point2(xs[src[i]], ys[src[i]])
                } else {
                    // 注入粒子的格内偏移落到通道外：退回选中的格子中心（或最近的可走点），
                    // 绝不退回重采样来源，否则会被拉进已收敛（可能锁错）的簇里
                    p = anchor[i] ?? w.nearestWalkable(to: p, radiusCm: 300) ?? p
                }
            }
            // 抖动跨了房间（没经过门）：同样退回来源粒子
            if src[i] >= 0, let g = roomGraph, g.crossesWithoutDoor(from: Point2(xs[src[i]], ys[src[i]]), to: p) {
                p = Point2(xs[src[i]], ys[src[i]])
            }
            nx[i] = p.x
            ny[i] = p.y
        }
        xs = nx; ys = ny; bias = nb; scale = ns
        ema0 = e0; ema1 = e1; ema2 = e2
        off0 = o0; off1 = o1; off2 = o2
        logw = [Double](repeating: -log(Double(m)), count: m)
    }

    // MARK: 估计

    /// 从 `seed` 开始（nil = 从权重总和最大的 2 m 方块开始）做均值漂移，返回簇中心、权重占比、1σ 不确定度。
    private func cluster(from seed: Point2?) -> (center: Point2, mass: Double, unc: Double) {
        let n = xs.count
        let mx = logw.max() ?? 0
        var w = [Double](repeating: 0, count: n)
        var total = 0.0
        for i in 0..<n { w[i] = exp(logw[i] - mx); total += w[i] }
        guard total > 0 else { return (Point2(field.widthCm / 2, field.heightCm / 2), 0, field.widthCm) }
        var cx: Double, cy: Double
        if let s = seed {
            cx = s.x; cy = s.y
        } else {
            // 不从「单个最重粒子」开始：权重很平的时候，单个最重粒子可能是刚注入的随机粒子，估计会满图跳
            var mass: [Int: Double] = [:], sumX: [Int: Double] = [:], sumY: [Int: Double] = [:]
            let bin = 200.0
            for i in 0..<n {
                let k = Int(ys[i] / bin) * 100_000 + Int(xs[i] / bin)
                mass[k, default: 0] += w[i]
                sumX[k, default: 0] += w[i] * xs[i]
                sumY[k, default: 0] += w[i] * ys[i]
            }
            let top = mass.max(by: { $0.value < $1.value })!
            cx = sumX[top.key]! / top.value
            cy = sumY[top.key]! / top.value
        }
        let r2 = config.clusterRadiusCm * config.clusterRadiusCm
        var m = 0.0
        for _ in 0..<3 {
            var sw = 0.0, sx = 0.0, sy = 0.0
            for i in 0..<n {
                let dx = xs[i] - cx, dy = ys[i] - cy
                if dx * dx + dy * dy <= r2 { sw += w[i]; sx += w[i] * xs[i]; sy += w[i] * ys[i] }
            }
            if sw > 0 { cx = sx / sw; cy = sy / sw }
            m = sw / total
        }
        var sw = 0.0, vx = 0.0, vy = 0.0
        for i in 0..<n {
            let dx = xs[i] - cx, dy = ys[i] - cy
            if dx * dx + dy * dy <= r2 { sw += w[i]; vx += w[i] * dx * dx; vy += w[i] * dy * dy }
        }
        let unc = sw > 0 ? ((vx + vy) / sw).squareRoot() : config.clusterRadiusCm
        return (Point2(cx, cy), m, unc)
    }

    public func estimate() -> MagneticEstimate { estimate(reportingUncertainty: true) }

    /// reportingUncertainty = false：内部只要位置 / 簇内散布（收敛判定、挑战者比较、房间兜底），不多扫一遍粒子算报的不确定度
    func estimate(reportingUncertainty: Bool) -> MagneticEstimate {
        let c = cluster(from: hasConverged ? committed : nil)
        var conf = max(0, min(1, c.mass * (1 - c.unc / config.confidenceScaleCm)))
        // 估计点本身落在没有磁场数据的地方：地磁说了不算，置信度归零
        // （跟踪配置档关掉：没采过的地方本来就该纯推算，不算丢）
        if config.zeroConfidenceOffMap && field.sample(at: c.center) == nil { conf = 0 }
        var e = MagneticEstimate(position: c.center,
                                 uncertaintyCm: config.honestUncertainty && reportingUncertainty ? reportedUncertainty(at: c.center, clusterUnc: c.unc) : c.unc,
                                 confidence: conf, effectiveRatio: lastEffectiveRatio, updates: updateCount, converged: hasConverged)
        e.clusterUncertaintyCm = c.unc
        // 后验航向只在对外报的时候算（内部的收敛 / 挑战者判定不需要，省一遍粒子）
        if reportingUncertainty, let hb = clusterHeadingBias(center: c.center) {
            e.headingBiasRad = hb.mean
            e.headingBiasSigmaRad = hb.sigma
            e.headingMultimodal = hb.multimodal
        }
        // 房间：所有房间的权重一次算完，报权重最多的房间（不是加权平均点所在的房间——粒子分在两个房间时，
        // 平均点可能落在中间的走廊或离错的房间更近，正好是房间级兜底要管的情况）
        if config.reportRoom, let g = walkable?.rooms {
            let m = roomMasses(in: g)
            let order = m.indices.filter { m[$0] > 0 }.sorted { m[$0] > m[$1] }
            if let r = order.first {
                e.roomId = g.rooms[r].id
                e.roomMass = m[r]
                e.roomOnly = e.roomMass < config.roomPointMassThreshold
                if order.count > 1 { e.roomRunnerUpId = g.rooms[order[1]].id; e.roomRunnerUpMass = m[order[1]] }
            }
        }
        return e
    }

    /// 主簇内（离 center ≤ clusterRadiusCm）粒子航向偏差的加权圆周统计（不能对角度做算术平均：±179° 平均成 0°）。
    /// 多峰：36 格（10°）直方图上 ±30° 窗口的最大权重为主峰，离主峰 ≥ 90° 的窗口里最大权重 ≥ 0.2 即多峰。
    func clusterHeadingBias(center: Point2) -> (mean: Double, sigma: Double, multimodal: Bool)? {
        guard !xs.isEmpty else { return nil }
        let mx = logw.max() ?? 0
        let r2 = config.clusterRadiusCm * config.clusterRadiusCm
        let nb = 36
        var hist = [Double](repeating: 0, count: nb)
        var sw = 0.0, sc = 0.0, ss = 0.0
        for i in xs.indices {
            let dx = xs[i] - center.x, dy = ys[i] - center.y
            guard dx * dx + dy * dy <= r2 else { continue }
            let w = exp(logw[i] - mx)
            let c = cos(bias[i]), s = sin(bias[i])
            sw += w; sc += w * c; ss += w * s
            var a = bias[i].truncatingRemainder(dividingBy: 2 * Double.pi)   // 规范到 [−π, π)
            if a < -Double.pi { a += 2 * Double.pi } else if a >= Double.pi { a -= 2 * Double.pi }
            hist[min(Int((a + Double.pi) / (2 * Double.pi) * Double(nb)), nb - 1)] += w
        }
        guard sw > 0, sw.isFinite else { return nil }
        let r = min(max((sc * sc + ss * ss).squareRoot() / sw, 1e-12), 1)
        let sigma = (-2 * log(r)).squareRoot()
        // ±30° 窗口（7 格）权重
        var win = [Double](repeating: 0, count: nb)
        for k in 0..<nb { for d in -3...3 { win[k] += hist[(k + d + nb) % nb] } }
        for k in 0..<nb { win[k] /= sw }
        let main = win.indices.max { win[$0] < win[$1] }!
        var second = 0.0
        for k in 0..<nb {
            let sep = min(abs(k - main), nb - abs(k - main))          // 格数，1 格 = 10°
            if sep >= 9 { second = max(second, win[k]) }
        }
        return (atan2(ss, sc), sigma, second >= 0.2)
    }

    /// 报的 1σ（cm，见 `ReportedUncertainty`）：√(全部粒子相对 p 的均方距离 + (步长散布缺口 · min(L, 地图边长))²)，不小于簇内散布
    func reportedUncertainty(at p: Point2, clusterUnc: Double) -> Double {
        guard !xs.isEmpty else { return clusterUnc }
        let mx = logw.max() ?? 0
        var sw = 0.0, s2 = 0.0, m1 = 0.0, m2 = 0.0
        for i in xs.indices {
            let w = exp(logw[i] - mx)
            let dx = xs[i] - p.x, dy = ys[i] - p.y
            sw += w; s2 += w * (dx * dx + dy * dy); m1 += w * scale[i]; m2 += w * scale[i] * scale[i]
        }
        guard sw > 0, sw.isFinite else { return clusterUnc }
        let mean = m1 / sw
        let particleVar = max(m2 / sw - mean * mean, 0)
        let lever = min(sinceFixCm, (field.widthCm * field.heightCm).squareRoot())
        let model = max(config.reportScaleSigma * config.reportScaleSigma - particleVar, 0).squareRoot() * lever
        return max(clusterUnc, (s2 / sw + model * model).squareRoot())
    }

    /// 每个房间的粒子权重占比（下标 = 房间编号；不在任何房间的粒子不计入任何房间，但计入总权重）
    func roomMasses(in g: RoomGraph) -> [Double] {
        let mx = logw.max() ?? 0
        var m = [Double](repeating: 0, count: g.rooms.count)
        var tot = 0.0
        for i in xs.indices {
            let w = exp(logw[i] - mx)
            tot += w
            if let r = g.roomIndex(at: Point2(xs[i], ys[i])) { m[r] += w }
        }
        return tot > 0 ? m.map { $0 / tot } : m
    }

    // MARK: 静止冻结

    /// 正在静止冻结（`freezeStationary` 之后、`releaseStationaryFreeze` 之前）：step 不推粒子
    public private(set) var stationaryFrozen = false
    /// 冻结期间收到的位移（时刻取最近一次 `noteStationaryTime`），解冻时按需补推
    private var frozenBuffer: [(t: Int64, d: Point2)] = []
    private var stationaryClockMs: Int64 = 0

    /// 静止够久（在房间里坐着 / 站着不动）：粒子向**各自房间**的加权中心收拢，加权散布不超过 `stationaryFreezeSpreadCm`，
    /// 之后 step 的位移不推粒子（坐着时口袋里的伪步），直到 `releaseStationaryFreeze`。
    /// 只在 `config.stationaryFreeze` 打开、已经收敛、（有房间图时）权重最多的房间占比 ≥ `stationaryFreezeMinRoomMass` 时生效；
    /// 返回是否冻结了。粒子不会被挪到别的房间（不穿墙、不把 60/40 的房间之争硬判成 100/0），也不会被收进墙 / 家具里。
    @discardableResult
    public func freezeStationary() -> Bool {
        guard config.stationaryFreeze, hasConverged, !stationaryFrozen, !xs.isEmpty else { return false }
        if let g = walkable?.rooms {
            guard let top = roomMasses(in: g).max(), top >= config.stationaryFreezeMinRoomMass else { return false }
        }
        let centers = roomCenters()
        let spread = weightedSpread(toCenters: centers)
        if spread > config.stationaryFreezeSpreadCm {
            rescaleParticles(centers: centers, factor: config.stationaryFreezeSpreadCm / spread)
        }
        stationaryFrozen = true
        frozenBuffer.removeAll()
        return true
    }

    /// 起身（真的在走了）：解除冻结，粒子散布（相对各自房间的中心）放大 `stationaryReleaseSpreadFactor` 倍（走不过去的粒子不动）；
    /// `replaySinceMs` 给了时，把冻结期间这之后收到的位移补推一次（起身后头几步在判定「真的在走」之前就发生了，不能丢）。
    public func releaseStationaryFreeze(replaySinceMs: Int64? = nil) {
        guard stationaryFrozen else { return }
        stationaryFrozen = false
        rescaleParticles(centers: roomCenters(), factor: config.stationaryReleaseSpreadFactor)
        let buf = frozenBuffer
        frozenBuffer.removeAll()
        if let since = replaySinceMs {
            let d = buf.filter { $0.t >= since }.reduce(Point2.zero) { $0 + $1.d }
            if d.length > 0 { step(delta: d, feature: nil) }
        }
    }

    /// 告诉定位「现在几点」（冻结期间的位移缓冲按它打时间戳；`feedStationary` 会调）
    public func noteStationaryTime(_ tMs: Int64) { stationaryClockMs = tMs }

    /// 每个粒子 → 它所在房间的加权中心（中心落在墙 / 家具里或别的房间时，取该房间里权重最大的粒子，保证能走）；
    /// 没有房间图时全部用估计点
    private func roomCenters() -> [Point2] {
        guard let g = walkable?.rooms else {
            let c = estimate(reportingUncertainty: false).position
            return [Point2](repeating: c, count: xs.count)
        }
        let none = g.rooms.count
        let mx = logw.max() ?? 0
        var sw = [Double](repeating: 0, count: none + 1)
        var sx = sw, sy = sw
        var best = [(w: Double, p: Point2)](repeating: (-1, .zero), count: none + 1)
        var rid = [Int](repeating: none, count: xs.count)
        for i in xs.indices {
            let p = Point2(xs[i], ys[i])
            let r = g.roomIndex(at: p) ?? none
            rid[i] = r
            let w = exp(logw[i] - mx)
            sw[r] += w; sx[r] += w * p.x; sy[r] += w * p.y
            if w > best[r].w { best[r] = (w, p) }
        }
        var cs = [Point2](repeating: .zero, count: none + 1)
        // 不在任何房间格里的粒子（门洞、墙缝）向估计点收拢
        cs[none] = estimate(reportingUncertainty: false).position
        for r in cs.indices where sw[r] > 0 && r != none {
            let c = Point2(sx[r] / sw[r], sy[r] / sw[r])
            let ok = (walkable?.isWalkable(c) ?? true) && (r == none || g.roomIndex(at: c) == r)
            cs[r] = ok ? c : best[r].p
        }
        return rid.map { cs[$0] }
    }

    private func weightedSpread(toCenters cs: [Point2]) -> Double {
        let mx = logw.max() ?? 0
        var sw = 0.0, s2 = 0.0
        for i in xs.indices {
            let w = exp(logw[i] - mx)
            let dx = xs[i] - cs[i].x, dy = ys[i] - cs[i].y
            sw += w; s2 += w * (dx * dx + dy * dy)
        }
        return sw > 0 ? (s2 / sw).squareRoot() : 0
    }

    /// 粒子相对 c 的加权 RMS 距离（cm）
    public func weightedSpread(around c: Point2) -> Double {
        let mx = logw.max() ?? 0
        var sw = 0.0, s2 = 0.0
        for i in xs.indices {
            let w = exp(logw[i] - mx)
            let dx = xs[i] - c.x, dy = ys[i] - c.y
            sw += w; s2 += w * (dx * dx + dy * dy)
        }
        return sw > 0 ? (s2 / sw).squareRoot() : 0
    }

    /// 每个粒子到它自己那个中心的偏移乘 factor。新位置不可走或换了房间时：收拢就退到中心（中心能走、在同一房间），放大就留在原地
    private func rescaleParticles(centers cs: [Point2], factor: Double) {
        let g = walkable?.rooms
        for i in xs.indices {
            let old = Point2(xs[i], ys[i]), c = cs[i]
            var p = Point2(c.x + (old.x - c.x) * factor, c.y + (old.y - c.y) * factor)
            p = Point2(min(max(p.x, 0), field.widthCm), min(max(p.y, 0), field.heightCm))
            var ok = walkable?.isWalkable(p) ?? true
            if ok, let g, g.roomIndex(at: p) != g.roomIndex(at: old) { ok = false }
            if !ok { p = factor < 1 ? c : old }
            xs[i] = p.x
            ys[i] = p.y
        }
    }
}

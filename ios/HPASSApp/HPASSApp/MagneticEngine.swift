import ARKit
import CoreMotion
import Foundation
import HPASSKit
import UIKit

/// 激光雷达（深度相机）测通道左右货架距离的使用方式。
enum DepthMode: String, CaseIterable, Identifiable {
    case off, logOnly, fuse
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "关"
        case .logOnly: return "只记录"
        case .fuse: return "参与定位"
        }
    }
}

/// 一次「我现在在点位 X」的验证结果。
struct MagCheck: Identifiable {
    let id = UUID()
    let pointId: String
    let errorCm: Double
}

/// 导航提示：到目标点的距离，以及需要转多少度（正 = 向左转，与 HPASSKit 的航向约定一致）。
struct MagNavHint {
    var targetId: String
    var distanceCm: Double
    var turnRad: Double
    var arrived: Bool
}

/// 流水线内核：只允许在引擎的串行队列上访问。
private final class MagPipeline {
    let extractor = MagneticFeatureExtractor()
    var fusion: FusionEngine?
    var localizer: MagneticLocalizer?
    var mode: MagneticEngine.Phase = .idle

    var latest: MagneticFeature?
    /// raw 模式下磁力计特征的新鲜度门（NAV-005）：磁力计停了 / 回调被拖住 / 时间戳乱序时，旧特征不再当成新的磁场证据
    var magGate = MagObservationGate()
    var calSamples: [MagneticFieldBuilder.TimedFeature] = []
    var lastCalSampleMs: Int64 = 0

    var lastFusedPos: Point2?
    var lastOut: FusionOutput?
    var estimate: MagneticEstimate?
    var lastPublishMs: Int64 = 0
    var pendingCheck: String?
    var trackWriter: CSVWriter?

    // 实时定位（标点即走）
    var tracking = false
    var magAccuracy = -1
    var stepBase = 0

    // 软件层：磁场可信度、持握姿态、推车嫌疑、计步器对照
    let trustMon = MagneticTrustMonitor()
    let hold = HoldClassifier()
    var lastRaw: (Double, Double, Double)?
    var trustNow = 1.0
    var posture: HoldPosture = .unknown
    var lastStepCount = 0
    var lastStepChangeMs: Int64 = 0
    var cartSuspected = false
    var pdrDistanceCm = 0.0

    /// 不用惯导以外的来源时，自己积分出来的位置。
    var pos: Point2?
    var lastShown: Point2?
    var lastHeadingRad = 0.0
    /// 粒子后验修正后的航向（不可信时 nil）
    var lastPostHeadingRad: Double?

    // 视觉里程计（ARKit）
    enum VioPending {
        case fresh(Point2, Double)      // 在这个位置、这个朝向重新锚定并重新对齐
        case keep(Point2)               // 保持旋转，只把位置拉到这里（长按修正）
    }
    let aligner = VisualOdometryAligner()
    var vioEnabled = false
    var vioPending: VioPending?
    var vioActive = false
    var vioAccum = Point2.zero
    var vioHeadingVec = Point2.zero
    var latestA: Point2?
    var vioTracking = 0
    var vioProgress = 0.0
    /// 旧的「冷启动直接把 ARKit 原始位移交给粒子」模式：终端用户定位里不再使用（计步永远推粒子），恒为 false
    var vioRaw = false
    /// 冷启动（不知道朝向）时，用「地磁定出来的地图位置 ↔ ARKit 位置」估旋转，给 AR 叠加用
    let rotFit = ARMapRotationFit()
    /// 和 lastShown 同一时刻的 ARKit 位置
    var shownA: Point2?
    /// 地磁滤波器当前是否有把握（没用地磁时为 true）
    var lastConverged = true
    /// 蓝牙粗定位：标签指纹、最近几秒的读数、上次用的时间
    var bleMap: BLEFingerprintMap?
    var bleAssist: BLEAssist?
    /// 地图还准不准（变化检测 + 定位时的磁场累积），有磁场图时才有
    var monitor: LiveFieldMonitor?
    var monitorField: MagneticFieldMap?
    var bleWindow: [(t: Int64, id: String, rssi: Double)] = []
    var lastBleApply: Int64 = 0
    /// 上次「贴近标签」定位的时间
    var lastTouchMs: Int64 = 0
    /// 盲测录制：当前声明的携带方式（写进 track.csv 的 carry_mode 列）
    var carryMode = ""
    /// 步长 K 在线标定（携带方式模型打开时）
    let calibrator = StepScaleCalibrator()
    /// 静止冻结判定（房间图地图）
    var freezeDet = StationaryFreezeDetector()
    /// 近距离传感器：贴着（true）/ 没贴着（false）/ 没开（nil）
    var proximityNear: Bool?
    /// 实时定位录下来的蓝牙 / 货架标签（和 imu、mag_raw 一起上传，电脑上能原样回放）
    var bleWriter: CSVWriter?
    var rawLastA: Point2?

    // 磁场来源：地图用「原始磁力计减偏置」建的，实时也必须一样
    var useRawMag = false
    var imuWriter: CSVWriter?
    var rawWriter: CSVWriter?
    let biasTracker = RawBiasTracker()
    var lastRawT: Int64?
    /// 定位参考系不含磁力计时（.xArbitraryZVertical），磁场 = 原始 − 这个偏置（本机存档 / 在线球面拟合）
    let magBias = MagBiasEstimator()

    // 深度横向距离
    var lateralMode: DepthMode = .off
    var pendingLateral: LateralObservation?
    var lastLatLeft: Double?
    var lastLatRight: Double?
    var lastWallLeft: Double?
    var lastWallRight: Double?

    // 视觉复核：ARKit 认出房间后的相机位置换到地图当真值，和地磁混合定位逐帧比（见 PositionReviewStats）
    var reviewAlign: MapARTransform?
    var reviewWriter: CSVWriter?
    var reviewStats = PositionReviewStats()
    var reviewLastMs: Int64 = 0
    var reviewLastPublishMs: Int64 = 0
    var lastUncCm = 0.0
}

/// 地磁模式：校准（现场建磁场图）和定位（惯导 + 磁场地图的粒子滤波）。
///
/// 自己持有一个 `MotionRecorder`，与采集页、蓝牙定位页互相独立，**请不要同时运行**。
/// 这个模式不用蓝牙。
@MainActor
final class MagneticEngine: ObservableObject {
    enum Phase { case idle, calibrating, localizing, live }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var feature: MagneticFeature?
    @Published private(set) var lastError: String?

    // 校准
    @Published private(set) var calIndex = 0            // 当前所在 / 刚离开的点位下标
    @Published private(set) var calMoving = false       // 已离开 calIndex，正在走向下一个点位
    @Published private(set) var calSampleCount = 0
    @Published private(set) var calUsedPoints: [MarkPoint] = []

    // 定位
    @Published private(set) var estimate: MagneticEstimate?
    @Published private(set) var position: Point2?
    @Published private(set) var headingRad: Double = 0
    @Published private(set) var stepCount = 0
    @Published private(set) var trail: [Point2] = []
    @Published private(set) var checks: [MagCheck] = []
    @Published private(set) var targetId: String?
    @Published private(set) var hint: MagNavHint?
    @Published var autoAdvance = true
    @Published private(set) var trackFileName: String?

    // 实时定位（标点即走）
    @Published private(set) var magAccuracy = -1
    @Published private(set) var isTracking = false
    @Published private(set) var headingEditing = false
    /// 冷启动搜索中：还没收敛，不显示位置
    @Published private(set) var searching = false
    /// 定位状态：没把握的时候不画位置（搜索中），或冻结在最后一个可信的位置（丢失）。
    enum LocState: Equatable { case idle, searching, tracking, lost }
    @Published private(set) var locState: LocState = .idle
    /// 开始自动定位的时间（找太久给提示）
    @Published private(set) var searchStarted: Date?
    /// 这次视觉定位成功过几次（跟丢再认出来也算）
    @Published private(set) var visualFixes = 0
    /// 房间里等视觉认房间：开始时间（nil = 没在等）、超时没认出来的次数
    @Published private(set) var visualSearchStarted: Date?
    @Published private(set) var visualTimeouts = 0
    static let visualTimeoutSec = 45.0
    private var visualTimer: Timer?
    private var visualTimeoutCounted = false
    /// 实时定位结束时的特征地图处理（见 WorldMapKeeper）
    private var liveWM: WorldMapKeeper.Plan?

    /// 当前地图有视觉特征地图（房间扫描时存的）和 ARKit → 地图的变换：可以视觉定位
    var visualAvailable: Bool {
        cameraAllowed && StoreDataStore.shared.map?.arAlign != nil && visualSource != nil
    }
    /// 视觉认房间用的特征地图和它的「ARKit → 地图」变换（见 MapLibrary.liveVisualSource）；读文件，缓存 5 秒
    var visualSource: MapLibrary.VisualSource? {
        let lib = MapLibrary.shared
        let key = "\(lib.activeId ?? "")|\(lib.geometryRevision)|\(StoreDataStore.shared.map?.frameId ?? "")"
        if let c = visualSourceCache, c.key == key, Date().timeIntervalSince(c.at) < 5 { return c.value }
        let v = lib.activeId.flatMap { lib.liveVisualSource($0, mapAlign: StoreDataStore.shared.map?.arAlign) }
        visualSourceCache = (key, Date(), v)
        return v
    }
    private var visualSourceCache: (key: String, at: Date, value: MapLibrary.VisualSource?)?
    /// 视觉位置换到地图用的变换：载入的特征地图自己的（扫描段的可能和地图的 arAlign 不同），否则地图的 arAlign
    private var liveAlign: MapARTransform? {
        guard let t = StoreDataStore.shared.map?.arAlign else { return nil }
        return visualSource?.align ?? t
    }
    @Published private(set) var uncertaintyCm: Double = 0
    /// 用磁罗盘持续修正航向。钢货架附近罗盘常偏，默认关，只靠陀螺。
    @Published var useCompassHeading = false
    /// 有磁场地图时，用地磁粒子滤波纠偏。默认打开（没有磁场图时自然不生效）。
    @Published var useMagCorrection = true
    /// 「视觉增强」（设置里，默认关）：终端用户定位不需要摄像头，任何携带方式都只靠计步 + 地磁 + 地图。
    /// 打开后，手机竖持 / 斜着看屏时才开 ARKit，视觉重定位只当一次 σ≈50 cm 的位置观测（见 VisualFixPolicy），
    /// 计步永远在推粒子。
    @Published var visualEnhancement: Bool = UserDefaults.standard.bool(forKey: "visualEnhancement") {
        didSet { UserDefaults.standard.set(visualEnhancement, forKey: "visualEnhancement") }
    }
    /// 携带无关的运动模型（设置 → 定位，默认开）：携带方式分类、分方式步长 / 航向、口袋 / 摆臂步幅平均，粒子按携带方式重撒，
    /// 步长 K 在线标定。HPASSKit FusionConfig.motion + MagneticConfig.carryModeAdaptive，评估 hpass-eval --carry-motion 同一套。
    /// 还没在真机上标定（全部占位参数），关掉就是原来的行为，双机测试可以两种各跑一遍对比
    nonisolated static var carryMotionEnabled: Bool {
        UserDefaults.standard.object(forKey: "carryMotionEnabled") as? Bool ?? true
    }
    /// 盲测录制时强制关摄像头（不管「视觉增强」开没开）
    var forceCameraOff = false
    /// 实时定位结束（不管从哪个页面结束）之后调一次：盲测模式在这里收尾（关近距离传感器、后台保活、敲击记录）
    var onLiveStopped: (() -> Void)?
    /// 这次实时定位允许用摄像头（视觉复核时不管「视觉增强」开没开，摄像头都要开着当裁判）
    var cameraAllowed: Bool { (visualEnhancement || reviewMode) && !forceCameraOff && ARKitLogger.isSupported }

    // MARK: 视觉复核（PositionReviewSession 在 startLive 之前设好）
    /// 视觉复核：摄像头全程开着，ARKit 认出房间后的位置只当真值，**不喂给定位**（不当观测、不抓定位、深度不参与），
    /// 测的是纯「计步 + 地磁 + 蓝牙」的误差。逐 0.2 秒写 review.csv，结束时摘要写进 meta.json（purpose = review）。
    var reviewMode = false
    /// 复核的起点：true = 视觉认出的位置和朝向当起点（只测跟踪）；false = 地磁自己冷启动（连起步一起测）
    var reviewStartFromVisual = true
    @Published private(set) var reviewStats = PositionReviewStats()
    @Published private(set) var reviewTruth: Point2?
    @Published private(set) var reviewEstimate: Point2?
    @Published private(set) var reviewTruthTrail: [Point2] = []
    @Published private(set) var reviewEstTrail: [Point2] = []
    /// 复核：视觉已经认出房间（有真值了）
    @Published private(set) var reviewHasTruth = false
    /// 视觉校验（普通实时定位也做）：最近一次视觉位置的时间。超过几秒没更新（摄像头关了、跟丢）界面就不画黄点
    @Published private(set) var reviewTruthAt: Date?
    /// 普通实时定位时视觉校验在不在录（地图有视觉特征地图和 ARKit → 地图对齐时自动打开）
    @Published private(set) var visualCheckOn = false
    static let reviewTrailCapacity = 1500
    /// 实时定位录制的附加 meta（盲测模式填），开始和结束时各取一次
    var liveExtraMeta: (() -> [String: Any])?
    /// 这次实时定位的录制目录（imu.csv、mag_raw.csv、ble.csv、meta.json；结束时拷进 track.csv）
    @Published private(set) var liveSessionDir: URL?
    /// 激光雷达测左右货架距离：关 / 只记录（用来核对）/ 参与定位。
    @Published var depthMode: DepthMode = .logOnly
    /// 用计步器的距离校正步长（默认关；只显示比值）。
    @Published var usePedometerScale = false

    // 状态
    @Published private(set) var magTrust = 1.0
    @Published private(set) var posture: HoldPosture = .unknown
    @Published private(set) var thermal: ProcessInfo.ThermalState = .nominal
    @Published private(set) var activityText = ""
    @Published private(set) var cartSuspected = false
    @Published private(set) var pedometerRatio: Double?
    @Published private(set) var vioTracking = 0      // 0 不可用 1 受限 2 正常
    @Published private(set) var vioAligned = false
    @Published private(set) var vioProgress = 0.0
    @Published private(set) var lateralText = ""
    // 沿通道导航（路径规划）
    @Published private(set) var navRoute: Route?
    @Published private(set) var navHint: NavHint?
    @Published private(set) var navLabel: String?
    /// 目标货架（播报"在左手边 / 右手边"用）；点位 / 坐标导航时为 nil
    @Published private(set) var navShelf: NavInstruction.Shelf?
    @Published private(set) var navArrived = false
    private var navArrivedText = "已到达"
    /// 这次导航是寻找模式自动开的（不找了 / 换目标时一起结束）
    private var navFromFind = false
    private var nav: NavigationSession?
    private var navMapKey = ""
    /// 正在跑的定位器（可走区域 / 射线模型）对应的地图几何指纹，见 refreshGeometryIfNeeded
    private var liveGeometryHash = ""
    /// 到达判定（NAV-002）：连续确认、定位可信、离目标直线近、不隔货架 / 墙才算到
    private var navArrival = ArrivalPolicy()
    /// 定位质量（NAV-004）：导航按它决定出不出转向、要不要重新规划、能不能判到达
    private var fixClassifier = FixQualityClassifier()
    /// 当前定位质量（界面可以据此提示「正在确认位置」）
    @Published private(set) var fixQuality: FixQuality = .searching
    /// 航向不可信（粒子的后验航向多峰 / 散布太大，NAV-003）：不画精确的朝向箭头
    @Published private(set) var headingUncertain = false

    /// 实时用的磁场来源（与地图一致）
    @Published private(set) var magSourceText = ""
    /// 地图 → ARKit 的变换（视觉里程计已对齐、且不是冷启动的原始模式时才有），给 AR 叠加用
    @Published private(set) var arAlignment: MapARTransform?
    @Published private(set) var arFloorY: Double?
    var arSession: ARSession { ar.session }
    var arRunningNow: Bool { arRunning }

    static let trailCapacity = 600
    private static let arriveCm: Double = 100

    private let motion = MotionRecorder()
    private let ar = ARKitLogger()

    // 抓定位：货架黄标签（摄像头）、手机贴近标签。都是「人一定在这一小块」的确定观测，能把定错的位置拉回来
    private let signReader = ShelfSignReader()
    private var shelfSigns: ShelfSigns?
    private var lastSignText: (String, Date)?
    /// 最近一次抓定位（界面显示）
    @Published private(set) var lastAnchorEvent: (text: String, at: Date)?
    @Published private(set) var anchorFixes = 0
    private var liveSignsWriter: CSVWriter?
    private var liveFilesDir: URL?
    /// 蓝牙扫描（有蓝牙指纹时才建，第一次用会问蓝牙权限）
    private var ble: BLEScanner?
    /// 蓝牙粗定位的位置（地图上画橙色空心圈）
    @Published private(set) var bleEstimate: Point2?
    @Published private(set) var bleTagsHeard = 0
    /// 蓝牙判断人在没采集过的区域（地磁不允许定位）
    @Published private(set) var bleOutside = false
    /// 可能变了的地方（定位时磁场持续和地图对不上），地图上画橙色方块
    @Published private(set) var changedSpots: [Point2] = []
    @Published private(set) var monitorSamples = 0
    @Published private(set) var liveVsMapText: String?

    nonisolated static var monitorURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("live-monitor.json")
    }

    /// 读回存盘的变化检测（和当前磁场图对得上才用）
    func loadMonitor() {
        guard let f = MagMapStore.shared.field else { changedSpots = []; monitorSamples = 0; liveVsMapText = nil; return }
        var m = (try? Data(contentsOf: Self.monitorURL)).flatMap { try? JSONDecoder().decode(LiveFieldMonitor.self, from: $0) }
        if m?.matches(f) != true { m = LiveFieldMonitor(field: f) }
        let mon = m!
        queue.sync { pipe.monitor = mon; pipe.monitorField = f }
        publishMonitor(mon, field: f)
    }

    private func publishMonitor(_ m: LiveFieldMonitor, field f: MagneticFieldMap) {
        changedSpots = m.changed().map(\.center)
        monitorSamples = m.totalSamples
        liveVsMapText = m.liveVsMap(f).map { "定位攒的磁场和地图平均差 \(Fmt.f($0.medianUT, 2)) µT（\($0.cells) 块）" }
    }

    private func saveMonitor() {
        let (m, f) = queue.sync { (pipe.monitor, pipe.monitorField) }
        guard let m, let f else { return }
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: Self.monitorURL, options: .atomic) }
        publishMonitor(m, field: f)
        if !changedSpots.isEmpty { AppLog.w("地磁", "可能变了的地方 \(changedSpots.count) 处（磁场持续和地图对不上），建议补采") }
    }
    private var arRunning = false
    /// ARKit 按姿态启停的计时（见 VisualFixPolicy）
    private var arGateTimer: Timer?
    private var arGateSince: Date?
    private var arBadTrackingSince: Date?
    private var arCooldownUntil: Date?
    /// 这次实时定位的 ARKit 位姿已经在录（ARKit 会按姿态多次启停，只录第一段，免得覆盖文件）
    private var arLoggedThisSession = false
    private let pedometer = CMPedometer()
    private let activityManager = CMMotionActivityManager()
    private let rawMagQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "mag.raw"
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private var thermalTimer: Timer?
    private var pedDistanceM: Double?
    private var pedBaseDist = 0.0
    private var pdrBaseCm = 0.0
    private var stepScale = 1.0
    private var trackStem: String?
    private nonisolated let queue = DispatchQueue(label: "mag.pipeline", qos: .userInitiated)
    private let pipe = MagPipeline()
    private var calWaypoints: [MagneticFieldBuilder.Waypoint] = []
    private var route: [MarkPoint] = []

    init() {
        let pipe = self.pipe
        let queue = self.queue
        ar.onPose = { [weak self] t, x, z, state in
            guard let self else { return }
            queue.async { self.handlePose(t: t, a: Point2(x, z), state: state, pipe: pipe) }
        }
        ar.onLateral = { [weak self] lat in
            guard let self else { return }
            queue.async { self.handleLateral(lat, pipe: pipe) }
        }
        ar.onFloor = { [weak self] y in
            Task { @MainActor in self?.arFloorY = y }
        }
        ar.onRelocalized = { [weak self] cam in
            Task { @MainActor in self?.applyVisualFix(camera: cam) }
        }
        ar.onAnchoredPose = { [weak self] t, x, z in
            guard let self else { return }
            queue.async { self.handleReviewTruth(t: t, a: Point2(x, z), pipe: pipe) }
        }
        signReader.onRead = { [weak self] _, text, _ in
            Task { @MainActor in self?.handleShelfSign(text) }
        }
        ar.onError = { [weak self] msg in
            Task { @MainActor in
                guard let self else { return }
                self.lastError = msg
                AppLog.e("地磁", msg)
                queue.async { pipe.vioEnabled = false; pipe.vioActive = false }
            }
        }
    }

    // MARK: - 校准

    /// 开始一遍校准：按点位顺序走。先站在第一个点位上，然后依次「离开 / 到达」。
    func startCalibration() {
        let store = MagMapStore.shared
        guard phase == .idle else { return }
        guard store.points.count >= 2 else {
            lastError = "至少需要 2 个点位才能校准"
            return
        }
        guard motion.isAvailable else {
            lastError = "设备运动传感器不可用"
            return
        }
        lastError = nil
        route = store.points
        calUsedPoints = route
        calIndex = 0
        calMoving = false
        calSampleCount = 0
        calWaypoints = [.init(tMs: Fmt.nowMs(), position: route[0].position)]
        startMotion(mode: .calibrating)
        AppLog.i("地磁", "开始校准：\(route.count) 个点位，从点位 \(route[0].id) 起")
    }

    /// 离开当前点位（开始走向下一个）。
    func calibrationDepart() {
        guard phase == .calibrating, !calMoving, calIndex < route.count - 1 else { return }
        calWaypoints.append(.init(tMs: Fmt.nowMs(), position: route[calIndex].position))
        calMoving = true
        AppLog.tap("校准·离开", "点位 \(route[calIndex].id)")
    }

    /// 到达下一个点位。
    func calibrationArrive() {
        guard phase == .calibrating, calMoving else { return }
        calIndex += 1
        calWaypoints.append(.init(tMs: Fmt.nowMs(), position: route[calIndex].position))
        calMoving = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        AppLog.tap("校准·到达", "点位 \(route[calIndex].id)")
    }

    var calibrationFinishable: Bool {
        phase == .calibrating && !calMoving && calIndex == route.count - 1
    }

    /// 结束这一遍，把数据并入地图。`keep == false` 表示放弃这一遍。
    func finishCalibration(keep: Bool) {
        guard phase == .calibrating else { return }
        let waypoints = calWaypoints
        stopMotion()
        guard keep else {
            AppLog.i("地磁", "放弃本遍校准")
            return
        }
        queue.async { [pipe] in
            let samples = pipe.calSamples
            pipe.calSamples = []
            Task { @MainActor in
                let used = MagMapStore.shared.addCalibration(waypoints: waypoints, samples: samples)
                if used == 0 { self.lastError = "这一遍没有有效数据（点位之间需要真的走过去）" }
            }
        }
    }

    // MARK: - 实时定位：校准传感器 → 长按定点 → 双击设朝向 → 走

    /// 打开传感器。此时就能看磁场精度和步数；定点、设好朝向后才开始推算位置。
    func startLive() {
        guard phase == .idle else { return }
        guard motion.isAvailable else {
            lastError = "设备运动传感器不可用"
            return
        }
        lastError = nil
        let store = MagMapStore.shared
        // 先用一个放在地图中心的引擎跑计步，便于在原地踏步检查
        let warmup = makeFusion(at: Point2(store.widthCm / 2, store.heightCm / 2), heading: nil)
        let writer = Self.makeTrackWriter()
        trackFileName = writer?.name
        trackStem = writer.map { ($0.name as NSString).deletingPathExtension }
        stepScale = 1
        pedometerRatio = nil
        pedDistanceM = nil
        pedBaseDist = 0
        pdrBaseCm = 0
        queue.sync {
            pipe.fusion = warmup
            pipe.localizer = nil
            pipe.tracking = false
            pipe.stepBase = 0
            pipe.pos = nil
            pipe.lastShown = nil
            pipe.pdrDistanceCm = 0
            pipe.cartSuspected = false
            pipe.lastStepCount = 0
            pipe.vioEnabled = false
            pipe.vioActive = false
            pipe.vioPending = nil
            pipe.aligner.anchor(map: .zero, ar: .zero, headingRad: nil)
            pipe.pendingLateral = nil
            pipe.lateralMode = depthMode
            pipe.trustMon.reset()
            pipe.hold.reset()
            pipe.lastFusedPos = nil
            pipe.lastOut = nil
            pipe.estimate = nil
            pipe.pendingCheck = nil
            pipe.trackWriter = writer?.writer
        }
        position = nil
        trail = []
        fixClassifier.reset()
        checks = []
        estimate = nil
        stepCount = 0
        uncertaintyCm = 0
        isTracking = false
        searching = false
        locState = .idle
        headingEditing = false
        hint = nil
        targetId = nil
        visualFixes = 0
        visualTimeouts = 0
        endVisualSearch()
        startMotion(mode: .live)
        startPedometerAndActivity()
        arLoggedThisSession = false
        startLiveRecording()
        startReviewRecording()
        BackgroundKeeper.shared.begin("实时定位")
        startARGate()
        if reviewMode { arGateTick() }          // 复核：马上开摄像头，不等姿态
        AppLog.i("地磁", "实时定位：打开传感器，视觉增强 \(cameraAllowed ? "开（竖持时才开摄像头）" : "关（不用摄像头）")，深度 \(depthMode.title)，罗盘修正 \(useCompassHeading ? "开" : "关")，地磁纠偏 \(useMagCorrection ? "开" : "关")")
        startBLE()
        loadMonitor()
    }

    /// 盲测录制：声明当前携带方式（写进 track.csv 的 carry_mode 列）
    func setCarryModeLabel(_ m: String) {
        queue.async { [pipe] in pipe.carryMode = m }
    }

    func stopLive() {
        guard phase == .live else { return }
        // 房间：认出房间的实时定位，结束时刷新特征地图（30 分钟内刷新过就不重复，免得每次都传几 MB）
        liveWM = arRunning ? WorldMapKeeper.Plan.make(ar: ar, sessionDir: liveFilesDir, name: "实时定位", minAgeMin: 30) : nil
        endVisualSearch()
        stopARGate()
        stopMotion()
        BackgroundKeeper.shared.end("实时定位")
        locState = .idle
        queue.async { [pipe] in
            pipe.trackWriter?.close()
            pipe.trackWriter = nil
            pipe.tracking = false
            pipe.bleWriter?.close()
            pipe.bleWriter = nil
            pipe.imuWriter?.close(); pipe.imuWriter = nil
            pipe.rawWriter?.close(); pipe.rawWriter = nil
            pipe.carryMode = ""
        }
        stopReviewRecording()
        writeLiveMeta(final: true)
        // 盲测附加的东西只属于这一次实时定位：从「导航」页 / 地磁页 / 传感器被别的页面抢走结束时也要清掉（评审）
        forceCameraOff = false
        liveExtraMeta = nil
        reviewMode = false
        if let cb = onLiveStopped { onLiveStopped = nil; cb() }
        liveSignsWriter?.close()
        liveSignsWriter = nil
        isTracking = false
        stopBLE()
        uploadLiveRecording()
        saveMonitor()
        searching = false
        searchStarted = nil
        headingEditing = false
        AppLog.i("地磁", "实时定位停止，修正 \(checks.count) 次")
    }

    /// 这次实时定位的完整记录（惯导、磁力计、ARKit、蓝牙、货架标签、定位轨迹）传到后台，电脑上能原样回放分析。
    /// 连着后台才传；不参与建图（meta 里 live = true）。
    private func uploadLiveRecording() {
        let wm = liveWM
        liveWM = nil
        guard let d = liveFilesDir else {
            if let wm { Task { await wm.finish(upload: nil) } }
            return
        }
        liveFilesDir = nil
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = trackFileName
        let upload = Telemetry.shared.enabled
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)     // 等文件写完（轨迹文件在引擎队列上关闭，关完才有内容）
            if let name {
                // 会话目录里放一份 track.csv（不上传也放：数据管理里导出时整目录带走）
                let src = docs.appendingPathComponent("mag-tracks", isDirectory: true).appendingPathComponent(name)
                try? FileManager.default.removeItem(at: d.appendingPathComponent("track.csv"))
                try? FileManager.default.copyItem(at: src, to: d.appendingPathComponent("track.csv"))
            }
            guard upload else {
                if let wm { await wm.finish(upload: nil) }       // 不上传也要把 ARKit 停掉、刷新本机特征地图
                return
            }
            if let wm {
                await wm.finish(upload: { await Telemetry.shared.upload(sessionDir: d) })
            } else {
                _ = await Telemetry.shared.upload(sessionDir: d)
            }
        }
    }

    /// 长按地图：我现在在这里。走动中长按 = 修正位置，同时记下修正前的误差。
    func setAnchor(_ p: Point2) {
        guard phase == .live else { return }
        let store = MagMapStore.shared
        // 离点位 50 cm 以内就吸附到点位上
        var target = p
        var label = "x \(Int(p.x)) y \(Int(p.y))"
        if let near = store.points.min(by: { $0.position.distance(to: p) < $1.position.distance(to: p) }),
           near.position.distance(to: p) <= 50 {
            target = near.position
            label = "点位 \(near.id)"
        }
        if isTracking, let cur = position {
            let err = cur.distance(to: target)
            checks.append(MagCheck(pointId: label, errorCm: err))
            AppLog.i("地磁", "修正位置到 \(label)：修正前估计 \(cur)，偏差 \(Fmt.f(err, 0)) cm")
            restartTracking(at: target, heading: headingRad, checkLabel: label, isCorrection: true)
            locState = .tracking
        } else {
            AppLog.i("地磁", "定点：\(label)")
        }
        position = target
        if isTracking { trail.append(target) } else { trail = [target] }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        refreshHint()
    }

    /// 双击地图：开始 / 结束设朝向。结束时如果还没开始推算，就从这里开始。
    func toggleHeadingEdit() {
        guard phase == .live else { return }
        guard let p = position else {
            lastError = "先长按地图，设定你现在的位置"
            return
        }
        lastError = nil
        if !headingEditing {
            headingEditing = true
            AppLog.tap("地磁·设朝向", "开始")
            return
        }
        headingEditing = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let deg = Int((headingRad * 180 / Double.pi).rounded())
        if isTracking {
            let h = headingRad
            queue.async { [pipe] in
                pipe.fusion?.setHeading(h)
                if pipe.vioEnabled, let p = pipe.lastShown ?? pipe.pos { pipe.vioPending = .fresh(p, h) }
            }
            AppLog.i("地磁", "重新设朝向：\(deg)°")
        } else {
            restartTracking(at: p, heading: headingRad, checkLabel: nil, isCorrection: false)
            isTracking = true
            locState = .tracking
            AppLog.i("地磁", "开始推算：起点 \(p)，朝向 \(deg)°")
        }
    }

    /// 当前地图外框面积（m²）：小场地（办公室 / 房间）只靠地磁的冷启动也报位置（MagneticConfig.liveColdStart）
    private static var mapAreaM2: Double {
        let s = MagMapStore.shared
        return s.widthCm * s.heightCm / 10_000
    }

    /// 不知道自己在哪：粒子撒满整张可走区域，沿通道走十几米后自动收敛。收敛之前不显示位置。
    func startColdSearch() {
        guard phase == .live, !isTracking else { return }
        let store = MagMapStore.shared
        searchStarted = Date()
        beginVisualSearch()
        guard let field = store.field else {
            // 没有磁场图，但开了视觉增强、有视觉特征地图：等视觉认出房间给起点（之后照样计步推算）
            guard visualAvailable else {
                lastError = "还没有磁场地图，无法自动定位：请长按地图设定起点"
                searchStarted = nil
                return
            }
            lastError = nil
            if VisualFixPolicy.postureAllowsCamera(posture) { startVisualOdometry() }
            searching = true
            isTracking = true
            locState = .searching
            position = nil
            trail = []
            fixClassifier.reset()
            AppLog.i("地磁", "自动定位：等视觉认房间给起点（这张地图还没有磁场图）")
            return
        }
        lastError = nil
        let (fusion, localizer) = makeColdStart(field: field)
        queue.sync {
            pipe.stepBase = 0
            pipe.fusion = fusion
            pipe.localizer = localizer
            Self.wireMotion(pipe)
            pipe.lastFusedPos = nil
            pipe.lastOut = nil
            pipe.pos = nil
            pipe.lastShown = nil
            pipe.tracking = true
            pipe.vioPending = nil
            pipe.vioRaw = false                   // 计步永远推粒子；ARKit（若开着）只给 AR 叠加和视觉观测
            pipe.rotFit.reset()
            pipe.shownA = nil
            pipe.vioActive = false
            pipe.rawLastA = nil
            pipe.vioAccum = .zero
        }
        searching = true
        isTracking = true
        locState = .searching
        position = nil
        trail = []
        fixClassifier.reset()
        AppLog.i("地磁", "自动定位：冷启动，运动 计步，" + (MagneticConfig.magOnlyColdStartAllowed(mapAreaM2: Self.mapAreaM2) ? "小场地只靠地磁也报，" : "") + "地图朝向 " + (store.mapUpBearingDeg.map { "\(Int($0))°（一半粒子按罗盘，一半全方向）" } ?? "未设置（全方向猜）"))
    }

    /// 冷启动的惯导 + 粒子：有地图朝向时用罗盘给一个大致方向，一半粒子信它、一半全方向；
    /// 没有地图朝向时只用陀螺给相对方向，粒子全方向猜。
    private func makeColdStart(field: MagneticFieldMap) -> (FusionEngine, MagneticLocalizer) {
        let store = MagMapStore.shared
        let center = Point2(store.widthCm / 2, store.heightCm / 2)
        let fusion: FusionEngine
        var prior = 0.0
        if let decl = store.declinationDeg {
            fusion = makeFusion(at: center, heading: nil, declinationDeg: decl, compass: true)
            prior = 0.5
        } else {
            fusion = makeFusion(at: center, heading: 0, compass: false)
        }
        let loc = makeLocalizer(field: field, start: nil, headingUnknown: true, priorFraction: prior)
        return (fusion, loc)
    }

    /// 惯导引擎 ↔ 粒子滤波的携带方式接线（HPASSKit docs/carry-motion.md，评估器 --carry-motion 同一套）：
    /// 携带事件 → `loc.apply`（按方式重撒航向偏差，粒子位置不动），粒子滤波一换就补告知当前方式，
    /// 步长 K 在线标定（学到的分方式比例存在本机），静止冻结判定器清零。在引擎队列上调。
    private nonisolated static func wireMotion(_ pipe: MagPipeline) {
        pipe.calibrator.reset()
        pipe.freezeDet.reset()
        guard let f = pipe.fusion else { return }
        guard let loc = pipe.localizer, f.config.motion.enabled else { f.onCarryEvent = nil; return }
        f.setLearnedStepScales(StepScaleStore.load())
        f.onStepScaleLearned = { m, v in StepScaleStore.save(mode: m, scale: v) }
        f.onCarryEvent = { [weak loc] ev in _ = loc?.apply(ev) }
        loc.setCarryMode(f.activeCarryMode, respread: false)
    }

    /// 设朝向时点 / 拖到的位置：箭头从我的位置指向这里。
    func pointHeading(toward t: Point2) {
        guard headingEditing, let p = position, p.distance(to: t) > 10 else { return }
        headingRad = atan2(t.x - p.x, t.y - p.y)
        refreshHint()
    }

    /// - Parameter compass: nil = 按页面上「用罗盘修正航向」的开关；冷启动时显式指定。
    private func makeFusion(at p: Point2, heading: Double?, declinationDeg: Double? = nil, compass: Bool? = nil) -> FusionEngine {
        let store = MagMapStore.shared
        // 和离线评估（SessionEvaluator .pdrIMU、hpass-eval --motion pdr-imu）同一份配置（HPASSKit FusionEngine.live）：
        // 有场地通道时惯导位置被限制在通道里，罗盘按页面开关（冷启动显式指定）
        // 有磁场图时惯导只当增量送粒子滤波：不加通道约束（冷启动的绝对位置 / 航向是随便给的，投影会剪掉增量；粒子滤波自己有墙）
        return FusionEngine.live(corridors: store.field == nil ? store.crosses : [], start: p, headingRad: heading,
                                 compass: compass ?? useCompassHeading, stepLengthScale: stepScale,
                                 declinationDeg: declinationDeg ?? store.declinationDeg,
                                 carryMotion: Self.carryMotionEnabled)
    }

    private func makeLocalizer(field: MagneticFieldMap, start: Point2?, headingUnknown: Bool = false,
                               priorFraction: Double = 0) -> MagneticLocalizer {
        var cfg: MagneticConfig
        if start != nil {
            // 已知起点：和评估的已知起点分支同一份跟踪配置档（HPASSKit MagneticConfig.tracking），
            // 视觉里程计 / 计步各一套；跟踪策略（远跳要确认、丢了先在附近找回、地磁按覆盖打折）都在里面。
            // 这里只是初值：每一步按实际在推粒子的来源 loc.setOdometry(.vio / .pdr)（视觉里程计没对齐、跟丢、
            // 启动失败时是计步在推，要用计步那套参数）
            // 终端用户定位永远是计步在推粒子（摄像头只是可选的位置观测），用计步那套参数
            cfg = MagneticConfig.tracking(odometry: .pdr, headingKnown: !headingUnknown)
        } else {
            // 冷启动配置档（HPASSKit MagneticConfig.liveColdStart，评估的冷启动同一套）：
            // 大场地只靠地磁不报位置，等蓝牙 / 贴近标签 / 货架标识牌给出外部先验，或用户指起点；
            // 小场地（办公室 / 房间，没有蓝牙标签）只靠地磁也报
            cfg = MagneticConfig.liveColdStart(visualOdometry: false, mapAreaM2: Self.mapAreaM2)
        }
        cfg.lateralWeight = depthMode == .fuse ? 1 : 0
        cfg.carryModeAdaptive = Self.carryMotionEnabled
        let walk = MagMapStore.shared.walkableMap()
        if walk?.rooms != nil {
            // 办公室地图：不经门不能换房间、估计带房间、坐着不动时冻结（门限都是占位值，待自采 iPhone 双机数据标定）
            cfg.roomConstraints = true
            cfg.reportRoom = true
            cfg.stationaryFreeze = true
        }
        let loc = MagneticLocalizer(field: field, walkable: walk, config: cfg)
        loc.raycaster = MagMapStore.shared.raycaster()
        liveGeometryHash = MagMapStore.shared.geometryHash
        loc.reset(start: start, spreadCm: TrackingProfile.startSpreadCm, headingUnknown: headingUnknown, priorFraction: priorFraction)
        return loc
    }

    // MARK: 蓝牙粗定位

    /// 蓝牙底图：标签位置表（全店）+ 采集学到的（表明显不对时用学到的）
    private func bleBaseMap() -> BLEFingerprintMap? {
        let learned = MagMapStore.shared.bleMap
        let locs = StoreDataStore.shared.tagLocations
        if locs.isEmpty { return learned }
        return TagLocations.seededBLEMap(locs, learned: learned)
    }

    private func startBLE() {
        // 这张地图不用蓝牙（房间 / 办公室默认）：定位不开蓝牙，只在找标签时开扫描
        guard MapLibrary.shared.activeBLEEnabled else {
            AppLog.i("地磁", "这张地图不用蓝牙：只用计步 + 地磁（开了视觉增强时 + 视觉观测）")
            startFinderScanOnly()
            return
        }
        guard let m = bleBaseMap(), !m.tags.isEmpty else { startFinderScanOnly(); return }
        let pipe = self.pipe, queue = self.queue
        queue.sync { pipe.bleMap = m; pipe.bleAssist = nil; pipe.bleWindow = []; pipe.lastBleApply = 0 }
        if ble == nil { ble = BLEScanner() }
        ble?.onlyTags = true
        let whitelist = StoreDataStore.shared.tagIds
        let finder = finderBox
        ble?.onReading = { [weak self] r in
            guard let id = r.tagId, whitelist?.contains(id) ?? true else { return }
            if finder.matches(id) { Task { @MainActor in self?.heardTarget(rssi: Double(r.rssi)) } }
            queue.async {
                pipe.bleWindow.append((r.tMs, id, Double(r.rssi)))
                pipe.bleWriter?.append("\(r.tMs),,\(id),\(r.rssi),,")
                if pipe.bleWindow.count > 2000 { pipe.bleWindow.removeFirst(pipe.bleWindow.count - 2000) }
                // 手机贴近标签：信号特别强 → 人就在这片标签所在的货架前（2.5 m 以内）
                if Double(r.rssi) >= BLEAssist.touchRssi, r.tMs - pipe.lastTouchMs > 4000,
                   let tag = pipe.bleMap?.tags[id], let loc = pipe.localizer {
                    pipe.lastTouchMs = r.tMs
                    let c = Point2(tag.x, tag.y), radius = 250.0
                    let relocated = loc.applyRegion(distance: { max(0, $0.distance(to: c) - radius) }, sample: {
                        let a = Double.random(in: 0..<(2 * Double.pi)), d = radius * Double.random(in: 0..<1).squareRoot()
                        return Point2(c.x + cos(a) * d, c.y + sin(a) * d)
                    })
                    Task { @MainActor in self?.noteAnchor("贴近标签 \(id)", relocated: relocated) }
                }
            }
        }
        ble?.start()
        AppLog.i("地磁", "蓝牙粗定位：已开，指纹 \(m.tags.count) 个标签")
    }

    // MARK: 寻找模式：找一个标签

    /// 正在找的标签（地图上高亮它的货架；实时显示它的信号）
    @Published private(set) var findTarget: TagLocation?
    @Published private(set) var findRssi: Double?
    @Published private(set) var findLastHeard: Date?
    /// 信号在变强（1）/ 变弱（-1）/ 差不多（0）
    @Published private(set) var findTrend = 0
    private let finderBox = FinderBox()
    private var findHistory: [(Date, Double)] = []
    private var lastProximity = 0

    func setFindTarget(_ e: TagLocation?) {
        if navFromFind { stopNavigation() }
        findTarget = e
        finderBox.set(e?.id)
        findRssi = nil
        findLastHeard = nil
        findHistory = []
        lastProximity = 0
        if let e { AppLog.i("寻找", "找标签 \(e.id)：\(e.label) \(e.plano)") }
        if e != nil && phase == .live && ble == nil { startFinderScanOnly() }
        // 有货架就直接导航过去；还没定位的话等第一个位置
        if let code = e?.shelfCode { navigateToShelf(code: code, fromFind: true) }
    }

    /// 没有蓝牙底图时也要能找：只开扫描
    private func startFinderScanOnly() {
        guard phase == .live, finderBox.id != nil || findTarget != nil else { return }
        if ble == nil { ble = BLEScanner() }
        ble?.onlyTags = true
        let finder = finderBox
        ble?.onReading = { [weak self] r in
            guard let id = r.tagId, finder.matches(id) else { return }
            Task { @MainActor in self?.heardTarget(rssi: Double(r.rssi)) }
        }
        ble?.start()
    }

    private func heardTarget(rssi: Double) {
        let now = Date()
        findRssi = findRssi.map { $0 * 0.6 + rssi * 0.4 } ?? rssi
        findLastHeard = now
        findHistory.append((now, findRssi!))
        findHistory.removeAll { now.timeIntervalSince($0.0) > 6 }
        if let old = findHistory.first(where: { now.timeIntervalSince($0.0) > 2.5 }) {
            let d = findRssi! - old.1
            findTrend = d > 3 ? 1 : (d < -3 ? -1 : 0)
        }
        let prox = Self.proximity(findRssi!)
        if prox > lastProximity { UIImpactFeedbackGenerator(style: prox >= 3 ? .heavy : .light).impactOccurred() }
        lastProximity = prox
    }

    /// 0 远 / 1 附近 / 2 很近 / 3 就在旁边（标签广播功率小，按经验阈值）
    static func proximity(_ rssi: Double) -> Int { rssi > -60 ? 3 : (rssi > -70 ? 2 : (rssi > -80 ? 1 : 0)) }
    static let proximityText = ["还远（> 8 m）", "附近（3～8 m）", "很近（1～3 m）", "就在旁边（< 1 m）"]

    private func stopBLE() {
        ble?.stop()
        ble?.onReading = nil
        queue.async { [pipe] in pipe.bleMap = nil; pipe.bleAssist = nil; pipe.bleWindow = [] }
        bleEstimate = nil
    }

    /// 每秒一次：最近 2.5 秒听到的标签 → 粗定位、「不在采集区域」判断、交叉检验（BLEAssist，和回放评估同一套）。
    /// 在引擎队列上调用。
    private nonisolated func bleTick(pipe: MagPipeline, tMs: Int64, loc: MagneticLocalizer) {
        guard let m = pipe.bleMap, tMs - pipe.lastBleApply >= 1000 else { return }
        pipe.lastBleApply = tMs
        pipe.bleWindow.removeAll { $0.t < tMs - 2500 }
        var acc: [String: (Double, Int)] = [:]
        for r in pipe.bleWindow { let a = acc[r.id] ?? (0, 0); acc[r.id] = (a.0 + r.rssi, a.1 + 1) }
        if pipe.bleAssist == nil { pipe.bleAssist = BLEAssist(map: m) }
        let assist = pipe.bleAssist!
        let resetsBefore = assist.resets
        assist.tick(obs: acc.mapValues { $0.0 / Double($0.1) }, localizer: loc,
                    current: loc.isConverged ? pipe.lastShown : nil, candidate: pipe.estimate?.position)
        let e = assist.lastEstimate?.position, n = assist.lastHeard, outside = assist.outsideSurveyed
        let reset = assist.resets > resetsBefore
        Task { @MainActor in
            self.bleEstimate = e
            self.bleTagsHeard = n
            if self.bleOutside != outside {
                self.bleOutside = outside
                AppLog.w("地磁", outside ? "听到的标签大多不在指纹里：可能在没采集过的区域，先不定位" : "回到采集过的区域")
            }
            if reset { AppLog.w("地磁", "蓝牙判断地磁定位错了，重新找") }
        }
    }

    /// 读到货架黄标签（定位时摄像头本来就开着做视觉里程计）
    private func handleShelfSign(_ text: String) {
        guard !reviewMode else { return }           // 复核：摄像头只当裁判，货架标签不抓定位
        guard phase == .live, isTracking || searching, let ss = shelfSigns, let sg = ss.sign(for: text) else { return }
        if let l = lastSignText, l.0 == text, Date().timeIntervalSince(l.1) < 3 { return }
        lastSignText = (text, Date())
        liveSignsWriter?.append("\(Fmt.nowMs()),\(text),\(sg.shelfCode),")
        queue.async { [pipe] in
            guard let loc = pipe.localizer else { return }
            let relocated = loc.applyRegion(distance: { ss.distance(sg, from: $0) },
                                            sample: { ss.randomPoint(sg, u: Double.random(in: 0..<1), v: Double.random(in: 0..<1)) })
            Task { @MainActor in self.noteAnchor("位置标识牌 \(text)", relocated: relocated) }
        }
    }

    private func noteAnchor(_ what: String, relocated: Bool) {
        lastAnchorEvent = (what + (relocated ? "：位置定错了，已拉回" : ""), Date())
        if relocated {
            anchorFixes += 1
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            AppLog.w("地磁", "\(what)：和当前位置对不上，判定定错，重新定位")
        } else {
            AppLog.i("地磁", "\(what)：位置约束")
        }
    }

    /// 视觉重定位成功：ARKit 认出了房间，此刻相机位姿就在扫描时的坐标里，换到地图上就是一个位置观测。
    ///
    /// 不再「认出房间就直接用视觉位置、地磁不参与」：只在「视觉增强」打开、手机竖持 / 斜着看屏、ARKit 跟踪正常时，
    /// 把它当成一次 σ≈50 cm 的位置观测交给粒子滤波（VisualFixPolicy），计步照样推粒子。
    /// 还没有粒子滤波（这张地图没有磁场图）时，它就是一个外部给的起点。
    private func applyVisualFix(camera cam: simd_float4x4) {
        if reviewMode { applyReviewStart(camera: cam); return }
        guard phase == .live, isTracking || searching, let t = liveAlign else { return }
        guard VisualFixPolicy.acceptsFix(enhancementEnabled: cameraAllowed, posture: posture,
                                         arTrackingNormal: vioTracking == 2) else {
            AppLog.i("地磁", "视觉认出房间，但条件不满足（姿态 \(posture.title)，跟踪 \(vioTracking)），不当观测用")
            return
        }
        let (a, p, h) = visualPose(cam, t)
        let before = position
        let wasSearching = searching
        let applied: Bool = queue.sync {
            guard let loc = pipe.localizer else { return false }
            loc.applyPositionPrior(p, sigmaCm: VisualFixPolicy.sigmaCm, weight: 1,
                                   injectFraction: wasSearching ? VisualFixPolicy.searchInjectFraction : 0)
            pipe.aligner.set(t, ar: a)            // AR 叠加用（不影响粒子）
            pipe.pendingCheck = "视觉观测"
            return true
        }
        if !applied {
            // 没有地磁粒子滤波：视觉位置当起点，之后计步推算
            restartTracking(at: p, heading: h, checkLabel: "视觉定位", isCorrection: locState == .tracking)
            queue.sync { pipe.aligner.set(t, ar: a) }
            searching = false
            isTracking = true
            locState = .tracking
            position = p
            headingRad = h
            trail = [p]
        }
        visualFixes += 1
        endVisualSearch()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AppLog.i("地磁", "视觉认出房间：\(p)，朝向 \(Int(h * 180 / Double.pi))°，" + (applied ? "作为 σ \(Int(VisualFixPolicy.sigmaCm)) cm 的位置观测" : "作为起点")
                 + (before.map { "，当前估计偏 \(Int($0.distance(to: p))) cm" } ?? ""))
    }

    /// 相机位姿 → (ARKit 平面位置, 地图位置, 地图朝向)
    private func visualPose(_ cam: simd_float4x4, _ t: MapARTransform) -> (Point2, Point2, Double) {
        let a = Point2(Double(cam.columns.3.x) * 100, Double(cam.columns.3.z) * 100)
        let p = t.toMap(a)
        // 相机朝前 = −z 轴；转到地图系，朝向 0 = +y
        let f = Point2(-Double(cam.columns.2.x), -Double(cam.columns.2.z))
        let c = cos(t.phi), s = sin(t.phi)
        let d = Point2(f.x * c - f.y * s, f.x * s + f.y * c)
        let h = d.length > 0.1 ? atan2(d.x, d.y) : headingRad
        return (a, p, h)
    }

    // MARK: 视觉复核

    /// 复核时视觉认出房间：不当观测。起点选「视觉」且还没开始推算时，拿它当起点（相当于用户长按定点 + 设朝向），之后完全不管。
    private func applyReviewStart(camera cam: simd_float4x4) {
        guard phase == .live, let t = liveAlign else { return }
        visualFixes += 1
        reviewHasTruth = true
        endVisualSearch()
        guard reviewStartFromVisual, !isTracking else {
            AppLog.i("复核", "视觉认出房间（第 \(visualFixes) 次），只当真值，不喂给定位")
            return
        }
        let (a, p, h) = visualPose(cam, t)
        restartTracking(at: p, heading: h, checkLabel: "复核·视觉起点", isCorrection: false)
        queue.sync { pipe.aligner.set(t, ar: a) }            // AR 叠加用（不影响粒子）
        searching = false
        isTracking = true
        locState = .tracking
        position = p
        headingRad = h
        trail = [p]
        Haptics.success()
        AppLog.i("复核", "视觉认出房间：\(p)，朝向 \(Int(h * 180 / Double.pi))°，当起点；之后视觉只当真值")
    }

    /// 复核录制：review.csv 和真值变换。没有视觉特征地图 / 对齐变换时不录（界面会先拦住）。
    private func startReviewRecording() {
        reviewStats = PositionReviewStats()
        reviewTruth = nil
        reviewEstimate = nil
        reviewTruthTrail = []
        reviewEstTrail = []
        reviewHasTruth = false
        reviewTruthAt = nil
        visualCheckOn = false
        // 复核模式之外也录：地图有视觉对齐时，普通实时定位也拿视觉位置（黄点）自动校验地磁混合定位，写 review.csv
        guard let d = liveSessionDir, let t = liveAlign else { return }
        visualCheckOn = !reviewMode
        let w = try? CSVWriter(url: d.appendingPathComponent("review.csv"),
                               header: "t_ms,truth_x_cm,truth_y_cm,est_x_cm,est_y_cm,err_cm,unc_cm,converged,steps")
        queue.sync {
            pipe.reviewAlign = t
            pipe.reviewWriter = w
            pipe.reviewStats = PositionReviewStats()
            pipe.reviewLastMs = 0
            pipe.reviewLastPublishMs = 0
        }
        if reviewMode { UIApplication.shared.isIdleTimerDisabled = true }
        if reviewMode {
            AppLog.i("复核", "开始视觉复核：起点 \(reviewStartFromVisual ? "视觉" : "地磁自动定位")，视觉位置只当真值")
        } else {
            AppLog.i("复核", "视觉自动校验已打开：认出房间后视觉位置画成黄点，和定位位置逐 0.2 秒比，写 review.csv")
        }
    }

    private func stopReviewRecording() {
        let wasCheck = visualCheckOn
        visualCheckOn = false
        reviewTruthAt = nil
        guard reviewMode || wasCheck else { return }
        let stats: PositionReviewStats = queue.sync {
            pipe.reviewWriter?.close()
            pipe.reviewWriter = nil
            pipe.reviewAlign = nil
            return pipe.reviewStats
        }
        reviewStats = stats
        if reviewMode { UIApplication.shared.isIdleTimerDisabled = false }
        AppLog.i("复核", (reviewMode ? "" : "视觉自动校验：") + "复核结束：\(stats.count) 个样本，误差中位 \(stats.medianCm.map { Fmt.f($0 / 100, 2) } ?? "—") m，"
                 + "P90 \(stats.p90Cm.map { Fmt.f($0 / 100, 2) } ?? "—") m，2 m 内 \(stats.withinShare(200).map { "\(Int($0 * 100))%" } ?? "—")")
    }

    /// 真值位姿（引擎队列上，30 Hz → 5 Hz）：和此刻的地磁混合估计相减，写一行 review.csv；界面 2 Hz 刷新。
    private nonisolated func handleReviewTruth(t: Int64, a: Point2, pipe: MagPipeline) {
        guard let align = pipe.reviewAlign, pipe.mode == .live, t - pipe.reviewLastMs >= 200 else { return }
        pipe.reviewLastMs = t
        let truth = align.toMap(a)
        let est: Point2? = pipe.tracking ? pipe.lastShown : nil
        let conv = pipe.lastConverged
        let err = pipe.reviewStats.add(tMs: t, truth: truth, estimate: est, converged: conv)
        let steps = pipe.stepBase + (pipe.lastOut?.stepCount ?? 0)
        pipe.reviewWriter?.append([
            "\(t)", Fmt.f(truth.x, 1), Fmt.f(truth.y, 1),
            est.map { Fmt.f($0.x, 1) } ?? "", est.map { Fmt.f($0.y, 1) } ?? "",
            err.map { Fmt.f($0, 1) } ?? "", est == nil ? "" : Fmt.f(pipe.lastUncCm, 1),
            conv ? "1" : "0", "\(steps)",
        ].joined(separator: ","))
        guard t - pipe.reviewLastPublishMs >= 500 else { return }
        pipe.reviewLastPublishMs = t
        let stats = pipe.reviewStats
        Task { @MainActor in
            self.reviewStats = stats
            self.reviewTruth = truth
            self.reviewTruthAt = Date()
            self.reviewEstimate = est
            self.reviewHasTruth = true
            self.reviewTruthTrail.append(truth)
            if self.reviewTruthTrail.count > Self.reviewTrailCapacity { self.reviewTruthTrail.removeFirst(self.reviewTruthTrail.count - Self.reviewTrailCapacity) }
            if let e = est {
                self.reviewEstTrail.append(e)
                if self.reviewEstTrail.count > Self.reviewTrailCapacity { self.reviewEstTrail.removeFirst(self.reviewEstTrail.count - Self.reviewTrailCapacity) }
            }
        }
    }

    // MARK: 房间视觉认房间的等待状态

    private func beginVisualSearch() {
        guard visualAvailable else { return }
        visualSearchStarted = Date()
        visualTimeoutCounted = false
        visualTimer?.invalidate()
        visualTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.visualTick() }
        }
    }

    private func visualTick() {
        guard let s = visualSearchStarted, searching else { endVisualSearch(); return }
        if !reviewMode, !visualTimeoutCounted, Date().timeIntervalSince(s) >= Self.visualTimeoutSec {
            visualTimeoutCounted = true
            visualTimeouts += 1
            // 一直认不出（多半不在这个房间）：丢掉特征地图，ARKit 按普通模式跟踪，不然视觉里程计一直不可用
            ar.dropWorldMap()
            AppLog.w("地磁", "视觉认房间超过 \(Int(Self.visualTimeoutSec)) 秒还没认出来，改成普通跟踪（只用地磁 + ARKit）")
            endVisualSearch()
        }
    }

    private func endVisualSearch() {
        visualTimer?.invalidate()
        visualTimer = nil
        if visualSearchStarted != nil { visualSearchStarted = nil }
    }

    /// 在 p 以朝向 heading 重新开始推算（换一个新引擎，步数累加）。
    private func restartTracking(at p: Point2, heading: Double, checkLabel: String?, isCorrection: Bool) {
        let fusion = makeFusion(at: p, heading: heading)
        var localizer: MagneticLocalizer?
        if useMagCorrection, let field = MagMapStore.shared.field {
            localizer = makeLocalizer(field: field, start: p)
        }
        queue.sync {
            pipe.stepBase += pipe.lastOut?.stepCount ?? 0
            if !pipe.tracking { pipe.stepBase = 0 }
            pipe.fusion = fusion
            pipe.localizer = localizer
            Self.wireMotion(pipe)
            pipe.lastFusedPos = nil
            pipe.lastOut = nil
            pipe.tracking = true
            pipe.pos = p
            pipe.lastShown = p
            pipe.vioAccum = .zero
            pipe.vioRaw = false
            pipe.rotFit.reset()
            pipe.shownA = nil
            if pipe.vioEnabled {
                // 修正位置且旋转已经对齐：只拉位置；其他情况重新对齐
                pipe.vioPending = (isCorrection && pipe.aligner.isAligned) ? .keep(p) : .fresh(p, heading)
            }
            if let c = checkLabel { pipe.pendingCheck = c }
        }
    }

    /// 实时定位的录制：惯导（imu.csv v4：真四元数 + 重力列）、原始磁力计、蓝牙、货架标签、meta。
    /// 和摄像头无关：不开 ARKit 也录，这段定位可以用 hpass-replay 原样回放。
    private func startLiveRecording() {
        guard let stem = trackStem else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("mag-tracks", isDirectory: true).appendingPathComponent(stem + "_files", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let imuW = try? CSVWriter(url: d.appendingPathComponent("imu.csv"), header: IMUSample.csvHeaderV4)
        let rawW = try? CSVWriter(url: d.appendingPathComponent("mag_raw.csv"), header: "t_ms,mx,my,mz")
        let bleW = try? CSVWriter(url: d.appendingPathComponent("ble.csv"), header: "t_ms,point_id,esl_id,rssi,src,mfg_hex")
        liveSignsWriter = try? CSVWriter(url: d.appendingPathComponent("signs.csv"), header: "t_ms,text,shelf_code,confidence")
        liveFilesDir = d
        liveSessionDir = d
        liveStartMs = Fmt.nowMs()
        UIDevice.current.isBatteryMonitoringEnabled = true
        liveStartBattery = UIDevice.current.batteryLevel
        liveStartThermal = ProcessInfo.processInfo.thermalState.rawValue
        queue.sync { pipe.imuWriter = imuW; pipe.rawWriter = rawW; pipe.bleWriter = bleW }
        writeLiveMeta(final: false)
    }

    private var liveStartMs: Int64 = 0
    private var liveStartBattery: Float = -1
    private var liveStartThermal = 0

    /// meta.json：开始时写一次，结束时带上结束时间、电量、发热、磁力计偏置和盲测附加字段再写一次。
    private func writeLiveMeta(final: Bool) {
        guard let d = liveSessionDir else { return }
        var sys = utsname()
        uname(&sys)
        let model = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let (biasSrc, bias, fitRms) = queue.sync { (pipe.magBias.source.rawValue, pipe.magBias.bias, pipe.magBias.fitRmsUT) }
        // map_id：云端融合按它把实时定位的记录归到同一张地图；survey = false：不当建图会话用
        var meta: [String: Any] = [
            "platform": "ios", "live": true, "survey": false, "start_ms": liveStartMs,
            "map_id": MapLibrary.shared.activeId ?? "",
            "map_version": MapLibrary.shared.active?.cloudVersion ?? 0,
            "arkit": arLoggedThisSession, "camera": cameraAllowed,
            "map_source": MagMapStore.shared.magSource,
            "model": model, "os_version": UIDevice.current.systemVersion,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "imu_format": 4, "attitude_frame": motion.frameName,
            // 参考系不含磁力计时 imu.csv 的 mx..mz = 原始 − 偏置（mag_acc 2 = 本机存档，1 = 在线拟合，-1 = 还没有）
            "mag_calibration": motion.frameName == "xArbitraryZVertical" ? "app_hard_iron:\(biasSrc)" : "ios",
            "imu_convention": "android: acc m/s^2 incl. gravity (+z up when flat), gyro rad/s, mag uT; gvx..gvz gyro-aided gravity m/s^2 same sign as acc; qw..qz CoreMotion attitude in attitude_frame",
            "background_mode": BackgroundKeeper.enabledSetting,
            // 蓝牙扫描只在前台（没有服务 UUID 过滤，iOS 后台不回报）；锁屏后的冷启动拿不到蓝牙先验
            "ble_background": false,
            "carry_motion": Self.carryMotionEnabled,
            "room_constraints": MagMapStore.shared.walkableMap()?.rooms != nil,
            "mag_pollution": queue.sync { pipe.magBias.polluted },
            "battery_start": Double(liveStartBattery), "thermal_start": liveStartThermal,
        ]
        if let b = bias { meta["mag_bias_ut"] = [b.0, b.1, b.2] }
        if let r = fitRms { meta["mag_bias_fit_rms_ut"] = r }
        if final {
            meta["end_ms"] = Fmt.nowMs()
            meta["battery_end"] = Double(UIDevice.current.batteryLevel)
            meta["thermal_end"] = ProcessInfo.processInfo.thermalState.rawValue
            meta["visual_fixes"] = visualFixes
            if reviewMode || reviewStats.count > 0 { meta["review"] = reviewStats.summary() }
        }
        if reviewMode {
            meta["purpose"] = "review"
            meta["review_start"] = reviewStartFromVisual ? "visual" : "auto"
        }
        // 地图几何版本 / 原点平移（扫描段注册表）：回放时按它换算地图坐标
        for (k, v) in MapLibrary.shared.sessionMapMeta { meta[k] = v }
        for (k, v) in liveExtraMeta?() ?? [:] { meta[k] = v }
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: d.appendingPathComponent("meta.json"))
        }
    }

    /// 打开 ARKit（只在「视觉增强」开着、手机竖持时；由 arGateTick 按姿态启停）。
    private func startVisualOdometry() {
        guard !arRunning, cameraAllowed else { return }
        // ARKit 位姿只录第一段（按姿态多次启停时不覆盖）
        let dir: URL? = arLoggedThisSession ? nil : liveFilesDir
        let lateralFile = dir?.appendingPathComponent("depth_lateral.csv")
        do {
            let src = visualAvailable ? visualSource : nil
            let wm = src.flatMap { ARKitLogger.loadWorldMap($0.url) }
            if let src, wm == nil { AppLog.w("地磁", "视觉特征地图（\(src.label)）读不出来，只做普通跟踪") }
            try ar.start(dir: dir, wantsDepth: depthMode != .off, lateralFile: lateralFile, worldMap: wm)
            arRunning = true
            if dir != nil { arLoggedThisSession = true }
            shelfSigns = StoreDataStore.shared.map.map { ShelfSigns(map: $0, walkable: MagMapStore.shared.walkableMap()) }
            let reader = signReader
            ar.onFrame = { f, t in reader.process(f, tMs: t) }
            if wm != nil { AppLog.i("地磁", "已载入视觉特征地图（\(src?.label ?? "")）：手机竖着对着房间就能认出位置（只当位置观测）") }
            let mode: DepthMode = (reviewMode && depthMode == .fuse) ? .logOnly : depthMode    // 复核：深度不参与定位
            let h = headingRad
            queue.sync {
                pipe.vioEnabled = true
                pipe.lateralMode = mode
                // AR 叠加要重新对齐：从当前显示的位置和朝向开始
                if let p = pipe.lastShown ?? pipe.pos { pipe.vioPending = .fresh(p, h) }
            }
            AppLog.i("地磁", "摄像头已打开（视觉增强），LiDAR 深度 \(ARKitLogger.supportsLiDAR ? depthMode.title : "不支持")")
        } catch {
            lastError = "打开摄像头失败：\(error.localizedDescription)，只用计步推算"
            AppLog.e("地磁", lastError ?? "")
        }
    }

    private func stopVisualOdometry() {
        guard arRunning else { return }
        ar.onFrame = nil
        if liveWM?.defersStop != true { ar.stop() }      // 要刷新特征地图的话，取完再停（Plan.finish）
        arRunning = false
        arAlignment = nil
        arFloorY = nil
        queue.async { [pipe] in pipe.vioEnabled = false; pipe.vioActive = false; pipe.vioPending = nil; pipe.latestA = nil }
        vioTracking = 0
        vioAligned = false
    }

    // MARK: ARKit 按姿态启停

    private func startARGate() {
        arGateTimer?.invalidate()
        arGateSince = nil
        arBadTrackingSince = nil
        arCooldownUntil = nil
        arGateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.arGateTick() }
        }
    }

    private func stopARGate() {
        arGateTimer?.invalidate()
        arGateTimer = nil
    }

    /// 每秒一次：「视觉增强」开着且手机竖持 3 秒 → 开摄像头；姿态不对 6 秒、或 20 秒都没正常跟踪 → 关摄像头（关后 30 秒内不再开）。
    private func arGateTick() {
        if reviewMode, phase == .live {
            // 复核：摄像头从头到尾开着当裁判，不按姿态启停、也不等定位开始（跟踪不好时界面提示「竖着拿、对着房间」）
            if !arRunning { startVisualOdometry() }
            return
        }
        guard phase == .live, isTracking || searching else {
            if arRunning { stopVisualOdometry() }
            return
        }
        let now = Date()
        if arRunning {
            arBadTrackingSince = vioTracking == 2 ? nil : (arBadTrackingSince ?? now)
            if let b = arBadTrackingSince, now.timeIntervalSince(b) >= 20 {
                AppLog.i("地磁", "摄像头 20 秒都没正常跟踪（多半在口袋 / 包里），先关掉")
                stopVisualOdometry()
                arCooldownUntil = now.addingTimeInterval(30)
                arBadTrackingSince = nil
                return
            }
        }
        var want = VisualFixPolicy.wantsARSession(enhancementEnabled: cameraAllowed, posture: posture)
        if let c = arCooldownUntil, now < c { want = false }
        if want == arRunning { arGateSince = nil; return }
        let since = arGateSince ?? now
        arGateSince = since
        let need = want ? VisualFixPolicy.startAfterSec : VisualFixPolicy.stopAfterSec
        guard now.timeIntervalSince(since) >= need else { return }
        arGateSince = nil
        if want { startVisualOdometry() } else { stopVisualOdometry() }
    }

    // MARK: - 计步器 / 运动类型 / 温度

    private func startPedometerAndActivity() {
        if CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: Date()) { [weak self] d, _ in
                guard let d, let dist = d.distance?.doubleValue else { return }
                Task { @MainActor in self?.pedDistanceM = dist }
            }
        }
        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.startActivityUpdates(to: .main) { [weak self] a in
                guard let a else { return }
                var text = "未知"
                if a.stationary { text = "静止" } else if a.walking { text = "步行" } else if a.running { text = "跑步" }
                else if a.automotive { text = "乘车" } else if a.cycling { text = "骑行" }
                let conf = a.confidence == .high ? "高" : (a.confidence == .medium ? "中" : "低")
                self?.activityText = "\(text)（\(conf)）"
            }
        }
    }

    private func stopPedometerAndActivity() {
        pedometer.stopUpdates()
        activityManager.stopActivityUpdates()
    }

    /// 用计步器的距离核对自己的步长：每累计 20 m 比一次。打开「用计步器校正步长」才会真的调整。
    private func comparePedometer(pdrCm: Double) {
        guard let d = pedDistanceM else { return }
        let dp = d - pedBaseDist
        let dm = (pdrCm - pdrBaseCm) / 100
        guard dm >= 20, dp >= 10 else { return }
        let r = dp / dm
        pedometerRatio = r
        if usePedometerScale {
            stepScale = min(max(stepScale * (1 + 0.5 * (r - 1)), 0.8), 1.25)
            let sc = stepScale
            queue.async { [pipe] in pipe.fusion?.config.stepLengthScale = sc }
            AppLog.i("地磁", "计步器距离比 \(Fmt.f(r, 2))，步长缩放调整为 \(Fmt.f(sc, 3))")
        }
        pedBaseDist = d
        pdrBaseCm = pdrCm
    }

    // MARK: - 定位

    /// 开始定位。已知起点：站在 `startId` 点位上、面朝下一个点位（或上一个，如果它是最后一个）。
    /// `unknownStart` 为 true 时不给位置，粒子撒满全图，用来测试冷启动。
    func startLocalizing(startId: String?, unknownStart: Bool) {
        let store = MagMapStore.shared
        guard phase == .idle else { return }
        guard let field = store.field else {
            lastError = "还没有磁场数据，请先完成地磁校准"
            return
        }
        guard motion.isAvailable else {
            lastError = "设备运动传感器不可用"
            return
        }
        lastError = nil

        var start: Point2?
        var heading: Double?
        if !unknownStart, let sid = startId, let idx = store.points.firstIndex(where: { $0.id == sid }) {
            let p = store.points[idx]
            let other = idx + 1 < store.points.count ? store.points[idx + 1]
                : (idx > 0 ? store.points[idx - 1] : nil)
            start = p.position
            if let o = other { heading = atan2(o.x - p.x, o.y - p.y) }
        }
        route = store.points

        let fusion: FusionEngine
        let localizer: MagneticLocalizer
        if let st = start {
            // 已知起点：朝向取「面朝下一个点位」；只有一个点位时朝向未知，粒子全方向猜
            fusion = makeFusion(at: st, heading: heading ?? 0, compass: heading == nil ? false : nil)
            localizer = makeLocalizer(field: field, start: st, headingUnknown: heading == nil)
        } else {
            (fusion, localizer) = makeColdStart(field: field)
        }

        let writer = Self.makeTrackWriter()
        trackFileName = writer?.name
        trackStem = writer.map { ($0.name as NSString).deletingPathExtension }
        let useVIO = cameraAllowed
        if useVIO { startVisualOdometry() }
        let headingKnown = start != nil && heading != nil
        queue.sync {
            pipe.fusion = fusion
            pipe.localizer = localizer
            Self.wireMotion(pipe)
            pipe.lastFusedPos = nil
            pipe.lastOut = nil
            pipe.estimate = nil
            pipe.pendingCheck = nil
            pipe.trackWriter = writer?.writer
            pipe.tracking = true
            pipe.pos = start
            pipe.lastShown = start
            pipe.vioAccum = .zero
            pipe.rawLastA = nil
            pipe.vioRaw = false
            pipe.rotFit.reset()
            pipe.shownA = nil
            pipe.vioActive = false
            pipe.vioPending = (useVIO && pipe.vioEnabled && headingKnown) ? .fresh(start!, heading!) : nil
        }
        trail = []
        fixClassifier.reset()
        checks = []
        estimate = nil
        position = start
        locState = start == nil ? .searching : .tracking
        stepCount = 0
        hint = nil
        targetId = nil
        startMotion(mode: .localizing)
        AppLog.i("地磁", "开始定位：" + (start.map { "起点 \($0)" } ?? "未知起点，收敛前不显示位置") + "，粒子 \(start == nil ? MagneticConfig().coldStartParticleCount : MagneticConfig().particleCount)")
    }

    func stopLocalizing() {
        guard phase == .localizing else { return }
        stopMotion()
        locState = .idle
        queue.async { [pipe] in
            pipe.trackWriter?.close()
            pipe.trackWriter = nil
        }
        AppLog.i("地磁", "停止定位，验证 \(checks.count) 次")
    }

    /// 沿通道导航到地图上的一个位置（比如货架中心；规划会落到货架旁的通道上）。
    func navigate(to target: Point2, label: String, shelf: NavInstruction.Shelf? = nil) {
        let store = StoreDataStore.shared
        guard let map = store.map, !map.crosses.isEmpty || MagMapStore.shared.walkableMap() != nil else {
            lastError = "导航需要场地地图（障碍物和通道）"
            return
        }
        // 规划器按地图几何指纹缓存：原来只比货架数 / 通道数，挪了货架、改了通道走向但数量不变时继续用旧规划器（NAV-001）
        let key = map.geometryHash
        if nav == nil || key != navMapKey { rebuildNavPlanner(map: map) }
        navArrival.reset()
        targetId = nil
        hint = nil
        navLabel = label
        navShelf = shelf
        navArrived = false
        navHint = nav?.start(targets: [target], from: position)
        navRoute = nav?.route
        if position == nil {
            // 还没定位：先记下目标，第一个位置出来后自动规划
            AppLog.i("地磁", "导航到 \(label)：等定位")
        } else if navRoute == nil {
            lastError = "规划不出到「\(label)」的路线"
            navLabel = nil
            navShelf = nil
        } else {
            AppLog.i("地磁", "导航到 \(label)：路线 \(Int((navRoute?.length ?? 0) / 100)) m")
        }
    }

    /// 导航到一个货架：目标是货架朝通道那一面前方 90 cm 的站位点（不是货架中心），路线会停在正确的那条通道里。
    func navigateToShelf(code: String, fromFind: Bool = false) {
        guard let map = StoreDataStore.shared.map, let s = map.shelves.first(where: { $0.code == code }) else {
            lastError = "地图里没有障碍物 \(code)"
            return
        }
        let signs = ShelfSigns(map: map, walkable: MagMapStore.shared.walkableMap())
        let target = signs.sign(forShelfCode: code).map { signs.standPoint($0) } ?? Point2(s.x, s.y)
        navigate(to: target, label: code,
                 shelf: NavInstruction.Shelf(name: String(code.dropFirst("Shelf-".count)), center: Point2(s.x, s.y)))
        navFromFind = fromFind && navLabel != nil
    }

    /// 按当前地图重建路径规划器和到达判定（到达判定的「不隔货架 / 墙」用同一个规划器的几何）
    private func rebuildNavPlanner(map: StoreMap) {
        var cfg = RoutePlannerConfig()
        cfg.offRouteDistanceCm = 300          // 偏离 3 m 以上
        cfg.offRouteConfirmUpdates = 3        // 连续 3 次定位更新才重新规划
        let planner = RoutePlanner(shelves: map.shelves, crosses: map.crosses,
                                   walkable: MagMapStore.shared.walkableMap(), config: cfg)
        nav = NavigationSession(planner: planner)
        navArrival = ArrivalPolicy(lineClear: { a, b in planner.isLineClear(from: a, to: b) })
        navMapKey = map.geometryHash
    }

    /// 定位 / 导航进行中地图几何变了（采集页、扫描页改了地图，NAV-001）：正在跑的粒子滤波换上新的可走区域和射线模型，
    /// 导航按新地图重新规划（目标不变），货架标识牌也按新地图重建。每次出位置前查一次（只比较缓存的指纹字符串）
    private func refreshGeometryIfNeeded() {
        let store = MagMapStore.shared
        let h = store.geometryHash
        guard !h.isEmpty, h != liveGeometryHash else { return }
        let first = liveGeometryHash.isEmpty
        liveGeometryHash = h
        guard !first else { return }
        AppLog.i("地磁", "定位中地图几何变了：粒子滤波换新的可走区域，导航按新地图重新规划")
        let walk = store.walkableMap(), rc = store.raycaster()
        queue.async { [pipe] in pipe.localizer?.replaceGeometry(walkable: walk, raycaster: rc) }
        guard let map = StoreDataStore.shared.map else { return }
        if shelfSigns != nil { shelfSigns = ShelfSigns(map: map, walkable: walk) }
        if let old = nav, old.isActive, map.geometryHash != navMapKey {
            let targets = old.targets
            rebuildNavPlanner(map: map)
            navHint = nav?.start(targets: targets, from: position)
            navRoute = nav?.route
        }
    }

    func stopNavigation() {
        nav?.stop()
        navRoute = nil
        navHint = nil
        navLabel = nil
        navShelf = nil
        navArrived = false
        navFromFind = false
    }

    /// 导航栏的一句话（寻找模式和导航面板共用）
    var navText: String {
        if navArrived { return navArrivedText }
        guard let h = navHint else { return position == nil ? "等定位…" : "正在规划路线…" }
        return NavInstruction.text(h, shelf: navShelf)
    }

    func setTarget(_ id: String?) {
        targetId = id
        hint = nil
        refreshHint()
    }

    /// 「我现在就站在点位 id 上」：记录当前估计与真值的差。
    func recordCheck(pointId: String) {
        guard phase == .localizing, let p = position, let truth = MagMapStore.shared.point(id: pointId) else { return }
        let err = p.distance(to: truth.position)
        checks.append(MagCheck(pointId: pointId, errorCm: err))
        queue.async { [pipe] in pipe.pendingCheck = pointId }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AppLog.i("地磁", "验证 点位 \(pointId)：估计 \(p)，误差 \(Fmt.f(err, 0)) cm")
    }

    func clearError() { lastError = nil }

    /// 给界面显示的定位状态说明；正常跟踪时为 nil。
    var locStateText: String? {
        switch locState {
        case .searching:
            if bleOutside {
                return "听到的标签大多不在蓝牙指纹里：你可能在没采集过的区域，这里没法自动定位。走到采集过的通道（地图上绿色），或长按地图定点。"
            }
            if visualAvailable && arRunning {
                if phase == .live { return nil }           // 实时定位页由 VisualRelocalizeBanner 显示
                return "视觉增强：手机竖着对着墙和家具时会顺便认房间（只当位置观测）。" +
                    (MagMapStore.shared.field != nil ? "同时在用地磁找。" : "")
            }
            if bleTagsHeard == 0 && !MagneticConfig.magOnlyColdStartAllowed(mapAreaM2: Self.mapAreaM2) {
                // 冷启动配置档（MagneticConfig.liveColdStart）只靠地磁不报位置：要等外部先验或用户定点
                return "没听到蓝牙标签：只靠地磁自动定位很容易定到长得像的别处，所以先不显示位置。长按地图定点，或走到货架标识牌 / 蓝牙标签旁。"
            }
            if let s = searchStarted, Date().timeIntervalSince(s) > 45 {
                return "找了 \(Int(Date().timeIntervalSince(s))) 秒还没定到：可能不在采集过的区域（地图上绿色涂过的地方才能自动定位），或这里磁场太平。可以走到采集过的通道再走一段，或者长按地图手动定点。"
            }
            return "定位中：还没有把握，先不显示位置。请在采集过的通道（地图上绿色）里正常往前走 10～20 米。"
        case .lost: return "定位丢失：灰点是最后一个可信的位置，已冻结。走回采集过的通道会自动恢复，也可以长按地图手动定点。"
        default: return nil
        }
    }

    // MARK: - 传感器与流水线

    private func startMotion(mode: Phase) {
        let pipe = self.pipe
        let rawMode = mode != .calibrating && MagMapStore.shared.magSource == "raw"
        magSourceText = mode == .calibrating ? "iOS 校准后" : (rawMode ? "原始磁力计（估偏置中）" : "原始磁力计 − 本机偏置")
        queue.sync {
            pipe.mode = mode
            pipe.useRawMag = rawMode
            pipe.biasTracker.reset()
            pipe.magBias.reset()
            pipe.lastRaw = nil
            pipe.lastRawT = nil
            pipe.extractor.reset()
            pipe.latest = nil
            pipe.magGate.reset()
            pipe.calSamples = []
            pipe.lastCalSampleMs = 0
            pipe.lastPublishMs = 0
        }
        motion.onSample = { [weak self] s in
            guard let self else { return }
            self.queue.async { self.handleIMU(s, pipe: pipe) }
        }
        SensorArbiter.shared.claim("地磁定位") { [weak self] in
            guard let self else { return }
            switch self.phase {
            case .calibrating: self.finishCalibration(keep: false)
            case .live: self.stopLive()
            case .localizing: self.stopLocalizing()
            case .idle: break
            }
        }
        // 定位：本机有没过期的硬铁偏置存档时用 .xArbitraryZVertical（姿态不用磁力计），磁场 = 原始 − 偏置，开始后先核对一段；
        // 没有存档时用 .xArbitraryCorrectedZVertical，iOS 照常给校准后磁场（定位不用 CoreMotion 的偏航，姿态里有没有磁力计不影响）。
        // 校准（建图）保持含磁力计的参考系
        let frame: MotionRecorder.Frame = mode == .calibrating ? .mapping
            : (MagBiasStore.loadValid() != nil ? .positioning : .positioningCalibrated)
        let band = MagMapStore.shared.field.flatMap { Self.totalBand($0) }
        queue.sync { pipe.magBias.expectedTotalUT = band }
        motion.start(hz: 50, frame: frame)
        // 近距离传感器（盲测模式打开；贴耳 / 口袋）交给携带方式分类区分通话和竖持
        proximityObserver = NotificationCenter.default.addObserver(forName: UIDevice.proximityStateDidChangeNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.proximityChanged() }
        }
        // 原始磁力计：和校准后磁场的差就是系统当前估计的偏置，用来发现重新校准；
        // 定位参考系不含磁力计时，磁场就靠它减本机偏置
        if motion.manager.isMagnetometerAvailable && mode != .calibrating {
            motion.manager.magnetometerUpdateInterval = 0.02
            let queue = self.queue
            let epochOffset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
            motion.manager.startMagnetometerUpdates(to: rawMagQueue) { d, _ in
                guard let d else { return }
                let v = (d.magneticField.x, d.magneticField.y, d.magneticField.z)
                let t = Int64(((epochOffset + d.timestamp) * 1000).rounded())
                queue.async {
                    pipe.lastRaw = v
                    pipe.lastRawT = t
                    pipe.rawWriter?.append("\(t),\(Fmt.f(v.0, 3)),\(Fmt.f(v.1, 3)),\(Fmt.f(v.2, 3))")
                    pipe.magBias.addRaw(tMs: t, v)
                    // raw 模式：特征按原始磁力计的时刻算（重力方向来自加速度），不受 iOS 重新校准影响
                    if pipe.useRawMag, let m = pipe.biasTracker.corrected(v) ?? pipe.magBias.corrected(v) {
                        if let f = pipe.extractor.process(magnetic: m, tMs: t) {
                            pipe.latest = f
                            pipe.magGate.offer(f, tMs: t)
                        }
                    }
                }
            }
        }
        thermal = ProcessInfo.processInfo.thermalState
        thermalTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.thermal = ProcessInfo.processInfo.thermalState
                if self.thermal == .serious || self.thermal == .critical {
                    AppLog.w("地磁", "手机发热（\(self.thermal.rawValue)），ARKit 可能降频、定位会变差")
                }
            }
        }
        phase = mode
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// 地图磁场强度 |B| 的 P5～P95（偏置核对用）
    private static func totalBand(_ f: MagneticFieldMap) -> ClosedRange<Double>? {
        f.totalPercentiles(0.05, 0.95)
    }

    private func proximityChanged() {
        let dev = UIDevice.current
        let near: Bool? = dev.isProximityMonitoringEnabled ? dev.proximityState : nil
        let pipe = self.pipe
        queue.async { pipe.proximityNear = near }
    }

    private var proximityObserver: NSObjectProtocol?

    private func stopMotion() {
        if let o = proximityObserver { NotificationCenter.default.removeObserver(o); proximityObserver = nil }
        SensorArbiter.shared.release("地磁定位")
        motion.stop()
        motion.onSample = nil
        motion.manager.stopMagnetometerUpdates()
        stopVisualOdometry()
        stopPedometerAndActivity()
        thermalTimer?.invalidate()
        thermalTimer = nil
        stopARGate()
        queue.async { [pipe] in
            // 没有本机偏置存档时（参考系含磁力计、iOS 给校准值）攒够了就存一份：iOS 校准值一次定位里会漂几十 µT，
            // 固定偏置的读数前后一致得多（tools/collection_eval.py 的回访一致性）
            if pipe.mode != .calibrating, MagBiasStore.loadValid() == nil, !pipe.magBias.polluted,
               pipe.biasTracker.secondsSeen >= MagBiasStore.liveMinSeconds, let b = pipe.biasTracker.bias {
                MagBiasStore.save(b, source: "live")
            }
            pipe.mode = .idle
        }
        phase = .idle
        feature = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private nonisolated func handleIMU(_ s: IMUSample, pipe: MagPipeline) {
        // 「校准后」磁场：iOS 给的（参考系含磁力计时），否则原始磁力计 − 本机偏置
        var magCal: (Double, Double, Double)?
        var magAcc = s.magAccuracy
        if s.magValid {
            magCal = s.mag
        } else if let r = pipe.lastRaw, let rt = pipe.lastRawT, abs(rt - s.tMs) <= 40, let c = pipe.magBias.corrected(r) {
            magCal = c
            magAcc = pipe.magBias.source == .learned ? 2 : 1
        } else {
            magAcc = -1
        }
        let m = magCal ?? (0, 0, 0)
        // 陀螺辅助的重力（Android 约定）一起给：摆臂时「向上」不被手的离心加速度带偏（携带方式分类、Bz 都用它）
        let sample = HPASSKit.IMUSample(tMs: s.tMs, ax: s.acc.0, ay: s.acc.1, az: s.acc.2,
                                        gx: s.gyr.0, gy: s.gyr.1, gz: s.gyr.2,
                                        mx: m.0, my: m.1, mz: m.2,
                                        gravity: (s.grav.0, s.grav.1, s.grav.2))
        // v4：真四元数 + 陀螺辅助重力；mx..mz 写上面这个「校准后」磁场
        pipe.imuWriter?.append(s.csvLineV4(mag: m, magAcc: magAcc))
        let feat: MagneticFeature?
        // 「原始 − 校准」一直攒（地图不是 raw 也攒）：结束时没有本机存档就存下来，下次定位用固定偏置（MagBiasStore.liveMinSeconds）
        if s.magValid, let r = pipe.lastRaw, let rt = pipe.lastRawT, abs(rt - s.tMs) <= 30 {
            pipe.biasTracker.add(tMs: s.tMs, raw: r, calibrated: s.mag)
        }
        if pipe.useRawMag {
            pipe.extractor.updateGravity(sample)
            if pipe.biasTracker.isReady || pipe.magBias.bias != nil {
                // 只用 100 ms 以内的原始磁力计特征；磁力计停了这一刻就只靠计步（原来直接拿 pipe.latest，旧的会一直被重复用）
                feat = pipe.magGate.current(at: s.tMs)
            } else if s.magValid {
                // 偏置还没估出来（开始的前几秒）：先用校准后磁场
                feat = pipe.extractor.process(magnetic: s.mag, tMs: s.tMs)
                pipe.latest = feat
            } else {
                feat = nil
            }
        } else if magCal != nil {
            feat = pipe.extractor.process(sample)
            pipe.latest = feat
        } else {
            // 还没有可用的磁场（没有偏置存档、在线拟合也还没成）：只用计步 + 地图
            pipe.extractor.updateGravity(sample)
            feat = nil
        }
        pipe.magAccuracy = magAcc
        // raw 模式下系统重新校准不影响读数，可信度只看精度和总强度
        pipe.trustNow = pipe.trustMon.update(tMs: s.tMs, calibrated: m,
                                             raw: (pipe.useRawMag || !s.magValid) ? nil : pipe.lastRaw,
                                             accuracy: magAcc)
        pipe.posture = pipe.hold.process(sample)
        switch pipe.mode {
        case .idle:
            return
        case .calibrating:
            // 25 Hz 足够，省内存。磁场不可信的时刻不记，免得把坏数据写进地图
            if let f = feat, pipe.trustNow > 0.5, s.tMs - pipe.lastCalSampleMs >= 40 {
                pipe.calSamples.append(.init(tMs: s.tMs, feature: f))
                pipe.lastCalSampleMs = s.tMs
            }
            publishLive(pipe: pipe, tMs: s.tMs)
        case .live:
            pipe.fusion?.proximityNear = pipe.proximityNear
            guard let fusion = pipe.fusion, let out = fusion.process(sample) else {
                publishLive(pipe: pipe, tMs: s.tMs)
                return
            }
            pipe.lastOut = out
            // 推车嫌疑：在动，但三秒以上没有脚步
            if out.stepCount != pipe.lastStepCount { pipe.lastStepCount = out.stepCount; pipe.lastStepChangeMs = out.tMs }
            pipe.cartSuspected = out.isMoving && out.tMs - pipe.lastStepChangeMs > 3000
            guard pipe.tracking else {
                publishLive(pipe: pipe, tMs: s.tMs)
                return
            }
            let delta = pipe.lastFusedPos.map { out.position - $0 } ?? .zero
            pipe.lastFusedPos = out.position
            pipe.pdrDistanceCm += delta.length
            // 计步永远推粒子（摄像头开着也一样）：任何携带方式下定位都不依赖摄像头
            pipe.pos = (pipe.pos ?? out.position) + delta
            var shown = pipe.pos ?? out.position
            var unc = out.uncertaintyCm
            var est: MagneticEstimate?
            if let loc = pipe.localizer {
                bleTick(pipe: pipe, tMs: s.tMs, loc: loc)
                loc.setOdometry(.pdr)
                let lat = pipe.pendingLateral
                pipe.pendingLateral = nil
                // 办公室房间图：坐着不动够久冻结，连续走几步才解冻（StationaryFreezeDetector；没开房间约束时什么都不做）
                if loc.config.stationaryFreeze {
                    loc.feedStationary(&pipe.freezeDet, tMs: out.tMs, still: !out.isMoving, stepCount: out.stepCount)
                }
                let e = loc.step(delta: delta, feature: feat, trust: pipe.trustNow, lateral: lat)
                pipe.calibrator.step(deltaCm: delta.length, engine: fusion, localizer: loc)
                est = e
                shown = e.position
                unc = e.uncertaintyCm
            }
            pipe.lastShown = shown
            pipe.shownA = pipe.vioEnabled ? pipe.latestA : nil      // AR 叠加：和显示位置同一时刻的 ARKit 位置
            pipe.lastConverged = est?.converged ?? true
            pipe.lastHeadingRad = out.headingRad
            // 视觉里程计对齐用的航向提示：有粒子后验航向就用它（NAV-003），否则融合航向
            pipe.lastPostHeadingRad = est?.correctedHeading(pdrHeadingRad: out.headingRad)
            emit(pipe: pipe, tMs: out.tMs, shown: shown, unc: unc, est: est, heading: out.headingRad,
                 headingDeg: out.headingDeg, src: "pdr", feature: feat)
        case .localizing:
            guard let fusion = pipe.fusion, let loc = pipe.localizer, let out = fusion.process(sample) else {
                publishLive(pipe: pipe, tMs: s.tMs)
                return
            }
            let delta = pipe.lastFusedPos.map { out.position - $0 } ?? .zero
            pipe.lastFusedPos = out.position
            pipe.lastOut = out
            bleTick(pipe: pipe, tMs: s.tMs, loc: loc)
            loc.setOdometry(.pdr)
            let est = loc.step(delta: delta, feature: feat, trust: pipe.trustNow)
            pipe.calibrator.step(deltaCm: delta.length, engine: fusion, localizer: loc)
            pipe.estimate = est
            pipe.lastShown = est.position
            emit(pipe: pipe, tMs: out.tMs, shown: est.position, unc: est.uncertaintyCm, est: est,
                 heading: out.headingRad, headingDeg: out.headingDeg, src: "pdr", feature: feat)
        }
    }

    /// 写轨迹一行，并把位置送到界面。惯导路径和视觉里程计路径共用。
    private nonisolated func emit(pipe: MagPipeline, tMs: Int64, shown: Point2, unc: Double, est: MagneticEstimate?,
                                  heading: Double, headingDeg: Double, src: String, feature feat: MagneticFeature?) {
        let steps = pipe.stepBase + (pipe.lastOut?.stepCount ?? 0)
        pipe.lastUncCm = unc
        // 变化检测：只用有把握的定位（地磁收敛，或纯视觉 / 推算时没有地磁估计）
        if let m = pipe.monitor, let f = pipe.monitorField, let ft = feat, est?.converged == true {
            m.add(position: shown, feature: ft, field: f)
        }
        if let w = pipe.trackWriter {
            let check = pipe.pendingCheck ?? ""
            pipe.pendingCheck = nil
            // 房间（房间图地图）、自动判的携带方式、是否静止冻结
            let roomText: String = Fmt.csv(est?.roomId ?? "")
            let roomMassText: String = est?.roomId == nil ? "" : Fmt.f(est?.roomMass ?? 0, 3)
            let carryAuto: String = pipe.lastOut?.carryMode.rawValue ?? ""
            let frozenText: String = (pipe.localizer?.stationaryFrozen ?? false) ? "1" : "0"
            w.append([
                "\(tMs)", Fmt.f(shown.x, 1), Fmt.f(shown.y, 1),
                Fmt.f(unc, 1), Fmt.f(est?.confidence ?? -1, 3),
                Fmt.f(pipe.lastOut?.position.x ?? 0, 1), Fmt.f(pipe.lastOut?.position.y ?? 0, 1), Fmt.f(headingDeg, 1),
                "\(steps)",
                Fmt.f(feat?.total ?? 0, 2), Fmt.f(feat?.vertical ?? 0, 2), Fmt.f(feat?.horizontal ?? 0, 2),
                Fmt.csv(check), src, Fmt.f(pipe.trustNow, 2), pipe.posture.rawValue,
                pipe.lastLatLeft.map { Fmt.f($0, 0) } ?? "", pipe.lastLatRight.map { Fmt.f($0, 0) } ?? "",
                roomText, Fmt.csv(pipe.carryMode), roomMassText, carryAuto, frozenText,
            ].joined(separator: ","))
        }
        let acc = pipe.magAccuracy
        Task { @MainActor in
            self.magAccuracy = acc
            // 用了地磁粒子滤波、但它还没把握：不更新位置。之前从没定到过 = 搜索中（不显示）；定到过又丢了 = 冻结在最后的位置
            if let e = est, !e.converged {
                self.stepCount = steps
                self.estimate = e
                self.pauseNavigationWhileUnconverged(e)
                let next: LocState = (self.locState == .tracking || self.locState == .lost) ? .lost : .searching
                if next != self.locState {
                    self.locState = next
                    AppLog.w("地磁", next == .lost ? "定位丢失：位置冻结在 \(self.position.map { "\($0)" } ?? "—")，等重新匹配上"
                                                   : "定位中：还没有把握，先不显示位置")
                }
                return
            }
            if self.locState != .tracking {
                AppLog.i("地磁", (self.locState == .lost ? "定位恢复：" : "定位成功：") + "\(shown)，步数 \(steps)")
                self.locState = .tracking
            }
            self.searching = false
            self.applyFix(position: shown, uncertainty: unc, heading: heading, steps: steps, feature: feat, estimate: est)
        }
    }

    // MARK: 视觉里程计与深度

    /// ARKit 位姿（在引擎队列上）。终端用户定位里 ARKit 只是可选增强：位姿只用来给 AR 叠加对齐，
    /// **不推粒子**（计步永远在推，见 handleIMU），视觉重定位另走 applyVisualFix 当位置观测。
    private nonisolated func handlePose(t: Int64, a: Point2, state: Int, pipe: MagPipeline) {
        pipe.latestA = a
        pipe.vioTracking = state
        // 步长 K 的视觉里程计标定（HPASSKit StepScaleCalibrator.observeVisualOdometry）：ARKit 跟踪正常、在走路时
        // 比同一段的惯导净位移和 ARKit 净位移，学到的分携带方式 K 存本机（StepScaleStore），摄像头关着的下次定位也用上。
        // 只在惯导位置在更新时喂（lastFusedPos 只在这两种状态下逐拍更新）
        if let f = pipe.fusion, let q = pipe.lastFusedPos,
           (pipe.mode == .live && pipe.tracking) || pipe.mode == .localizing {
            pipe.calibrator.observeVisualOdometry(tMs: t, ar: a, trackingNormal: state == 2, pdr: q, engine: f)
        }
        guard pipe.vioEnabled, pipe.mode == .live || pipe.mode == .localizing, pipe.tracking else { return }
        if let pending = pipe.vioPending, state == 2 {
            switch pending {
            case .fresh(let p, let h): pipe.aligner.anchor(map: p, ar: a, headingRad: h)
            case .keep(let p): pipe.aligner.reanchorKeepingRotation(map: p, ar: a)
            }
            pipe.vioPending = nil
            pipe.vioAccum = .zero
        }
        guard pipe.vioPending == nil else { return }
        let out = pipe.aligner.process(ar: a, trackingNormal: state == 2,
                                       headingHint: pipe.lastPostHeadingRad ?? pipe.lastOut?.headingRad,
                                       currentMap: pipe.lastShown ?? pipe.pos)
        switch out {
        case .unaligned(let progress):
            pipe.vioActive = false
            pipe.vioProgress = progress
        case .aligned:
            pipe.vioActive = true
            pipe.vioProgress = 1
        }
    }

    /// 深度相机量到的左右货架距离（在引擎队列上）。
    private nonisolated func handleLateral(_ lat: DepthLateral, pipe: MagPipeline) {
        pipe.lastWallLeft = lat.wallLeftCm
        pipe.lastWallRight = lat.wallRightCm
        // 只有墙距离（前方视野里没东西）时保留上一次的货架距离，不让它闪成空
        guard lat.leftCm != nil || lat.rightCm != nil else { return }
        pipe.lastLatLeft = lat.leftCm
        pipe.lastLatRight = lat.rightCm
        guard pipe.mode == .live, pipe.vioActive, let phi = pipe.aligner.rotationRad else { return }
        // 相机朝向换到地图系，再得到行进方向角
        let c = cos(phi), s = sin(phi)
        let mx = lat.forwardAR.x * c - lat.forwardAR.z * s
        let my = lat.forwardAR.x * s + lat.forwardAR.z * c
        if pipe.lateralMode == .fuse {
            pipe.pendingLateral = LateralObservation(leftCm: lat.leftCm, rightCm: lat.rightCm, headingRad: atan2(mx, my))
        }
    }

    /// 刷新实时磁场读数和各路状态，最多 5 Hz。
    private nonisolated func publishLive(pipe: MagPipeline, tMs: Int64) {
        guard tMs - pipe.lastPublishMs >= 200 else { return }
        pipe.lastPublishMs = tMs
        let f = pipe.latest, n = pipe.calSamples.count
        let acc = pipe.magAccuracy, steps = pipe.stepBase + (pipe.lastOut?.stepCount ?? 0)
        let tracking = pipe.tracking
        let trust = pipe.trustNow, posture = pipe.posture, cart = pipe.cartSuspected
        let vioT = pipe.vioEnabled ? pipe.vioTracking : 0
        let aligned = pipe.vioActive, progress = pipe.vioProgress
        let pdr = pipe.pdrDistanceCm
        let lat = Self.lateralDescription(pipe.lastLatLeft, pipe.lastLatRight, wallLeft: pipe.lastWallLeft, wallRight: pipe.lastWallRight)
        // AR 叠加：以「界面上显示的位置」为锚点，这样地磁修正了位置，AR 里的货架也跟着挪，和地图上的点一致。
        // 旋转：对齐过的用对齐器的；冷启动用地磁轨迹和 ARKit 轨迹拟合出来的。地磁没把握时不显示。
        var alignment: MapARTransform?
        if pipe.vioEnabled, pipe.lastConverged, let p = pipe.lastShown, let a = pipe.shownA {
            let phi = pipe.vioRaw ? pipe.rotFit.phi : (pipe.vioActive ? pipe.aligner.transform?.phi : nil)
            if let phi { alignment = MapARTransform(pRef: p, aRef: a, phi: phi) }
        }
        let rawReady = pipe.useRawMag ? (pipe.biasTracker.bias ?? pipe.magBias.bias) : nil
        let rawMode = pipe.useRawMag
        // 参考系含磁力计时（本机没有偏置存档）iOS 给校准后磁场，不用本机偏置
        let biasSrc: MagBiasEstimator.Source = pipe.magAccuracy >= 0 && pipe.magBias.bias == nil && pipe.magBias.source != .rejected
            ? .ios : pipe.magBias.source
        Task { @MainActor in
            self.feature = f
            self.magTrust = trust
            self.posture = posture
            if self.phase == .calibrating { self.calSampleCount = n }
            if self.phase == .live {
                self.magAccuracy = acc
                if !tracking { self.stepCount = steps }
                self.cartSuspected = cart
                self.vioTracking = vioT
                self.vioAligned = aligned
                self.vioProgress = progress
                self.lateralText = lat
                if self.arAlignment != alignment { self.arAlignment = alignment }
                if rawMode {
                    let txt = rawReady.map { "原始磁力计（偏置 \(Int($0.0)), \(Int($0.1)), \(Int($0.2)) µT）" } ?? "原始磁力计（估偏置中）"
                    if self.magSourceText != txt { self.magSourceText = txt }
                } else {
                    let txt: String
                    switch biasSrc {
                    case .ios: txt = "iOS 校准后"
                    case .learned: txt = "原始磁力计 − 本机偏置（采集时学到的）"
                    case .sphereFit: txt = "原始磁力计 − 本机偏置（现场拟合）"
                    case .none: txt = "磁力计偏置未知：先只用计步（做一次采集或多转几下手机）"
                    case .rejected: txt = "磁力计读数和地图对不上（可能有磁吸附件 / 磁性保护壳）：这次只用计步 + 地图"
                    }
                    if self.magSourceText != txt { self.magSourceText = txt }
                }
                self.comparePedometer(pdrCm: pdr)
            }
        }
    }

    private nonisolated static func lateralDescription(_ l: Double?, _ r: Double?, wallLeft: Double? = nil, wallRight: Double? = nil) -> String {
        func f(_ v: Double?) -> String { v.map { String(Int($0)) } ?? "—" }
        var parts: [String] = []
        if l != nil || r != nil { parts.append("左 \(f(l)) / 右 \(f(r)) cm") }
        if wallLeft != nil || wallRight != nil { parts.append("墙 左 \(f(wallLeft)) / 右 \(f(wallRight)) cm") }
        return parts.joined(separator: " · ")
    }

    private func applyFix(position p: Point2, uncertainty: Double, heading: Double, steps: Int,
                          feature f: MagneticFeature?, estimate est: MagneticEstimate?) {
        guard phase == .localizing || (phase == .live && isTracking) else { return }
        refreshGeometryIfNeeded()
        estimate = est
        uncertaintyCm = uncertainty
        // 航向：有粒子滤波时用后验修正过的航向（粒子各自的航向偏差，主簇加权圆周均值，NAV-003）；
        // 后验航向多峰 / 散布太大时不画精确箭头。没有粒子滤波（纯计步）时照旧用融合航向
        let postHeading = est.flatMap { $0.correctedHeading(pdrHeadingRad: heading) }
        headingUncertain = est != nil && postHeading == nil
        if !headingEditing { headingRad = postHeading ?? heading }
        stepCount = steps
        feature = f
        // 显示平滑：小步移动取一半，蓝点连续滑动而不是一跳一跳；大跳（滤波切到别的簇、手动修正）直接到位
        let shown: Point2
        if let prev = position, prev.distance(to: p) < 300 {
            shown = prev + (p - prev) * 0.5
        } else {
            shown = p
        }
        if let prev = position, prev.distance(to: p) > 200 {
            AppLog.w("地磁", "位置跳变 \(Int(prev.distance(to: p))) cm：\(prev) → \(p)，置信度 \(est.map { Fmt.f($0.confidence, 2) } ?? "—")，不确定度 \(Int(uncertainty)) cm")
        }
        position = shown
        if let last = trail.last, last.distance(to: p) < 15 {
            // 太近不记
        } else {
            trail.append(p)
            if trail.count > Self.trailCapacity { trail.removeFirst(trail.count - Self.trailCapacity) }
        }
        refreshHint()
        // 统一的定位结果（位置 + 质量），导航按质量决定行为（NAV-004）
        let tMs = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        var fix: LocalizationFix
        if let e = est {
            fix = LocalizationFix.from(e, timestampMs: tMs, pdrHeadingRad: heading, classifier: &fixClassifier)
        } else {
            let q = fixClassifier.classify(position: p, timestampMs: tMs, uncertaintyCm: uncertainty, converged: true)
            fix = LocalizationFix(position: p, timestampMs: tMs, headingRad: heading, uncertaintyCm: uncertainty,
                                  quality: q, source: .pdr)
        }
        fix.position = shown
        if fixQuality != fix.quality {
            AppLog.i("地磁", "定位质量 \(fixQuality.rawValue) → \(fix.quality.rawValue)，不确定度 \(Int(uncertainty)) cm")
            fixQuality = fix.quality
        }
        if let n = nav, n.isActive, let h = n.onFix(fix) {
            navHint = h
            navRoute = h.route
            // 到达：原来「投影剩余 ≤ 120 cm」一次就停，人在货架背面 / 隔壁房间、定位跳一下都会误报（NAV-002）
            if navArrival.evaluate(fix: fix, hint: h) == .arrived {
                AppLog.i("地磁", "导航到达 \(navLabel ?? "")，离目标 \(Int(h.route.targetPoints.last.map { shown.distance(to: $0) } ?? 0)) cm")
                var done = h
                done.remainingDistance = 0                      // 到达播报（「到了，货架在右手边」）
                navArrivedText = NavInstruction.text(done, shelf: navShelf)
                n.stop()
                navRoute = nil
                navHint = nil
                navArrived = true
            }
        }
    }

    /// 粒子滤波没把握（搜索中 / 丢了）：位置不更新，但导航不能继续显示上一次的转向提示——
    /// 按 searching / lost 送进导航，播报变成「正在确认位置」，到达判定清零（NAV-004）
    private func pauseNavigationWhileUnconverged(_ e: MagneticEstimate) {
        let tMs = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let q = fixClassifier.classify(position: e.position, timestampMs: tMs, uncertaintyCm: e.uncertaintyCm, converged: false)
        if fixQuality != q {
            AppLog.i("地磁", "定位质量 \(fixQuality.rawValue) → \(q.rawValue)：导航暂停转向提示")
            fixQuality = q
        }
        headingUncertain = true
        navArrival.reset()
        guard let n = nav, n.isActive else { return }
        let fix = LocalizationFix(position: position ?? e.position, timestampMs: tMs, uncertaintyCm: e.uncertaintyCm,
                                  confidence: e.confidence, roomId: e.roomId, quality: q, source: .magnetic)
        if let h = n.onFix(fix) {
            navHint = h
            navRoute = h.route
        }
    }

    private func refreshHint() {
        guard let id = targetId, let p = position, let t = MagMapStore.shared.point(id: id) else {
            hint = nil
            return
        }
        let dx = t.x - p.x, dy = t.y - p.y
        let dist = (dx * dx + dy * dy).squareRoot()
        var turn = atan2(dx, dy) - headingRad
        turn = atan2(sin(turn), cos(turn))                 // 规范到 (−π, π]
        let arrived = dist <= Self.arriveCm
        hint = MagNavHint(targetId: id, distanceCm: dist, turnRad: turn, arrived: arrived)
        if arrived, autoAdvance, phase == .localizing || phase == .live {
            let pts = MagMapStore.shared.points
            if let i = pts.firstIndex(where: { $0.id == id }), i + 1 < pts.count {
                AppLog.i("地磁", "到达点位 \(id)，下一个目标 \(pts[i + 1].id)")
                targetId = pts[i + 1].id
                refreshHint()
            }
        }
    }

    // MARK: - 轨迹文件

    private static func makeTrackWriter() -> (writer: CSVWriter, name: String)? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("mag-tracks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let name = "mag_\(fmt.string(from: Date())).csv"
        guard let w = try? CSVWriter(url: dir.appendingPathComponent(name),
                                     header: "t_ms,x_cm,y_cm,unc_cm,conf,pdr_x,pdr_y,heading_deg,steps,b_total,b_vert,b_horiz,check,src,trust,posture,lat_left_cm,lat_right_cm,room_id,carry_mode,room_mass,carry_auto,frozen") else {
            return nil
        }
        return (w, name)
    }
}

/// 寻找模式的目标标签编号（蓝牙回调线程读、主线程写）
final class FinderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _id: String?
    var id: String? { lock.lock(); defer { lock.unlock() }; return _id }
    func set(_ v: String?) { lock.lock(); _id = v; lock.unlock() }
    func matches(_ v: String) -> Bool { lock.lock(); defer { lock.unlock() }; return _id == v }
}

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
    /// 朝向未知（冷启动 / 只知道位置）时，直接把 ARKit 的原始位移交给粒子滤波，旋转由粒子去猜
    var vioRaw = false
    /// 冷启动（不知道朝向）时，用「地磁定出来的地图位置 ↔ ARKit 位置」估旋转，给 AR 叠加用
    let rotFit = ARMapRotationFit()
    /// 和 lastShown 同一时刻的 ARKit 位置
    var shownA: Point2?
    /// 地磁滤波器当前是否有把握（没用地磁时为 true）
    var lastConverged = true
    /// 蓝牙粗定位：价签指纹、最近几秒的读数、上次用的时间
    var bleMap: BLEFingerprintMap?
    var bleAssist: BLEAssist?
    /// 地图还准不准（变化检测 + 定位时的磁场累积），有磁场图时才有
    var monitor: LiveFieldMonitor?
    var monitorField: MagneticFieldMap?
    var bleWindow: [(t: Int64, id: String, rssi: Double)] = []
    var lastBleApply: Int64 = 0
    /// 上次「贴近价签」定位的时间
    var lastTouchMs: Int64 = 0
    /// 实时定位录下来的蓝牙 / 货架标签（和 imu、mag_raw 一起上传，电脑上能原样回放）
    var bleWriter: CSVWriter?
    var rawLastA: Point2?

    // 磁场来源：地图用「原始磁力计减偏置」建的，实时也必须一样
    var useRawMag = false
    var imuWriter: CSVWriter?
    var rawWriter: CSVWriter?
    let biasTracker = RawBiasTracker()
    var lastRawT: Int64?

    // 深度横向距离
    var lateralMode: DepthMode = .off
    var pendingLateral: LateralObservation?
    var lastLatLeft: Double?
    var lastLatRight: Double?
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
        MapLibrary.shared.activeWorldMapURL != nil && StoreDataStore.shared.map?.arAlign != nil && ARKitLogger.isSupported
    }
    @Published private(set) var uncertaintyCm: Double = 0
    /// 用磁罗盘持续修正航向。钢货架附近罗盘常偏，默认关，只靠陀螺。
    @Published var useCompassHeading = false
    /// 有磁场地图时，用地磁粒子滤波纠偏。默认打开（没有磁场图时自然不生效）。
    @Published var useMagCorrection = true
    /// 用摄像头 + ARKit 视觉里程计做运动模型（取代计步）。丢跟踪时自动退回计步。
    @Published var useVisualOdometry = true
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
    private static let navArriveCm: Double = 120

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

    // 抓定位：货架黄标签（摄像头）、手机贴近价签。都是「人一定在这一小块」的确定观测，能把定错的位置拉回来
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
        AppLog.i("地磁", "实时定位：打开传感器，视觉里程计 \(useVisualOdometry ? "开" : "关")，深度 \(depthMode.title)，罗盘修正 \(useCompassHeading ? "开" : "关")，地磁纠偏 \(useMagCorrection ? "开" : "关")")
        startBLE()
        loadMonitor()
    }

    func stopLive() {
        guard phase == .live else { return }
        // 房间：认出房间的实时定位，结束时刷新特征地图（30 分钟内刷新过就不重复，免得每次都传几 MB）
        liveWM = arRunning ? WorldMapKeeper.Plan.make(ar: ar, sessionDir: liveFilesDir, name: "实时定位", minAgeMin: 30) : nil
        endVisualSearch()
        stopMotion()
        locState = .idle
        queue.async { [pipe] in
            pipe.trackWriter?.close()
            pipe.trackWriter = nil
            pipe.tracking = false
            pipe.bleWriter?.close()
            pipe.bleWriter = nil
        }
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
        guard let d = liveFilesDir, Telemetry.shared.enabled else {
            if let wm { Task { await wm.finish(upload: nil) } }       // 不上传也要把 ARKit 停掉、刷新本机特征地图
            return
        }
        liveFilesDir = nil
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let name = trackFileName {
            let src = docs.appendingPathComponent("mag-tracks", isDirectory: true).appendingPathComponent(name)
            try? FileManager.default.removeItem(at: d.appendingPathComponent("track.csv"))
            try? FileManager.default.copyItem(at: src, to: d.appendingPathComponent("track.csv"))
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)     // 等文件写完
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

    /// 不知道自己在哪：粒子撒满整张可走区域，沿通道走十几米后自动收敛。收敛之前不显示位置。
    func startColdSearch() {
        guard phase == .live, !isTracking else { return }
        let store = MagMapStore.shared
        searchStarted = Date()
        beginVisualSearch()
        guard let field = store.field else {
            // 没有磁场图，但有视觉特征地图：只靠视觉认房间
            guard visualAvailable else {
                lastError = "还没有磁场地图，无法自动定位"
                searchStarted = nil
                return
            }
            lastError = nil
            startVisualOdometry()
            searching = true
            isTracking = true
            locState = .searching
            position = nil
            trail = []
            AppLog.i("地磁", "自动定位：只用视觉（这张地图还没有磁场图）")
            return
        }
        lastError = nil
        let (fusion, localizer) = makeColdStart(field: field)
        let raw = useVisualOdometry && ARKitLogger.isSupported
        if raw { startVisualOdometry() }
        queue.sync {
            pipe.stepBase = 0
            pipe.fusion = fusion
            pipe.localizer = localizer
            pipe.lastFusedPos = nil
            pipe.lastOut = nil
            pipe.pos = nil
            pipe.lastShown = nil
            pipe.tracking = true
            pipe.vioPending = nil
            pipe.vioRaw = raw && pipe.vioEnabled
            pipe.rotFit.reset()
            pipe.shownA = nil
            pipe.vioActive = pipe.vioRaw          // 从一开始就不让计步推粒子：两种位移的旋转不一致
            pipe.rawLastA = nil
            pipe.vioAccum = .zero
        }
        searching = true
        isTracking = true
        locState = .searching
        position = nil
        trail = []
        AppLog.i("地磁", "自动定位：冷启动，运动 \(raw ? "视觉里程计" : "计步（误差大）")，地图朝向 " + (store.mapUpBearingDeg.map { "\(Int($0))°（一半粒子按罗盘，一半全方向）" } ?? "未设置（全方向猜）"))
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

    /// 设朝向时点 / 拖到的位置：箭头从我的位置指向这里。
    func pointHeading(toward t: Point2) {
        guard headingEditing, let p = position, p.distance(to: t) > 10 else { return }
        headingRad = atan2(t.x - p.x, t.y - p.y)
        refreshHint()
    }

    /// - Parameter compass: nil = 按页面上「用罗盘修正航向」的开关；冷启动时显式指定。
    private func makeFusion(at p: Point2, heading: Double?, declinationDeg: Double? = nil, compass: Bool? = nil) -> FusionEngine {
        let store = MagMapStore.shared
        var cfg = FusionConfig()
        // 有门店通道时，惯导位置被限制在通道里（与蓝牙定位页一致）
        cfg.useCorridorConstraint = !store.crosses.isEmpty
        cfg.useMagneticHeading = compass ?? useCompassHeading
        cfg.stepLengthScale = stepScale
        if let d = declinationDeg ?? store.declinationDeg { cfg.magneticDeclinationDeg = d }
        let f = FusionEngine(corridors: store.crosses, config: cfg)
        f.setInitialPosition(p, headingRad: heading)
        return f
    }

    private func makeLocalizer(field: MagneticFieldMap, start: Point2?, headingUnknown: Bool = false,
                               priorFraction: Double = 0) -> MagneticLocalizer {
        var cfg = MagneticConfig()
        // 冷启动时航向只来自罗盘，偏差可能很大
        if start == nil || headingUnknown { cfg.initialHeadingBiasSigmaDeg = 30 }
        if useVisualOdometry && start != nil {
            // 视觉里程计的位移和航向都比计步准得多，粒子不用撒那么开；丢跟踪退回计步时仍留有余量
            cfg.initialHeadingBiasSigmaDeg = 5
            cfg.headingBiasWalkDegPerM = 1
            cfg.positionNoiseFraction = 0.04
            cfg.initialScaleSigma = 0.03
            cfg.scaleWalkPerM = 0.003
        }
        if useVisualOdometry && ARKitLogger.isSupported {
            // 视觉里程计时：
            // - 以垂直分量 Bz 为主：人掉头时，手机偏置的估计误差会让水平分量 Bh 和总强度 |B| 的误差反过来，Bz 不受影响；
            // - 跳到远处另一个簇要连续确认 15 次（约 7.5 m）：视觉里程计一路漂移不到 1%，地磁只该做小修正；
            // - 收敛后粒子噪声调小，不会沿着「长得像」的通道滑走。
            cfg.featureWeights = (0.5, 1.0, 0.25)
            cfg.jumpConfirmUpdates = 15
            cfg.convergedPositionNoiseFraction = 0.03
        }
        cfg.lateralWeight = depthMode == .fuse ? 1 : 0
        // 每次读数的整体水平会差 10～16 µT（磁力计偏置估计不同）：没定到按起伏找，定到后估出偏移再按绝对值比
        cfg.hybridOffset = true
        let loc = MagneticLocalizer(field: field, walkable: MagMapStore.shared.walkableMap(), config: cfg)
        loc.raycaster = MagMapStore.shared.raycaster()
        loc.reset(start: start, spreadCm: 50, headingUnknown: headingUnknown, priorFraction: priorFraction)
        return loc
    }

    // MARK: 蓝牙粗定位

    /// 蓝牙底图：价签位置表（全店）+ 采集学到的（表明显不对时用学到的）
    private func bleBaseMap() -> BLEFingerprintMap? {
        let learned = MagMapStore.shared.bleMap
        let locs = StoreDataStore.shared.eslLocations
        if locs.isEmpty { return learned }
        return EslLocations.seededBLEMap(locs, learned: learned)
    }

    private func startBLE() {
        // 这张地图不用蓝牙（房间 / 办公室默认）：定位不开蓝牙，只在找价签时开扫描
        guard MapLibrary.shared.activeBLEEnabled else {
            AppLog.i("地磁", "这张地图不用蓝牙：只用地磁 + ARKit（+ 视觉定位）")
            startFinderScanOnly()
            return
        }
        guard let m = bleBaseMap(), !m.tags.isEmpty else { startFinderScanOnly(); return }
        let pipe = self.pipe, queue = self.queue
        queue.sync { pipe.bleMap = m; pipe.bleAssist = nil; pipe.bleWindow = []; pipe.lastBleApply = 0 }
        if ble == nil { ble = BLEScanner() }
        ble?.onlyESL = true
        let whitelist = StoreDataStore.shared.eslIds
        let finder = finderBox
        ble?.onReading = { [weak self] r in
            guard let id = r.eslId, whitelist?.contains(id) ?? true else { return }
            if finder.matches(id) { Task { @MainActor in self?.heardTarget(rssi: Double(r.rssi)) } }
            queue.async {
                pipe.bleWindow.append((r.tMs, id, Double(r.rssi)))
                pipe.bleWriter?.append("\(r.tMs),,\(id),\(r.rssi),,")
                if pipe.bleWindow.count > 2000 { pipe.bleWindow.removeFirst(pipe.bleWindow.count - 2000) }
                // 手机贴近价签：信号特别强 → 人就在这片价签所在的货架前（2.5 m 以内）
                if Double(r.rssi) >= BLEAssist.touchRssi, r.tMs - pipe.lastTouchMs > 4000,
                   let tag = pipe.bleMap?.tags[id], let loc = pipe.localizer {
                    pipe.lastTouchMs = r.tMs
                    let c = Point2(tag.x, tag.y), radius = 250.0
                    let relocated = loc.applyRegion(distance: { max(0, $0.distance(to: c) - radius) }, sample: {
                        let a = Double.random(in: 0..<(2 * Double.pi)), d = radius * Double.random(in: 0..<1).squareRoot()
                        return Point2(c.x + cos(a) * d, c.y + sin(a) * d)
                    })
                    Task { @MainActor in self?.noteAnchor("贴近价签 \(id)", relocated: relocated) }
                }
            }
        }
        ble?.start()
        AppLog.i("地磁", "蓝牙粗定位：已开，指纹 \(m.tags.count) 个价签")
    }

    // MARK: 寻找模式：找一个价签

    /// 正在找的价签（地图上高亮它的货架；实时显示它的信号）
    @Published private(set) var findTarget: EslLocation?
    @Published private(set) var findRssi: Double?
    @Published private(set) var findLastHeard: Date?
    /// 信号在变强（1）/ 变弱（-1）/ 差不多（0）
    @Published private(set) var findTrend = 0
    private let finderBox = FinderBox()
    private var findHistory: [(Date, Double)] = []
    private var lastProximity = 0

    func setFindTarget(_ e: EslLocation?) {
        if navFromFind { stopNavigation() }
        findTarget = e
        finderBox.set(e?.id)
        findRssi = nil
        findLastHeard = nil
        findHistory = []
        lastProximity = 0
        if let e { AppLog.i("寻找", "找价签 \(e.id)：\(e.label) \(e.plano)") }
        if e != nil && phase == .live && ble == nil { startFinderScanOnly() }
        // 有货架就直接导航过去；还没定位的话等第一个位置
        if let code = e?.shelfCode { navigateToShelf(code: code, fromFind: true) }
    }

    /// 没有蓝牙底图时也要能找：只开扫描
    private func startFinderScanOnly() {
        guard phase == .live, finderBox.id != nil || findTarget != nil else { return }
        if ble == nil { ble = BLEScanner() }
        ble?.onlyESL = true
        let finder = finderBox
        ble?.onReading = { [weak self] r in
            guard let id = r.eslId, finder.matches(id) else { return }
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

    /// 0 远 / 1 附近 / 2 很近 / 3 就在旁边（价签广播功率小，按经验阈值）
    static func proximity(_ rssi: Double) -> Int { rssi > -60 ? 3 : (rssi > -70 ? 2 : (rssi > -80 ? 1 : 0)) }
    static let proximityText = ["还远（> 8 m）", "附近（3～8 m）", "很近（1～3 m）", "就在旁边（< 1 m）"]

    private func stopBLE() {
        ble?.stop()
        ble?.onReading = nil
        queue.async { [pipe] in pipe.bleMap = nil; pipe.bleAssist = nil; pipe.bleWindow = [] }
        bleEstimate = nil
    }

    /// 每秒一次：最近 2.5 秒听到的价签 → 粗定位、「不在采集区域」判断、交叉检验（BLEAssist，和回放评估同一套）。
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
                AppLog.w("地磁", outside ? "听到的价签大多不在指纹里：可能在没采集过的区域，先不定位" : "回到采集过的区域")
            }
            if reset { AppLog.w("地磁", "蓝牙判断地磁定位错了，重新找") }
        }
    }

    /// 读到货架黄标签（定位时摄像头本来就开着做视觉里程计）
    private func handleShelfSign(_ text: String) {
        guard phase == .live, isTracking || searching, let ss = shelfSigns, let sg = ss.sign(for: text) else { return }
        if let l = lastSignText, l.0 == text, Date().timeIntervalSince(l.1) < 3 { return }
        lastSignText = (text, Date())
        liveSignsWriter?.append("\(Fmt.nowMs()),\(text),\(sg.shelfCode),")
        queue.async { [pipe] in
            guard let loc = pipe.localizer else { return }
            let relocated = loc.applyRegion(distance: { ss.distance(sg, from: $0) },
                                            sample: { ss.randomPoint(sg, u: Double.random(in: 0..<1), v: Double.random(in: 0..<1)) })
            Task { @MainActor in self.noteAnchor("货架标签 \(text)", relocated: relocated) }
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

    /// 视觉重定位成功：ARKit 认出了房间，此刻相机位姿就在扫描时的坐标里，换到地图上就是精确位置和朝向。
    private func applyVisualFix(camera cam: simd_float4x4) {
        guard phase == .live, isTracking || searching, let t = StoreDataStore.shared.map?.arAlign else { return }
        let a = Point2(Double(cam.columns.3.x) * 100, Double(cam.columns.3.z) * 100)
        let p = t.toMap(a)
        // 相机朝前 = −z 轴；转到地图系，朝向 0 = +y
        let f = Point2(-Double(cam.columns.2.x), -Double(cam.columns.2.z))
        let c = cos(t.phi), s = sin(t.phi)
        let d = Point2(f.x * c - f.y * s, f.x * s + f.y * c)
        let h = d.length > 0.1 ? atan2(d.x, d.y) : headingRad
        let wasTracking = locState == .tracking
        let before = position
        restartTracking(at: p, heading: h, checkLabel: "视觉定位", isCorrection: wasTracking)
        queue.sync {
            pipe.aligner.set(t, ar: a)
            pipe.vioPending = nil
            pipe.vioRaw = false
            pipe.vioActive = true
            pipe.pos = p
            pipe.lastShown = p
            pipe.shownA = a
            pipe.lastConverged = true
        }
        searching = false
        isTracking = true
        locState = .tracking
        position = p
        headingRad = h
        if wasTracking { trail.append(p) } else { trail = [p] }
        visualFixes += 1
        endVisualSearch()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AppLog.i("地磁", "视觉定位成功：\(p)，朝向 \(Int(h * 180 / Double.pi))°"
                 + (before.map { "，修正前偏 \(Int($0.distance(to: p))) cm" } ?? ""))
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
        if !visualTimeoutCounted, Date().timeIntervalSince(s) >= Self.visualTimeoutSec {
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
        if useVisualOdometry { startVisualOdometry() }
        queue.sync {
            pipe.stepBase += pipe.lastOut?.stepCount ?? 0
            if !pipe.tracking { pipe.stepBase = 0 }
            pipe.fusion = fusion
            pipe.localizer = localizer
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

    /// 打开 ARKit（只在开始推算时，不在检查传感器时占用摄像头）。
    private func startVisualOdometry() {
        guard !arRunning else { return }
        guard ARKitLogger.isSupported else {
            lastError = "这台设备不支持 ARKit，只用计步推算"
            return
        }
        var dir: URL?
        var lateralFile: URL?
        if let stem = trackStem {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let d = docs.appendingPathComponent("mag-tracks", isDirectory: true).appendingPathComponent(stem + "_files", isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            dir = d
            lateralFile = d.appendingPathComponent("depth_lateral.csv")
            // 原始惯导和磁力计也记下来，这段定位可以用 hpass-replay 原样回放
            let imuW = try? CSVWriter(url: d.appendingPathComponent("imu.csv"),
                                      header: "t_ms,ax,ay,az,gx,gy,gz,mx,my,mz,mag_acc,qw,qx,qy,qz,heading_deg")
            let rawW = try? CSVWriter(url: d.appendingPathComponent("mag_raw.csv"), header: "t_ms,mx,my,mz")
            // map_id：云端融合按它把实时定位的记录归到同一张地图；survey = false：不当建图会话用
            let meta: [String: Any] = ["platform": "ios", "live": true, "survey": false, "start_ms": Fmt.nowMs(),
                                       "map_id": MapLibrary.shared.activeId ?? "", "arkit": true,
                                       "map_source": MagMapStore.shared.magSource]
            if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) {
                try? data.write(to: d.appendingPathComponent("meta.json"))
            }
            let bleW = try? CSVWriter(url: d.appendingPathComponent("ble.csv"), header: "t_ms,point_id,esl_id,rssi,src,mfg_hex")
            liveSignsWriter = try? CSVWriter(url: d.appendingPathComponent("signs.csv"), header: "t_ms,text,shelf_code,confidence")
            liveFilesDir = d
            queue.sync { pipe.imuWriter = imuW; pipe.rawWriter = rawW; pipe.bleWriter = bleW }
        }
        do {
            let wm = visualAvailable ? MapLibrary.shared.activeWorldMapURL.flatMap(ARKitLogger.loadWorldMap) : nil
            try ar.start(dir: dir, wantsDepth: depthMode != .off, lateralFile: lateralFile, worldMap: wm)
            arRunning = true
            shelfSigns = StoreDataStore.shared.map.map { ShelfSigns(map: $0, walkable: MagMapStore.shared.walkableMap()) }
            let reader = signReader
            ar.onFrame = { f, t in reader.process(f, tMs: t) }
            if wm != nil { AppLog.i("地磁", "已载入视觉特征地图：对着房间转一圈就能认出位置") }
            queue.sync { pipe.vioEnabled = true; pipe.lateralMode = depthMode }
            AppLog.i("地磁", "视觉里程计已启动，LiDAR 深度 \(ARKitLogger.supportsLiDAR ? depthMode.title : "不支持")")
        } catch {
            lastError = "启动视觉里程计失败：\(error.localizedDescription)，只用计步推算"
            AppLog.e("地磁", lastError ?? "")
        }
    }

    private func stopVisualOdometry() {
        guard arRunning else { return }
        ar.onFrame = nil
        queue.async { [pipe] in
            pipe.imuWriter?.close(); pipe.imuWriter = nil
            pipe.rawWriter?.close(); pipe.rawWriter = nil
        }
        if liveWM?.defersStop != true { ar.stop() }      // 要刷新特征地图的话，取完再停（Plan.finish）
        arRunning = false
        arAlignment = nil
        arFloorY = nil
        queue.async { [pipe] in pipe.vioEnabled = false; pipe.vioActive = false; pipe.vioPending = nil }
        vioTracking = 0
        vioAligned = false
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
        let useVIO = useVisualOdometry && ARKitLogger.isSupported
        if useVIO { startVisualOdometry() }
        let headingKnown = start != nil && heading != nil
        queue.sync {
            pipe.fusion = fusion
            pipe.localizer = localizer
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
            pipe.vioRaw = useVIO && pipe.vioEnabled && !headingKnown
            pipe.rotFit.reset()
            pipe.shownA = nil
            pipe.vioActive = pipe.vioRaw
            pipe.vioPending = (useVIO && pipe.vioEnabled && headingKnown) ? .fresh(start!, heading!) : nil
        }
        trail = []
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
            lastError = "导航需要门店地图（货架和通道）"
            return
        }
        let key = "\(map.shelves.count)/\(map.crosses.count)"
        if nav == nil || key != navMapKey {
            var cfg = RoutePlannerConfig()
            cfg.offRouteDistanceCm = 300          // 偏离 3 m 以上
            cfg.offRouteConfirmUpdates = 3        // 连续 3 次定位更新才重新规划
            nav = NavigationSession(planner: RoutePlanner(shelves: map.shelves, crosses: map.crosses,
                                                          walkable: MagMapStore.shared.walkableMap(), config: cfg))
            navMapKey = key
        }
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
            lastError = "地图里没有货架 \(code)"
            return
        }
        let signs = ShelfSigns(map: map, walkable: MagMapStore.shared.walkableMap())
        let target = signs.sign(forShelfCode: code).map { signs.standPoint($0) } ?? Point2(s.x, s.y)
        navigate(to: target, label: code,
                 shelf: NavInstruction.Shelf(name: String(code.dropFirst("Shelf-".count)), center: Point2(s.x, s.y)))
        navFromFind = fromFind && navLabel != nil
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
                return "听到的价签大多不在蓝牙指纹里：你可能在没采集过的区域，这里没法自动定位。走到采集过的通道（地图上绿色），或长按地图定点。"
            }
            if visualAvailable && arRunning {
                if phase == .live { return nil }           // 实时定位页由 VisualRelocalizeBanner 显示
                return "正在认房间：拿着手机对着墙和家具慢慢转一圈（视觉定位，一般几秒）。" +
                    (MagMapStore.shared.field != nil ? "同时也在用地磁找。" : "")
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
        magSourceText = rawMode ? "原始磁力计（估偏置中）" : "iOS 校准后"
        queue.sync {
            pipe.mode = mode
            pipe.useRawMag = rawMode
            pipe.biasTracker.reset()
            pipe.lastRaw = nil
            pipe.lastRawT = nil
            pipe.extractor.reset()
            pipe.latest = nil
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
        motion.start(hz: 50)
        // 原始磁力计：和校准后磁场的差就是系统当前估计的偏置，用来发现重新校准
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
                    // raw 模式：特征按原始磁力计的时刻算（重力方向来自加速度），不受 iOS 重新校准影响
                    if pipe.useRawMag, let m = pipe.biasTracker.corrected(v) {
                        pipe.latest = pipe.extractor.process(magnetic: m, tMs: t) ?? pipe.latest
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

    private func stopMotion() {
        SensorArbiter.shared.release("地磁定位")
        motion.stop()
        motion.onSample = nil
        motion.manager.stopMagnetometerUpdates()
        stopVisualOdometry()
        stopPedometerAndActivity()
        thermalTimer?.invalidate()
        thermalTimer = nil
        queue.async { [pipe] in pipe.mode = .idle }
        phase = .idle
        feature = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private nonisolated func handleIMU(_ s: IMUSample, pipe: MagPipeline) {
        let sample = HPASSKit.IMUSample(tMs: s.tMs, ax: s.acc.0, ay: s.acc.1, az: s.acc.2,
                                        gx: s.gyr.0, gy: s.gyr.1, gz: s.gyr.2,
                                        mx: s.mag.0, my: s.mag.1, mz: s.mag.2)
        pipe.imuWriter?.append([
            "\(s.tMs)", Fmt.f(s.acc.0), Fmt.f(s.acc.1), Fmt.f(s.acc.2),
            Fmt.f(s.gyr.0, 5), Fmt.f(s.gyr.1, 5), Fmt.f(s.gyr.2, 5),
            Fmt.f(s.mag.0, 3), Fmt.f(s.mag.1, 3), Fmt.f(s.mag.2, 3), "\(s.magAccuracy)", "1", "0", "0", "0", "-1",
        ].joined(separator: ","))
        let feat: MagneticFeature?
        if pipe.useRawMag {
            pipe.extractor.updateGravity(sample)
            if let r = pipe.lastRaw, let rt = pipe.lastRawT, abs(rt - s.tMs) <= 30 {
                pipe.biasTracker.add(tMs: s.tMs, raw: r, calibrated: s.mag)
            }
            if pipe.biasTracker.isReady {
                feat = pipe.latest
            } else {
                // 偏置还没估出来（开始的前几秒）：先用校准后磁场
                feat = pipe.extractor.process(magnetic: s.mag, tMs: s.tMs)
                pipe.latest = feat
            }
        } else {
            feat = pipe.extractor.process(sample)
            pipe.latest = feat
        }
        pipe.magAccuracy = s.magAccuracy
        // raw 模式下系统重新校准不影响读数，可信度只看精度和总强度
        pipe.trustNow = pipe.trustMon.update(tMs: s.tMs, calibrated: s.mag, raw: pipe.useRawMag ? nil : pipe.lastRaw,
                                             accuracy: s.magAccuracy)
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
            if pipe.vioActive {
                // 视觉里程计在带位移，计步这路只更新统计
                publishLive(pipe: pipe, tMs: s.tMs)
                return
            }
            pipe.pos = (pipe.pos ?? out.position) + delta
            var shown = pipe.pos ?? out.position
            var unc = out.uncertaintyCm
            var est: MagneticEstimate?
            if let loc = pipe.localizer {
                bleTick(pipe: pipe, tMs: s.tMs, loc: loc)
                let e = loc.step(delta: delta, feature: feat, trust: pipe.trustNow)
                est = e
                shown = e.position
                unc = e.uncertaintyCm
            }
            pipe.lastShown = shown
            pipe.lastHeadingRad = out.headingRad
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
            if pipe.vioActive {
                publishLive(pipe: pipe, tMs: s.tMs)
                return
            }
            bleTick(pipe: pipe, tMs: s.tMs, loc: loc)
            let est = loc.step(delta: delta, feature: feat, trust: pipe.trustNow)
            pipe.estimate = est
            emit(pipe: pipe, tMs: out.tMs, shown: est.position, unc: est.uncertaintyCm, est: est,
                 heading: out.headingRad, headingDeg: out.headingDeg, src: "pdr", feature: feat)
        }
    }

    /// 写轨迹一行，并把位置送到界面。惯导路径和视觉里程计路径共用。
    private nonisolated func emit(pipe: MagPipeline, tMs: Int64, shown: Point2, unc: Double, est: MagneticEstimate?,
                                  heading: Double, headingDeg: Double, src: String, feature feat: MagneticFeature?) {
        let steps = pipe.stepBase + (pipe.lastOut?.stepCount ?? 0)
        // 变化检测：只用有把握的定位（地磁收敛，或纯视觉 / 推算时没有地磁估计）
        if let m = pipe.monitor, let f = pipe.monitorField, let ft = feat, est?.converged == true {
            m.add(position: shown, feature: ft, field: f)
        }
        if let w = pipe.trackWriter {
            let check = pipe.pendingCheck ?? ""
            pipe.pendingCheck = nil
            w.append([
                "\(tMs)", Fmt.f(shown.x, 1), Fmt.f(shown.y, 1),
                Fmt.f(unc, 1), Fmt.f(est?.confidence ?? -1, 3),
                Fmt.f(pipe.lastOut?.position.x ?? 0, 1), Fmt.f(pipe.lastOut?.position.y ?? 0, 1), Fmt.f(headingDeg, 1),
                "\(steps)",
                Fmt.f(feat?.total ?? 0, 2), Fmt.f(feat?.vertical ?? 0, 2), Fmt.f(feat?.horizontal ?? 0, 2),
                Fmt.csv(check), src, Fmt.f(pipe.trustNow, 2), pipe.posture.rawValue,
                pipe.lastLatLeft.map { Fmt.f($0, 0) } ?? "", pipe.lastLatRight.map { Fmt.f($0, 0) } ?? "",
            ].joined(separator: ","))
        }
        let acc = pipe.magAccuracy
        Task { @MainActor in
            self.magAccuracy = acc
            // 用了地磁粒子滤波、但它还没把握：不更新位置。之前从没定到过 = 搜索中（不显示）；定到过又丢了 = 冻结在最后的位置
            if let e = est, !e.converged {
                self.stepCount = steps
                self.estimate = e
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

    /// ARKit 位姿（在引擎队列上）。对齐之后用它的位移当运动模型；跟踪变差或还没对齐时由计步顶上。
    private nonisolated func handlePose(t: Int64, a: Point2, state: Int, pipe: MagPipeline) {
        pipe.latestA = a
        pipe.vioTracking = state
        guard pipe.vioEnabled, pipe.mode == .live || pipe.mode == .localizing, pipe.tracking else { return }

        if pipe.vioRaw {
            defer { pipe.rawLastA = state == 2 ? a : nil }
            guard state == 2, let last = pipe.rawLastA else { return }
            let d = a - last
            guard d.length < 300 else { return }                  // ARKit 坐标系重置，这一帧不算
            pipe.vioAccum = pipe.vioAccum + d
            guard pipe.vioAccum.length >= 20, let loc = pipe.localizer else { return }
            let step = pipe.vioAccum
            pipe.vioAccum = .zero
            bleTick(pipe: pipe, tMs: t, loc: loc)
            let e = loc.step(delta: step, feature: pipe.latest, trust: pipe.trustNow)
            // 朝向：用地图上显示位置的移动方向（ARKit 自己的方向和地图差一个未知旋转）
            if let ls = pipe.lastShown {
                let dv = e.position - ls
                if dv.length > 3 {
                    let u = dv * (1 / dv.length)
                    pipe.vioHeadingVec = pipe.vioHeadingVec * 0.85 + u * 0.15
                }
            }
            pipe.lastShown = e.position
            pipe.shownA = a
            pipe.lastConverged = e.converged
            if e.converged { pipe.rotFit.add(ar: a, map: e.position) } else { pipe.rotFit.reset() }
            pipe.pos = e.position
            let h = pipe.vioHeadingVec.length > 0.3 ? atan2(pipe.vioHeadingVec.x, pipe.vioHeadingVec.y) : pipe.lastHeadingRad
            pipe.lastHeadingRad = h
            var hd = h * 180 / Double.pi
            if hd < 0 { hd += 360 }
            emit(pipe: pipe, tMs: t, shown: e.position, unc: e.uncertaintyCm, est: e, heading: h, headingDeg: hd,
                 src: "vio-raw", feature: pipe.latest)
            return
        }

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
                                       headingHint: pipe.lastOut?.headingRad,
                                       currentMap: pipe.lastShown ?? pipe.pos)
        switch out {
        case .unaligned(let progress):
            pipe.vioActive = false
            pipe.vioProgress = progress
        case .aligned(let position, let delta):
            if !pipe.vioActive {
                // 刚切到视觉里程计：用它的位置接着走，不跳变（对齐输出的位置从锚点算起，与我们已显示的位置一致）
                pipe.vioActive = true
            }
            pipe.vioProgress = 1
            pipe.vioAccum = pipe.vioAccum + delta
            if delta.length > 1 {
                let u = delta * (1 / delta.length)
                pipe.vioHeadingVec = pipe.vioHeadingVec * 0.92 + u * 0.08
            }
            // 每走 20 cm 才往滤波器送一次，免得 30 Hz 的小步把位置噪声累积得太大
            guard pipe.vioAccum.length >= 20 else { return }
            let step = pipe.vioAccum
            pipe.vioAccum = .zero
            pipe.pos = position
            var shown = position
            var unc = 30.0
            var est: MagneticEstimate?
            if let loc = pipe.localizer {
                let lat = pipe.pendingLateral
                pipe.pendingLateral = nil
                bleTick(pipe: pipe, tMs: t, loc: loc)
                let e = loc.step(delta: step, feature: pipe.latest, trust: pipe.trustNow, lateral: lat)
                est = e
                shown = e.position
                unc = e.uncertaintyCm
            }
            pipe.lastShown = shown
            pipe.shownA = a
            pipe.lastConverged = est?.converged ?? true
            let h = pipe.vioHeadingVec.length > 0.3 ? atan2(pipe.vioHeadingVec.x, pipe.vioHeadingVec.y) : pipe.lastHeadingRad
            pipe.lastHeadingRad = h
            var hd = h * 180 / Double.pi
            if hd < 0 { hd += 360 }
            emit(pipe: pipe, tMs: t, shown: shown, unc: unc, est: est, heading: h, headingDeg: hd,
                 src: "vio", feature: pipe.latest)
        }
    }

    /// 深度相机量到的左右货架距离（在引擎队列上）。
    private nonisolated func handleLateral(_ lat: DepthLateral, pipe: MagPipeline) {
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
        let lat = Self.lateralDescription(pipe.lastLatLeft, pipe.lastLatRight)
        // AR 叠加：以「界面上显示的位置」为锚点，这样地磁修正了位置，AR 里的货架也跟着挪，和地图上的点一致。
        // 旋转：对齐过的用对齐器的；冷启动用地磁轨迹和 ARKit 轨迹拟合出来的。地磁没把握时不显示。
        var alignment: MapARTransform?
        if pipe.vioEnabled, pipe.lastConverged, let p = pipe.lastShown, let a = pipe.shownA {
            let phi = pipe.vioRaw ? pipe.rotFit.phi : (pipe.vioActive ? pipe.aligner.transform?.phi : nil)
            if let phi { alignment = MapARTransform(pRef: p, aRef: a, phi: phi) }
        }
        let rawReady = pipe.useRawMag ? pipe.biasTracker.bias : nil
        let rawMode = pipe.useRawMag
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
                }
                self.comparePedometer(pdrCm: pdr)
            }
        }
    }

    private nonisolated static func lateralDescription(_ l: Double?, _ r: Double?) -> String {
        guard l != nil || r != nil else { return "" }
        return "左 \(l.map { String(Int($0)) } ?? "—") / 右 \(r.map { String(Int($0)) } ?? "—") cm"
    }

    private func applyFix(position p: Point2, uncertainty: Double, heading: Double, steps: Int,
                          feature f: MagneticFeature?, estimate est: MagneticEstimate?) {
        guard phase == .localizing || (phase == .live && isTracking) else { return }
        estimate = est
        uncertaintyCm = uncertainty
        if !headingEditing { headingRad = heading }
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
        if let n = nav, n.isActive, let h = n.onLocation(shown) {
            navHint = h
            navRoute = h.route
            if h.remainingDistance <= Self.navArriveCm {
                AppLog.i("地磁", "导航到达 \(navLabel ?? "")")
                navArrivedText = NavInstruction.text(h, shelf: navShelf)
                n.stop()
                navRoute = nil
                navHint = nil
                navArrived = true
            }
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
                                     header: "t_ms,x_cm,y_cm,unc_cm,conf,pdr_x,pdr_y,heading_deg,steps,b_total,b_vert,b_horiz,check,src,trust,posture,lat_left_cm,lat_right_cm") else {
            return nil
        }
        return (w, name)
    }
}

/// 寻找模式的目标价签编号（蓝牙回调线程读、主线程写）
final class FinderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _id: String?
    var id: String? { lock.lock(); defer { lock.unlock() }; return _id }
    func set(_ v: String?) { lock.lock(); _id = v; lock.unlock() }
    func matches(_ v: String) -> Bool { lock.lock(); defer { lock.unlock() }; return _id == v }
}

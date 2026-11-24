import CoreBluetooth
import Foundation
import HPASSKit
import UIKit

// MARK: - 流水线内核

/// 持有 HPASSKit 的三个非线程安全对象（指纹定位器 / 融合引擎 / 导航会话）。
///
/// **本类的任何成员只允许在 `LiveLocationEngine` 的 `live.pipeline` 串行队列上访问。**
/// 蓝牙回调、IMU 回调、1 Hz 节拍、界面发来的命令全部先 `async` 到那条队列，
/// 再回到主线程发布界面状态。主线程绝不直接碰这些对象。
private final class LivePipeline {

    /// 指纹定位结果与融合结果相差多少厘米算「分歧」（写一条警告日志）
    static let divergeThresholdCm: Double = 300
    /// 标定用滚动缓冲保留多久
    static let calBufferMs: Int64 = 120_000

    // 场地数据快照（启动时从 StoreDataStore 取一次）
    let points: [FingerprintPoint]
    let tagToShelf: [String: String]

    let positioner: FingerprintPositioner
    let fusion: FusionEngine
    let nav: NavigationSession
    /// 到达判定（NAV-002）和定位质量（NAV-004）
    var arrival = ArrivalPolicy()
    var fixClassifier = FixQualityClassifier()

    // 最近状态
    var estimate: PositionEstimate?
    var fused: FusionOutput?
    var hint: NavHint?
    var useIMU = true

    // 统计：最近 2 秒的 (时间, 标签 ID)
    var recent: [(t: Int64, id: String)] = []
    var readingsPerSecond = 0
    var uniqueTagsPerSecond = 0

    // 标定缓冲
    var calBuffer: [HPASSKit.BLEReading] = []
    /// 非 nil 表示正在采集某个已知指纹点
    var knownPointId: String?
    var knownBuffer: [HPASSKit.BLEReading] = []

    // 轨迹 CSV
    var trackWriter: CSVWriter?

    // 日志限流
    var lastPosLogMs: Int64 = 0
    var lastDivergeLogMs: Int64 = 0
    var gotFirstFix = false

    init(points: [FingerprintPoint],
         tagToShelf: [String: String],
         map: StoreMap,
         positioning: PositioningConfig,
         fusionConfig: FusionConfig,
         plannerConfig: RoutePlannerConfig = .init()) {
        self.points = points
        self.tagToShelf = tagToShelf
        self.positioner = FingerprintPositioner(points: points, tagToShelf: tagToShelf, config: positioning)
        self.fusion = FusionEngine(map: map, config: fusionConfig)
        let planner = RoutePlanner(map: map, config: plannerConfig)
        self.nav = NavigationSession(planner: planner)
        self.arrival = ArrivalPolicy(lineClear: { a, b in planner.isLineClear(from: a, to: b) })
    }

    /// 当前用于显示的位置：开启 IMU 时用融合结果，否则用原始指纹结果。
    var displayPosition: Point2? {
        if useIMU, let f = fused { return f.position }
        return estimate?.position
    }
}

// MARK: - 发布给界面的快照

/// 一帧界面状态。由流水线队列组装，整体送到主线程，避免字段之间不一致。
struct LiveSnapshot {
    var estimate: PositionEstimate?
    var fused: FusionOutput?
    var display: Point2?
    var headingRad: Double = 0
    var hint: NavHint?
    var route: Route?
    var readingsPerSecond: Int = 0
    var uniqueTagsPerSecond: Int = 0
    var stepCount: Int = 0
    var wasConstrained: Bool = false
    /// 本帧导航已结束（到达），界面需要复位导航开关
    var navFinished: Bool = false
}

// MARK: - 引擎

/// 实时定位 / 导航流水线。
///
/// 自己持有一套 `BLEScanner` + `MotionRecorder`，与「录制」页完全独立。
/// **注意：边录制边跑实时定位意味着同时存在两个蓝牙扫描器**，iOS 下会互相摊薄广播回调、
/// 读数率下降。界面用 `isRunning` 提示用户不要同时开。
@MainActor
final class LiveLocationEngine: ObservableObject {

    // MARK: 发布状态

    @Published private(set) var isRunning = false
    @Published private(set) var estimate: PositionEstimate?
    @Published private(set) var fused: FusionOutput?
    @Published private(set) var displayPosition: Point2?
    @Published private(set) var headingRad: Double = 0
    @Published private(set) var hint: NavHint?
    @Published private(set) var route: Route?
    @Published private(set) var readingsPerSecond = 0
    @Published private(set) var uniqueTagsPerSecond = 0
    @Published private(set) var stepCount = 0
    @Published private(set) var wasConstrained = false
    @Published private(set) var bleState = "未知"
    @Published private(set) var lastError: String?
    /// 走过的轨迹（cm），环形缓冲
    @Published private(set) var trail: [Point2] = []

    @Published private(set) var isNavigating = false
    @Published private(set) var isRecordingTrack = false
    @Published private(set) var trackFileName: String?
    /// 正在采集的已知指纹点编号；nil 表示没在采
    @Published private(set) var knownPointCapturing: String?
    /// 最近一次标定结果
    @Published private(set) var calibration: RSSICalibration?
    /// 标定结果的文字说明
    @Published private(set) var calibrationNote: String?
    @Published private(set) var isCalibrating = false

    // MARK: 参数（界面可改，改完下推到流水线队列）

    @Published var rssiOffset: Double = 0 { didSet { pushConfig() } }
    @Published var rssiScale: Double = 1 { didSet { pushConfig() } }
    @Published var useGraphSmoothing = true { didSet { pushConfig() } }
    @Published var useIMU = true { didSet { pushConfig() } }
    @Published var magneticDeclinationDeg: Double = 0 { didSet { pushConfig() } }
    @Published var useCorridorConstraint = true { didSet { pushConfig() } }

    /// 轨迹最多保留多少个点
    static let trailCapacity = 600
    /// 两个轨迹点之间至少相隔多少厘米才记一笔
    private static let trailMinStepCm: Double = 20

    // MARK: 内部

    private let ble = BLEScanner()
    private let motion = MotionRecorder()
    /// HPASSKit 的三个对象全部只在这条队列上使用
    private nonisolated let queue = DispatchQueue(label: "live.pipeline", qos: .userInitiated)
    private var pipeline: LivePipeline?
    /// 内核是按哪份场地数据建的（指纹点数 + 标签数），数据换了就重建
    private var pipelineSignature: Int?
    private var tickTimer: DispatchSourceTimer?

    init() {
        ble.onState = { [weak self] state in
            Task { @MainActor in self?.bleState = LiveLocationEngine.describe(state) }
        }
    }

    // MARK: - 启停

    func start() {
        guard !isRunning else { return }
        let store = StoreDataStore.shared
        guard store.isReady, let map = store.map else {
            lastError = "请先在场地数据页导入地图、指纹和标签"
            return
        }
        lastError = nil

        // 复用已有内核（保留标定滚动缓冲），场地数据换了才重建
        let fpCount = store.fingerprints.count
        let tagCount = store.tagItems.count
        let signature = fpCount &* 1_000_003 &+ tagCount
        let pipe: LivePipeline
        if let existing = pipeline, pipelineSignature == signature {
            pipe = existing
        } else {
            pipe = LivePipeline(points: store.fingerprints,
                                tagToShelf: store.tagToShelf,
                                map: map,
                                positioning: positioningConfig(),
                                fusionConfig: fusionConfig())
            pipeline = pipe
            pipelineSignature = signature
        }

        let cfgP = positioningConfig()
        let cfgF = fusionConfig()
        let imu = useIMU
        queue.async {
            pipe.positioner.config = cfgP
            pipe.fusion.config = cfgF
            pipe.useIMU = imu
            pipe.positioner.reset()
            pipe.fusion.reset()
            pipe.nav.stop()
            pipe.estimate = nil
            pipe.fused = nil
            pipe.hint = nil
            pipe.recent.removeAll()
            pipe.gotFirstFix = false
            pipe.lastPosLogMs = 0
            pipe.lastDivergeLogMs = 0
        }

        trail = []
        estimate = nil
        fused = nil
        displayPosition = nil
        hint = nil
        route = nil
        isNavigating = false
        stepCount = 0

        // BLE：回调线程 → 流水线队列
        ble.onlyTags = true
        ble.onReading = { [weak self] r in
            guard let self else { return }
            self.queue.async { self.handleReading(r, pipe: pipe) }
        }
        // IMU：OperationQueue → 流水线队列
        motion.onSample = { [weak self] s in
            guard let self else { return }
            self.queue.async { self.handleIMU(s, pipe: pipe) }
        }
        ble.start()
        motion.start(hz: 50, frame: .mapping)      // 这页用 iOS 校准后磁场，保持原来的参考系
        if !motion.isAvailable {
            lastError = "设备运动传感器不可用，只能用纯指纹定位"
        }

        // 1 Hz 节拍直接跑在流水线队列上
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick(pipe: pipe) }
        tickTimer = t
        t.activate()

        isRunning = true
        SensorArbiter.shared.claim("蓝牙定位") { [weak self] in self?.stop() }
        AppLog.i("实时定位", "开始：\(fpCount) 个指纹点，\(tagCount) 个标签，"
                 + "offset \(Fmt.f(rssiOffset, 1)) / scale \(Fmt.f(rssiScale, 2))，"
                 + "IMU \(useIMU ? "开" : "关")，平滑 \(useGraphSmoothing ? "开" : "关")")
    }

    func stop() {
        guard isRunning else { return }
        ble.stop()
        motion.stop()
        ble.onReading = nil
        motion.onSample = nil
        tickTimer?.cancel()
        tickTimer = nil
        isRunning = false
        SensorArbiter.shared.release("蓝牙定位")
        stopTrackRecording()
        if let pipe = pipeline {
            queue.async {
                pipe.nav.stop()
                if let id = pipe.knownPointId {
                    pipe.knownPointId = nil
                    pipe.knownBuffer.removeAll()
                    AppLog.w("实时定位", "停止时放弃了点位 \(id) 的标定采集")
                }
            }
        }
        knownPointCapturing = nil
        isNavigating = false
        AppLog.i("实时定位", "停止")
    }

    // MARK: - 流水线（全部在 queue 上执行）

    /// App 的 `BLEReading` → `HPASSKit.BLEReading`。type = 1 表示手机蓝牙扫描。
    private nonisolated func handleReading(_ r: BLEReading, pipe: LivePipeline) {
        guard let id = r.tagId, !id.isEmpty else { return }   // 没解出标签 ID 的广播对定位无用
        let reading = HPASSKit.BLEReading(tagId: id, rssi: r.rssi, type: 1, tMs: r.tMs)
        pipe.positioner.add([reading])

        pipe.recent.append((r.tMs, id))
        pipe.calBuffer.append(reading)
        if pipe.knownPointId != nil { pipe.knownBuffer.append(reading) }

        // 滚动裁剪
        if pipe.calBuffer.count > 200, let newest = pipe.calBuffer.last?.tMs {
            let from = newest - LivePipeline.calBufferMs
            if let first = pipe.calBuffer.first, first.tMs < from {
                pipe.calBuffer.removeAll { $0.tMs < from }
            }
        }
    }

    /// App 的 `IMUSample`（已是 Android 约定）→ `HPASSKit.IMUSample`。
    private nonisolated func handleIMU(_ s: IMUSample, pipe: LivePipeline) {
        let sample = HPASSKit.IMUSample(tMs: s.tMs,
                                        ax: s.acc.0, ay: s.acc.1, az: s.acc.2,
                                        gx: s.gyr.0, gy: s.gyr.1, gz: s.gyr.2,
                                        mx: s.mag.0, my: s.mag.1, mz: s.mag.2)
        guard let out = pipe.fusion.process(sample) else { return }
        pipe.fused = out
        advanceNavigation(pipe: pipe, position: pipe.displayPosition)
        publish(pipe: pipe)
    }

    /// 1 Hz：出一次指纹定位结果，喂给融合引擎。
    private nonisolated func tick(pipe: LivePipeline) {
        let now = Fmt.nowMs()

        // 统计
        pipe.recent.removeAll { now - $0.t > 2000 }
        let lastSec = pipe.recent.filter { now - $0.t <= 1000 }
        pipe.readingsPerSecond = lastSec.count
        pipe.uniqueTagsPerSecond = Set(lastSec.map { $0.id }).count

        if let fix = pipe.positioner.estimate(nowMs: now) {
            pipe.estimate = fix
            pipe.fusion.updateFix(position: fix.position, confidence: fix.confidence, tMs: now)
            if !pipe.gotFirstFix {
                pipe.gotFirstFix = true
                AppLog.i("实时定位", "首次定位：\(fix.position) 点位 \(fix.pointId ?? "?")"
                         + "，置信度 \(Fmt.f(fix.confidence, 2))，\(fix.readingsUsed) 条读数")
            }
            // 限流：最多每秒一条
            if now - pipe.lastPosLogMs >= 1000 {
                pipe.lastPosLogMs = now
                AppLog.d("实时定位", "指纹 \(fix.position) 点位 \(fix.pointId ?? "?") "
                         + "conf \(Fmt.f(fix.confidence, 2)) σ \(Fmt.f(fix.uncertaintyCm, 0))cm "
                         + "读数 \(fix.readingsUsed) / \(pipe.readingsPerSecond)/s")
            }
            // 指纹与融合分歧
            if let f = pipe.fused, now - pipe.lastDivergeLogMs >= 5000 {
                let d = f.position.distance(to: fix.position)
                if d > LivePipeline.divergeThresholdCm {
                    pipe.lastDivergeLogMs = now
                    AppLog.w("实时定位", "指纹与融合相差 \(Fmt.f(d, 0)) cm：指纹 \(fix.position) / 融合 \(f.position)")
                }
            }
        }

        advanceNavigation(pipe: pipe, position: pipe.displayPosition)
        publish(pipe: pipe)
    }

    /// 把当前位置送进导航会话。
    private nonisolated func advanceNavigation(pipe: LivePipeline, position: Point2?) {
        guard pipe.nav.isActive, let p = position else { return }
        let tMs = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let unc = (pipe.useIMU ? pipe.fused?.uncertaintyCm : nil) ?? pipe.estimate?.uncertaintyCm ?? .infinity
        let q = pipe.fixClassifier.classify(position: p, timestampMs: tMs, uncertaintyCm: unc, converged: true)
        let fix = LocalizationFix(position: p, timestampMs: tMs, uncertaintyCm: unc, quality: q,
                                  source: pipe.useIMU && pipe.fused != nil ? .pdr : .fingerprint)
        guard let h = pipe.nav.onFix(fix) else { return }
        pipe.hint = h
        // 原来「投影剩余 ≤ 120 cm」一次就停（NAV-002）：现在要连续确认、定位可信、不隔货架
        if pipe.arrival.evaluate(fix: fix, hint: h) == .arrived {
            AppLog.i("实时定位", "导航到达，剩余 \(Fmt.f(h.remainingDistance, 0)) cm")
            pipe.nav.stop()
        }
    }

    /// 组装快照并切回主线程发布。
    private nonisolated func publish(pipe: LivePipeline) {
        var s = LiveSnapshot()
        s.estimate = pipe.estimate
        s.fused = pipe.fused
        s.display = pipe.displayPosition
        s.headingRad = pipe.fused?.headingRad ?? 0
        s.hint = pipe.nav.isActive ? pipe.hint : nil
        s.route = pipe.nav.isActive ? pipe.nav.route : nil
        s.readingsPerSecond = pipe.readingsPerSecond
        s.uniqueTagsPerSecond = pipe.uniqueTagsPerSecond
        s.stepCount = pipe.fused?.stepCount ?? 0
        s.wasConstrained = pipe.fused?.wasConstrained ?? false
        s.navFinished = !pipe.nav.isActive

        // 轨迹 CSV 在队列上写（CSVWriter 内部自带串行队列）
        if let w = pipe.trackWriter, let p = s.display {
            let source = (pipe.useIMU && pipe.fused != nil) ? "fused" : "fingerprint"
            let conf = pipe.estimate?.confidence ?? 0
            w.append([
                "\(pipe.fused?.tMs ?? pipe.estimate?.tMs ?? Fmt.nowMs())",
                Fmt.f(p.x, 1), Fmt.f(p.y, 1),
                Fmt.f(pipe.fused.map { $0.headingDeg } ?? -1, 1),
                source,
                Fmt.f(conf, 3),
                "\(s.stepCount)",
                s.wasConstrained ? "1" : "0",
            ].joined(separator: ","))
        }

        Task { @MainActor in self.apply(s) }
    }

    private func apply(_ s: LiveSnapshot) {
        estimate = s.estimate
        fused = s.fused
        readingsPerSecond = s.readingsPerSecond
        uniqueTagsPerSecond = s.uniqueTagsPerSecond
        stepCount = s.stepCount
        wasConstrained = s.wasConstrained
        headingRad = s.headingRad
        hint = s.hint
        route = s.route
        if isNavigating && s.navFinished {
            isNavigating = false
            hint = nil
            route = nil
        }
        if let p = s.display {
            if let last = displayPosition, last.distance(to: p) < Self.trailMinStepCm {
                displayPosition = p
            } else {
                displayPosition = p
                trail.append(p)
                if trail.count > Self.trailCapacity {
                    trail.removeFirst(trail.count - Self.trailCapacity)
                }
            }
        }
    }

    // MARK: - 参数

    private func positioningConfig() -> PositioningConfig {
        var c = PositioningConfig()
        c.rssiOffset = rssiOffset
        c.rssiScale = rssiScale
        c.useGraphSmoothing = useGraphSmoothing
        return c
    }

    private func fusionConfig() -> FusionConfig {
        var c = FusionConfig()
        c.magneticDeclinationDeg = magneticDeclinationDeg
        c.useCorridorConstraint = useCorridorConstraint
        return c
    }

    private func pushConfig() {
        guard let pipe = pipeline else { return }
        let cfgP = positioningConfig()
        let cfgF = fusionConfig()
        let imu = useIMU
        queue.async {
            pipe.positioner.config = cfgP
            pipe.fusion.config = cfgF
            pipe.useIMU = imu
        }
    }

    // MARK: - 起点 / 导航

    /// 用户在地图上点出已知起点：同时给定位器一个先验、给融合引擎一个初值。
    func setStartPosition(_ p: Point2) {
        guard let pipe = pipeline else {
            lastError = "请先点「开始」"
            return
        }
        queue.async {
            pipe.positioner.seed(position: p)
            pipe.fusion.setInitialPosition(p, headingRad: nil)
            AppLog.i("实时定位", "设置起点 \(p)")
            self.publish(pipe: pipe)
        }
    }

    /// 开始导航到一个目标点（cm）。路线规划里会自动把目标吸附到通道。
    func startNavigation(to target: Point2, label: String) {
        guard let pipe = pipeline, isRunning else {
            lastError = "请先点「开始」"
            return
        }
        isNavigating = true
        let from = displayPosition
        queue.async {
            pipe.arrival.reset()
            let h = pipe.nav.start(targets: [target], from: from)
            pipe.hint = h
            if h == nil && from == nil {
                AppLog.i("实时定位", "导航目标 \(label) \(target) 已记下，等第一个定位结果再规划")
            } else if let h {
                AppLog.i("实时定位", "开始导航到 \(label) \(target)，里程 \(Fmt.f(h.route.length, 0)) cm，"
                         + "\(h.route.turns.count) 次转弯")
            } else {
                AppLog.w("实时定位", "导航到 \(label) \(target) 规划失败（通道图不可达？）")
            }
            self.publish(pipe: pipe)
        }
    }

    func stopNavigation() {
        isNavigating = false
        hint = nil
        route = nil
        guard let pipe = pipeline else { return }
        queue.async {
            pipe.nav.stop()
            pipe.hint = nil
            AppLog.i("实时定位", "结束导航")
        }
    }

    // MARK: - 轨迹记录

    func startTrackRecording() {
        guard let pipe = pipeline else {
            lastError = "请先点「开始」"
            return
        }
        guard !isRecordingTrack else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let name = "live_\(fmt.string(from: Date())).csv"
        do {
            let dir = Self.tracksRoot
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let w = try CSVWriter(url: dir.appendingPathComponent(name),
                                  header: "t_ms,x_cm,y_cm,heading_deg,source,confidence,step_count,constrained")
            queue.async { pipe.trackWriter = w }
            isRecordingTrack = true
            trackFileName = name
            AppLog.i("实时定位", "开始记录轨迹 live-tracks/\(name)")
        } catch {
            lastError = "无法创建轨迹文件：\(error.localizedDescription)"
            AppLog.e("实时定位", lastError ?? "")
        }
    }

    func stopTrackRecording() {
        guard isRecordingTrack, let pipe = pipeline else { return }
        isRecordingTrack = false
        let name = trackFileName ?? ""
        queue.async {
            pipe.trackWriter?.flush()
            pipe.trackWriter?.close()
            pipe.trackWriter = nil
            AppLog.i("实时定位", "停止记录轨迹 \(name)")
        }
    }

    nonisolated static var tracksRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("live-tracks", isDirectory: true)
    }

    // MARK: - RSSI 标定

    /// 盲标定：拿滚动缓冲里最近 `seconds` 秒的读数，在指纹库上网格搜索最优偏移。
    func runBlindCalibration(seconds: Int = 120) {
        guard let pipe = pipeline else {
            lastError = "请先点「开始」，让引擎先收一会儿读数"
            return
        }
        guard !isCalibrating else { return }
        isCalibrating = true
        calibrationNote = nil
        let cutoff = Fmt.nowMs() - Int64(max(seconds, 5)) * 1000
        queue.async {
            let window = pipe.calBuffer.filter { $0.tMs >= cutoff }
            guard window.count >= 20 else {
                Task { @MainActor in
                    self.isCalibrating = false
                    self.calibrationNote = "读数太少（\(window.count) 条），再走一会儿"
                }
                return
            }
            let r = RSSICalibrator.fitBlind(readings: window, points: pipe.points, tagToShelf: pipe.tagToShelf)
            AppLog.i("实时定位", "盲标定：offset \(Fmt.f(r.offset, 2)) scale \(Fmt.f(r.scale, 3))，"
                     + "得分 \(Fmt.f(r.scoreBefore, 3)) → \(Fmt.f(r.score, 3))，\(r.samples) 个时间窗")
            Task { @MainActor in
                self.isCalibrating = false
                self.calibration = r
                self.calibrationNote = "盲标定 \(window.count) 条读数 / \(r.samples) 个窗"
            }
        }
    }

    /// 已知点标定：站在某个指纹点上点「开始」，待一会儿再点「结束」。
    func startKnownPointCapture(pointId: String) {
        guard let pipe = pipeline, isRunning else {
            lastError = "请先点「开始」"
            return
        }
        knownPointCapturing = pointId
        queue.async {
            pipe.knownPointId = pointId
            pipe.knownBuffer.removeAll()
        }
        AppLog.i("实时定位", "开始在点位 \(pointId) 采集标定数据")
    }

    func finishKnownPointCapture() {
        guard let pipe = pipeline, let pid = knownPointCapturing else { return }
        knownPointCapturing = nil
        isCalibrating = true
        calibrationNote = nil
        queue.async {
            let buf = pipe.knownBuffer
            pipe.knownPointId = nil
            pipe.knownBuffer.removeAll()
            guard buf.count >= 20 else {
                AppLog.w("实时定位", "点位 \(pid) 只收到 \(buf.count) 条读数，标定放弃")
                Task { @MainActor in
                    self.isCalibrating = false
                    self.calibrationNote = "点位 \(pid) 读数太少（\(buf.count) 条）"
                }
                return
            }
            let r = RSSICalibrator.fit(readingsByPoint: [pid: buf],
                                       points: pipe.points,
                                       tagToShelf: pipe.tagToShelf)
            AppLog.i("实时定位", "点位 \(pid) 标定：offset \(Fmt.f(r.offset, 2)) scale \(Fmt.f(r.scale, 3))，"
                     + "得分 \(Fmt.f(r.scoreBefore, 3)) → \(Fmt.f(r.score, 3))，\(r.samples) 个时间窗")
            Task { @MainActor in
                self.isCalibrating = false
                self.calibration = r
                self.calibrationNote = "点位 \(pid)：\(buf.count) 条读数 / \(r.samples) 个窗"
            }
        }
    }

    /// 把建议值填进参数里。
    func applySuggestedCalibration() {
        guard let r = calibration else { return }
        rssiOffset = (r.offset * 2).rounded() / 2
        rssiScale = (r.scale * 100).rounded() / 100
        AppLog.i("实时定位", "应用建议偏移 offset \(Fmt.f(rssiOffset, 2)) scale \(Fmt.f(rssiScale, 2))")
    }

    // MARK: - 杂项

    func clearError() { lastError = nil }

    func clearTrail() {
        trail = []
    }

    private static func describe(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "已开启"
        case .poweredOff: return "已关闭"
        case .unauthorized: return "未授权"
        case .unsupported: return "不支持"
        case .resetting: return "重置中"
        default: return "未知"
        }
    }
}

import ARKit
import Combine
import Foundation
import HPASSKit
import UIKit

/// 各条通道的采集进度：每条通道按 1 m 分段，分别记「沿 a→b 方向走过」和「沿 b→a 方向走过」。
/// 存在 `Documents/survey-coverage.json`，换会话也保留。
@MainActor
final class SurveyCoverage: ObservableObject {
    static let binCm = 100.0

    @Published private(set) var revision = 0
    private var forward: [[Bool]] = []
    private var backward: [[Bool]] = []
    private var segments: [CrossSegment] = []
    private var lengths: [Double] = []

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("survey-coverage.json")
    }
    private var paintObserver: NSObjectProtocol?

    init() {
        paintObserver = NotificationCenter.default.addObserver(forName: .surveyPaintFileChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mergePaintFromDisk() }
        }
    }

    // MARK: 涂色（Oriient 式：走过的地方按圆圈涂满通道宽度）

    /// 涂色网格；地图尺寸已知时才有
    private(set) var paintGrid: CoveragePaint?
    /// 给 2D / 3D 画的涂色图（只含有通道的那块），每秒最多重画一次
    @Published private(set) var paintLayer: PaintLayer?
    /// 当前所在通道的涂色比例（采集时显示）
    @Published private(set) var currentCorridorPaint: (code: String, fraction: Double, widthCm: Double)?
    /// 离我最近的还没涂的地方（找 30 m 以内），地图上画个橙色圈指过去
    @Published private(set) var nextUnpainted: Point2?
    /// 路线规划：下一段该走的走线（地图上画橙色粗箭头），全部走线还剩多少（cm）
    @Published private(set) var nextLane: SurveyPlanner.Next?
    @Published private(set) var planRemainingCm: Double?
    private var planner: SurveyPlanner?
    /// 通道（> 1 m 宽）的建议走线：去程贴一边、回程贴另一边（地图坐标线段）
    @Published private(set) var laneGuides: [(Point2, Point2)] = []
    /// 比这个宽的通道，走中间一趟涂不满（圆圈直径 80 cm），要分两边走
    static let wideCorridorCm = 100.0
    /// 采集分区（每块约 25 分钟）；进采集模式自动分到一块，路线规划只在这块里
    private(set) var zones: SurveyZones?
    @Published private(set) var zoneId: Int?
    @Published private(set) var zoneStatus: [SurveyZones.Status] = []
    /// 本区还没怎么采时：从这里（已采过的地方）进区，先沿已采路段走 10～20 m，磁场才能和已有数据对齐
    @Published private(set) var zoneEntry: Point2?
    /// 本区的通道段（地图上紫色高亮）：两端、通道宽
    @Published private(set) var zoneSegments: [(Point2, Point2, Double)] = []
    private var lastZoneStatus = Date.distantPast
    var zone: SurveyZones.Zone? { zones?.zone(zoneId) }
    /// 地图上每个区域中心的标签：位置、编号、状态（done = 已采好不用采，current = 本次区域）
    var zoneLabels: [(p: Point2, text: String, done: Bool, current: Bool)] {
        guard let zs = zones else { return [] }
        return zs.zones.map { z in
            let st = zoneStatus.first { $0.id == z.id }
            let pct = Int((st?.fraction ?? 0) * 100)
            return (z.center, st?.done == true ? "\(z.id) ✓" : "\(z.id) · \(pct)%", st?.done == true, z.id == zoneId)
        }
    }
    var currentZoneStatus: SurveyZones.Status? { zoneStatus.first { $0.id == zoneId } }
    private var paintDirty = false
    private var lastPaintImage = Date.distantPast

    private static var paintURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("survey-paint.bin")
    }

    /// 地图尺寸 / 通道变了才重建涂色网格，并读回存盘的涂色。
    func configurePaint(crosses: [CrossSegment], widthCm: Double, heightCm: Double, walkable: WalkableMap? = nil) {
        guard widthCm > 0, heightCm > 0 else { return }
        let p: CoveragePaint
        if crosses.isEmpty {
            // 房间：涂色范围 = 可走区域
            guard let w = walkable else { return }
            if let q = paintGrid, q.crosses.isEmpty, q.cols == w.cols, q.rows == w.rows, q.walkableCells == w.walkableCellCount { return }
            p = CoveragePaint(walkable: w)
        } else {
            if let q = paintGrid, q.cols == Int((widthCm / q.cellCm).rounded(.up)), q.crosses.count == crosses.count,
               zip(q.crosses, crosses).allSatisfy({ $0.a == $1.a && $0.b == $1.b }) { return }
            p = CoveragePaint(crosses: crosses, widthCm: widthCm, heightCm: heightCm)
        }
        planner = crosses.isEmpty ? nil : SurveyPlanner(crosses: crosses, radiusCm: p.radiusCm)
        zones = crosses.isEmpty ? nil : SurveyZones(crosses: crosses, radiusCm: p.radiusCm)
        zoneId = nil
        if let d = try? Data(contentsOf: Self.paintURL) { p.load(d) }
        loadCloudPaint(into: p)
        paintGrid = p
        rebuildPaintImage()
        assignZone()
    }

    /// 云端确认过的涂色（每格趟数）；画图时这些格是绿色，本机涂了但云端没有的是蓝色（待确认）
    private(set) var cloudCounts: [UInt8]?

    private func loadCloudPaint(into p: CoveragePaint) {
        cloudCounts = nil
        guard let id = MapLibrary.shared.activeId else { return }
        guard let d = try? Data(contentsOf: MapLibrary.shared.cloudPaintURL(id)) else {
            AppLog.i("建图", "这张地图还没有云端确认的涂色")
            return
        }
        guard let c = p.counts(of: d) else {
            AppLog.w("建图", "云端涂色和地图尺寸对不上（\(d.count) 字节，网格 \(p.cols)×\(p.rows)），没用")
            return
        }
        cloudCounts = c
        p.merge(d)
        AppLog.i("建图", "云端确认的涂色：\(c.filter { $0 > 0 }.count) 格")
    }

    // MARK: 采集分区

    /// 自动分配本次的区域：开了头的先采完，否则离已采部分最近的（有重叠才能对齐磁场），都没采过就离我最近的
    func assignZone(from pos: Point2? = nil) {
        guard let zs = zones, let pt = paintGrid else { return }
        zoneId = zs.next(pt, from: pos) ?? zs.zones.first?.id
        refreshZone()
    }

    /// 手动换区域
    func selectZone(_ id: Int) {
        zoneId = id
        refreshZone()
        AppLog.i("建图", "换采集区域：\(zone?.name ?? "-")")
    }

    private func refreshZone() {
        guard let zs = zones, let pt = paintGrid else { zoneStatus = []; zoneSegments = []; zoneEntry = nil; return }
        zoneStatus = zs.status(pt)
        lastZoneStatus = Date()
        if let z = zone {
            planner = zs.planner(for: z)
            zoneSegments = z.pieces.map { ($0.a, $0.b, $0.widthCm) }
            let f = currentZoneStatus?.fraction ?? 0
            zoneEntry = f < zs.startedFraction ? zs.entry(z, paint: pt) : nil
        } else {
            planner = zs.planner
            zoneSegments = []
            zoneEntry = nil
        }
    }

    /// 在 p 处涂一圈（采集质量合格时调用）。
    func paint(at p: Point2) {
        guard let pt = paintGrid else { return }
        if pt.paint(at: p) { paintDirty = true }
        if paintDirty && Date().timeIntervalSince(lastPaintImage) > 1 { rebuildPaintImage() }
        if Date().timeIntervalSince(lastGuide) > 1 || currentCorridorPaint == nil {
            lastGuide = Date()
            let ci = pt.corridorIndex(at: p)
            currentCorridorPaint = ci.map { (pt.crosses[$0].code, pt.fraction(corridor: $0), pt.crosses[$0].lineWidth) }
            nextUnpainted = pt.nearestUnpainted(from: p, maxCm: 3000)
            if let pl = planner {
                nextLane = pl.next(from: p, paint: pt)
                planRemainingCm = pl.remainingCm(pt)
            }
            if Date().timeIntervalSince(lastZoneStatus) > 5 { refreshZone() }
            laneGuides = ci.map { Self.lanes(pt.crosses[$0], radiusCm: pt.radiusCm) } ?? []
        }
    }

    func breakPaintStroke() { paintGrid?.breakStroke() }

    /// 不在采集时清掉引导
    func clearGuides() {
        nextUnpainted = nil
        nextLane = nil
        laneGuides = []
        currentCorridorPaint = nil
    }

    private var lastGuide = Date.distantPast

    /// 建议走线：离两边各留一个圆圈半径，两趟就能把边上涂到（正好去程一边、回程一边，两个方向也都有了）；
    /// 宽度超过 4 个半径（两边各一趟中间还会漏）时再加一条中线。窄通道不画。
    static func lanes(_ c: CrossSegment, radiusCm r: Double) -> [(Point2, Point2)] {
        let half = c.lineWidth / 2
        guard c.lineWidth > wideCorridorCm else { return [] }
        let d = c.b - c.a
        let len = d.length
        guard len > 1 else { return [] }
        let n = Point2(-d.y / len, d.x / len)
        var offs = [half - r, -(half - r)]
        if c.lineWidth > 4 * r { offs.append(0) }
        return offs.map { o in (c.a + n * o, c.b + n * o) }
    }

    func rebuildPaintImage() {
        paintDirty = false
        lastPaintImage = Date()
        paintLayer = paintGrid.flatMap { PaintLayer.make($0, cloud: cloudCounts) }
    }

    /// 装上了新的云端版本：涂色 = 云端确认的；正在采集时本次已涂的保留（这次的会话云端还没判）
    func mergePaintFromDisk() {
        // 方向图同理：本机的清掉，读云端的（采集中保留本次已走的）
        if !sessionActive {
            try? FileManager.default.removeItem(at: Self.fileURL)
            forward = forward.map { [Bool](repeating: false, count: $0.count) }
            backward = forward
        }
        load()
        guard let p = paintGrid else { revision += 1; return }
        let keep = p.serialized()
        p.reset()
        try? FileManager.default.removeItem(at: Self.paintURL)
        loadCloudPaint(into: p)
        if sessionActive { p.merge(keep) }
        rebuildPaintImage()
        refreshZone()
        revision += 1
    }

    /// 采集中（SurveyEngine 开始 / 结束时设置）
    var sessionActive = false

    /// 换了地图：下次 configure / configurePaint 一定重建并从（新地图的）文件读
    func invalidate() {
        segments = []
        lengths = []
        forward = []
        backward = []
        paintGrid = nil
        paintLayer = nil
        clearGuides()
        revision += 1
    }

    func configure(crosses: [CrossSegment]) {
        guard crosses.count != segments.count || zip(crosses, segments).contains(where: { $0.a != $1.a || $0.b != $1.b }) else { return }
        segments = crosses
        lengths = crosses.map { $0.a.distance(to: $0.b) }
        forward = lengths.map { [Bool](repeating: false, count: max(Int(($0 / Self.binCm).rounded(.up)), 1)) }
        backward = forward
        load()
        revision += 1
    }

    /// 地图位置 p（cm）、行进方向 dir（任意长度的位移向量）落在哪条通道上，标记那一段已走。
    func mark(position p: Point2, moving dir: Point2) {
        var changed = false
        for (i, c) in segments.enumerated() {
            let dx = c.b.x - c.a.x, dy = c.b.y - c.a.y
            let len2 = dx * dx + dy * dy
            guard len2 > 1 else { continue }
            let t = ((p.x - c.a.x) * dx + (p.y - c.a.y) * dy) / len2
            guard t >= -0.01, t <= 1.01 else { continue }
            let q = Point2(c.a.x + t * dx, c.a.y + t * dy)
            guard p.distance(to: q) <= max(c.lineWidth, 0) / 2 + 40 else { continue }
            let bin = min(max(Int(t * lengths[i] / Self.binCm), 0), forward[i].count - 1)
            let along = dir.x * dx + dir.y * dy
            if along >= 0 {
                if !forward[i][bin] { forward[i][bin] = true; changed = true }
            } else if !backward[i][bin] {
                backward[i][bin] = true; changed = true
            }
        }
        if changed { revision += 1 }
    }

    /// 0...1：两个方向各占一半。
    func fraction(_ i: Int) -> Double {
        guard forward.indices.contains(i) else { return 0 }
        let f = Double(forward[i].filter { $0 }.count) / Double(forward[i].count)
        let b = Double(backward[i].filter { $0 }.count) / Double(backward[i].count)
        return (f + b) / 2
    }

    var fractions: [Double] { segments.indices.map { fraction($0) } }

    /// 每条通道每 1 m 一段的状态：没采完 / 已采完但孤立 / 已采完且已和别的路段关联（共用路口）。
    /// 每段的状态：双向采完的按是否关联分「孤立 / 已关联」；只走了一个方向的标「单向」；其余「没采」。
    var states: [[CoverageState]] {
        var s = CoverageLinker.link(crosses: segments, done: doneBins, binCm: Self.binCm)
        for i in s.indices {
            for b in s[i].indices where s[i][b] == .none && (forward[i][b] || backward[i][b]) {
                s[i][b] = .partial
            }
        }
        return s
    }

    /// 只走了一个方向的长度（m）。
    var oneWayMeters: Double {
        forward.indices.reduce(0.0) { acc, i in
            acc + Double(zip(forward[i], backward[i]).filter { $0 != $1 }.count) * Self.binCm / 100
        }
    }

    /// 离 p 最近的没采完的一段：通道编号、直线距离（m）、是不是只差一个方向。
    func nearestTodo(from p: Point2) -> (code: String, distanceM: Double, oneWay: Bool)? {
        var best: (String, Double, Bool)?
        for i in segments.indices {
            let c = segments[i]
            let n = forward[i].count
            for b in 0..<n where !(forward[i][b] && backward[i][b]) {
                let t = min((Double(b) + 0.5) * Self.binCm / max(lengths[i], 1), 1)
                let q = Point2(c.a.x + (c.b.x - c.a.x) * t, c.a.y + (c.b.y - c.a.y) * t)
                let d = q.distance(to: p) / 100
                if best == nil || d < best!.1 { best = (c.code, d, forward[i][b] || backward[i][b]) }
            }
        }
        return best.map { ($0.0, $0.1, $0.2) }
    }

    /// 每条通道每 1 m 一段：两个方向都走过才算采完。
    var doneBins: [[Bool]] {
        forward.indices.map { i in zip(forward[i], backward[i]).map { $0 && $1 } }
    }

    /// 已走过的通道长度（m），按「通道长度 × 覆盖率」累计；双向都走完才算满。
    var coveredMeters: Double { segments.indices.reduce(0) { $0 + fraction($1) * lengths[$1] / 100 } }
    var totalMeters: Double { lengths.reduce(0, +) / 100 }

    func reset() {
        paintGrid?.reset()
        try? FileManager.default.removeItem(at: Self.paintURL)
        if let p = paintGrid { loadCloudPaint(into: p) }     // 云端确认的不清
        rebuildPaintImage()
        currentCorridorPaint = nil
        for i in forward.indices {
            forward[i] = [Bool](repeating: false, count: forward[i].count)
            backward[i] = forward[i]
        }
        revision += 1
        save()
    }

    func save() {
        struct File: Codable { var f: [[Int]]; var b: [[Int]] }
        let file = File(f: forward.map { $0.map { $0 ? 1 : 0 } }, b: backward.map { $0.map { $0 ? 1 : 0 } })
        if let d = try? JSONEncoder().encode(file) { try? d.write(to: Self.fileURL, options: .atomic) }
        if let p = paintGrid { try? p.serialized().write(to: Self.paintURL, options: .atomic) }
        if paintDirty { rebuildPaintImage() }
    }

    /// 本机的方向图 + 云端确认的方向图（取并集）
    private func load() {
        var urls = [Self.fileURL]
        if let id = MapLibrary.shared.activeId { urls.append(MapLibrary.shared.cloudDirectionURL(id)) }
        for url in urls {
            guard let d = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(DirectionCoverage.File.self, from: d),
                  file.f.count == forward.count, file.b.count == backward.count else { continue }
            for i in forward.indices where file.f[i].count == forward[i].count && file.b[i].count == backward[i].count {
                for k in forward[i].indices {
                    if file.f[i][k] != 0 { forward[i][k] = true }
                    if file.b[i][k] != 0 { backward[i][k] = true }
                }
            }
        }
    }
}

/// 建图采集：沿通道走，一边录全部传感器，一边用 ARKit 视觉里程计提供位置真值。
///
/// 流程与「实时定位」一致：长按地图 = 我在这里；双击设朝向；朝设定方向走出 1.5 m 后，
/// ARKit 轨迹自动对齐到地图。之后位置由 ARKit 给出，走到路口或已知点位时长按地图修正，
/// 每次修正都写进 `anchors.csv`，离线建图时用它们分段校正 ARKit 的漂移。
@MainActor
final class SurveyEngine: ObservableObject {
    enum Stage { case idle, needPosition, autoLocating, needHeading, aligning, tracking }

    /// 走出多远（cm）才用位移方向对齐朝向
    private static let alignCm = 150.0
    /// 建议每隔多少米修正一次位置
    static let anchorEveryM = 30.0
    /// 长按时吸附到路点 / 点位的半径（cm）
    private static let snapCm = 60.0

    let recorder = Recorder()
    let coverage = SurveyCoverage()

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var position: Point2?
    @Published private(set) var headingRad: Double = 0
    @Published private(set) var headingEditing = false
    @Published private(set) var trail: [Point2] = []
    @Published private(set) var trackingState = 0
    @Published private(set) var anchorCount = 0
    @Published private(set) var walkedSinceAnchorM = 0.0
    @Published private(set) var totalWalkedM = 0.0
    @Published private(set) var sessionName: String?
    /// LiDAR 实景扫描：建图时同时扫网格，结束时导出 mesh.ply（电脑上用 tools/meshcheck.py 量货架高度和偏移）
    @Published var scanMesh = false
    /// 地图 → ARKit 的变换（对齐之后才有），给 AR 叠加用
    @Published private(set) var arAlignment: MapARTransform?
    @Published private(set) var arFloorY: Double?
    var arSession: ARSession { ar.session }
    /// 上一次建图采集的会话目录（结束之后用来导出）
    @Published private(set) var lastSessionDir: URL?
    @Published private(set) var lastError: String?
    @Published private(set) var lastSnap: String?
    /// 在线贴通道：沿通道直走时自动把 ARKit 的朝向和横向偏差拉回通道（默认开）
    @Published var corridorLock = true
    @Published private(set) var lockFixes = 0
    /// 最近 2 秒的步行速度（m/s）
    @Published private(set) var speedMS = 0.0
    /// 太快的时候不记采集进度（磁场采样跟不上、ARKit 也容易丢）
    static let maxSpeedMS = 1.6

    private let ar = ARKitLogger()
    private var anchorsWriter: CSVWriter?

    // 货架黄色位置标签（「082-20」）：摄像头读到就知道在哪段货架前——自动定起点、轨迹偏了自动纠
    /// 采集时识别货架标签
    @Published var readSigns = true
    @Published private(set) var lastSign: (text: String, shelf: String?, at: Date)?
    @Published private(set) var signCount = 0
    @Published private(set) var signFixes = 0
    private let signReader = ShelfSignReader()
    private var shelfSigns: ShelfSigns?
    private var signsWriter: CSVWriter?
    private var lastSignFixMs: Int64 = 0
    /// 轨迹离标签所在货架段前的区域超过这么远（cm）才自动纠（区域本身已经含了站位误差）
    static let signFixCm = 300.0

    // 蓝牙打底：全店价签位置表不用采集就能定到 2 m 左右（实测中位 1.4～2.3 m）。采集时它做「低精度的底」——
    // 自动定起点（罗盘 + 地图朝向定方向）、发现 ARKit 轨迹走偏就拉回；ARKit + 贴通道 + 地磁做高精度。
    @Published var bleBase = true
    @Published private(set) var bleFix: (position: Point2, spreadCm: Double)?
    @Published private(set) var bleTagCount = 0
    @Published private(set) var bleBaseFixes = 0
    private var bleBaseMap: BLEFingerprintMap?
    private var bleWalk: WalkableMap?
    private var bleObs: [(t: Int64, id: String, rssi: Double)] = []
    private var lastBleTick: Int64 = 0
    private var compassDeg: Double?
    private var bleStable = 0
    private var lastFixPos: Point2?
    private var disagreeTicks = 0
    private var lastBleCorrectionMs: Int64 = 0
    private var cancellable: AnyCancellable?

    // 对齐参数：map = pRef + R(phi) · (a − aRef)，a 是 ARKit 的 (x, z)，单位 cm
    private var aRef = Point2.zero
    private var pRef = Point2.zero
    private var phi = 0.0
    private var targetHeading = 0.0
    private var latestA: Point2?
    private var lastMapPos: Point2?
    private var lastLogMs: Int64 = 0
    private var lock: CorridorLock?

    // 地磁定位（和采集一起跑）：自动起点 + 精度测试
    /// 采集的同时测地磁定位精度（需要已经有磁场图）
    @Published var evaluate = false
    /// 这次是「测试会话」：只用来测精度，不参与生成磁场图（避免自己考自己）
    @Published var isTestSession = false
    @Published private(set) var shadowStatus: String?
    @Published private(set) var evalSummary: String?
    private(set) var evaluator = LocalizationEvaluator()
    private let shadowQueue = DispatchQueue(label: "survey.shadow", qos: .userInitiated)
    private let shadowBox = ShadowBox()
    private var shadowWriter: CSVWriter?
    private var lastEvalPublish = Date.distantPast
    /// 自动起点：收敛后连续走这么远（cm）才认
    static let autoStartStableCm = 500.0
    private var speedRef: (t: Int64, a: Point2)?

    init() {
        // 把录制器的变化转发出来，界面只需要观察本对象
        cancellable = Publishers.Merge(recorder.objectWillChange, coverage.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
        let box = shadowBox, sq = shadowQueue
        ar.onPose = { [weak self] t, x, z, state in
            Task { @MainActor in self?.handlePose(t: t, a: Point2(x, z), state: state) }
            sq.async {
                guard let sh = box.sh, let e = sh.pose(a: Point2(x, z), normal: state == 2) else { return }
                let stable = sh.stableCm, phi = sh.rotFit.phi, ea = sh.estimateA
                Task { @MainActor in self?.handleShadow(t: t, e, stable: stable, phi: phi, a: ea) }
            }
        }
        recorder.tap.imu = { s in
            let h = HPASSKit.IMUSample(tMs: s.tMs, ax: s.acc.0, ay: s.acc.1, az: s.acc.2,
                                       gx: s.gyr.0, gy: s.gyr.1, gz: s.gyr.2,
                                       mx: s.mag.0, my: s.mag.1, mz: s.mag.2)
            sq.async { box.sh?.imu(h) }
        }
        recorder.tap.raw = { t, v in sq.async { box.sh?.rawMag(tMs: t, v) } }
        ar.onFloor = { [weak self] y in
            Task { @MainActor in self?.arFloorY = y }
        }
        recorder.tap.ble = { [weak self] t, id, rssi in
            Task { @MainActor in self?.bleReading(tMs: t, id: id, rssi: rssi) }
        }
        recorder.tap.heading = { [weak self] _, deg in
            Task { @MainActor in self?.compassDeg = deg }
        }
        signReader.onRead = { [weak self] t, text, conf in
            Task { @MainActor in self?.handleSign(tMs: t, text: text, confidence: conf) }
        }
        ar.onError = { [weak self] msg in
            Task { @MainActor in
                self?.lastError = msg
                AppLog.e("建图", msg)
            }
        }
    }

    var isRunning: Bool { stage != .idle }

    /// IMU / 磁力计采样率太低（后台被系统限流、传感器被别的功能占用）时的提示
    var lowSampleRate: Bool { recorder.imuHz > 0 && recorder.imuHz < Self.minImuHz }
    static let minImuHz = 50

    /// 这一刻采到的数据能不能算进度：速度正常、采样率正常
    private var sampleQualityOK: Bool { speedMS <= Self.maxSpeedMS && !lowSampleRate }

    // MARK: 开始 / 结束

    func start(note: String) {
        guard stage == .idle else { return }
        guard ARKitLogger.isSupported else {
            lastError = "这台设备不支持 ARKit 世界跟踪"
            return
        }
        let store = MagMapStore.shared
        coverage.configure(crosses: store.crosses)
        coverage.configurePaint(crosses: store.crosses, widthCm: store.widthCm, heightCm: store.heightCm,
                                walkable: store.walkableMap())
        coverage.breakPaintStroke()
        if coverage.zoneId == nil { coverage.assignZone() }
        coverage.sessionActive = true
        lastError = nil
        recorder.deviceLabel = "survey"
        // 价签广播顺便录下来，生成磁场图时自动做成蓝牙指纹；这张地图不用蓝牙（房间 / 办公室）就不录
        let bleOn = MapLibrary.shared.activeBLEEnabled
        recorder.recordBLE = bleOn
        recorder.arbiterName = ""
        SensorArbiter.shared.claim("建图采集") { [weak self] in self?.stop() }
        recorder.setupNote = note
        recorder.extraMeta = [
            "survey": true,
            "map_width_cm": store.widthCm, "map_height_cm": store.heightCm,
            "map_id": MapLibrary.shared.activeId ?? "",
            "purpose": isTestSession ? "test" : "build",
            "zone": coverage.zoneId ?? 0,
            "zone_name": coverage.zone?.name ?? "",
            "arkit": true,
            "arkit_frame": "gravity-aligned, x right, y up, z toward viewer; map = pRef + R(phi)(a - aRef), a = (x, z) cm",
        ]
        recorder.startRecording()
        guard recorder.isRecording, let dir = recorder.currentSessionDir else {
            lastError = recorder.lastError ?? "录制没有启动"
            return
        }
        do {
            if readSigns {
                shelfSigns = StoreDataStore.shared.map.map { ShelfSigns(map: $0, walkable: store.walkableMap()) }
                signsWriter = try CSVWriter(url: dir.appendingPathComponent("signs.csv"), header: "t_ms,text,shelf_code,confidence")
                let reader = signReader
                ar.onFrame = { f, t in reader.process(f, tMs: t) }
            } else {
                shelfSigns = nil
                ar.onFrame = nil
            }
            signCount = 0
            signFixes = 0
            lastSign = nil
            if bleBase && bleOn {
                let locs = StoreDataStore.shared.eslLocations
                bleBaseMap = locs.isEmpty ? MagMapStore.shared.bleMap : EslLocations.seededBLEMap(locs, learned: MagMapStore.shared.bleMap)
                bleWalk = store.walkableMap()
            } else {
                bleBaseMap = nil
            }
            bleObs = []; bleFix = nil; bleTagCount = 0; bleBaseFixes = 0; bleStable = 0; lastFixPos = nil
            disagreeTicks = 0; lastBleCorrectionMs = 0
            anchorsWriter = try CSVWriter(url: dir.appendingPathComponent("anchors.csv"),
                                          header: "t_ms,kind,map_x_cm,map_y_cm,ar_x_cm,ar_z_cm,heading_rad,note")
            try ar.start(dir: dir, wantsDepth: true, lateralFile: dir.appendingPathComponent("depth_lateral.csv"),
                         wantsMesh: scanMesh)
            arFloorY = nil
            arAlignment = nil
        } catch {
            lastError = "启动失败：\(error.localizedDescription)"
            recorder.stopRecording()
            return
        }
        sessionName = dir.lastPathComponent
        lastSessionDir = dir
        position = nil
        trail = []
        anchorCount = 0
        walkedSinceAnchorM = 0
        totalWalkedM = 0
        latestA = nil
        lastMapPos = nil
        lock = store.crosses.isEmpty ? nil : CorridorLock(crosses: store.crosses)
        evaluator = LocalizationEvaluator()
        evalSummary = nil
        shadowStatus = nil
        shadowWriter = nil
        if evaluate { startShadow(dir: dir) }
        lockFixes = 0
        speedMS = 0
        speedRef = nil
        stage = .needPosition
        UIApplication.shared.isIdleTimerDisabled = true
        AppLog.i("建图", "开始建图采集：\(dir.lastPathComponent)")
    }

    func stop() {
        coverage.sessionActive = false
        guard stage != .idle else { return }
        if stage == .tracking, let p = position, let a = latestA {
            writeAnchor(kind: "end", map: p, ar: a, heading: nil, note: "")
        }
        if scanMesh, let dir = recorder.currentSessionDir {
            do {
                let n = try ar.exportMesh(to: dir.appendingPathComponent("mesh.ply"))
                recorder.extraMeta["lidar_mesh"] = n.vertices > 0
                AppLog.i("建图", "LiDAR 网格：\(n.vertices) 个顶点，\(n.faces) 个三角形")
            } catch {
                AppLog.e("建图", "导出网格失败：\(error.localizedDescription)")
            }
        }
        ar.stop()
        arAlignment = nil
        stopShadow()
        if evaluate, let s = evalSummary { AppLog.i("建图", "地磁定位精度：\(s)") }
        anchorsWriter?.close()
        anchorsWriter = nil
        ar.onFrame = nil
        signsWriter?.close()
        signsWriter = nil
        recorder.stopRecording()
        coverage.save()
        coverage.clearGuides()
        stage = .idle
        headingEditing = false
        SensorArbiter.shared.release("建图采集")
        UIApplication.shared.isIdleTimerDisabled = false
        if Telemetry.shared.enabled && Telemetry.shared.autoUpload, let dir = lastSessionDir {
            Task { _ = await Telemetry.shared.upload(sessionDir: dir) }
        }
        AppLog.i("建图", "结束：走了 \(Fmt.f(totalWalkedM, 0)) m，修正 \(anchorCount) 次，自动贴通道 \(lockFixes) 次"
                 + (lock.map { "（累计转 \(Fmt.f($0.totalAbsAngle * 180 / Double.pi, 1))°）" } ?? ""))
    }

    // MARK: 交互

    /// 长按地图：我现在在这里（第一次 = 起点，之后 = 修正）。
    func anchor(at tapped: Point2) {
        guard stage != .idle else { return }
        guard let a = latestA else {
            lastError = "ARKit 还没有出位姿，等一两秒再试"
            return
        }
        let (p, snapLabel) = snap(tapped)
        lastSnap = snapLabel
        switch stage {
        case .needPosition, .autoLocating, .needHeading:
            if stage == .autoLocating && !evaluate { stopShadow() }
            shadowStatus = nil
            pRef = p
            aRef = a
            position = p
            lastMapPos = p
            trail = [p]
            writeAnchor(kind: "start", map: p, ar: a, heading: nil, note: snapLabel ?? "")
            stage = .needHeading
        case .aligning, .tracking:
            // 修正：不改旋转，只把位置拉到 p
            let before = position
            pRef = p
            aRef = a
            position = p
            lastMapPos = p
            trail.append(p)
            walkedSinceAnchorM = 0
            lock?.reset()
            coverage.breakPaintStroke()
            writeAnchor(kind: "reanchor", map: p, ar: a, heading: nil,
                        note: (snapLabel ?? "") + (before.map { " 修正前偏 \(Int($0.distance(to: p))) cm" } ?? ""))
            publishAlignment()
        case .idle:
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: 蓝牙打底

    private func bleReading(tMs: Int64, id: String, rssi: Double) {
        guard stage != .idle, bleBaseMap != nil else { return }
        bleObs.append((tMs, id, rssi))
        if tMs - lastBleTick >= 1000 { lastBleTick = tMs; bleTick(tMs) }
    }

    private func bleTick(_ t: Int64) {
        guard let m = bleBaseMap else { return }
        bleObs.removeAll { $0.t < t - 2500 }
        var acc: [String: (Double, Int)] = [:]
        for r in bleObs { let a = acc[r.id] ?? (0, 0); acc[r.id] = (a.0 + r.rssi, a.1 + 1) }
        let tags = TagRangeFix.tags(acc.mapValues { $0.0 / Double($0.1) }, map: m)
        bleTagCount = tags.count
        bleFix = TagRangeFix.fix(tags, walkable: bleWalk)
        switch stage {
        case .needPosition:
            // 站着几秒、价签定位稳定（连续 3 秒落在 3 m 内、范围 ≤ 4 m）→ 自动定起点
            guard let f = bleFix, f.spreadCm <= 400 else { bleStable = 0; return }
            bleStable = (lastFixPos.map { $0.distance(to: f.position) <= 300 } ?? false) ? bleStable + 1 : 1
            lastFixPos = f.position
            guard bleStable >= 3 else { return }
            anchor(at: f.position)
            AppLog.i("建图", "蓝牙定了起点（\(tags.count) 片价签，范围 ±\(Int(f.spreadCm / 100)) m）")
            autoHeadingFromCompass()
        case .tracking:
            guard tags.count >= 3, let p = position else { disagreeTicks = 0; return }
            disagreeTicks = TagRangeFix.agreement(tags, at: p) < 0.4 ? disagreeTicks + 1 : 0
            guard disagreeTicks >= 4, t - lastBleCorrectionMs > 15_000,
                  let q = TagRangeFix.nearestConsistent(tags, to: p, walkable: bleWalk), q.distance(to: p) > 500 else { return }
            let d = q.distance(to: p)
            disagreeTicks = 0
            lastBleCorrectionMs = t
            anchor(at: q)
            bleBaseFixes += 1
            AppLog.w("建图", "蓝牙判断轨迹走偏 \(Int(d / 100)) m，已拉回")
        default:
            return
        }
    }

    /// 罗盘 + 地图朝向（云端融合自动估的）→ 直接设好朝向，往前走 1.5 m 就对齐，不用手动设
    private func autoHeadingFromCompass() {
        guard stage == .needHeading, let c = compassDeg, let up = MagMapStore.shared.mapUpBearingDeg,
              let p = position, let a = latestA else { return }
        headingRad = TagRangeFix.mapHeading(compassDeg: c, mapUpBearingDeg: up)
        targetHeading = headingRad
        pRef = p
        aRef = a
        stage = .aligning
        lock?.reset()
        publishAlignment()
        writeAnchor(kind: "heading", map: p, ar: a, heading: headingRad, note: "罗盘 \(Int(c))°")
        AppLog.i("建图", "罗盘定朝向：\(Int(c))°（地图朝向 \(Int(up))°），往前走就行")
    }

    /// 读到一个货架标签
    private func handleSign(tMs: Int64, text: String, confidence: Float) {
        guard stage != .idle else { return }
        let sg = shelfSigns?.sign(for: text)
        signsWriter?.append("\(tMs),\(text),\(sg?.shelfCode ?? ""),\(Fmt.f(Double(confidence), 2))")
        signCount += 1
        lastSign = (text, sg?.shelfCode, Date())
        guard let sg, let ss = shelfSigns else { return }
        switch stage {
        case .needPosition, .autoLocating:
            // 还没有起点：站在这段货架前
            anchor(at: ss.standPoint(sg))
            AppLog.i("建图", "货架标签 \(text) 定了起点（\(sg.shelfCode)）")
            autoHeadingFromCompass()
        case .tracking:
            guard let p = position, ss.distance(sg, from: p) > Self.signFixCm, tMs - lastSignFixMs > 10_000 else { return }
            let before = ss.distance(sg, from: p)
            lastSignFixMs = tMs
            anchor(at: ss.nearestValid(sg, to: p))
            signFixes += 1
            AppLog.i("建图", "货架标签 \(text)：轨迹偏了 \(Int(before / 100)) m，已自动纠正")
        default:
            return
        }
    }

    /// 双击：开始 / 结束设朝向。
    func toggleHeadingEdit() {
        guard stage == .needHeading || stage == .aligning || stage == .tracking else {
            if stage == .needPosition { lastError = "先长按地图，设定你现在的位置" }
            return
        }
        guard let p = position, let a = latestA else { return }
        if !headingEditing {
            headingEditing = true
            return
        }
        headingEditing = false
        targetHeading = headingRad
        // 以当前位置为新起点，朝这个方向走 1.5 m 后对齐
        pRef = p
        aRef = a
        stage = .aligning
        lock?.reset()
        publishAlignment()
        writeAnchor(kind: "heading", map: p, ar: a, heading: headingRad, note: "")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func pointHeading(toward t: Point2) {
        guard headingEditing, let p = position, p.distance(to: t) > 10 else { return }
        headingRad = atan2(t.x - p.x, t.y - p.y)
    }

    func resetCoverage() { coverage.reset() }

    private func publishAlignment() {
        arAlignment = stage == .tracking ? MapARTransform(pRef: pRef, aRef: aRef, phi: phi) : nil
    }

    // MARK: ARKit 位姿

    private func handlePose(t: Int64, a: Point2, state: Int) {
        guard stage != .idle else { return }
        latestA = a
        if state != trackingState { trackingState = state }
        guard state == 2 else { lock?.reset(); return }   // 跟踪受限时不更新位置，也不记覆盖
        if let r = speedRef {
            if t - r.t >= 2000 { speedMS = a.distance(to: r.a) / 100 / (Double(t - r.t) / 1000); speedRef = (t, a) }
        } else { speedRef = (t, a) }

        switch stage {
        case .aligning:
            let d = a - aRef
            guard d.length >= Self.alignCm else { return }
            let hm = Point2(sin(targetHeading), cos(targetHeading))
            phi = atan2(hm.y, hm.x) - atan2(d.y, d.x)
            stage = .tracking
            AppLog.i("建图", "朝向对齐完成，旋转 \(Fmt.f(phi * 180 / Double.pi, 1))°")
            publishAlignment()
        case .tracking:
            break
        default:
            return
        }
        guard stage == .tracking else { return }

        let d = a - aRef
        let c = cos(phi), s = sin(phi)
        var p = Point2(pRef.x + d.x * c - d.y * s, pRef.y + d.x * s + d.y * c)
        if corridorLock, let fix = lock?.update(p) {
            // 绕当前位置转 dPhi 再平移：map = p' + R(phi + dPhi)(a' − a)
            phi += fix.dPhi
            p = p + fix.shift
            pRef = p
            aRef = a
            lockFixes += 1
            publishAlignment()
        }
        let step = lastMapPos.map { p - $0 } ?? .zero
        if step.length >= 15 {
            walkedSinceAnchorM += step.length / 100
            totalWalkedM += step.length / 100
            trail.append(p)
            if trail.count > 1500 { trail.removeFirst(trail.count - 1500) }
            if sampleQualityOK {
                coverage.mark(position: p, moving: step)
                coverage.paint(at: p)
            }
            lastMapPos = p
            headingRad = atan2(step.x, step.y)
        }
        position = p
    }

    // MARK: 地磁定位（自动起点 / 精度测试）

    var canUseShadow: Bool { MagMapStore.shared.field != nil }

    /// 自动起点：不长按、不设朝向，直接沿采集过的通道走，地磁定到了就自动当起点。
    func startAutoLocate() {
        guard stage == .needPosition, let dir = recorder.currentSessionDir else { return }
        guard canUseShadow else { lastError = "还没有磁场图：自动起点只能在已经采过、生成过磁场图的区域用"; return }
        startShadow(dir: dir)
        stage = .autoLocating
        shadowStatus = "地磁定位中：沿采集过的通道正常往前走 10～20 m"
        AppLog.i("建图", "自动起点：开始地磁定位")
    }

    private func startShadow(dir: URL) {
        let store = MagMapStore.shared
        guard shadowBox.sh == nil, let field = store.field else { return }
        let walk = store.walkableMap()
        let raw = store.magSource == "raw"
        if shadowWriter == nil {
            shadowWriter = try? CSVWriter(url: dir.appendingPathComponent("shadow_loc.csv"),
                                          header: "t_ms,est_x_cm,est_y_cm,unc_cm,converged,ref_x_cm,ref_y_cm")
        }
        let box = shadowBox
        shadowQueue.async { box.sh = ShadowLocalizer(field: field, walkable: walk, useRawMag: raw) }
    }

    private func stopShadow() {
        let box = shadowBox
        shadowQueue.async { box.sh = nil }
        shadowWriter?.close()
        shadowWriter = nil
    }

    private func handleShadow(t: Int64, _ e: MagneticEstimate, stable: Double, phi: Double?, a: Point2?) {
        let ref = stage == .tracking ? position : nil
        shadowWriter?.append([
            "\(t)", Fmt.f(e.position.x, 1), Fmt.f(e.position.y, 1), Fmt.f(e.uncertaintyCm, 0), e.converged ? "1" : "0",
            ref.map { Fmt.f($0.x, 1) } ?? "", ref.map { Fmt.f($0.y, 1) } ?? "",
        ].joined(separator: ","))
        switch stage {
        case .autoLocating:
            if !e.converged {
                shadowStatus = "地磁定位中：沿采集过的通道正常往前走 10～20 m"
            } else if stable < Self.autoStartStableCm || phi == nil {
                shadowStatus = "已经定到，确认中（\(Int(stable / 100)) / \(Int(Self.autoStartStableCm / 100)) m）"
            } else if let phi, let a {
                autoStart(at: e.position, ar: a, phi: phi, uncertainty: e.uncertaintyCm)
            }
        case .tracking where evaluate:
            guard let r = ref else { return }
            evaluator.add(estimate: e, reference: r)
            if Date().timeIntervalSince(lastEvalPublish) > 1 {
                lastEvalPublish = Date()
                evalSummary = evaluator.summary
            }
        default:
            break
        }
    }

    private func autoStart(at p: Point2, ar a: Point2, phi newPhi: Double, uncertainty: Double) {
        pRef = p
        aRef = a
        phi = newPhi
        position = p
        lastMapPos = p
        trail = [p]
        walkedSinceAnchorM = 0
        lock?.reset()
        coverage.breakPaintStroke()
        let note = "自动起点 ±\(Int(uncertainty)) cm"
        writeAnchor(kind: "start", map: p, ar: a, heading: nil, note: note)
        writeAnchor(kind: "align", map: p, ar: a, heading: newPhi, note: note)
        stage = .tracking
        shadowStatus = nil
        if !evaluate { stopShadow() }
        publishAlignment()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AppLog.i("建图", "自动起点：\(p)，旋转 \(Fmt.f(newPhi * 180 / Double.pi, 1))°，不确定度 \(Int(uncertainty)) cm")
    }

    // MARK: 工具

    /// 离路点 / 点位 60 cm 以内就吸附上去。
    private func snap(_ p: Point2) -> (Point2, String?) {
        var best: (Point2, String)?
        var bd = Self.snapCm
        for m in MagMapStore.shared.points where m.position.distance(to: p) <= bd {
            bd = m.position.distance(to: p)
            best = (m.position, "点位 \(m.id)")
        }
        if let map = StoreDataStore.shared.map {
            for o in map.others where o.shapeType == "MapRoadPoint" {
                let q = Point2(o.x, o.y)
                if q.distance(to: p) <= bd {
                    bd = q.distance(to: p)
                    best = (q, "路点")
                }
            }
        }
        return best.map { ($0.0, $0.1) } ?? (p, nil)
    }

    private func writeAnchor(kind: String, map p: Point2, ar a: Point2, heading: Double?, note: String) {
        anchorsWriter?.append([
            "\(Fmt.nowMs())", kind, Fmt.f(p.x, 1), Fmt.f(p.y, 1), Fmt.f(a.x, 1), Fmt.f(a.y, 1),
            heading.map { Fmt.f($0, 4) } ?? "", Fmt.csv(note),
        ].joined(separator: ","))
        anchorsWriter?.flush()
        anchorCount += 1
    }
}

/// 只在 shadowQueue 上读写
private final class ShadowBox: @unchecked Sendable {
    var sh: ShadowLocalizer?
}

/// 涂色图层：一张图（每格一个像素）+ 它在地图上的范围（cm）。2D 和 3D 共用。
final class PaintLayer {
    let image: CGImage
    let rect: CGRect
    /// 涂色的圆圈半径（cm），画当前位置的圈用
    let radiusCm: Double

    init(image: CGImage, rect: CGRect, radiusCm: Double) {
        self.image = image
        self.rect = rect
        self.radiusCm = radiusCm
    }

    /// 通道里没涂：淡灰；云端确认已采好：浅绿（一趟）/ 深绿（两趟以上）；本机涂了、云端还没确认：蓝。通道外透明。
    /// cloud = nil（开发模式本机建图、还没融合过）时按本机趟数画绿色。
    static func make(_ p: CoveragePaint, cloud: [UInt8]? = nil) -> PaintLayer? {
        let b = p.bbox
        let w = b.i1 - b.i0 + 1, h = b.j1 - b.j0 + 1
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for j in 0..<h {
            for i in 0..<w {
                let k = (b.j0 + j) * p.cols + (b.i0 + i)
                guard p.mask[k] else { continue }
                let o = (j * w + i) * 4
                // 预乘 alpha
                let (r, g, bl, a): (Double, Double, Double, Double)
                let confirmed = cloud.map { $0[k] } ?? p.counts[k]
                switch (confirmed, p.counts[k]) {
                case (0, 0): (r, g, bl, a) = (0.55, 0.55, 0.58, 0.18)
                case (0, _): (r, g, bl, a) = (0.20, 0.55, 0.95, 0.55)
                case (1, _): (r, g, bl, a) = (0.20, 0.78, 0.35, 0.45)
                default: (r, g, bl, a) = (0.10, 0.55, 0.22, 0.80)
                }
                px[o] = UInt8(r * a * 255); px[o + 1] = UInt8(g * a * 255); px[o + 2] = UInt8(bl * a * 255); px[o + 3] = UInt8(a * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let rect = CGRect(x: Double(b.i0) * p.cellCm, y: Double(b.j0) * p.cellCm,
                          width: Double(w) * p.cellCm, height: Double(h) * p.cellCm)
        return PaintLayer(image: img, rect: rect, radiusCm: p.radiusCm)
    }
}

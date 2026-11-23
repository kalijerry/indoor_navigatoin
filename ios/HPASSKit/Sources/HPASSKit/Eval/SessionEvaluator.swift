import Foundation

/// 一次测试会话的定位精度。参考轨迹 = 这个会话自己的采集轨迹（ARKit + 贴通道），定位 = 冷启动地磁（+ 蓝牙），
/// 磁场图和蓝牙指纹只用「建图会话」生成，测试会话不参与（不是自己考自己）。
public struct EvalReport: Codable {
    public var session: String
    public var medianCm: Double?
    public var p90Cm: Double?
    public var within1m: Double?
    public var jumps: Int
    public var firstFixM: Double?
    public var pathM: Double
    public var points: Int
    public var usedBLE: Bool
    /// 有把握时误差超过 5 m 的比例（「定错了还很自信」，最伤人的情况）
    public var wrongFixShare: Double?
    /// 蓝牙交叉检验判错、重新找的次数
    public var crossCheckResets: Int = 0
    /// 只算参考位置在磁场图覆盖范围内（离有数据的格子 1.5 m 内）的点：去掉「走到建图没走过的地方」的影响
    public var inMapMedianCm: Double?
    public var inMapP90Cm: Double?
    public var inMapWithin1m: Double?
    /// 参考轨迹有多少比例在磁场图覆盖范围内
    public var inMapShare: Double?
    /// 每个已定位点的误差（cm），汇总多个会话时用
    public var errorsCm: [Double] = []
    /// `.pdrIMU` + 携带运动模型：回放结束时惯导引擎学到的分模式步长比例（App 存到本机、下次恢复的那份，见 StepScaleStore）
    /// 和这次在线标定吸收了几次。hpass-eval --carry-k 按时间顺序把前一次的传给下一次
    public var learnedStepScales: [String: Double]?
    public var stepScaleAbsorbed: Int?
    /// --carry-k：这次是同一个场地按时间顺序回放的第几个会话（0 = 第一次，还没有学到的 K）
    public var sequenceIndex: Int?
    /// 参考轨迹上的点数（含没定到位的），算「定位覆盖率」
    public var refPoints: Int = 0
    /// 和 errorsCm 一一对应：报的 1σ 不确定度（cm；−1 = 没报），量不确定度标定
    public var uncertaintiesCm: [Double] = []
    /// 相邻两个有把握的打分点之间估计 / 参考走过的路（cm）和估计跳 > 3 m 的次数（见 `LocalizationEvaluator`），量跳点 / 来回抖
    public var estPathCm: Double = 0
    public var refPathFixCm: Double = 0
    public var bigJumps: Int = 0

    public var line: String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "—" }
        return "\(session)\t中位 \(f(medianCm)) cm\tP90 \(f(p90Cm)) cm\t≤1m \(within1m.map { "\(Int($0 * 100))%" } ?? "—")"
            + "\t跳 \(jumps)\t首次定位 \(firstFixM.map { String(format: "%.1f m", $0) } ?? "没定到")\t走了 \(Int(pathM)) m"
            + "\t错定 \(wrongFixShare.map { "\(Int($0 * 100))%" } ?? "—")"
            + (usedBLE ? "\t+蓝牙（交叉检验重找 \(crossCheckResets) 次）" : "")
            + "\n    └ 只看建图覆盖到的地方（占 \(inMapShare.map { "\(Int($0 * 100))%" } ?? "—")）：中位 \(f(inMapMedianCm)) cm\tP90 \(f(inMapP90Cm)) cm\t≤1m \(inMapWithin1m.map { "\(Int($0 * 100))%" } ?? "—")"
    }
}

private func pct(_ a: [Double], _ q: Double) -> Double? {
    guard !a.isEmpty else { return nil }
    let s = a.sorted()
    return s[min(Int(Double(s.count - 1) * q + 0.5), s.count - 1)]
}

public enum SessionEvaluator {
    /// 建图方式
    public enum MapBuild {
        /// 和云端出图（hpass-build）完全一样：MultiSessionFusion.buildProduction —— 三遍融合（全局解偏移，和会话顺序无关）、
        /// 有标签位置表 / 货架标签时的轨迹锚定修正、质量筛选（不合格的段 / 会话不用）、磁场图只用主体连通分量
        case production
        /// 同一条流水线（同一份代码）的融合核心：全局解偏移 + 有标签时的轨迹锚定修正，**不做**质量筛选、
        /// **不排除**和主体连不上的分量（各分量各自对齐，分量之间不对齐）。评估默认用这个。
        /// 原因（公开数据集实测，夜间 Lab）：建图轨迹不是按「分片之间要有重叠」采的，101 条分成 23～33 个连通分量，
        /// 只用主体会从图里去掉约 36% 的格子；质量筛选拿「别的会话」比磁场，而别的会话分在互相没对齐的分量里，
        /// 101 条里 36 条整条被判不合格。两者量到的都是采集方式，而不是定位。
        /// 云端会排除哪些会话见 BuiltMaps.offMain（hpass-eval 打印）；要量云端地图包本身用 .production
        case fusion
        /// 手机上「生成磁场图」那套：会话按顺序一个个加，每个只和已经加进去的数据对齐偏移（结果和顺序有关）
        case sequential
    }

    public struct BuiltMaps {
        public var field: MagneticFieldMap
        public var ble: BLEFingerprintMap?
        /// Wi-Fi 指纹（只有 buildMaps 传 withWiFi 才建；会话里没有 wifi.csv 时为 nil）
        public var wifi: WiFiFingerprintMap?
        /// 进了磁场图的会话的建图说明（production：只有主体分量里合格的会话）
        public var reports: [SurveySessionReport]
        /// 合格会话分成几个连通分量（sequential 恒为 1）
        public var components: Int = 1
        /// 质量筛选没通过、不用的会话（名字 + 原因；只有 production 做质量筛选）
        public var rejected: [(name: String, reason: String)] = []
        /// 质量合格但和主体连不上、磁场图没用的会话（只有 .production 会排除）
        public var magExcluded: [String] = []
        /// 质量合格但不在主体分量里的会话（云端出图会排除的）
        public var offMain: [String] = []
    }

    public enum BuildError: Error { case noUsableSession }

    /// 用建图会话生成磁场图 + 蓝牙指纹。默认和云端出图同一份流水线（见 MapBuild.production / .fusion 的区别），蓝牙指纹用合格会话
    /// （含和主体连不上的）对齐后的轨迹和筛过的读数，和 hpass-build 一样。
    /// - tagPositions: 标签位置表（hpass-build --tag-locations 同一份）；空 = 没有表
    /// - withWiFi: 同时用各会话的 wifi.csv 建 Wi-Fi 指纹（位置取和蓝牙指纹同一条对齐好的轨迹）
    public static func buildMaps(sessions: [URL], map: StoreMap, mode: MapBuild = .fusion,
                                 tagPositions: [String: Point2] = [:], withWiFi: Bool = false) throws -> BuiltMaps {
        let bb = BLEFingerprintBuilder(widthCm: map.width, heightCm: map.height)
        let wb = WiFiFingerprintBuilder()
        func wifiMap() -> WiFiFingerprintMap? { withWiFi && wb.count > 0 ? wb.build() : nil }
        switch mode {
        case .sequential:
            let b = SurveyMapBuilder(widthCm: map.width, heightCm: map.height, crosses: map.crosses)
            var reps: [SurveySessionReport] = []
            for u in sessions {
                let s = try SurveySessionLoader.load(u, mapOriginOffsetCm: map.originOffsetCm)
                let r = b.add(s)
                _ = bb.add(samples: SurveySessionLoader.loadBLE(u), track: r.track)
                if withWiFi { wb.add(scans: WiFiScan.group(SurveySessionLoader.loadWiFi(u)), track: r.track) }
                reps.append(r)
            }
            let ble = bb.build()
            return BuiltMaps(field: b.build(), ble: ble.tags.count >= 20 ? ble : nil, wifi: wifiMap(), reports: reps)
        case .production, .fusion:
            var loaded: [SurveySession] = [], bles: [[BLESample]] = [], signs: [[SignSample]] = []
            for u in sessions {
                loaded.append(try SurveySessionLoader.load(u, mapOriginOffsetCm: map.originOffsetCm))
                bles.append(SurveySessionLoader.loadBLE(u))
                signs.append(SignSample.load(u))
            }
            guard let pb = MultiSessionFusion(map: map).buildProduction(loaded, ble: bles, signs: signs, tagPositions: tagPositions,
                                                                     options: mode == .production ? MultiSessionFusion.ProductionOptions.cloud
                                                                         : MultiSessionFusion.ProductionOptions(qualityGate: false, mainComponentOnly: false)) else {
                throw BuildError.noUsableSession
            }
            for (k, track) in pb.all.tracks.enumerated() where k < pb.keptBLE.count { _ = bb.add(samples: pb.keptBLE[k], track: track) }
            if withWiFi {
                for (k, track) in pb.all.tracks.enumerated() where k < pb.keptIndices.count {
                    wb.add(scans: WiFiScan.group(SurveySessionLoader.loadWiFi(sessions[pb.keptIndices[k]])), track: track)
                }
            }
            let ble = bb.build()
            return BuiltMaps(field: pb.magnetic.field, ble: ble.tags.count >= 20 ? ble : nil, wifi: wifiMap(), reports: pb.magnetic.reports,
                             components: pb.components,
                             rejected: pb.quality.filter { !$0.kept }.map { ($0.name, $0.reason ?? "") },
                             magExcluded: pb.magExcluded, offMain: pb.offMain)
        }
    }

    /// 跟踪似然的地图标定（`TrackingCalibration`）：建图会话按下标奇偶分两折，一折建图、另一折沿自己的参考轨迹
    /// （有 truth.csv 用它，没有用自己的锚点对齐）每 50 cm 取一次读数和图比，两折合起来标定。hpass-build 出图时同一份。
    /// 会话不到 2 个、标不出来（窗口太少 / 图上没有米级信息）时 nil。
    /// 计算量：多建两次图 + 每个建图会话回放一遍特征流水线（不跑定位），离线做，手机上不算。
    public static func trackingCalibration(sessions: [URL], map: StoreMap, mode: MapBuild = .fusion,
                                           tagPositions: [String: Point2] = [:]) -> TrackingCalibration.Result? {
        guard sessions.count >= 2 else { return nil }
        let every = MagneticConfig().updateDistanceCm
        var folds: [TrackingCalibration.Fold] = []
        for k in 0..<2 {
            let held = sessions.indices.filter { $0 % 2 == k }.map { sessions[$0] }
            let rest = sessions.indices.filter { $0 % 2 != k }.map { sessions[$0] }
            guard let f = try? buildMaps(sessions: rest, map: map, mode: mode, tagPositions: tagPositions).field else { continue }
            let seqs = held.compactMap { u in
                (try? residualSamples(dir: u, field: f, map: map, everyCm: every))?
                    .map { TrackingCalibration.Sample(feature: $0.feature, reference: $0.reference) }
            }
            folds.append(.init(field: f, sequences: seqs))
        }
        return TrackingCalibration.calibrate(folds: folds)
    }

    /// - Parameter rooms: 地图有单元（房间 / 走廊）时用房间约束版（墙挡住、门打通、带房间编号，见 `RoomGraph`）
    public static func walkable(_ map: StoreMap, rooms: Bool = false) -> WalkableMap? {
        if rooms, map.crosses.isEmpty, let w = WalkableMap(roomsOf: map) { return w }
        if !map.crosses.isEmpty { return WalkableMap(crosses: map.crosses, widthCm: map.width, heightCm: map.height) }
        if !map.floor.isEmpty {
            return WalkableMap(floor: map.floor, obstacles: map.physicalShelves, widthCm: map.width, heightCm: map.height)
        }
        return nil
    }

    /// 读 truth.csv（t_ms,x_cm,y_cm）。没有返回 nil
    static func loadTruth(_ dir: URL) -> [(tMs: Int64, p: Point2)]? {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("truth.csv"), encoding: .utf8) else { return nil }
        let out = text.split(separator: "\n").dropFirst().compactMap { l -> (tMs: Int64, p: Point2)? in
            let r = l.split(separator: ",")
            guard r.count >= 3, let t = Int64(r[0]), let x = Double(r[1]), let y = Double(r[2]) else { return nil }
            return (t, Point2(x, y))
        }
        return out.count > 1 ? out.sorted { $0.tMs < $1.tMs } : nil
    }

    /// 回放一个测试会话：按时间顺序送 IMU、原始磁力计、蓝牙、ARKit 位姿，和参考轨迹比
    /// 已知起点（`oracleStart`）跟踪用的配置：产品的跟踪配置档 + 命令行覆盖。冷启动收敛门只属于冷启动，
    /// 这里总是关掉（就算命令行的覆盖打开了它）。
    /// - headingKnown: 起点朝向已知（跟踪档的航向偏差按 10° 级先验撒）；false = 整圆（口袋 / 包里起步，手机-行走夹角未知）
    public static func oracleTrackingConfig(odometry: OdometrySource, headingKnown: Bool = true,
                                            configure: ((inout MagneticConfig) -> Void)? = nil) -> MagneticConfig {
        var cfg = MagneticConfig.tracking(odometry: odometry, headingKnown: headingKnown)
        configure?(&cfg)
        cfg.clearColdStartGate()
        return cfg
    }

    /// 粒子滤波的运动从哪来
    public enum MotionSource: String {
        /// 会话里的 arkit_pose.csv（ARKit 位姿，或公开数据集的合成漂移位姿）。默认，老行为
        case poses
        /// 真实 IMU（imu.csv）走 FusionEngine 计步推算，配置和 App 实时定位页一致（`FusionEngine.live`，罗盘关）；
        /// 推算位置的增量送粒子滤波（`ShadowLocalizer.odometryStep`），arkit_pose.csv 不用（可以只有表头）
        case pdrIMU = "pdr-imu"
    }

    /// 已知起点（`oracleStart`）时起步朝向怎么给
    public enum StartHeading: String {
        /// 真值轨迹前 1.5 m 的方向（hpass-replay 的做法）。等于假定手机-行走夹角 δ≈0：只对手持看屏的数据成立（公开 ILC）
        case truth
        /// 不给朝向：粒子航向整圆撒开（口袋 / 包 / 摆臂等 δ 未知的携带方式；评估不能把真值航向漏给滤波器）
        case unknown
    }

    /// 回放时每个打分时刻的一行（hpass-eval --track-out → tools/lab/office_metrics.py）
    public struct TrackPoint {
        public var tMs: Int64
        /// 滤波器最新估计；nil = 还没有任何估计
        public var estimate: Point2?
        /// 有把握（App 会显示位置）
        public var converged: Bool
        public var uncertaintyCm: Double?
        public var reference: Point2
        /// 估计的房间（打开 reportRoom 时）和房间置信度
        public var roomId: String? = nil
        public var roomMass: Double = 0
        /// 惯导引擎判的携带模式（`--carry-motion` 时；否则 unknown）
        public var carryMode: CarryMode = .unknown
        /// 这一刻是静止冻结状态
        public var frozen = false
        /// 纯推算位置（`.pdrIMU`：惯导引擎的输出，已知起点时从真值起点、起步朝向出发；诊断用）
        public var odometry: Point2? = nil
        /// 滤波器报的置信度（诊断用）
        public var confidence: Double? = nil
        /// 诊断（`SessionEvaluator.trackDiagnostics` 打开时才算，每拍多扫一遍粒子）：全部粒子的位置散布（cm）、
        /// 航向偏差的圆周标准差（度）、步长比例的加权中位数 / 标准差
        public var spreadCm: Double? = nil
        public var headingSpreadDeg: Double? = nil
        public var scaleMedian: Double? = nil
        public var scaleSigma: Double? = nil
        /// 航向偏差的加权直方图（12 格，−180°…180°）
        public var headingHistogram: [Double]? = nil
        /// 全部粒子相对报的位置的加权 RMS 距离（cm）
        public var spreadAroundEstimateCm: Double? = nil
        /// 全部粒子的加权平均位置
        public var particleMean: Point2? = nil
        /// 惯导引擎当前生效的步长 K（`.pdrIMU`；诊断用）
        public var stepK: Double? = nil
    }

    /// 逐点轨迹里带上粒子散布等诊断量（hpass-eval --diag-out）。默认关：每拍要多扫一遍粒子
    nonisolated(unsafe) public static var trackDiagnostics = false

    /// `.pdrIMU` 回放用的惯导引擎：App 实时定位页同一份配置（`FusionEngine.live`，罗盘关），**不带通道约束**
    /// （输出只当增量送粒子滤波，见 `FusionConfig.live`）。
    static func replayFusion(start: Point2, headingRad: Double, carryMotion: Bool, stepLengthScale: Double = 1) -> FusionEngine {
        FusionEngine.live(corridors: [], start: start, headingRad: headingRad, compass: false, stepLengthScale: stepLengthScale,
                          carryMotion: carryMotion)
    }

    /// 视觉里程计标定步长 K 的回放（hpass-eval --carry-k --vio-k）：一个有 ARKit 位姿的会话（测绘，或开着摄像头增强的定位）
    /// 按 App 的接法跑一遍——惯导引擎（携带运动模型）从 `initial` 学到的 K 开始，每个 ARKit 位姿配上最新的惯导输出位置喂
    /// `StepScaleCalibrator.observeVisualOdometry`——返回结束时的分姿态 K 和更新次数。不跑粒子滤波，不用地图。
    public static func learnStepScalesFromVIO(dir: URL, initial: [CarryMode: Double]) throws
        -> (scales: [CarryMode: Double], updates: Int, ratios: [Double]) {
        let s = try SurveySessionLoader.load(dir, requireAnchors: false)
        guard !s.poses.isEmpty else { return (initial, 0, []) }
        let f = replayFusion(start: .zero, headingRad: 0, carryMotion: true)
        if !initial.isEmpty { f.setLearnedStepScales(initial) }
        let cal = StepScaleCalibrator()
        var ratios: [Double] = []
        var last: Point2?
        var pi = 0
        for x in s.imu {
            // 这个 IMU 样本之前的 ARKit 位姿：配上当时最新的惯导位置
            while pi < s.poses.count, s.poses[pi].tMs <= x.tMs {
                let p = s.poses[pi]
                if let q = last, cal.observeVisualOdometry(tMs: p.tMs, ar: p.a, trackingNormal: p.normal, pdr: q, engine: f) != nil,
                   let r = cal.lastVIORatio { ratios.append(r) }
                pi += 1
            }
            if let out = f.process(x) { last = out.position }
        }
        return (f.learnedStepScales, cal.vioUpdates, ratios)
    }

    /// 真值轨迹从起点走出 `minCm` 后的方向（弧度，0 = 地图 +y，dx = sin）；走不出这么远返回 nil
    static func truthHeading(_ ref: [(tMs: Int64, p: Point2)], minCm: Double = 150) -> Double? {
        guard let r0 = ref.first, let far = ref.first(where: { $0.p.distance(to: r0.p) >= minCm }) else { return nil }
        return atan2(far.p.x - r0.p.x, far.p.y - r0.p.y)
    }

    public static func evaluate(dir: URL, map: StoreMap, field: MagneticFieldMap, ble: BLEFingerprintMap?,
                                walkable: WalkableMap?, crossCheck: Bool = true,
                                configure: ((inout MagneticConfig) -> Void)? = nil, seed: UInt64 = 1,
                                refTagPositions: [String: Point2]? = nil, oracleStart: Bool = false,
                                odometry: OdometrySource = .pdr, coldStartGate: Bool = false,
                                wifi: WiFiFingerprintMap? = nil, motion: MotionSource = .poses,
                                startHeading: StartHeading = .truth,
                                carryMotion: Bool = false, stationaryFreeze: Bool = false,
                                stepLengthScale: Double = 1, learnedStepScales: [CarryMode: Double] = [:],
                                scaleDiagnostics: Bool = false, posteriorStepScale: Bool = false,
                                onTrack: ((TrackPoint) -> Void)? = nil) throws -> EvalReport {
        // 公开数据集基准 / 盲测会话：会话里有 truth.csv（t_ms,x_cm,y_cm）就直接当参考轨迹（位姿是合成的或根本没有，不能再对齐）；
        // 这时不需要 anchors.csv（盲测机不建图、没有锚点）
        let truth = Self.loadTruth(dir)
        let s = try SurveySessionLoader.load(dir, requireAnchors: truth == nil, mapOriginOffsetCm: map.originOffsetCm)
        // 参考轨迹：这个会话自己的对齐结果（只用它的锚点和贴通道，不用磁场）；给了标签位置时再用标签锚定修正一遍
        // （采集轨迹中途偏航时，不修正的参考本身就是错的）
        let refB = SurveyMapBuilder(widthCm: map.width, heightCm: map.height, crosses: map.crosses)
        var ref = truth ?? refB.add(s).track
        if truth == nil, let tp = refTagPositions, !map.crosses.isEmpty,
           let (fn, _) = TagTrajectoryCorrector(tagPositions: tp).solve(track: ref, ble: SurveySessionLoader.loadBLE(dir)) {
            let b2 = SurveyMapBuilder(widthCm: map.width, heightCm: map.height, crosses: map.crosses)
            b2.correction = fn
            ref = b2.prepare(s).0.track
        }
        func refAt(_ t: Int64) -> Point2? {
            var lo = 0, hi = ref.count - 1
            guard hi > 0, t >= ref[0].tMs, t <= ref[hi].tMs else { return nil }
            while hi - lo > 1 { let m = (lo + hi) / 2; if ref[m].tMs <= t { lo = m } else { hi = m } }
            return t - ref[lo].tMs > 300 ? nil : ref[lo].p  // 参考点比查询时刻旧 300 ms 以上就不算
        }
        let pdr = motion == .pdrIMU
        // 冷启动配置档按地图外框面积取（和 App 实时定位页一样：小场地的搜索更强，见 SmallMapColdStart）；
        // 已知起点下面马上换成跟踪档，不传（不多撒一遍冷启动粒子，随机数序列和原来一样）
        let sh = ShadowLocalizer(field: field, walkable: walkable, useRawMag: !s.raw.isEmpty, configure: configure, seed: seed,
                                coldStartGate: coldStartGate, visualOdometry: !pdr,
                                mapAreaM2: oracleStart ? nil : map.width * map.height / 10_000)
        sh.bleMap = ble
        sh.crossCheckEnabled = crossCheck
        // 真实计步：惯导引擎和 App 实时定位页同一份配置（FusionEngine.live，罗盘关）。
        // 已知起点 = 真值起点 + 起步朝向（见 StartHeading）；冷启动 = 地图中心、朝向 0（App 没设地图朝向时的冷启动），
        // 粒子本来就整圆撒开，惯导的绝对朝向和位置都不进滤波器，只用它的增量。
        // - 通道约束关（corridors 空）：只用增量时，按随便给的绝对位置 / 航向投影到通道会把增量剪掉或冻住（评审）；
        // - 起步朝向在参考轨迹的第一个点重新设：盲测会话里 IMU 比参考轨迹早开始（敲击、把手机放进口袋、转身起步），
        //   这段预滚的偏航不能变成之后每一步的恒定航向误差（评审）。
        // - carryMotion：携带无关的运动模型 + 粒子按携带模式重撒（App 同一套接法，见 docs/carry-motion.md）+ 步长 K 在线标定；
        // - stationaryFreeze：惯导说没在动就算静止，在房间里静止够久冻结，连续走几步解冻（StationaryFreezeDetector）
        var fusion: FusionEngine?
        var seedAt: (p: Point2, h: Double?)?
        let calibrator = StepScaleCalibrator()
        calibrator.learnFromPosterior = posteriorStepScale
        var freezeDet = StationaryFreezeDetector()
        var reachedRef = false
        if pdr {
            if oracleStart, let r0 = ref.first {
                let h = startHeading == .truth ? Self.truthHeading(ref) : nil
                fusion = Self.replayFusion(start: r0.p, headingRad: h ?? 0, carryMotion: carryMotion, stepLengthScale: stepLengthScale)
                seedAt = (r0.p, h)
                sh.localizer.config = oracleTrackingConfig(odometry: odometry, headingKnown: h != nil, configure: configure)
                sh.localizer.reset(start: r0.p, spreadCm: TrackingProfile.startSpreadCm, headingUnknown: h == nil)
            } else {
                fusion = Self.replayFusion(start: Point2(map.width / 2, map.height / 2), headingRad: 0, carryMotion: carryMotion,
                                           stepLengthScale: stepLengthScale)
            }
            if carryMotion, let f = fusion {
                // App 每次开始定位时恢复本机存的分模式 K（StepScaleStore → setLearnedStepScales）；评估默认空 = 第一次用
                if !learnedStepScales.isEmpty { f.setLearnedStepScales(learnedStepScales) }
                // 参考轨迹开始之前的事件不重撒（已知起点的先验是在第一个参考点给的），到第一个参考点时补告知当前模式
                f.onCarryEvent = { ev in if reachedRef { _ = sh.localizer.apply(ev) } }
            }
        }
        // 已知起点 + 已知朝向的「跟踪」模式（基准用，不含冷启动）：
        // 用参考轨迹前 8 m 把位姿坐标系转到地图坐标系，粒子从真实起点出发。
        // 配置用和实时定位页同一份跟踪配置档（MagneticConfig.tracking，按运动来源），起点撒开也一样
        // （TrackingProfile.startSpreadCm），量到的就是产品的跟踪行为；命令行的 configure 照样最后套上
        var poseRot = (c: 1.0, s: 0.0)
        if !pdr, oracleStart, let r0 = ref.first, let pi0 = s.poses.firstIndex(where: { $0.tMs >= r0.tMs }) {
            let a0 = s.poses[pi0].a
            if let pj = s.poses[pi0...].firstIndex(where: { $0.a.distance(to: a0) >= 800 }),
               let rj = ref.first(where: { $0.tMs >= s.poses[pj].tMs }) {
                let da = s.poses[pj].a - a0, dm = rj.p - r0.p
                let phi = atan2(dm.y, dm.x) - atan2(da.y, da.x)
                poseRot = (cos(phi), sin(phi))
                sh.localizer.config = oracleTrackingConfig(odometry: odometry, configure: configure)
                sh.localizer.reset(start: r0.p, spreadCm: TrackingProfile.startSpreadCm, headingUnknown: false)
            }
        }
        // Wi-Fi 冷启动（--wifi，只有 Android 能扫）：和已知起点不同时用
        var wifiScans: [WiFiScan] = []
        if let w = wifi, !oracleStart {
            sh.enableWiFi(w, odometry: odometry, configure: configure)
            wifiScans = WiFiScan.group(SurveySessionLoader.loadWiFi(dir))
        }
        if pdr && carryMotion { sh.localizer.config.carryModeAdaptive = true }
        if pdr && stationaryFreeze { sh.localizer.config.stationaryFreeze = true }
        let bleSamples = ble == nil ? [] : SurveySessionLoader.loadBLE(dir)
        enum Ev { case imu(IMUSample), raw(Int64, (Double, Double, Double)), ble(BLESample), wifi(WiFiScan), pose(SurveySession.Pose) }
        var evs: [(Int64, Int, Ev)] = []
        evs.reserveCapacity(s.imu.count + s.raw.count + s.poses.count + bleSamples.count + wifiScans.count)
        for x in s.imu { evs.append((x.tMs, 0, .imu(x))) }
        for x in s.raw { evs.append((x.tMs, 1, .raw(x.tMs, x.v))) }
        for x in bleSamples { evs.append((x.tMs, 2, .ble(x))) }
        for x in wifiScans { evs.append((x.tMs, 2, .wifi(x))) }
        // 真实计步时位姿不推粒子（会话里可以只有表头）
        if !pdr { for x in s.poses { evs.append((x.tMs, 3, .pose(x))) } }
        evs.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        let ev = LocalizationEvaluator()
        var inMapErr: [Double] = []
        var refTotal = 0, refInMap = 0
        func score(_ est: MagneticEstimate, _ r: Point2) {
            ev.add(estimate: est, reference: r)
            let covered = field.sample(at: r) != nil
            refTotal += 1
            if covered { refInMap += 1 }
            if covered && est.converged { inMapErr.append(est.position.distance(to: r)) }
        }
        // 每个运动节拍（位姿 / 惯导输出）都写一行轨迹，滤波器这一拍没更新时用它最新的估计
        func track(_ t: Int64, odometry: Point2? = nil) {
            guard let cb = onTrack, let r = refAt(t) else { return }
            let e = sh.estimate
            var tp = TrackPoint(tMs: t, estimate: e?.position, converged: e?.converged ?? false,
                                uncertaintyCm: e?.uncertaintyCm, reference: r, roomId: e?.roomId, roomMass: e?.roomMass ?? 0,
                                carryMode: fusion?.carryMode ?? .unknown, frozen: sh.localizer.stationaryFrozen, odometry: odometry)
            tp.confidence = e?.confidence
            if Self.trackDiagnostics {
                let ws = sh.localizer.weightedSpread(), ss = sh.localizer.scaleStatistics()
                tp.spreadCm = ws.spreadCm
                tp.particleMean = ws.mean
                tp.headingSpreadDeg = ws.headingSpreadDeg
                tp.scaleMedian = ss.median
                tp.scaleSigma = ss.sigma
                tp.headingHistogram = sh.localizer.headingBiasHistogram(bins: 12)
                if let p = e?.position { tp.spreadAroundEstimateCm = sh.localizer.weightedSpread(around: p) }
            }
            if scaleDiagnostics, odometry != nil {
                let st = sh.localizer.scaleStatistics()
                tp.scaleMedian = st.median
                tp.scaleSigma = st.sigma
                tp.stepK = fusion?.effectiveStepLengthK
            }
            cb(tp)
        }
        var lastFused: Point2?
        for (_, _, e) in evs {
            switch e {
            case .imu(let x):
                sh.imu(x)
                guard let f = fusion, let out = f.process(x) else { continue }
                // 参考轨迹开始之前（盲测会话：开始敲击、把手机放进口袋那几秒）的位移不推粒子：已知起点是参考轨迹的第一个点
                if let r0 = ref.first, out.tMs < r0.tMs { lastFused = out.position; continue }
                if !reachedRef {
                    reachedRef = true
                    if let s0 = seedAt {
                        // 已知起点：在第一个参考点重新设起点和起步朝向（预滚的偏航不带进来）
                        f.setInitialPosition(s0.p, headingRad: s0.h)
                        seedAt = nil
                        lastFused = s0.p
                    } else {
                        lastFused = out.position
                    }
                    if carryMotion { sh.localizer.setCarryMode(f.activeCarryMode, respread: false) }
                    track(out.tMs, odometry: lastFused)
                    continue
                }
                let d = lastFused.map { out.position - $0 } ?? .zero
                lastFused = out.position
                if stationaryFreeze {
                    sh.localizer.feedStationary(&freezeDet, tMs: out.tMs, still: !out.isMoving, stepCount: out.stepCount)
                }
                if let est = sh.odometryStep(delta: d, tMs: out.tMs), let r = refAt(out.tMs) { score(est, r) }
                if carryMotion { calibrator.step(deltaCm: d.length, engine: f, localizer: sh.localizer) }
                track(out.tMs, odometry: out.position)
            case .raw(let t, let v): sh.rawMag(tMs: t, v)
            case .ble(let b): sh.bleReading(tMs: b.tMs, id: b.id, rssi: b.rssi)
            case .wifi(let w): sh.wifiScan(w)
            case .pose(let p):
                let pa = Point2(p.a.x * poseRot.c - p.a.y * poseRot.s, p.a.x * poseRot.s + p.a.y * poseRot.c)
                if let est = sh.pose(a: pa, normal: p.normal, tMs: p.tMs), let r = refAt(p.tMs) { score(est, r) }
                // 位姿（只转了方向、没平移到地图）当「纯推算」给 --odo-out：诊断只用它的路程 / 位移比例
                track(p.tMs, odometry: scaleDiagnostics ? pa : nil)
            }
        }
        var rep = EvalReport(session: dir.lastPathComponent, medianCm: ev.percentile(0.5), p90Cm: ev.percentile(0.9),
                          within1m: ev.within1m, jumps: ev.jumps, firstFixM: ev.firstFixPathCm.map { $0 / 100 },
                          pathM: ev.pathCm / 100, points: ev.errors.count, usedBLE: ble != nil,
                          wrongFixShare: ev.errors.isEmpty ? nil : Double(ev.errors.filter { $0 > 500 }.count) / Double(ev.errors.count),
                          crossCheckResets: sh.crossCheckResets,
                          inMapMedianCm: pct(inMapErr, 0.5), inMapP90Cm: pct(inMapErr, 0.9),
                          inMapWithin1m: inMapErr.isEmpty ? nil : Double(inMapErr.filter { $0 <= 100 }.count) / Double(inMapErr.count),
                          inMapShare: refTotal > 0 ? Double(refInMap) / Double(refTotal) : nil)
        rep.errorsCm = ev.errors
        rep.refPoints = refTotal
        rep.uncertaintiesCm = ev.uncertainties
        rep.estPathCm = ev.estPathCm
        rep.refPathFixCm = ev.refPathFixCm
        rep.bigJumps = ev.bigJumps
        if carryMotion, let f = fusion {
            rep.learnedStepScales = Dictionary(uniqueKeysWithValues: f.learnedStepScales.map { ($0.key.rawValue, $0.value) })
            rep.stepScaleAbsorbed = calibrator.absorbed
        }
        return rep
    }

    /// 诊断：测试会话里每走 `everyCm` 取一次实测特征（和定位用的同一条流水线），和地图在参考位置的值比。
    /// 用来按「实际残差」标定跟踪档的观测噪声（见 MagneticConfig.trackingLikelihood）。只用有 truth.csv 的会话。
    public struct ResidualSample {
        public var tMs: Int64
        public var pathCm: Double
        public var feature: MagneticFeature
        /// 地图在参考位置的均值 / 标准差；nil = 那里没数据
        public var mean: MagneticFeature?
        public var sigma: MagneticFeature?
        /// 参考位置（地图坐标，cm）
        public var reference: Point2 = .zero
    }

    /// - map: 给了时，没有 truth.csv 的会话（自采建图会话，留一法）用它自己的对齐结果（锚点 + 贴通道）当参考，和 evaluate 一样
    public static func residualSamples(dir: URL, field: MagneticFieldMap, map: StoreMap? = nil, everyCm: Double = 50) throws -> [ResidualSample] {
        let truth = Self.loadTruth(dir)
        let s = try SurveySessionLoader.load(dir, requireAnchors: truth == nil, mapOriginOffsetCm: map?.originOffsetCm ?? .zero)
        var ref: [(tMs: Int64, p: Point2)]
        if let truth { ref = truth } else if let map {
            ref = SurveyMapBuilder(widthCm: map.width, heightCm: map.height, crosses: map.crosses).add(s).track
        } else { return [] }
        guard ref.count > 1 else { return [] }
        func refAt(_ t: Int64) -> Point2? {
            var lo = 0, hi = ref.count - 1
            guard hi > 0, t >= ref[0].tMs, t <= ref[hi].tMs else { return nil }
            while hi - lo > 1 { let m = (lo + hi) / 2; if ref[m].tMs <= t { lo = m } else { hi = m } }
            return t - ref[lo].tMs > 300 ? nil : ref[lo].p
        }
        let sh = ShadowLocalizer(field: field, walkable: nil, useRawMag: !s.raw.isEmpty)
        enum Ev { case imu(IMUSample), raw(Int64, (Double, Double, Double)), pose(SurveySession.Pose) }
        var evs: [(Int64, Int, Ev)] = []
        for x in s.imu { evs.append((x.tMs, 0, .imu(x))) }
        for x in s.raw { evs.append((x.tMs, 1, .raw(x.tMs, x.v))) }
        for x in s.poses { evs.append((x.tMs, 3, .pose(x))) }
        evs.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var out: [ResidualSample] = []
        var lastA: Point2?, path = 0.0, nextAt = everyCm
        for (_, _, e) in evs {
            switch e {
            case .imu(let x): sh.imu(x)
            case .raw(let t, let v): sh.rawMag(tMs: t, v)
            case .pose(let p):
                guard p.normal else { lastA = nil; continue }
                if let l = lastA, p.a.distance(to: l) < 300 { path += p.a.distance(to: l) }
                lastA = p.a
                guard path >= nextAt else { continue }
                nextAt = path + everyCm
                guard let f = sh.latestFeature, let r = refAt(p.tMs) else { continue }
                let m = field.sample(at: r)
                out.append(ResidualSample(tMs: p.tMs, pathCm: path, feature: f, mean: m?.mean, sigma: m?.sigma, reference: r))
            }
        }
        return out
    }
}

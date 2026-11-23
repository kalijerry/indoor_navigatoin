import Foundation
import HPASSKit

// 定位精度评估：建图会话生成磁场图 + 蓝牙指纹，测试会话冷启动回放，和各自的采集轨迹比。
//
//   swift run -c release hpass-eval --map map.json --build s1,s2 --test t1,t2 [--no-ble] [--json report.json]
//
// 会话目录里要有 imu.csv、arkit_pose.csv、anchors.csv（建图采集会话的格式），mag_raw.csv / ble.csv 可选。
//
//   --motion poses|pdr-imu        粒子滤波的运动：位姿（默认）/ 真实 IMU 计步推算（同 App 实时定位页的 FusionEngine 配置）
//   --start-heading truth|unknown 已知起点（--oracle-start）的起步朝向：真值前 1.5 m 方向（默认）/ 整圆撒开
//   --track-out track.csv         每个运动节拍一行估计 + 参考（tools/lab/office_metrics.py 用）
//   --carry-motion                pdr-imu 时打开携带无关的运动模型 + 粒子按携带模式重撒 + 步长 K 在线标定（App 同一套接法）
//   --stationary-freeze           pdr-imu 时打开静止冻结（惯导说没在动就算静止；办公室坐着不动用，配合 --rooms）
//   --dr-dump dr.csv              诊断：只对 --test 跑纯计步推算（起点 / 朝向取参考轨迹），逐拍写 CSV，给 tools/bench/dr_decompose.py 拆误差
//   --residuals res.csv           只导出测试会话「实测特征 vs 地图在参考位置」的残差（含参考坐标），不跑定位；
//                                 没有 truth.csv 的会话用它自己的锚点对齐当参考（留一法，tools/bench/map_cv.py 用）
//   --field-out field.json        把建好的磁场图（magField 节点）写出来
//   --fill-radius cm / --gp-length cm / --fill gp|idw   磁场图补空格的试验开关（默认 = 产品设置 150 / 100 / gp）
//   --no-tracking-calibration / --tracking-temperature T   跟踪似然的地图标定：不标定（老地图）/ 直接给温度（默认建图会话两折交叉验证标定）

func arg(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}
// 逗号分隔的会话目录；某项下面没有 imu.csv 就当成「会话的父目录」，展开成所有子目录（公开数据集基准用）
func list(_ s: String?) -> [URL] {
    (s ?? "").split(separator: ",").flatMap { part -> [URL] in
        let u = URL(fileURLWithPath: String(part))
        if FileManager.default.fileExists(atPath: u.appendingPathComponent("imu.csv").path) { return [u] }
        let kids = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
        return kids.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("imu.csv").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

guard let mapPath = arg("--map") else {
    print("用法：hpass-eval --map map.json --build 会话1,会话2 --test 会话3,会话4 [--no-ble] [--json 输出.json]")
    exit(2)
}
do {
    let map = try StoreDataLoader.loadMap(Data(contentsOf: URL(fileURLWithPath: mapPath)))
    // 诊断：--test 的每个会话只跑纯计步推算（不建图、不定位），逐拍和参考轨迹一起写成 CSV（tools/bench/dr_decompose.py 拆误差）
    if let dp = arg("--dr-dump") {
        var lines = [DeadReckoningDump.csvHeader]
        for t in list(arg("--test")) {
            let rows = try DeadReckoningDump.run(dir: t, map: map, carryMotion: CommandLine.arguments.contains("--carry-motion"))
            lines += DeadReckoningDump.csvLines(session: t.lastPathComponent, rows: rows)
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: dp, atomically: true, encoding: .utf8)
        print("纯推算已写到 \(dp)")
        exit(0)
    }
    let build = list(arg("--build")), test = list(arg("--test"))
    guard !build.isEmpty, !test.isEmpty else { print("--build 和 --test 都要给"); exit(2) }
    let overlap = Set(build.map(\.standardizedFileURL)).intersection(test.map(\.standardizedFileURL))
    if !overlap.isEmpty { print("⚠️ 有会话同时在建图和测试里：\(overlap.map(\.lastPathComponent))，结果会偏乐观") }
    // 标签位置表：建图时和 hpass-build 一样用来修正轨迹 / 质量筛选，测试时用来修正参考轨迹
    var refTags: [String: Point2]?
    if let p = arg("--tag-locations") ?? arg("--esl-locations"), let t = try? String(contentsOfFile: p, encoding: .utf8) {
        let locs = TagLocations.parse(t, map: map)
        var tp: [String: Point2] = [:]
        for e in locs { if let q = e.position { tp[e.id] = q } }
        refTags = tp
        print("参考轨迹：用标签锚定修正")
    }
    // 磁场图默认用云端出图同一份流水线（MultiSessionFusion.buildProduction）的融合核心：全局解偏移 + 标签修正，
    // 不做质量筛选、不排除和主体连不上的分量（原因见 SessionEvaluator.MapBuild.fusion）；
    // --map-build production = 和云端完全一样（磁场图只用主体分量）；sequential = 手机上按顺序逐个对齐的老办法
    let modes: [String: SessionEvaluator.MapBuild] = ["sequential": .sequential, "production": .production, "fusion": .fusion]
    let mapMode = modes[arg("--map-build") ?? "fusion"] ?? .fusion
    // --wifi：Wi-Fi 冷启动（只有 Android 能扫 Wi-Fi；见 WiFiColdStartProfile），用建图会话的 wifi.csv 建指纹
    let useWiFi = CommandLine.arguments.contains("--wifi")
    // 磁场图补空格的试验开关（默认 = 产品的设置）
    if let v = arg("--fill-radius").flatMap(Double.init) { MagneticFieldBuilder.defaultFillRadiusCm = v }
    if let v = arg("--fill").flatMap(MagneticFieldBuilder.FillMethod.init(rawValue:)) { MagneticFieldBuilder.defaultFillMethod = v }
    if let v = arg("--gp-length").flatMap(Double.init) { MagneticFieldBuilder.defaultGPLengthCm = v }
    let built = try SessionEvaluator.buildMaps(sessions: build, map: map, mode: mapMode, tagPositions: refTags ?? [:],
                                               withWiFi: useWiFi)
    var field = built.field
    let bleMap = built.ble
    // 跟踪似然的地图标定（和 hpass-build 出图时同一份，见 SessionEvaluator.trackingCalibration）。只有已知起点的跟踪用得到，
    // 冷启动不算（省时间）。--tracking-temperature T 直接给（≤ 0 = 不标定），--no-tracking-calibration = 老地图（不带标定）
    if let v = arg("--tracking-temperature").flatMap(Double.init) {
        field.trackingTemperature = v > 0 ? v : nil
    } else if CommandLine.arguments.contains("--oracle-start") && !CommandLine.arguments.contains("--no-tracking-calibration") {
        let cal = SessionEvaluator.trackingCalibration(sessions: build, map: map, mode: mapMode, tagPositions: refTags ?? [:])
        field.trackingTemperature = cal?.temperature
        let per = cal?.perDistance.map { String(format: "%.1f m：%d 窗、LLR %.2f、T %.1f", $0.distanceCm / 100, $0.windows, $0.meanLLR, $0.temperature) }
        print("跟踪似然标定：" + (cal.map { String(format: "温度 %.1f", $0.temperature)
            + ($0.temperature <= TrackingCalibration.maxTemperature ? "（计步跟踪用粒子偏移似然）" : "（超过 \(Int(TrackingCalibration.maxTemperature))，照旧）") } ?? "没标定")
              + (per.map { "；" + $0.joined(separator: "，") } ?? ""))
    }
    for r in built.reports {
        let off = r.offsetUT.map { String(format: "，偏移 |B| %+.1f Bz %+.1f Bh %+.1f µT", $0.total, $0.vertical, $0.horizontal) } ?? ""
        print("建图 \(r.name)：样本 \(r.samplesUsed)" + off + (r.warnings.isEmpty ? "" : "，⚠️ \(r.warnings.joined(separator: "；"))"))
    }
    for x in built.rejected { print("建图不用 \(x.name)：\(x.reason)") }
    var summary = "建图：\(build.count) 个会话，"
    summary += mapMode == .production ? "合格 \(build.count - built.rejected.count) 个" : "不做质量筛选"
    summary += "，\(built.components) 个连通分量"
    if !built.offMain.isEmpty {
        summary += "，不在主体里 \(built.offMain.count) 个"
        summary += built.magExcluded.isEmpty ? "（仍在磁场图里；云端出图会排除）" : "（磁场图没用）"
    }
    summary += "，磁场 \(field.coveredCells) 格"
    if let t = field.trackingTemperature { summary += String(format: "，跟踪似然标定温度 %.1f", t) }
    print(summary)
    print("磁场图：有数据 \(field.coveredCells) 格；蓝牙指纹：\(bleMap.map { "\($0.tags.count) 个标签" } ?? "无")")
    if useWiFi {
        guard let w = built.wifi else { print("--wifi：建图会话里没有 Wi-Fi 扫描（wifi.csv）"); exit(2) }
        print("Wi-Fi 指纹：\(w.entries.count) 次扫描")
    }
    if CommandLine.arguments.contains("--old-ble") { BLEAssist.defaultTagRanges = false }
    if CommandLine.arguments.contains("--no-pregate") { BLEAssist.defaultPreGate = false }
    if CommandLine.arguments.contains("--no-covgate") { BLEAssist.defaultCoverageGate = false }
    if CommandLine.arguments.contains("--fixed-ble-ranges") { BLEAssist.defaultLearnedRanges = false }
    if let r = bleMap?.learnedRanges {
        print("蓝牙标签范围（学到的，P90）：" + r.map { "≥\(Int($0.minRssi)) dBm \(Int($0.rangeCm / 100)) m" }.joined(separator: "，"))
    }
    var ble = CommandLine.arguments.contains("--no-ble") ? nil : bleMap
    if ble != nil, let p = arg("--tag-locations") ?? arg("--esl-locations"), let t = try? String(contentsOfFile: p, encoding: .utf8) {
        ble = TagLocations.seededBLEMap(TagLocations.parse(t, map: map), learned: bleMap)
        print("蓝牙底图：标签位置表 + 学到的，\(ble!.tags.count) 个标签")
    }
    // 诊断：把建好的磁场图（magField 节点）写出来
    if let fp = arg("--field-out") {
        try JSONSerialization.data(withJSONObject: field.jsonObject()).write(to: URL(fileURLWithPath: fp))
    }
    // 诊断：只导出测试会话「实测特征 vs 地图在参考位置」的残差（每 50 cm 一条），不跑定位
    if let rp = arg("--residuals") {
        var csv = "session,t_ms,path_cm,f_total,f_vertical,f_horizontal,m_total,m_vertical,m_horizontal,s_total,s_vertical,s_horizontal,ref_x,ref_y" + "\n"
        func f3(_ v: MagneticFeature?) -> String {
            v.map { String(format: "%.3f,%.3f,%.3f", $0.total, $0.vertical, $0.horizontal) } ?? ",,"
        }
        for t in test {
            for r in try SessionEvaluator.residualSamples(dir: t, field: field, map: map) {
                csv += "\(t.lastPathComponent),\(r.tMs),\(String(format: "%.1f", r.pathCm)),\(f3(r.feature)),\(f3(r.mean)),\(f3(r.sigma)),"
                    + String(format: "%.1f,%.1f", r.reference.x, r.reference.y) + "\n"
            }
        }
        try csv.write(toFile: rp, atomically: true, encoding: .utf8)
        print("残差已写到 \(rp)")
        exit(0)
    }
    // --rooms：办公室地图（有单元 / 门 / 墙）用房间约束（不经门不能换房间）并在估计里带房间，见 RoomGraph
    let useRooms = CommandLine.arguments.contains("--rooms")
    let walk = SessionEvaluator.walkable(map, rooms: useRooms)
    if useRooms { print(walk?.rooms.map { "房间约束：\($0.rooms.count) 个单元、\($0.doors.count) 扇门、\($0.openSeams) 段没墙的分界" } ?? "房间约束：地图没有单元，不用") }
    var out: [EvalReport] = []
    // 粒子滤波有随机性（加上字典遍历顺序每次不同），单次结果波动很大：--runs N 跑 N 次（不同随机种子），报中位和范围
    let runs = max(Int(arg("--runs") ?? "1") ?? 1, 1)
    // 运动来源（只影响 --oracle-start 的跟踪配置档，见 MagneticConfig.tracking）：vio = 视觉里程计，pdr = 计步（默认）
    let odoArg = arg("--odometry") ?? "pdr"
    guard let odometry = OdometrySource(rawValue: odoArg) else { print("--odometry 只能是 vio 或 pdr"); exit(2) }
    if CommandLine.arguments.contains("--oracle-start") { print("跟踪配置档：\(odometry.rawValue)") }
    // 粒子滤波的运动从哪来：poses = arkit_pose.csv（默认，老行为；公开数据集是合成漂移）；
    // pdr-imu = 真实 IMU 走 FusionEngine 计步推算（配置同 App 实时定位页），arkit_pose.csv 可以只有表头
    let motionArg = arg("--motion") ?? "poses"
    guard let motion = SessionEvaluator.MotionSource(rawValue: motionArg) else { print("--motion 只能是 poses 或 pdr-imu"); exit(2) }
    // 已知起点的起步朝向：truth = 真值前 1.5 m 的方向（默认；等于假定手机-行走夹角 δ≈0，只对手持看屏成立），
    // unknown = 整圆撒开（口袋 / 包 / 摆臂，不把真值航向漏给滤波器）
    let shArg = arg("--start-heading") ?? "truth"
    guard let startHeading = SessionEvaluator.StartHeading(rawValue: shArg) else { print("--start-heading 只能是 truth 或 unknown"); exit(2) }
    if motion == .pdrIMU { print("运动来源：真实 IMU 计步推算（FusionEngine）" + (CommandLine.arguments.contains("--oracle-start") ? "，起步朝向 \(startHeading.rawValue)" : "")) }
    // --track-out：每个运动节拍一行（会话、第几次、时刻、估计、是否有把握、不确定度、参考），给 tools/lab/office_metrics.py
    let trackOut = arg("--track-out")
    // --odo-out：诊断用，--motion pdr-imu 时每个运动节拍一行纯推算位置（惯导引擎输出）+ 参考 + 滤波估计
    let odoOut = arg("--odo-out")
    // --diag-out：诊断用，每个运动节拍一行估计 + 参考 + 置信度 + 粒子散布 / 航向散布 / 步长比例（每拍多扫一遍粒子，只给诊断）
    let diagOut = arg("--diag-out")
    if diagOut != nil { SessionEvaluator.trackDiagnostics = true }
    var diagLines = ["session,run,t_ms,est_x,est_y,converged,unc_cm,ref_x,ref_y,confidence,spread_cm,heading_spread_deg,scale_median,scale_sigma,odo_x,odo_y,heading_hist,spread_est_cm,mean_x,mean_y"]
    var odoLines = ["session,run,t_ms,odo_x,odo_y,ref_x,ref_y,est_x,est_y,converged,unc_cm"]
    var trackLines = ["session,run,t_ms,est_x,est_y,converged,unc_cm,ref_x,ref_y,room_id,room_mass,carry_mode,frozen"]
    let carryMotion = CommandLine.arguments.contains("--carry-motion")
    let stationaryFreeze = CommandLine.arguments.contains("--stationary-freeze")
    if motion == .pdrIMU && (carryMotion || stationaryFreeze) {
        print("运动模型：" + [carryMotion ? "携带无关（按携带模式重撒 + K 在线标定）" : nil, stationaryFreeze ? "静止冻结" : nil].compactMap { $0 }.joined(separator: "，"))
    }
    for t in test {
        var rs: [EvalReport] = []
        for k in 0..<runs {
            let r = try SessionEvaluator.evaluate(dir: t, map: map, field: field, ble: ble, walkable: walk,
                                                  crossCheck: !CommandLine.arguments.contains("--no-crosscheck"), configure: { cfg in
                if CommandLine.arguments.contains("--offset") { cfg.offsetInvariant = true }
                if CommandLine.arguments.contains("--hybrid") { cfg.hybridOffset = true }
                if CommandLine.arguments.contains("--absolute") { cfg.offsetInvariant = false }
                if CommandLine.arguments.contains("--no-hybrid") { cfg.hybridOffset = false }
                if let w = arg("--abs").flatMap(Double.init) { cfg.absoluteWeight = w }
                if let w = arg("--win").flatMap(Double.init) { cfg.offsetWindowUpdates = w }
                if let w = arg("--missing").flatMap(Double.init) { cfg.missingDataPenalty = w }
                if CommandLine.arguments.contains("--adaptive") { cfg.adaptiveMagWeight = true }
                if CommandLine.arguments.contains("--wall-slide") { cfg.wallSlide = true }
                if useRooms { cfg.roomConstraints = true; cfg.reportRoom = true }
                // 似然标定的试验开关（默认不给 = 用配置档里的值）
                if let v = arg("--obs-sigma-floor").flatMap(Double.init) { cfg.observationSigmaFloorUT = v }
                if let v = arg("--mag-corr-cm").flatMap(Double.init) { cfg.magneticCorrelationCm = v }
                if let v = arg("--converged-mag-weight").flatMap(Double.init) { cfg.convergedMagWeight = v }
                // 每个粒子自己估偏移（MagneticConfig.particleOffsetFilter）的试验开关
                // （只改跟踪配置档：冷启动的配置档不动）
                if cfg.trackingOdometry != nil, let v = arg("--particle-offset").flatMap(Int.init) { cfg.particleOffsetFilter = v != 0 }
                if let v = arg("--po-q").flatMap(Double.init) { cfg.particleOffsetWalkVarUT2 = v }
                if let v = arg("--po-r").flatMap(Double.init) { cfg.particleOffsetWhiteVarUT2 = v }
                if let v = arg("--po-temp").flatMap(Double.init) { cfg.particleOffsetTemperature = v }
                if let v = arg("--offset-warmup").flatMap(Int.init) { cfg.offsetWarmupUpdates = v }
                if let v = arg("--offset-window").flatMap(Int.init) { cfg.offsetMedianWindow = v }
                if let v = arg("--lost-updates").flatMap(Int.init) { cfg.lostUpdates = v }
                if let v = arg("--lost-confidence").flatMap(Double.init) { cfg.lostConfidence = v }
                if let v = arg("--lost-confidence-prior").flatMap(Double.init) { cfg.lostConfidenceWithExternalPrior = v }
                if let v = arg("--confidence-scale").flatMap(Double.init) { cfg.confidenceScaleCm = v }
                if let v = arg("--cluster-radius").flatMap(Double.init) { cfg.clusterRadiusCm = v }
                // 运动模型的试验开关（默认不给 = 用配置档里的值）
                if let v = arg("--init-scale-sigma").flatMap(Double.init) { cfg.initialScaleSigma = v }
                if let v = arg("--scale-walk").flatMap(Double.init) { cfg.scaleWalkPerM = v }
                if let v = arg("--heading-walk").flatMap(Double.init) { cfg.headingBiasWalkDegPerM = v }
                if let v = arg("--init-heading-sigma").flatMap(Double.init) { cfg.initialHeadingBiasSigmaDeg = v }
                if let v = arg("--pos-noise").flatMap(Double.init) { cfg.positionNoiseFraction = v }
                if let v = arg("--conv-pos-noise").flatMap(Double.init) { cfg.convergedPositionNoiseFraction = v }
                if let v = arg("--particles").flatMap(Int.init) { cfg.particleCount = v }
                if let v = arg("--jump-confirm").flatMap(Int.init) { cfg.jumpConfirmUpdates = v }
                if let v = arg("--keep-near").flatMap(Int.init) { cfg.keepClusterRequiresNear = v != 0 }
                if let v = arg("--blocked-penalty").flatMap(Double.init) { cfg.blockedPenalty = v }
                if CommandLine.arguments.contains("--hard-ble-tracking") { cfg.bleSoftTracking = false }
                if CommandLine.arguments.contains("--ble-soft-no-recover") { cfg.bleSoftLocalRecovery = false }
                if let w = arg("--ble-soft-weight").flatMap(Double.init) { cfg.bleSoftPriorWeight = w }
                if let w = arg("--ble-soft-sigma").flatMap(Double.init) { cfg.bleSoftPriorSigmaCm = w }
                if let w = arg("--ble-soft-range-weight").flatMap(Double.init) { cfg.bleSoftRangeWeight = w }
                // 冷启动收敛门的单项覆盖（实验用；--cold-gate 打开推荐值，这几项再改其中一项）
                if let v = arg("--cold-min-path").flatMap(Double.init) { cfg.coldMinPathCm = v }
                if let v = arg("--cold-mode-ratio").flatMap(Double.init) { cfg.coldModeRatio = v }
                if let v = arg("--cold-streak").flatMap(Int.init) { cfg.coldMinStreak = v }
                if let v = arg("--cold-ess").flatMap(Double.init) { cfg.coldMinEffectiveRatio = v }
                if let v = arg("--cold-temp").flatMap(Double.init) { cfg.coldSearchTemperature = v }
                // 只靠地磁的冷启动不报位置（产品决定，见 MagneticConfig.magOnlyColdStartReports）
                if CommandLine.arguments.contains("--no-mag-only-cold-fix") { cfg.magOnlyColdStartReports = false }
                if let v = arg("--uniform-inject").flatMap(Int.init) { cfg.uniformHeadingForInjection = v != 0 }
                // 冷启动搜索的试验开关（默认按地图面积取，见 SmallMapColdStart）：粒子数、挑战者开关 / 门限 / 粒子数
                if let v = arg("--cold-particles").flatMap(Int.init) { cfg.coldStartParticleCount = v }
                if let v = arg("--challenger").flatMap(Int.init) { cfg.coldChallenger = v != 0 }
                if let v = arg("--challenger-bf").flatMap(Double.init) { cfg.coldChallengerLogBayesFactor = v }
                if let v = arg("--challenger-particles").flatMap(Int.init) { cfg.coldChallengerParticleCount = v }
            }, seed: UInt64(k + 1), refTagPositions: refTags,
                                                  oracleStart: CommandLine.arguments.contains("--oracle-start"),
                                                  odometry: odometry,
                                                  // 冷启动收敛门：只在冷启动、还没用过蓝牙先验时起作用；--oracle-start 的跟踪从不用
                                                  coldStartGate: CommandLine.arguments.contains("--cold-gate"),
                                                  wifi: useWiFi ? built.wifi : nil, motion: motion, startHeading: startHeading,
                                                  carryMotion: carryMotion, stationaryFreeze: stationaryFreeze,
                                                  onTrack: trackOut == nil && odoOut == nil && diagOut == nil ? nil : { p in
                func f1(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }
                func f3(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "" }
                if diagOut != nil {
                    diagLines.append("\(t.lastPathComponent),\(k + 1),\(p.tMs),\(f1(p.estimate?.x)),\(f1(p.estimate?.y)),\(p.converged ? 1 : 0),"
                                     + "\(f1(p.uncertaintyCm.flatMap { $0.isFinite ? $0 : nil })),\(f1(p.reference.x)),\(f1(p.reference.y)),"
                                     + "\(f3(p.confidence)),\(f1(p.spreadCm.flatMap { $0.isFinite ? $0 : nil })),\(f1(p.headingSpreadDeg)),"
                                     + "\(f3(p.scaleMedian)),\(f3(p.scaleSigma)),\(f1(p.odometry?.x)),\(f1(p.odometry?.y)),"
                                     + (p.headingHistogram ?? []).map { String(format: "%.2f", $0) }.joined(separator: ";")
                                     + ",\(f1(p.spreadAroundEstimateCm)),\(f1(p.particleMean?.x)),\(f1(p.particleMean?.y))")
                }
                if odoOut != nil, let o = p.odometry {
                    odoLines.append("\(t.lastPathComponent),\(k + 1),\(p.tMs),\(f1(o.x)),\(f1(o.y)),\(f1(p.reference.x)),\(f1(p.reference.y)),"
                                    + "\(f1(p.estimate?.x)),\(f1(p.estimate?.y)),\(p.converged ? 1 : 0),\(f1(p.uncertaintyCm.flatMap { $0.isFinite ? $0 : nil }))")
                }
                trackLines.append("\(t.lastPathComponent),\(k + 1),\(p.tMs),\(f1(p.estimate?.x)),\(f1(p.estimate?.y)),"
                                  + "\(p.converged ? 1 : 0),\(f1(p.uncertaintyCm.flatMap { $0.isFinite ? $0 : nil })),\(f1(p.reference.x)),\(f1(p.reference.y)),"
                                  + "\(p.roomId ?? ""),\(p.roomId == nil ? "" : String(format: "%.3f", p.roomMass)),\(p.carryMode.rawValue),\(p.frozen ? 1 : 0)")
            })
            if runs == 1 { print(r.line) }
            rs.append(r)
        }
        if runs > 1 {
            func summary(_ xs: [Double?], unit: String = " cm") -> String {
                let v = xs.compactMap { $0 }.sorted()
                guard !v.isEmpty else { return "—" }
                return String(format: "%.0f%@（%.0f～%.0f）", v[v.count / 2], unit, v.first!, v.last!)
            }
            print("\(t.lastPathComponent)  \(runs) 次：中位 \(summary(rs.map(\.medianCm)))  P90 \(summary(rs.map(\.p90Cm)))"
                  + "  首次定位 \(summary(rs.map(\.firstFixM), unit: " m"))  跳 \(summary(rs.map { Double($0.jumps) }, unit: ""))")
            print("    └ 只看建图覆盖到的地方：中位 \(summary(rs.map(\.inMapMedianCm)))  P90 \(summary(rs.map(\.inMapP90Cm)))"
                  + "  ≤1m \(summary(rs.map { $0.inMapWithin1m.map { $0 * 100 } }, unit: "%"))")
        }
        out.append(contentsOf: rs)
    }
    // 汇总（所有会话、所有次数的点混在一起）：基准用
    do {
        let errs = out.flatMap(\.errorsCm).sorted()
        let ff = out.compactMap(\.firstFixM).sorted()
        let refN = out.reduce(0) { $0 + $1.refPoints }
        if !errs.isEmpty {
            func q(_ a: [Double], _ p: Double) -> Double { a[min(Int(Double(a.count - 1) * p + 0.5), a.count - 1)] }
            print(String(format: "【汇总】%d 次回放：中位 %.0f cm  P90 %.0f cm  >5m %.0f%%  ≤2m %.0f%%  定位覆盖 %.0f%%  首次定位中位 %@（%d/%d 次定到）",
                         out.count, q(errs, 0.5), q(errs, 0.9),
                         100 * Double(errs.filter { $0 > 500 }.count) / Double(errs.count),
                         100 * Double(errs.filter { $0 <= 200 }.count) / Double(errs.count),
                         refN > 0 ? 100 * Double(errs.count) / Double(refN) : 0,
                         ff.isEmpty ? "—" : String(format: "%.1f m", q(ff, 0.5)), ff.count, out.count))
            // 不确定度标定（报的 1σ 是均方根半径：二维高斯时 误差 / 1σ 的中位 0.83、63% 落在 1σ 内、98% 在 2σ 内）和跳点
            let ratios = zip(out.flatMap(\.errorsCm), out.flatMap(\.uncertaintiesCm)).compactMap { $1 > 0 ? $0 / $1 : nil }.sorted()
            let estP = out.reduce(0) { $0 + $1.estPathCm }, refP = out.reduce(0) { $0 + $1.refPathFixCm }
            if !ratios.isEmpty {
                print(String(format: "【稳健】误差/不确定度 中位 %.2f  1σ 内 %.0f%%  2σ 内 %.0f%%  轨迹长度比 %.2f  跳 >3 m %.2f 次/100 m",
                             q(ratios, 0.5), 100 * Double(ratios.filter { $0 <= 1 }.count) / Double(ratios.count),
                             100 * Double(ratios.filter { $0 <= 2 }.count) / Double(ratios.count),
                             refP > 0 ? estP / refP : 0, refP > 0 ? Double(out.reduce(0) { $0 + $1.bigJumps }) / (refP / 10_000) : 0))
            }
        } else { print("【汇总】没有任何定位结果") }
    }
    let all = out.compactMap(\.medianCm)
    if all.count > 1 { print(String(format: "测试会话中位误差的中位：%.0f cm", all.sorted()[all.count / 2])) }
    if let p = odoOut {
        try (odoLines.joined(separator: "\n") + "\n").write(toFile: p, atomically: true, encoding: .utf8)
        print("纯推算轨迹已写到 \(p)（\(odoLines.count - 1) 行）")
    }
    if let p = diagOut {
        try (diagLines.joined(separator: "\n") + "\n").write(toFile: p, atomically: true, encoding: .utf8)
        print("诊断轨迹已写到 \(p)（\(diagLines.count - 1) 行）")
    }
    if let p = trackOut {
        try (trackLines.joined(separator: "\n") + "\n").write(toFile: p, atomically: true, encoding: .utf8)
        print("逐点轨迹已写到 \(p)（\(trackLines.count - 1) 行）")
    }
    if let j = arg("--json") {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(out).write(to: URL(fileURLWithPath: j))
    }
} catch {
    print("出错：\(error)")
    exit(1)
}

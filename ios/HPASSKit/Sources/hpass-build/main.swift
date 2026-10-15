import Foundation
import HPASSKit

// 云端融合建图：把一张地图的所有建图会话（可以是不同手机、不同天、不同分片）融合成一张磁场图 + 蓝牙指纹，
// 打成云端地图包，并出一份报告（各会话偏移、哪些分片没连上、覆盖率、测试会话精度）。
//
//   hpass-build --map map.json --sessions 目录1,目录2,… [--test 测试会话,…] [--esl-ids 价签名单.txt]
//               --id 地图编号 --name 名字 [--kind store|room] [--bearing 316]
//               [--esl-locations 价签位置表.csv（也打进包里）] --out 包.hpmp --report 报告.json [--runs 3]
//               [--worldmap 视觉特征地图文件（房间；打进包里，≤15 MB，>8 MB 报告里警告）]
//               [--live 实时定位记录目录1,目录2,…]  地图自愈：普通定位记录里可信的路段低权重并进磁场图（见 LiveRunLoader / LiveFieldMerger）

func arg(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}
func list(_ s: String?) -> [URL] { (s ?? "").split(separator: ",").map { URL(fileURLWithPath: String($0)) } }

struct Report: Encodable {
    var mapId: String
    var name: String
    var version: Int64
    var sessions: [MultiSessionFusion.SessionInfo]
    var components: Int
    var fieldCells: Int
    var bleTags: Int
    var coverage: Double?
    var coveredM2: Double?
    var walkableM2: Double?
    var unfinishedCorridors: [String]
    var tests: [EvalReport]
    var packageBytes: Int
    var warnings: [String]
    var eslMismatches: [String]
    /// 质量筛选：每个会话用没用、为什么、丢了哪些段
    var quality: [SessionQualityGate.Report]
    /// 价签锚定修正的统计
    var corrections: [String: EslTrajectoryCorrector.Stats]
    /// 采集分区进度 + 下次该采的区域（手机进采集模式按同一套分区自动分配）
    var zones: [SurveyZones.Status]
    var nextZone: Int?
    var nextZoneEntry: [Double]?
    /// 质量合格但和主体连不上、磁场图没用的会话
    var magExcluded: [String]
    /// 地图自愈：实时定位记录并进磁场图的情况（没给 --live 为 nil）
    var live: LiveFieldMerger.Report?
}

guard let mapPath = arg("--map"), let out = arg("--out"), let id = arg("--id") else {
    print("用法：hpass-build --map map.json --sessions 会话1,会话2 --id 地图编号 --name 名字 --out 包.hpmp --report 报告.json")
    exit(2)
}
do {
    let mapData = try Data(contentsOf: URL(fileURLWithPath: mapPath))
    let map = try StoreDataLoader.loadMap(mapData)
    let dirs = list(arg("--sessions"))
    guard !dirs.isEmpty else { print("没有建图会话"); exit(2) }
    var sessions: [SurveySession] = []
    var bleSamples: [[BLESample]] = []
    var signSamples: [[SignSample]] = []
    var headingSamples: [[(tMs: Int64, deg: Double)]] = []
    for d in dirs {
        do {
            sessions.append(try SurveySessionLoader.load(d)); bleSamples.append(SurveySessionLoader.loadBLE(d))
            signSamples.append(SignSample.load(d))
            headingSamples.append(MapBearingEstimator.loadHeadings(d))
        }
        catch { print("⚠️ 跳过 \(d.lastPathComponent)：\(error)") }
    }
    let t0 = Date()
    let fusion = MultiSessionFusion(map: map)
    // 价签位置表：蓝牙底图、轨迹修正的锚点、质量筛选的依据
    var locs: [EslLocation] = []
    var eslText: String?
    if let p = arg("--esl-locations"), let t = try? String(contentsOfFile: p, encoding: .utf8) { eslText = t; locs = EslLocations.parse(t, map: map) }
    var tagPos: [String: Point2] = [:]
    for e in locs { if let p = e.position { tagPos[e.id] = p } }

    // 第 1 遍：各会话原样对齐（起点 + 贴通道）
    let r1 = fusion.fuse(sessions)
    // 货架标签（摄像头读到的「082-20」）：每条换成「人应该在那段货架前」的区域
    let shelfSigns = ShelfSigns(map: map, walkable: SessionEvaluator.walkable(map))
    let signObs: [[EslTrajectoryCorrector.SignObservation]] = signSamples.map { ss in
        ss.compactMap { x in shelfSigns.sign(for: x.text).map { sg in .init(tMs: x.tMs, region: { shelfSigns.nearestValid(sg, to: $0) }) } }
    }
    let signDist: [[(tMs: Int64, distanceTo: (Point2) -> Double)]] = signSamples.map { ss in
        ss.compactMap { x in shelfSigns.sign(for: x.text).map { sg in (x.tMs, { shelfSigns.distance(sg, from: $0) }) } }
    }
    let nSigns = signObs.reduce(0) { $0 + $1.count }
    if nSigns > 0 { print("货架标签：\(nSigns) 次（\(signObs.filter { !$0.isEmpty }.count) 个会话）") }
    // 价签锚定修正：每 5 秒一个结点，把轨迹拉向听到的价签（全店 2 万片 = 2 万个绝对锚点）
    var corrections: [((Int64) -> Point2)?] = Array(repeating: nil, count: sessions.count)
    var corrStats: [String: EslTrajectoryCorrector.Stats] = [:]
    if (!tagPos.isEmpty || nSigns > 0) && !map.crosses.isEmpty {
        let corr = EslTrajectoryCorrector(tagPositions: tagPos)
        for (k, s) in sessions.enumerated() where k < bleSamples.count {
            guard let (fn, st) = corr.solve(track: r1.tracks[k], ble: bleSamples[k], signs: signObs[k]) else { continue }
            corrections[k] = fn
            corrStats[s.name] = st
            print(String(format: "价签 / 标签修正 %@：价签读数 %d、货架标签 %d，人−价签中位 %.1f → %.1f m，最大挪动 %.1f m",
                         s.name, st.readings, st.signs ?? 0, st.beforeMedianM, st.afterMedianM, st.maxShiftM))
        }
    }
    // 第 2 遍：带修正对齐，拿来做质量检查
    let r2 = fusion.fuse(sessions, corrections: corrections)
    // 质量筛选：每 10 秒一段，价签 + 磁场（和别的会话比）两种证据；不合格的段丢掉，整体不可信的会话整个不用
    let gate = SessionQualityGate(tagPositions: tagPos)
    if map.crosses.isEmpty { gate.minPathCm = 500; gate.minGoodSamples = 150 }   // 房间小，走几米就够
    var quality: [SessionQualityGate.Report] = []
    var filters: [((Int64) -> Bool)?] = []
    var keepIdx: [Int] = []
    for (k, s) in sessions.enumerated() {
        let others = MagneticFieldBuilder(widthCm: map.width, heightCm: map.height, cellCm: fusion.cellCm)
        var any = false
        for (j, ss) in r2.samples.enumerated() where j != k { for x in ss { _ = others.add(position: x.p, feature: x.f); any = true } }
        let v = gate.evaluate(name: s.name, track: r2.tracks[k], ble: k < bleSamples.count ? bleSamples[k] : [],
                              mag: r2.samples[k], others: any ? others.snapshot() : nil, othersBuilder: any ? others : nil,
                              signs: signDist[k])
        quality.append(v.report)
        let q = v.report
        let ble = q.bleMedianM.map { String(format: "价签 %.1f m（最差 %.1f）", $0, q.bleWorstM ?? 0) } ?? "价签 -"
        let mag = q.magResidualUT.map { String(format: "磁场残差 %.1f µT（最差 %.1f）", $0, q.magWorstUT ?? 0) } ?? "磁场 -"
        if v.keep != nil {
            filters.append(v.keep); keepIdx.append(k)
            print("✅ \(s.name)：\(ble)，\(mag)，\(q.windows) 段里 \(q.bad) 段不合格" + (q.droppedSpans.isEmpty ? "" : "，丢掉 " + q.droppedSpans.map { "\($0[0])–\($0[1]) 秒" }.joined(separator: "、")))
        } else {
            print("❌ \(s.name)：不用 —— \(q.reason ?? "")（\(ble)，\(mag)）")
        }
    }
    guard !keepIdx.isEmpty else { print("没有合格的会话，不出图"); exit(3) }
    // 第 3 遍：只用合格的会话和合格的段
    let keptSessions = keepIdx.map { sessions[$0] }
    let keptBLE = keepIdx.map { k in k < bleSamples.count ? bleSamples[k].filter { filters[keepIdx.firstIndex(of: k)!]!($0.tMs) } : [] }
    let r = fusion.fuse(keptSessions, filters: filters, corrections: keepIdx.map { corrections[$0] })
    print("融合 \(keptSessions.count) / \(sessions.count) 个会话，\(r.components) 个连通分量，磁场 \(r.field.coveredCells) 格（\(Int(Date().timeIntervalSince(t0))) 秒）")
    for s in r.sessions {
        print(String(format: "  %@：样本 %d，格 %d，偏移 |B| %+.1f Bz %+.1f Bh %+.1f µT，分量 %d，重叠 %@",
                     s.name, s.samples, s.cells, s.offset[0], s.offset[1], s.offset[2], s.component,
                     s.overlaps.isEmpty ? "无" : s.overlaps.map { "\($0.key.suffix(6))×\($0.value)" }.joined(separator: " ")))
        for w in s.warnings { print("    ⚠️ \(w)") }
    }
    // 和主体连不上的会话（重叠不够、整体偏移解不出来）：磁场整体可能差 10～16 µT，放进去会污染磁场图，
    // 所以磁场图只用主体（分量 0）；它们的价签读数照用（价签位置和磁场水平无关）。补采一段重叠后自动加入。
    var magExcluded: [String] = []
    var rm = r
    if r.components > 1 {
        let main = r.sessions.indices.filter { r.sessions[$0].component == 0 }
        magExcluded = r.sessions.indices.filter { r.sessions[$0].component != 0 }.map { r.sessions[$0].name }
        let cs = keepIdx.map { corrections[$0] }
        rm = fusion.fuse(main.map { keptSessions[$0] }, filters: main.map { filters[$0] }, corrections: main.map { cs[$0] })
        print("⚠️ 磁场图不用（和主体没有足够重叠，整体偏移对不齐）：\(magExcluded.joined(separator: "、"))；价签读数照用。补采一段和已采区域重叠的路段后会自动加入")
        print("磁场图：\(main.count) 个会话，磁场 \(rm.field.coveredCells) 格")
    }
    // 地图自愈：实时定位记录里可信的路段，低权重并进磁场图（要和建图数据有重叠才能对齐，对不齐的跳过）
    var liveReport: LiveFieldMerger.Report?
    let liveDirs = list(arg("--live"))
    if !liveDirs.isEmpty {
        let runs = liveDirs.map { LiveRunLoader.load($0, tagPositions: tagPos, shelfSigns: shelfSigns) }
        let merger = LiveFieldMerger()
        let (lb, lr) = merger.merge(survey: rm.builder, runs: runs, gate: gate)
        liveReport = lr
        for i in lr.runs {
            let t = i.trust
            let rej = t.rejectedWindows.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value) 段" }.joined(separator: "、")
            if i.used {
                print(String(format: "✅ 实时 %@：路程 %.0f m，可信 %d / %d 段（佐证 %d 段），样本 %d 个并入", i.name, t.pathM, t.trustedWindows, t.windows, t.verifiedWindows, i.samplesUsed)
                      + (rej.isEmpty ? "" : "；丢段：" + rej))
            } else {
                print("❌ 实时 \(i.name)：不用 —— \(i.reason ?? "")" + (rej.isEmpty ? "" : "（丢段：" + rej + "）"))
            }
        }
        print("地图自愈：\(lr.runsUsed) / \(lr.runsGiven) 个实时记录、\(lr.samplesUsed) 个样本并入；补 \(lr.cellsAdded) 格、更新 \(lr.cellsUpdated) 格"
              + (lr.maxShiftUT.map { String(format: "（均值挪动中位 %.2f、最大 %.2f µT）", lr.medianShiftUT ?? 0, $0) } ?? "") + "、冲突没动 \(lr.cellsConflict) 格")
        if lr.runsUsed > 0 {
            rm.builder = lb
            rm.field = lb.build()
            print("磁场图：并入实时数据后 \(rm.field.coveredCells) 格")
        }
    }
    // 蓝牙指纹
    let bb = BLEFingerprintBuilder(widthCm: map.width, heightCm: map.height)
    if let p = arg("--esl-ids"), let t = try? String(contentsOfFile: p, encoding: .utf8) { bb.whitelist = BLEFingerprintBuilder.parseIdList(t) }
    for (k, track) in r.tracks.enumerated() where k < keptBLE.count { _ = bb.add(samples: keptBLE[k], track: track) }
    let learnedBLE = bb.build()
    print("蓝牙指纹（采集学到）：\(learnedBLE.tags.count) 个价签" + (bb.rejectedMoving.isEmpty ? "" : "（\(bb.rejectedMoving.count) 个移动设备不算）"))
    // 价签位置表：当蓝牙底图（全店都有），学到的只在表明显不对时替换
    var bleMap = learnedBLE
    var eslMismatches: [String] = []
    var eslCSV: Data?
    if let t = eslText {
        eslCSV = Data(t.utf8)
        bleMap = EslLocations.seededBLEMap(locs, learned: learnedBLE)
        eslMismatches = EslLocations.mismatches(locs, learned: learnedBLE).map { "\($0.id) \($0.shelf) 差 \(Int($0.distanceCm / 100)) m" }
        print("价签位置表：\(locs.count) 个，对上货架 \(locs.filter { $0.position != nil }.count) 个；合并后 \(bleMap.tags.count) 个；表里可能不对 \(eslMismatches.count) 个")
    }
    let ble: BLEFingerprintMap? = bleMap.tags.count >= 20 ? bleMap : nil
    // 覆盖率：按所有会话的轨迹涂色
    var coverage: Double?, covered: Double?, walkableM2: Double?
    var unfinished: [String] = []
    let walk = SessionEvaluator.walkable(map)
    let paint: CoveragePaint? = !map.crosses.isEmpty
        ? CoveragePaint(crosses: map.crosses, widthCm: map.width, heightCm: map.height)
        : walk.map { CoveragePaint(walkable: $0) }
    if let p = paint {
        for track in rm.tracks { p.breakStroke(); for tp in track { p.paint(at: tp.p) } }
        coverage = p.fraction; covered = p.paintedAreaM2; walkableM2 = p.walkableAreaM2
        for (i, c) in map.crosses.enumerated() where c.a.distance(to: c.b) > 500 && c.lineWidth >= 50 {
            let f = p.fraction(corridor: i)
            if f > 0 && f < 0.5 { unfinished.append("\(c.code) \(Int(f * 100))%") }
        }
        print(String(format: "覆盖：%.1f%%（%.0f / %.0f m²），没涂完一半的通道 %d 条", (coverage ?? 0) * 100, covered ?? 0, walkableM2 ?? 0, unfinished.count))
    }
    // 采集分区：各区域进度、下次去哪
    var zoneStatus: [SurveyZones.Status] = []
    var nextZone: Int?
    var nextEntry: [Double]?
    if let p = paint, !map.crosses.isEmpty {
        let zs = SurveyZones(crosses: map.crosses, radiusCm: p.radiusCm)
        zoneStatus = zs.status(p)
        nextZone = zs.next(p)
        if let z = zs.zone(nextZone), let e = zs.entry(z, paint: p) { nextEntry = [e.x.rounded(), e.y.rounded()] }
        for st in zoneStatus {
            print(String(format: "  %@：%.0f%%，还剩 %.2f km（约 %d 分钟）%@", st.name, st.fraction * 100, st.remainingCm / 100_000,
                         Int(st.remainingCm / 100 / 0.8 / 60), st.id == nextZone ? " ← 下次采这里" : ""))
        }
    }
    // 测试会话
    var tests: [EvalReport] = []
    let runs = max(Int(arg("--runs") ?? "3") ?? 3, 1)
    for t in list(arg("--test")) {
        for k in 0..<runs {
            if let e = try? SessionEvaluator.evaluate(dir: t, map: map, field: rm.field, ble: ble, walkable: walk, seed: UInt64(k + 1)) {
                tests.append(e)
                if k == 0 { print("测试 " + e.line) }
            }
        }
    }
    // 地图朝向（地图上方的罗盘方位）：从合格会话的轨迹 + 罗盘自动估；冷启动时粒子按它定朝向，不用全方向猜
    var bearing = arg("--bearing").flatMap(Double.init)
    if !map.crosses.isEmpty {
        var ests: [(deg: Double, devDeg: Double, n: Int)] = []
        for (j, k) in keepIdx.enumerated() where j < r.tracks.count && k < headingSamples.count {
            if let e = MapBearingEstimator.estimate(track: r.tracks[j], headings: headingSamples[k]) {
                ests.append(e)
                print(String(format: "  地图朝向 %@：%.0f°（中位偏差 %.0f°，%d 段）", sessions[k].name, e.deg, e.devDeg, e.n))
            }
        }
        if let b = MapBearingEstimator.combine(ests) {
            print(String(format: "地图朝向：%.0f°（之前 %@）", b, bearing.map { String(format: "%.0f°", $0) } ?? "没有"))
            bearing = b
        }
    }
    // 视觉特征地图（房间）：云端脚本已经挑好、确认过坐标系和地图的 arAlign 一致，这里只管大小
    var worldMap: Data?
    var wmWarnings: [String] = []
    if let wp = arg("--worldmap") {
        if let d = try? Data(contentsOf: URL(fileURLWithPath: wp)), !d.isEmpty {
            if let why = WorldMapPolicy.sizeProblem(d.count) {
                wmWarnings.append("视觉特征地图\(why)，没打进包")
            } else {
                worldMap = d
                if d.count > WorldMapPolicy.warnBytes { wmWarnings.append("视觉特征地图 \(d.count / 1024 / 1024) MB，超过 \(WorldMapPolicy.warnBytes / 1024 / 1024) MB，手机下载会偏慢") }
                print("视觉特征地图 \(d.count / 1024) KB 打进包")
            }
        } else {
            wmWarnings.append("视觉特征地图读不出来：\(wp)，没打进包")
        }
    }
    // 打包
    var meta = MapPackage.Meta(id: id, name: arg("--name") ?? id, kind: arg("--kind") ?? (map.crosses.isEmpty ? "room" : "store"),
                               version: Int64((Date().timeIntervalSince1970 * 1000).rounded()),
                               source: "云端融合 \(keptSessions.count - magExcluded.count) 个会话（共 \(sessions.count) 个，质量筛选后）" + ((liveReport?.runsUsed ?? 0) > 0 ? "，并入 \(liveReport!.runsUsed) 个实时定位记录" : ""), mapUpBearingDeg: bearing,
                               magSource: "raw")
    meta.fieldCells = rm.field.coveredCells
    meta.origin = "cloud"
    meta.sessions = keptSessions.count - magExcluded.count
    meta.bleTags = ble?.tags.count
    let pkg = try MapPackage.encode(meta: meta, mapJSON: mapData, field: rm.field, ble: ble, worldMap: worldMap, paint: paint?.serialized(), eslCSV: meta.kind == "store" ? eslCSV : nil,
                                     direction: map.crosses.isEmpty ? nil : try JSONEncoder().encode(DirectionCoverage.build(crosses: map.crosses, tracks: rm.tracks)))
    try pkg.write(to: URL(fileURLWithPath: out))
    print("地图包 \(pkg.count / 1024) KB → \(out)")
    var warnings: [String] = wmWarnings
    if !magExcluded.isEmpty { warnings.append("磁场图没用（和主体重叠不够）：\(magExcluded.joined(separator: "、"))；补采一段重叠后自动加入") }
    if let rp = arg("--report") {
        let rep = Report(mapId: id, name: meta.name, version: meta.version, sessions: rm.sessions, components: r.components,
                         fieldCells: rm.field.coveredCells, bleTags: ble?.tags.count ?? 0, coverage: coverage, coveredM2: covered,
                         walkableM2: walkableM2, unfinishedCorridors: unfinished, tests: tests, packageBytes: pkg.count, warnings: warnings,
                         eslMismatches: eslMismatches, quality: quality, corrections: corrStats,
                         zones: zoneStatus, nextZone: nextZone, nextZoneEntry: nextEntry, magExcluded: magExcluded, live: liveReport)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rep).write(to: URL(fileURLWithPath: rp))
    }
    for w in warnings { print("⚠️ \(w)") }
} catch {
    print("出错：\(error)")
    exit(1)
}

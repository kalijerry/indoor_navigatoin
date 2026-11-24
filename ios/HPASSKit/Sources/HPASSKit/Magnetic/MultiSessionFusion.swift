import Foundation

/// 多会话（分片采集）融合成一张磁场图：云端（GitHub Actions 上的 hpass-build）用。
///
/// 每个会话的位置已经对齐到同一张场地地图（起点 + 贴通道），难点是**磁场整体水平每次不一样**
/// （实测同一处两次差 10～16 µT）。手机上是「新会话对齐到已有数据」，会话一多误差会一路传下去；
/// 这里一次性解：
///
/// 1. 每个会话单独统计每格均值；
/// 2. 两两比：共同格子 ≥ minCommonCells 时，得到一条「oᵢ − oⱼ = 中位差」的方程（权重 = √共同格数）；
/// 3. 按连通分量做加权最小二乘，每个分量里样本最多的会话当基准（偏移 0）；
/// 4. 各会话减去自己的偏移再累积成一张图。
///
/// 和别的会话都没有足够重叠的会话（孤立的分片）没法对齐：照样加进去，但在报告里标出来（要补一段重叠）。
public final class MultiSessionFusion {
    public struct SessionInfo: Codable {
        public var name: String
        public var samples: Int
        public var cells: Int
        /// 减掉的偏移（µT）：|B|、Bz、Bh
        public var offset: [Double]
        /// 所在连通分量（0 = 最大的那个）
        public var component: Int
        /// 和哪些会话有足够重叠（共同格数）
        public var overlaps: [String: Int]
        public var warnings: [String]
    }

    public struct Result {
        public var field: MagneticFieldMap
        public var builder: MagneticFieldBuilder
        public var sessions: [SessionInfo]
        public var components: Int
        public var tracks: [[(tMs: Int64, p: Point2)]]
        /// 每个会话的样本（时间、位置、减掉偏移后的磁场），质量筛选用
        public var samples: [[(tMs: Int64, p: Point2, f: MagneticFeature)]]
        /// 每个会话的建图说明（对齐、丢样本原因、累积进图的样本数、减掉的偏移、警告），和单会话 SurveyMapBuilder.add 的报告同一种
        public var reports: [SurveySessionReport] = []
    }

    public let map: StoreMap
    public var minCommonCells = 20
    /// 放宽条件下的最少共同格子（只在两个会话本来连不上时用）
    public var weakMinCommonCells = 4
    public var weakMaxMadUT = 4.0
    public var cellCm = 50.0

    public init(map: StoreMap) { self.map = map }

    /// - filters: 每个会话只用哪些时刻的样本（质量筛选的结果；nil = 都用）
    /// - corrections: 每个会话的标签锚定轨迹修正（TagTrajectoryCorrector；nil = 不修正）
    /// - rigid: 每个会话的多遍互相对齐修正（SessionRegistration；nil = 不修正），对齐好之后整体套上
    public func fuse(_ sessions: [SurveySession], filters: [((Int64) -> Bool)?]? = nil,
                     corrections: [((Int64) -> Point2)?]? = nil,
                     rigid: [SessionRegistration.Rigid?]? = nil,
                     edits: [SurveySegments.SessionEdits?]? = nil) -> Result {
        // 1. 每个会话：对齐、算样本、单独统计
        var prepared: [(rep: SurveySessionReport, samples: [(Point2, MagneticFeature)], snap: MagneticFieldBuilder.Snapshot)] = []
        for (si, s) in sessions.enumerated() {
            let b = SurveyMapBuilder(widthCm: map.width, heightCm: map.height, crosses: map.crosses, cellCm: cellCm)
            if let fs = filters, si < fs.count { b.sampleFilter = fs[si] }
            if let cs = corrections, si < cs.count { b.correction = cs[si] }
            // 手动分段修改（看板上拖过 / 删过的段）：删掉的段不用；摆过的段按手动位置，不再套自动对齐
            let ed: SurveySegments.SessionEdits? = edits.flatMap { si < $0.count ? $0[si] : nil }
            if let ed {
                let prev = b.sampleFilter
                b.sampleFilter = { t in !ed.deleted(t) && (prev?(t) ?? true) }
            }
            var (rep, samples) = b.prepare(s)
            let r: SessionRegistration.Rigid? = rigid.flatMap { si < $0.count ? $0[si] : nil }.flatMap { $0.isIdentity ? nil : $0 }
            if r != nil || ed != nil {
                func place(_ p: Point2, _ t: Int64) -> Point2 { ed?.pinned(t)?.apply(p) ?? r?.apply(p) ?? p }
                samples = zip(rep.sampleTimes, samples).map { (place($1.0, $0), $1.1) }
                rep.track = rep.track.filter { !(ed?.deleted($0.tMs) ?? false) }.map { ($0.tMs, place($0.p, $0.tMs)) }
            }
            let own = MagneticFieldBuilder(widthCm: map.width, heightCm: map.height, cellCm: cellCm)
            for (p, f) in samples { _ = own.add(position: p, feature: f) }
            prepared.append((rep, samples, own.snapshot()))
        }
        let n = prepared.count
        // 2. 两两的偏移差
        func pair(_ i: Int, _ j: Int, minCount: Int) -> (d: [Double], common: Int, mad: Double)? {
            let a = prepared[i].snap, b = prepared[j].snap
            var diffs: [[Double]] = [[], [], []]
            for k in a.counts.indices where a.counts[k] >= minCount && b.counts[k] >= minCount {
                for c in 0..<3 { diffs[c].append(a.means[k * 3 + c] - b.means[k * 3 + c]) }
            }
            guard !diffs[0].isEmpty else { return nil }
            // 偶数个取中间两个的平均：pair(i, j) = −pair(j, i)，结果才和会话顺序无关
            func median(_ x: [Double]) -> Double {
                let s = x.sorted(), h = s.count / 2
                return s.count % 2 == 1 ? s[h] : (s[h - 1] + s[h]) / 2
            }
            let med = diffs.map(median)
            return (med, diffs[0].count, median(diffs[0].map { abs($0 - med[0]) }))
        }
        var edges: [(i: Int, j: Int, d: [Double], w: Double, common: Int)] = []
        for i in 0..<n {
            for j in (i + 1)..<max(n, i + 1) where j < n {
                guard let p = pair(i, j, minCount: 5), p.common >= minCommonCells else { continue }
                edges.append((i, j, p.d, Double(p.common).squareRoot(), p.common))
            }
        }
        // 重叠不够的：放宽（每格 ≥ 2 个样本、≥ weakMinCommonCells 格）也连上，权重低。
        // 不对齐的话两个会话整体差 10～16 µT，比粗一点的偏移估计差得多。
        // 只看正常边连不连通（不看已经加的放宽边），哪些放宽边加进来就和会话顺序无关
        var strongRoot = Array(0..<n)
        func root(_ x: Int) -> Int { var x = x; while strongRoot[x] != x { x = strongRoot[x] }; return x }
        for e in edges { let a = root(e.i), b = root(e.j); if a != b { strongRoot[max(a, b)] = min(a, b) } }
        for i in 0..<n {
            for j in (i + 1)..<max(n, i + 1) where j < n && root(i) != root(j) {
                // 格子少时要求各格的差很一致（中位绝对偏差 ≤ weakMaxMadUT），不一致说明位置没真对上
                guard let p = pair(i, j, minCount: 2), p.common >= weakMinCommonCells, p.mad <= weakMaxMadUT else { continue }
                edges.append((i, j, p.d, Double(p.common).squareRoot() * 0.5, p.common))
            }
        }
        // 3. 连通分量
        var comp = [Int](repeating: -1, count: n)
        var comps: [[Int]] = []
        for s in 0..<n where comp[s] < 0 {
            var stack = [s], members: [Int] = []
            comp[s] = comps.count
            while let x = stack.popLast() {
                members.append(x)
                for e in edges where e.i == x || e.j == x {
                    let y = e.i == x ? e.j : e.i
                    if comp[y] < 0 { comp[y] = comps.count; stack.append(y) }
                }
            }
            comps.append(members)
        }
        // 按样本数排分量：最大的当 0 号
        let order = comps.indices.sorted { comps[$0].reduce(0) { $0 + prepared[$1].samples.count } > comps[$1].reduce(0) { $0 + prepared[$1].samples.count } }
        var remap = [Int](repeating: 0, count: comps.count)
        for (newIdx, old) in order.enumerated() { remap[old] = newIdx }
        // 每个分量做加权最小二乘（基准 = 样本最多的会话，偏移固定 0）
        var offsets = [[Double]](repeating: [0, 0, 0], count: n)
        for members in comps where members.count > 1 {
            let ref = members.max { prepared[$0].samples.count < prepared[$1].samples.count }!
            let unknown = members.filter { $0 != ref }
            let idx = Dictionary(uniqueKeysWithValues: unknown.enumerated().map { ($1, $0) })
            let m = unknown.count
            for c in 0..<3 {
                var A = [Double](repeating: 0, count: m * m), rhs = [Double](repeating: 0, count: m)
                for e in edges where members.contains(e.i) {
                    // oᵢ − oⱼ = d
                    let w = e.w
                    let ii = idx[e.i], jj = idx[e.j]
                    if let ii { A[ii * m + ii] += w; rhs[ii] += w * e.d[c] }
                    if let jj { A[jj * m + jj] += w; rhs[jj] -= w * e.d[c] }
                    if let ii, let jj { A[ii * m + jj] -= w; A[jj * m + ii] -= w }
                }
                for k in 0..<m { A[k * m + k] += 1e-6 }          // 数值稳定
                guard let L = MagneticFieldBuilder.cholesky(A, m) else { continue }
                let x = MagneticFieldBuilder.cholSolve(L, m, rhs)
                for (s, k) in idx { offsets[s][c] = x[k] }
            }
        }
        // 4. 减偏移累积
        let builder = MagneticFieldBuilder(widthCm: map.width, heightCm: map.height, cellCm: cellCm)
        var infos: [SessionInfo] = []
        var reports: [SurveySessionReport] = []
        for (s, p) in prepared.enumerated() {
            let o = MagneticFeature(total: offsets[s][0], vertical: offsets[s][1], horizontal: offsets[s][2])
            var used = 0
            for (pt, f) in p.samples where builder.add(position: pt, feature: f - o) { used += 1 }
            var ov: [String: Int] = [:]
            for e in edges where e.i == s || e.j == s { ov[prepared[e.i == s ? e.j : e.i].rep.name] = e.common }
            var w = p.rep.warnings
            if p.samples.isEmpty { w.append("没有可用样本（检查起点和朝向）") }
            else if ov.isEmpty && n > 1 { w.append("和别的会话都没有足够重叠（< \(minCommonCells) 个共同格子），整体偏移没法对齐：补采一段和相邻分片重叠的通道") }
            var rp = p.rep
            rp.samplesUsed = used
            rp.offsetUT = comps[comp[s]].count > 1 ? o : nil
            rp.warnings = w
            reports.append(rp)
            infos.append(SessionInfo(name: p.rep.name, samples: p.samples.count,
                                     cells: p.snap.counts.filter { $0 >= 5 }.count,
                                     offset: offsets[s].map { ($0 * 100).rounded() / 100 },
                                     component: remap[comp[s]], overlaps: ov, warnings: w))
        }
        return Result(field: builder.build(), builder: builder, sessions: infos, components: comps.count,
                      tracks: prepared.map(\.rep.track),
                      samples: prepared.enumerated().map { s, p in
                          let o = MagneticFeature(total: offsets[s][0], vertical: offsets[s][1], horizontal: offsets[s][2])
                          return zip(p.rep.sampleTimes, p.samples).map { ($0, $1.0, $1.1 - o) }
                      },
                      reports: reports)
    }
}

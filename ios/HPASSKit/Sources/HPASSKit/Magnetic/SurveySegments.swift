import Foundation

/// 建图路线「分段」：每遍采集按拐弯 / 长度切成几段，每段可以在看板上手动拖动、旋转、删除，
/// 每段按「和别的路线在重叠处的磁场对不对得上」着色（灰 = 没和别的路线重叠、没法验证；绿 = 对得上；黄 = 有点对不上；红 = 对不上）。
///
/// 原理（商用地磁建图工具的路线着色是同一个思路，见 docs/survey-route-consistency.md）：
/// 磁场是位置的函数，同一处走两遍读数应该一样（减掉手机整体偏置后）。单独一条路线没有东西可比 → 灰；
/// 第二条路线走过同一处时就能比：对得上 → 两条都绿；对不上 → 至少有一条位置画错了（起点点偏、朝向偏、ARKit 漂了），
/// 这时两条都变黄 / 红；第三条路线来了，和多数一致的回到绿，错的那条留红 —— 这就是「走第二条有关联的路线时出现黄 / 红」。
public enum SurveySegments {

    // MARK: 分段

    /// 切段参数
    public struct SplitConfig {
        /// 拐弯判定：前后各这么长的弦（cm）的方向差超过 turnDeg 算一个拐弯
        public var chordCm = 150.0
        public var turnDeg = 55.0
        /// 每段至少这么长（cm），更短的并到前一段
        public var minCm = 300.0
        /// 每段最长（cm）：长直路也切开，ARKit 沿长走廊的累积漂移可以一段一段修
        public var maxCm = 2000.0
        /// 轨迹断开（时间间隔 ms）就切
        public var gapMs: Int64 = 3000
        public init() {}
    }

    /// 一段的时间范围（含两端；相邻段首尾相接，样本按 t0 ≤ t < 下一段 t0 归属）
    public struct Span: Codable, Equatable {
        public var t0Ms: Int64
        public var t1Ms: Int64
        public var lengthCm: Double
        public init(t0Ms: Int64, t1Ms: Int64, lengthCm: Double) { self.t0Ms = t0Ms; self.t1Ms = t1Ms; self.lengthCm = lengthCm }
    }

    /// 把一遍的轨迹（时间有序，约 10 Hz）切成段。确定性：同一条轨迹总是切出同样的段。
    public static func split(_ track: [(tMs: Int64, p: Point2)], config: SplitConfig = SplitConfig()) -> [Span] {
        guard let first = track.first, let last = track.last else { return [] }
        // 1. 按路程每 25 cm 取一个点（站着不动的点不算）
        var pts: [(t: Int64, p: Point2, s: Double)] = [(first.tMs, first.p, 0)]
        var gaps: [Int64] = []          // 断开处：后一点的时间
        for i in track.indices.dropFirst() {
            let a = track[i - 1], b = track[i]
            if b.tMs - a.tMs > config.gapMs || a.p.distance(to: b.p) > 300 { gaps.append(b.tMs); pts.append((b.tMs, b.p, pts.last!.s)); continue }
            let d = pts.last!.p.distance(to: b.p)
            if d >= 25 { pts.append((b.tMs, b.p, pts.last!.s + d)) }
        }
        let total = pts.last!.s
        // 2. 拐弯：在每个点看前后 chordCm 的弦方向差
        func index(atS s: Double) -> Int {
            var lo = 0, hi = pts.count - 1
            while lo < hi { let m = (lo + hi) / 2; if pts[m].s < s { lo = m + 1 } else { hi = m } }
            return lo
        }
        var turn = [Double](repeating: 0, count: pts.count)
        for i in pts.indices {
            let s = pts[i].s
            guard s - config.chordCm >= 0, s + config.chordCm <= total else { continue }
            let a = pts[index(atS: s - config.chordCm)].p, b = pts[i].p, c = pts[index(atS: s + config.chordCm)].p
            let h1 = atan2(b.y - a.y, b.x - a.x), h2 = atan2(c.y - b.y, c.x - b.x)
            var d = abs(h2 - h1) * 180 / .pi
            if d > 180 { d = 360 - d }
            turn[i] = d
        }
        // 拐弯处取局部最大
        var cuts: [(t: Int64, s: Double)] = []
        var i = 0
        while i < pts.count {
            guard turn[i] >= config.turnDeg else { i += 1; continue }
            var j = i, best = i
            while j + 1 < pts.count && turn[j + 1] >= config.turnDeg { j += 1; if turn[j] > turn[best] { best = j } }
            cuts.append((pts[best].t, pts[best].s))
            i = j + 1
        }
        for g in gaps { if let k = pts.firstIndex(where: { $0.t >= g }) { cuts.append((pts[k].t, pts[k].s)) } }
        cuts.sort { $0.s < $1.s }
        // 3. 太近的切点去掉（离上一个切点 / 起点 < minCm），离终点太近的也去掉
        var kept: [(t: Int64, s: Double)] = []
        for c in cuts where c.s - (kept.last?.s ?? 0) >= config.minCm && total - c.s >= config.minCm { kept.append(c) }
        // 4. 太长的段平均切开
        var bounds: [(t: Int64, s: Double)] = [(first.tMs, 0)] + kept + [(last.tMs, total)]
        var out: [(t: Int64, s: Double)] = [bounds[0]]
        for k in 1..<bounds.count {
            let a = bounds[k - 1], b = bounds[k]
            let n = Int(((b.s - a.s) / config.maxCm).rounded(.up))
            if n > 1 {
                for m in 1..<n {
                    let s = a.s + (b.s - a.s) * Double(m) / Double(n)
                    out.append((pts[index(atS: s)].t, s))
                }
            }
            out.append(b)
        }
        bounds = out
        var spans: [Span] = []
        for k in 1..<bounds.count where bounds[k].t > bounds[k - 1].t {
            spans.append(Span(t0Ms: bounds[k - 1].t, t1Ms: bounds[k].t, lengthCm: bounds[k].s - bounds[k - 1].s))
        }
        if spans.isEmpty { spans = [Span(t0Ms: first.tMs, t1Ms: last.tMs, lengthCm: total)] }
        return spans
    }

    // MARK: 手动修改

    /// 一段的刚体修改：p' = pivot + R(rot)(p − pivot) + shift，作用在「没做多遍对齐之前」的位置上
    /// （手动摆好的段固定不动，自动对齐不再挪它）
    public struct Edit: Codable, Equatable {
        public var session: String
        public var t0Ms: Int64
        public var t1Ms: Int64
        public var dx: Double = 0
        public var dy: Double = 0
        public var rotDeg: Double = 0
        public var pivotX: Double = 0
        public var pivotY: Double = 0
        /// 删掉：这段的磁场不进图
        public var deleted: Bool? = nil
        public var updatedMs: Int64? = nil

        public init(session: String, t0Ms: Int64, t1Ms: Int64, dx: Double = 0, dy: Double = 0, rotDeg: Double = 0,
                    pivotX: Double = 0, pivotY: Double = 0, deleted: Bool? = nil) {
            self.session = session; self.t0Ms = t0Ms; self.t1Ms = t1Ms; self.dx = dx; self.dy = dy; self.rotDeg = rotDeg
            self.pivotX = pivotX; self.pivotY = pivotY; self.deleted = deleted
        }

        enum CodingKeys: String, CodingKey { case session, t0Ms, t1Ms, dx, dy, rotDeg, pivotX, pivotY, deleted, updatedMs }
        /// 看板存的可能缺键（没转过就没有 rotDeg 等），缺的当 0
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            session = try c.decode(String.self, forKey: .session)
            t0Ms = try c.decode(Int64.self, forKey: .t0Ms)
            t1Ms = try c.decode(Int64.self, forKey: .t1Ms)
            dx = try c.decodeIfPresent(Double.self, forKey: .dx) ?? 0
            dy = try c.decodeIfPresent(Double.self, forKey: .dy) ?? 0
            rotDeg = try c.decodeIfPresent(Double.self, forKey: .rotDeg) ?? 0
            pivotX = try c.decodeIfPresent(Double.self, forKey: .pivotX) ?? 0
            pivotY = try c.decodeIfPresent(Double.self, forKey: .pivotY) ?? 0
            deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted)
            updatedMs = try c.decodeIfPresent(Int64.self, forKey: .updatedMs)
        }

        public var isDeleted: Bool { deleted == true }
        public func contains(_ t: Int64) -> Bool { t >= t0Ms && t <= t1Ms }

        public func apply(_ p: Point2) -> Point2 {
            let th = rotDeg * .pi / 180, c = cos(th), s = sin(th)
            let x = p.x - pivotX, y = p.y - pivotY
            return Point2(pivotX + x * c - y * s + dx, pivotY + x * s + y * c + dy)
        }

        public func inverse(_ p: Point2) -> Point2 {
            let th = -rotDeg * .pi / 180, c = cos(th), s = sin(th)
            let x = p.x - dx - pivotX, y = p.y - dy - pivotY
            return Point2(pivotX + x * c - y * s, pivotY + x * s + y * c)
        }
    }

    /// 后台存的一张地图的全部手动修改（/api/config/segments/<地图>）
    public struct EditSet: Codable {
        public var version: Int = 1
        public var mapId: String?
        public var edits: [Edit] = []
        public init(mapId: String? = nil, edits: [Edit] = []) { self.mapId = mapId; self.edits = edits }
        enum CodingKeys: String, CodingKey { case version, mapId, edits }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            mapId = try c.decodeIfPresent(String.self, forKey: .mapId)
            edits = try c.decodeIfPresent([Edit].self, forKey: .edits) ?? []
        }

        public static func load(_ data: Data) throws -> EditSet { try JSONDecoder().decode(EditSet.self, from: data) }

        /// 这一遍的修改（没有返回 nil）
        public func session(_ name: String) -> SessionEdits? {
            let e = edits.filter { $0.session == name }
            return e.isEmpty ? nil : SessionEdits(edits: e)
        }
    }

    /// 一遍的修改：按时间查
    public struct SessionEdits {
        public var edits: [Edit]
        public init(edits: [Edit]) { self.edits = edits }
        /// 这个时刻落在被删掉的段里
        public func deleted(_ t: Int64) -> Bool { edits.contains { $0.isDeleted && $0.contains(t) } }
        /// 这个时刻落在手动摆过的段里：那段的修改（删掉的段不算）
        public func pinned(_ t: Int64) -> Edit? { edits.first { !$0.isDeleted && $0.contains(t) } }
        public var hasPinned: Bool { edits.contains { !$0.isDeleted } }
    }

    // MARK: 一致性（着色）

    public enum Grade: String, Codable { case gray, green, yellow, red }

    public struct ConsistencyConfig {
        /// 比较格（cm）
        public var cellCm = 50.0
        /// 参考值（别的段）在这格（3×3 加权）至少这么多样本才算重叠
        public var minRefWeight = 2.0
        /// 重叠至少这么长（m）才评，否则灰
        public var minOverlapM = 3.0
        /// 残差（µT，|B| 和 Bz 平均的中位绝对差）：≤ green 绿，≤ yellow 黄，再大红
        public var greenUT = 2.0
        public var yellowUT = 3.5
        /// 建议挪动：在 ±searchCm 里找残差最小的位置，比现在小 improve 倍以上、挪动 ≥ minSuggestCm 才建议
        public var searchCm = 150.0
        public var searchStepCm = 25.0
        public var improve = 0.7
        public var minSuggestCm = 50.0
        /// 比之前再减掉这段自己残留的整体偏移（中位）。办公室实测：不减的话同一遍里偏置慢慢变（2～3 µT）
        /// 就让 26 段里 21 段变黄 / 红；减了以后正常的段 17 绿、6 黄、1 红（红的那遍质量筛选也判了不合格）
        public var removeSegmentOffset = true
        /// 两段离真值点的路程差至少这么多（m）才判谁更可能错
        public var tieBreakM = 5.0
        public init() {}
    }

    /// 参与比较的一段：样本（最终位置、减掉会话偏移后的 |B|、Bz），每隔约 25 cm 一个
    public struct Piece {
        public var id: String
        public var session: String
        public var samples: [(p: Point2, t: Double, v: Double)]
        public var deleted: Bool
        /// 这段中点离这遍最近一个真值点（起点 / 途中长按修正）走了多远（m）：越远 ARKit 累积漂移越大，越可能画偏
        public var driftM: Double?
        public init(id: String, session: String, samples: [(p: Point2, t: Double, v: Double)], deleted: Bool, driftM: Double? = nil) {
            self.id = id; self.session = session; self.samples = samples; self.deleted = deleted; self.driftM = driftM
        }
    }

    public struct Verdict: Codable, Equatable {
        public var grade: Grade
        /// 和别的段重叠的长度（m）
        public var overlapM: Double
        /// 重叠处的磁场残差（µT）；没重叠 nil
        public var residualUT: Double?
        /// 对不上最厉害的几段（段 id → 残差 µT），只列重叠够的
        public var conflicts: [String: Double]
        /// 建议挪动（cm）和挪过去后的残差；没有建议 nil
        public var suggestDx: Double?
        public var suggestDy: Double?
        public var suggestResidualUT: Double?
        /// 和对不上的段相比谁更可能错（按离真值点的路程，差 ≥ tieBreakM 才判）：true = 这段更可能错，
        /// false = 对方更可能错，nil = 分不出 / 没有对不上的。只是参考，颜色仍按多数一致
        public var likelyWrong: Bool? = nil
        public var driftM: Double? = nil
    }

    /// 每段的评定（和输入一一对应；删掉的段也评，方便看删得对不对，但它不当别人的参考）
    /// - walkable: 可走区域（有的话建议挪动不能把段挪出去：比现在多出去 10% 以上的位置不建议）
    public static func consistency(_ pieces: [Piece], config: ConsistencyConfig = ConsistencyConfig(),
                                   walkable: ((Point2) -> Bool)? = nil) -> [Verdict] {
        let c = config.cellCm
        var maxX = 0.0, maxY = 0.0
        for pc in pieces { for s in pc.samples { maxX = max(maxX, s.p.x); maxY = max(maxY, s.p.y) } }
        let pad = config.searchCm + c * 2
        let nx = Int((maxX + pad) / c) + 3, ny = Int((maxY + pad) / c) + 3
        // 每段各自的格统计（n, Σ|B|, ΣBz）
        func cells(_ pc: Piece) -> [Int: (n: Double, t: Double, v: Double)] {
            var m: [Int: (n: Double, t: Double, v: Double)] = [:]
            for s in pc.samples {
                let i = Int(floor(s.p.x / c)), j = Int(floor(s.p.y / c))
                guard i >= 0, j >= 0, i < nx, j < ny else { continue }
                let k = j * nx + i
                var e = m[k] ?? (0, 0, 0)
                e.n += 1; e.t += s.t; e.v += s.v
                m[k] = e
            }
            return m
        }
        let own = pieces.map(cells)
        // 全部（没删的）段加起来
        var all = [Int: (n: Double, t: Double, v: Double)]()
        for (k, pc) in pieces.enumerated() where !pc.deleted {
            for (cell, e) in own[k] { var a = all[cell] ?? (0, 0, 0); a.n += e.n; a.t += e.t; a.v += e.v; all[cell] = a }
        }
        let wts: [(di: Int, dj: Int, w: Double)] = [(0, 0, 1), (1, 0, 0.5), (-1, 0, 0.5), (0, 1, 0.5), (0, -1, 0.5),
                                                    (1, 1, 0.25), (1, -1, 0.25), (-1, 1, 0.25), (-1, -1, 0.25)]
        /// 参考（别的段）在 p 处的值：3×3 加权
        func refAt(_ p: Point2, excluding k: Int?, only: Int? = nil) -> (t: Double, v: Double)? {
            let i = Int(floor(p.x / c)), j = Int(floor(p.y / c))
            var n = 0.0, t = 0.0, v = 0.0
            for d in wts {
                let ii = i + d.di, jj = j + d.dj
                guard ii >= 0, jj >= 0, ii < nx, jj < ny else { continue }
                let cell = jj * nx + ii
                var e: (n: Double, t: Double, v: Double)
                if let o = only { e = own[o][cell] ?? (0, 0, 0) }
                else {
                    e = all[cell] ?? (0, 0, 0)
                    if let k, !pieces[k].deleted, let m = own[k][cell] { e.n -= m.n; e.t -= m.t; e.v -= m.v }
                }
                guard e.n > 0.5 else { continue }
                n += d.w * e.n; t += d.w * e.t; v += d.w * e.v
            }
            guard n >= config.minRefWeight else { return nil }
            return (t / n, v / n)
        }
        func median(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        /// 段 k 挪 (dx, dy) 后和参考的残差、重叠样本数
        func residual(_ k: Int, dx: Double, dy: Double, only: Int? = nil) -> (r: Double, n: Int)? {
            var dt: [Double] = [], dv: [Double] = []
            for s in pieces[k].samples {
                guard let q = refAt(Point2(s.p.x + dx, s.p.y + dy), excluding: k, only: only) else { continue }
                dt.append(s.t - q.t); dv.append(s.v - q.v)
            }
            guard !dt.isEmpty else { return nil }
            // 会话之间的整体偏移已经在融合里减掉了，这里只再减残留的一点（中位），比形状
            let mt = config.removeSegmentOffset ? median(dt) : 0, mv = config.removeSegmentOffset ? median(dv) : 0
            let e = dt.indices.map { (abs(dt[$0] - mt) + abs(dv[$0] - mv)) / 2 }
            return (median(e), dt.count)
        }
        let step = 0.25   // 样本间隔约 25 cm
        return pieces.indices.map { k in
            guard let r0 = residual(k, dx: 0, dy: 0), Double(r0.n) * step >= config.minOverlapM else {
                let n = residual(k, dx: 0, dy: 0)?.n ?? 0
                return Verdict(grade: .gray, overlapM: (Double(n) * step * 10).rounded() / 10, residualUT: nil, conflicts: [:],
                               suggestDx: nil, suggestDy: nil, suggestResidualUT: nil, driftM: pieces[k].driftM.map { ($0 * 10).rounded() / 10 })
            }
            // 和每一段单独比（重叠够的）。评定用「至少和一半（按重叠长度算）对得上」：
            // 按残差从小到大，取累计重叠到一半的那个（加权下中位）。所以两条对不上时两条都红；
            // 第三条和其中一条一致时，那两条回到绿，错的那条还是红（和所有人比的平均会被错的那条拖成黄）
            var pair: [(id: String, r: Double, n: Int)] = []
            for j in pieces.indices where j != k && !pieces[j].deleted {
                guard let r = residual(k, dx: 0, dy: 0, only: j), Double(r.n) * step >= config.minOverlapM else { continue }
                pair.append((pieces[j].id, r.r, r.n))
            }
            var score = r0.r
            if !pair.isEmpty {
                let sorted = pair.sorted { $0.r < $1.r }
                let half = Double(sorted.reduce(0) { $0 + $1.n }) / 2
                var acc = 0.0
                for x in sorted { acc += Double(x.n); if acc >= half { score = x.r; break } }
            }
            let grade: Grade = score <= config.greenUT ? .green : score <= config.yellowUT ? .yellow : .red
            var conf: [String: Double] = [:]
            for x in pair.filter({ $0.r > config.greenUT }).sorted(by: { $0.r > $1.r }).prefix(5) { conf[x.id] = (x.r * 10).rounded() / 10 }
            // 建议挪动（只在不是绿的时候找）
            var sug: (dx: Double, dy: Double, r: Double)?
            if grade != .green {
                let ns = Int((config.searchCm / config.searchStepCm).rounded())
                var best = (dx: 0.0, dy: 0.0, r: r0.r)
                func inside(_ dx: Double, _ dy: Double) -> Double {
                    guard let w = walkable, !pieces[k].samples.isEmpty else { return 1 }
                    return Double(pieces[k].samples.filter { w(Point2($0.p.x + dx, $0.p.y + dy)) }.count) / Double(pieces[k].samples.count)
                }
                let in0 = inside(0, 0)
                for ix in -ns...ns {
                    for iy in -ns...ns where ix != 0 || iy != 0 {
                        let dx = Double(ix) * config.searchStepCm, dy = Double(iy) * config.searchStepCm
                        // 挪过去重叠要和现在差不多（不能靠挪到没人走过的地方「躲开」比较）
                        guard let r = residual(k, dx: dx, dy: dy), Double(r.n) >= Double(r0.n) * 0.7, inside(dx, dy) >= in0 - 0.1 else { continue }
                        // 小一点的先验：同样好时选挪得少的
                        let sc = r.r + 0.002 * (dx * dx + dy * dy).squareRoot()
                        if sc < best.r + 0.002 * (best.dx * best.dx + best.dy * best.dy).squareRoot() { best = (dx, dy, r.r) }
                    }
                }
                if best.r <= r0.r * config.improve && best.r <= config.greenUT * 1.5 && (best.dx * best.dx + best.dy * best.dy).squareRoot() >= config.minSuggestCm { sug = best }
            }
            // 谁更可能错：和对不上的各段比离真值点的路程，按重叠加权投票
            var likely: Bool?
            if grade != .green, let dk = pieces[k].driftM {
                var me = 0.0, them = 0.0
                for x in pair where x.r > config.greenUT {
                    guard let j = pieces.firstIndex(where: { $0.id == x.id }), let dj = pieces[j].driftM else { continue }
                    if dk - dj >= config.tieBreakM { me += Double(x.n) } else if dj - dk >= config.tieBreakM { them += Double(x.n) }
                }
                if me > them { likely = true } else if them > me { likely = false }
            }
            return Verdict(grade: grade, overlapM: (Double(r0.n) * step * 10).rounded() / 10, residualUT: (score * 100).rounded() / 100,
                           conflicts: conf, suggestDx: sug?.dx, suggestDy: sug?.dy, suggestResidualUT: sug.map { ($0.r * 100).rounded() / 100 },
                           likelyWrong: likely, driftM: pieces[k].driftM.map { ($0 * 10).rounded() / 10 })
        }
    }

    /// 按路程每隔 stepCm 抽一个样本
    public static func thin<T>(_ xs: [T], position: (T) -> Point2, stepCm: Double = 25) -> [T] {
        var out: [T] = []
        var last: Point2?
        for x in xs {
            let p = position(x)
            if let l = last, l.distance(to: p) < stepCm { continue }
            out.append(x); last = p
        }
        return out
    }
}

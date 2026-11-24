import Foundation

/// 每段自动对齐（多遍整体对齐 SessionRegistration 之后再细调一层）：每遍按拐弯 / 长度切成段（SurveySegments.split），
/// 每段估一个小的刚体修正（平移 ±1 m、绕段中心转 ±4°），让各段的磁场和别的路线在重叠处对得上，
/// 同时相邻两段首尾要接得上（这一项相当于位姿图里的里程计边，ARKit 段内形状可信、段与段之间允许慢慢漂），
/// 不走出可走区域，修正量越小越好（先验）。
///
/// 为什么：整遍一个刚体修不了「走到后半段 ARKit 慢慢漂了」，长走廊尽头横向偏 0.5～1 m 很常见。
/// 和别的路线没有重叠的段只靠相邻段 + 可走区域 + 先验，跟着邻居走。
/// 手动摆过的段（看板）固定不动，只当参考；删掉的段不参与。
public struct SegmentRefinement {
    public struct Config {
        public var maxShiftCm = 100.0
        public var shiftStepCm = 25.0
        public var maxRotDeg = 4.0
        public var rotStepDeg = 1.0
        public var cellCm = 50.0
        public var minRefWeight = 2.0
        /// 至少这么多重叠样本（约 25 cm 一个）才用磁场
        public var minOverlap = 12
        public var capUT = 8.0
        /// 相邻两段首尾断开的代价：(断开距离 / jointCm)²，乘 jointWeight（µT）
        public var jointCm = 25.0
        public var jointWeight = 0.3
        /// 走出可走区域的比例的权重（µT / 100%）
        public var outsideWeight = 10.0
        /// 先验：(平移 / priorShiftCm)² + (转角 / priorRotDeg)²，乘 priorWeight
        public var priorShiftCm = 60.0
        public var priorRotDeg = 2.5
        public var priorWeight = 0.4
        public var rounds = 4
        public var step = 0.5
        public init() {}
    }

    /// 一段：样本（现在的位置、减掉会话偏移的 |B|、Bz）和它在哪一遍、第几段
    public struct Piece {
        public var session: Int
        public var t0Ms: Int64
        public var t1Ms: Int64
        public var samples: [(p: Point2, t: Double, v: Double)]
        /// 固定不动（手动摆过）
        public var fixed: Bool
        public init(session: Int, t0Ms: Int64, t1Ms: Int64, samples: [(p: Point2, t: Double, v: Double)], fixed: Bool) {
            self.session = session; self.t0Ms = t0Ms; self.t1Ms = t1Ms; self.samples = samples; self.fixed = fixed
        }
    }

    /// 段的修正：p' = c + R(rot)(p − c) + (dx, dy)，c = 段中心
    public struct Move: Equatable {
        public var dx = 0.0, dy = 0.0, rotDeg = 0.0
        public var cx = 0.0, cy = 0.0
        public func apply(_ p: Point2) -> Point2 {
            let th = rotDeg * .pi / 180, c = cos(th), s = sin(th)
            let x = p.x - cx, y = p.y - cy
            return Point2(cx + x * c - y * s + dx, cy + x * s + y * c + dy)
        }
        public var isIdentity: Bool { dx == 0 && dy == 0 && rotDeg == 0 }
    }

    public var config: Config
    public let walkable: WalkableMap?
    public init(walkable: WalkableMap?, config: Config = Config()) { self.walkable = walkable; self.config = config }

    /// 每段一个修正（和输入一一对应；固定的、没样本的给恒等）
    public func solve(_ pieces: [Piece]) -> [Move] {
        let n = pieces.count
        var moves = pieces.map { pc -> Move in
            var m = Move()
            if !pc.samples.isEmpty {
                m.cx = pc.samples.map(\.p.x).reduce(0, +) / Double(pc.samples.count)
                m.cy = pc.samples.map(\.p.y).reduce(0, +) / Double(pc.samples.count)
            }
            return m
        }
        // 同一遍里的前后段（按时间）
        var prev = [Int?](repeating: nil, count: n), next = [Int?](repeating: nil, count: n)
        let bySession = Dictionary(grouping: pieces.indices, by: { pieces[$0].session })
        for (_, idx) in bySession {
            let s = idx.sorted { pieces[$0].t0Ms < pieces[$1].t0Ms }
            for k in s.indices.dropFirst() where pieces[s[k]].t0Ms - pieces[s[k - 1]].t1Ms < 3000 { prev[s[k]] = s[k - 1]; next[s[k - 1]] = s[k] }
        }
        let c = config.cellCm
        func key(_ p: Point2) -> Int64 { Int64(floor(p.x / c)) << 32 | Int64(Int32(truncatingIfNeeded: Int(floor(p.y / c)))) & 0xffffffff }
        for _ in 0..<config.rounds {
            // 当前位置下的全体格统计
            var cells: [Int64: (n: Double, t: Double, v: Double)] = [:]
            var own: [[Int64: (n: Double, t: Double, v: Double)]] = Array(repeating: [:], count: n)
            for k in 0..<n {
                for s in pieces[k].samples {
                    let q = moves[k].apply(s.p), kk = key(q)
                    var e = own[k][kk] ?? (0, 0, 0); e.n += 1; e.t += s.t; e.v += s.v; own[k][kk] = e
                }
                for (kk, e) in own[k] { var a = cells[kk] ?? (0, 0, 0); a.n += e.n; a.t += e.t; a.v += e.v; cells[kk] = a }
            }
            let wts: [(Int, Int, Double)] = [(0, 0, 1), (1, 0, 0.5), (-1, 0, 0.5), (0, 1, 0.5), (0, -1, 0.5), (1, 1, 0.25), (1, -1, 0.25), (-1, 1, 0.25), (-1, -1, 0.25)]
            var nextMoves = moves
            for k in 0..<n where !pieces[k].fixed && pieces[k].samples.count >= 2 {
                // 参考 = 别的段，去掉自己和同一遍的相邻段（相邻段在接缝处和自己挨着，比了等于自己比自己）
                let skip = [k, prev[k], next[k]].compactMap { $0 }
                func refAt(_ p: Point2) -> (t: Double, v: Double)? {
                    let i = Int(floor(p.x / c)), j = Int(floor(p.y / c))
                    var n = 0.0, t = 0.0, v = 0.0
                    for (di, dj, w) in wts {
                        let kk = Int64(i + di) << 32 | Int64(Int32(truncatingIfNeeded: j + dj)) & 0xffffffff
                        guard var e = cells[kk] else { continue }
                        for s in skip { if let m = own[s][kk] { e.n -= m.n; e.t -= m.t; e.v -= m.v } }
                        guard e.n > 0.5 else { continue }
                        n += w * e.n; t += w * e.t; v += w * e.v
                    }
                    return n >= config.minRefWeight ? (t / n, v / n) : nil
                }
                let samp = pieces[k].samples
                func magCost(_ m: Move) -> (r: Double, n: Int)? {
                    var dt: [Double] = [], dv: [Double] = []
                    for s in samp { guard let q = refAt(m.apply(s.p)) else { continue }; dt.append(s.t - q.t); dv.append(s.v - q.v) }
                    guard dt.count >= config.minOverlap else { return nil }
                    let mt = Self.median(dt), mv = Self.median(dv)
                    var e = 0.0
                    for i in dt.indices { e += min((abs(dt[i] - mt) + abs(dv[i] - mv)) / 2, config.capUT) }
                    return (e / Double(dt.count), dt.count)
                }
                let useMag = magCost(moves[k]) != nil
                let first = samp.first!.p, last = samp.last!.p
                func cost(_ m: Move) -> Double? {
                    var cst = 0.0
                    if useMag { guard let r = magCost(m) else { return nil }; cst += r.r }
                    if let w = walkable {
                        var inside = 0, tot = 0
                        for i in stride(from: 0, to: samp.count, by: 2) { tot += 1; if w.isWalkable(m.apply(samp[i].p)) { inside += 1 } }
                        cst += config.outsideWeight * (1 - Double(inside) / Double(max(tot, 1)))
                    }
                    if let p = prev[k], let pe = pieces[p].samples.last?.p {
                        let g = m.apply(first).distance(to: moves[p].apply(pe)) / config.jointCm; cst += config.jointWeight * g * g
                    }
                    if let q = next[k], let ns = pieces[q].samples.first?.p {
                        let g = m.apply(last).distance(to: moves[q].apply(ns)) / config.jointCm; cst += config.jointWeight * g * g
                    }
                    let sh = (m.dx * m.dx + m.dy * m.dy).squareRoot() / config.priorShiftCm, ro = m.rotDeg / config.priorRotDeg
                    return cst + config.priorWeight * (sh * sh + ro * ro)
                }
                var best = (cost(moves[k]) ?? .infinity, moves[k])
                let ns = Int((config.maxShiftCm / config.shiftStepCm).rounded()), nr = Int((config.maxRotDeg / config.rotStepDeg).rounded())
                for ir in -nr...nr {
                    for ix in -ns...ns {
                        for iy in -ns...ns {
                            var m = moves[k]
                            m.rotDeg = Double(ir) * config.rotStepDeg
                            m.dx = Double(ix) * config.shiftStepCm
                            m.dy = Double(iy) * config.shiftStepCm
                            if let cc = cost(m), cc < best.0 { best = (cc, m) }
                        }
                    }
                }
                nextMoves[k].dx += config.step * (best.1.dx - moves[k].dx)
                nextMoves[k].dy += config.step * (best.1.dy - moves[k].dy)
                nextMoves[k].rotDeg += config.step * (best.1.rotDeg - moves[k].rotDeg)
            }
            moves = nextMoves
        }
        return moves
    }

    static func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
}

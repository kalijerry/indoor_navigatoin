import Foundation

/// 多遍采集互相对齐：每遍（会话）估一个小的刚体修正（平移 + 绕起点转一点），让各遍的磁场在同一处对得上、轨迹落在可走区域里。
///
/// 为什么要有：每遍的位置只靠起点（用户点的地图位置）+ 起步朝向，实测起点点偏 0.5～1 m、朝向差 3～5° 很常见，
/// 20 m 走廊尽头就横向偏 1～2 m。没有通道中心线（办公室这种房间地图）时没东西把它拉回来，
/// 几遍叠在一起磁场图就糊了，再走一遍定位就沿走廊漂。
///
/// 做法（和多会话 SLAM 里的「扫描配准」同一个思路，代价换成磁场）：
/// 1. 其余各遍（用当前修正）累积成一张平滑的磁场参考图（25 cm 格，高斯平滑）；
/// 2. 本遍在 ±2 m、±8° 里网格搜索，代价 = 和参考图的磁场残差（|B|、Bz，先减本遍整体偏移的中位数，截断防野值）
///    + 走出可走区域的比例 + 修正量的先验（起点误差约 0.75 m、朝向约 4°）；
/// 3. 各遍同时更新（和会话顺序无关），每轮只往最优走一半，迭代几轮。
/// 和别的遍重叠不够时只用「可走区域 + 先验」（把穿墙的轨迹拉回来）。
///
/// 只修「位置只靠起点 + 起步朝向」的遍。路上又定过位置（`Session.fixed`：起点之外还有 reanchor，
/// 例如公开数据 ILC 每几秒一个真值路标点、App 里中途长按修正）的遍，轨迹在每个锚点处已经被钉住、分段对齐过，
/// 误差不是一个整体的刚体偏差，整体挪只会把钉准的点挪走：这种遍不挪，只当别的遍的参考。
public struct SessionRegistration {
    /// 一遍的刚体修正：p' = pivot + R(rot)(p − pivot) + shift
    public struct Rigid: Codable, Equatable {
        public var dx: Double
        public var dy: Double
        public var rotDeg: Double
        public var pivotX: Double
        public var pivotY: Double
        /// 修正前后和别的遍的磁场残差（µT）；重叠不够时 nil
        public var residualBefore: Double?
        public var residualAfter: Double?
        /// 修正前后落在可走区域里的比例
        public var insideBefore: Double
        public var insideAfter: Double

        public static func identity(pivot: Point2) -> Rigid {
            Rigid(dx: 0, dy: 0, rotDeg: 0, pivotX: pivot.x, pivotY: pivot.y, residualBefore: nil, residualAfter: nil,
                  insideBefore: 1, insideAfter: 1)
        }

        public var isIdentity: Bool { dx == 0 && dy == 0 && rotDeg == 0 }

        public func apply(_ p: Point2) -> Point2 {
            let th = rotDeg * .pi / 180, c = cos(th), s = sin(th)
            let x = p.x - pivotX, y = p.y - pivotY
            return Point2(pivotX + x * c - y * s + dx, pivotY + x * s + y * c + dy)
        }
    }

    public struct Config {
        public var maxShiftCm = 200.0
        public var shiftStepCm = 25.0
        public var maxRotDeg = 8.0
        public var rotStepDeg = 1.0
        public var cellCm = 25.0
        /// 参考图高斯平滑（格）
        public var blurCells = 1.5
        /// 参考图在这格的（平滑后）样本权重至少这么多才算有数据
        public var minRefWeight = 0.5
        /// 本遍样本按这个间隔抽（ms）
        public var sampleEveryMs: Int64 = 100
        /// 至少这么多抽出来的样本落在参考图有数据的地方，才用磁场（否则只用可走区域 + 先验）
        public var minOverlap = 100
        /// 残差截断（µT）
        public var capUT = 8.0
        /// 走出可走区域的比例的权重（µT / 100%）
        public var outsideWeight = 10.0
        /// 先验：(平移 / priorShiftCm)² + (转角 / priorRotDeg)²，乘 priorWeight
        public var priorShiftCm = 75.0
        public var priorRotDeg = 4.0
        public var priorWeight = 0.3
        public var rounds = 4
        /// 每轮往本轮最优走多少（1 = 全走）
        public var step = 0.5
        public init() {}
    }

    public struct Session {
        public var name: String
        public var samples: [(p: Point2, f: MagneticFeature, tMs: Int64)]
        /// 固定不动（手动摆好的段，或路上定过位置的遍）：当别人的参考，自己不挪
        public var fixed: Bool
        public init(name: String, samples: [(p: Point2, f: MagneticFeature, tMs: Int64)], fixed: Bool = false) {
            self.name = name; self.samples = samples; self.fixed = fixed
        }

        /// 起点之外还定过位置：start / reanchor 锚点里有两个以上不同的位置（相距 ≥ minSeparationCm）
        public static func isMultiplyAnchored(_ anchors: [SurveySession.Anchor], minSeparationCm: Double = 50) -> Bool {
            let pins = anchors.filter { $0.kind == "start" || $0.kind == "reanchor" }.map(\.map)
            guard let first = pins.first else { return false }
            return pins.contains { $0.distance(to: first) >= minSeparationCm }
        }
    }

    public let widthCm: Double
    public let heightCm: Double
    public let walkable: WalkableMap?
    public var config: Config

    public init(widthCm: Double, heightCm: Double, walkable: WalkableMap?, config: Config = Config()) {
        self.widthCm = widthCm; self.heightCm = heightCm; self.walkable = walkable; self.config = config
    }

    /// 每遍一个修正（和输入一一对应；没有样本的给恒等）
    public func solve(_ sessions: [Session]) -> [Rigid] {
        // 抽样 + 减整体偏移（中位数）
        let thin: [[(p: Point2, t: Double, v: Double)]] = sessions.map { s in
            var out: [(Point2, MagneticFeature)] = []
            var last: Int64?
            for x in s.samples where last == nil || x.tMs - last! >= config.sampleEveryMs { out.append((x.p, x.f)); last = x.tMs }
            guard !out.isEmpty else { return [] }
            let mt = Self.median(out.map { $0.1.total }), mv = Self.median(out.map { $0.1.vertical })
            return out.map { ($0.0, $0.1.total - mt, $0.1.vertical - mv) }
        }
        let pivots = sessions.map { $0.samples.first?.p ?? .zero }
        var cur = pivots.map { Rigid.identity(pivot: $0) }
        guard sessions.contains(where: { !$0.fixed }), sessions.count > 1 || walkable != nil else { return cur }
        // 修正前：和别的遍（都不修正）比的残差、可走比例
        let before: [(res: Double?, inside: Double)] = sessions.indices.map { k in
            guard !thin[k].isEmpty else { return (nil, 1) }
            return (reference(thin, cur, excluding: k).flatMap { residual(thin[k], cur[k], $0) }, inside(thin[k], cur[k]))
        }
        // 各遍同时更新（和输入顺序无关），每轮只走一半：全走的话两遍会互相「换位置」来回振荡；
        // 轮流更新（后面的对齐到前面挪过的）实测会让一串遍一起漂走
        for _ in 0..<config.rounds {
            var next = cur
            for k in sessions.indices where !thin[k].isEmpty && !sessions[k].fixed {
                let b = search(thin[k], pivot: pivots[k], ref: reference(thin, cur, excluding: k))
                next[k].dx += config.step * (b.dx - cur[k].dx)
                next[k].dy += config.step * (b.dy - cur[k].dy)
                next[k].rotDeg += config.step * (b.rotDeg - cur[k].rotDeg)
            }
            cur = next
        }
        for k in sessions.indices where !thin[k].isEmpty && !sessions[k].fixed {
            cur[k].residualBefore = before[k].res
            cur[k].insideBefore = before[k].inside
            cur[k].residualAfter = reference(thin, cur, excluding: k).flatMap { residual(thin[k], cur[k], $0) }
            cur[k].insideAfter = inside(thin[k], cur[k])
        }
        return cur
    }

    // MARK: 参考图

    struct Ref {
        let nx: Int, ny: Int, cell: Double
        let w: [Double], t: [Double], v: [Double]
        func at(_ p: Point2) -> (t: Double, v: Double, w: Double)? {
            let i = Int(p.x / cell), j = Int(p.y / cell)
            guard p.x >= 0, p.y >= 0, i < nx, j < ny else { return nil }
            let k = j * nx + i
            return (t[k], v[k], w[k])
        }
    }

    private func reference(_ thin: [[(p: Point2, t: Double, v: Double)]], _ rig: [Rigid], excluding: Int) -> Ref? {
        let c = config.cellCm
        let nx = Int(widthCm / c) + 2, ny = Int(heightCm / c) + 2
        var w = [Double](repeating: 0, count: nx * ny), st = w, sv = w
        var any = false
        for (k, ss) in thin.enumerated() where k != excluding {
            for x in ss {
                let p = rig[k].apply(x.p)
                let i = Int(p.x / c), j = Int(p.y / c)
                guard p.x >= 0, p.y >= 0, i < nx, j < ny else { continue }
                w[j * nx + i] += 1; st[j * nx + i] += x.t; sv[j * nx + i] += x.v
                any = true
            }
        }
        guard any else { return nil }
        let bw = Self.blur(w, nx, ny, config.blurCells), bt = Self.blur(st, nx, ny, config.blurCells), bv = Self.blur(sv, nx, ny, config.blurCells)
        var mt = bt, mv = bv
        for k in bw.indices {
            if bw[k] > 1e-9 { mt[k] = bt[k] / bw[k]; mv[k] = bv[k] / bw[k] } else { mt[k] = 0; mv[k] = 0 }
        }
        return Ref(nx: nx, ny: ny, cell: c, w: bw, t: mt, v: mv)
    }

    /// 可分离高斯平滑
    static func blur(_ a: [Double], _ nx: Int, _ ny: Int, _ sigma: Double) -> [Double] {
        let r = max(1, Int((3 * sigma).rounded(.up)))
        var ker = (-r...r).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let sum = ker.reduce(0, +)
        ker = ker.map { $0 / sum }
        var tmp = [Double](repeating: 0, count: a.count), out = tmp
        for j in 0..<ny {
            for i in 0..<nx {
                var s = 0.0
                for d in -r...r { let ii = i + d; if ii >= 0 && ii < nx { s += ker[d + r] * a[j * nx + ii] } }
                tmp[j * nx + i] = s
            }
        }
        for j in 0..<ny {
            for i in 0..<nx {
                var s = 0.0
                for d in -r...r { let jj = j + d; if jj >= 0 && jj < ny { s += ker[d + r] * tmp[jj * nx + i] } }
                out[j * nx + i] = s
            }
        }
        return out
    }

    // MARK: 代价

    /// 和参考图的磁场残差（µT）：落在参考图有数据处的样本，先减中位偏移再截断平均。重叠不够时 nil
    func residual(_ s: [(p: Point2, t: Double, v: Double)], _ r: Rigid, _ ref: Ref) -> Double? {
        var dt: [Double] = [], dv: [Double] = []
        dt.reserveCapacity(s.count); dv.reserveCapacity(s.count)
        for x in s {
            guard let q = ref.at(r.apply(x.p)), q.w >= config.minRefWeight else { continue }
            dt.append(x.t - q.t); dv.append(x.v - q.v)
        }
        guard dt.count >= config.minOverlap else { return nil }
        let mt = Self.median(dt), mv = Self.median(dv)
        var e = 0.0
        for i in dt.indices { e += min((abs(dt[i] - mt) + abs(dv[i] - mv)) / 2, config.capUT) }
        return e / Double(dt.count)
    }

    func inside(_ s: [(p: Point2, t: Double, v: Double)], _ r: Rigid) -> Double {
        guard let wm = walkable, !s.isEmpty else { return 1 }
        var n = 0, k = 0
        for i in stride(from: 0, to: s.count, by: 2) { k += 1; if wm.isWalkable(r.apply(s[i].p)) { n += 1 } }
        return Double(n) / Double(max(k, 1))
    }

    private func search(_ s: [(p: Point2, t: Double, v: Double)], pivot: Point2, ref: Ref?) -> Rigid {
        let id = Rigid.identity(pivot: pivot)
        // 搜索范围里有没有哪个候选和参考图重叠够（没有就只用可走区域 + 先验）
        var useMag = false
        if let ref {
            let ns = Int((config.maxShiftCm / config.shiftStepCm).rounded())
            outer: for ix in stride(from: -ns, through: ns, by: 2) {
                for iy in stride(from: -ns, through: ns, by: 2) {
                    var r = id
                    r.dx = Double(ix) * config.shiftStepCm; r.dy = Double(iy) * config.shiftStepCm
                    if residual(s, r, ref) != nil { useMag = true; break outer }
                }
            }
        }
        guard useMag || walkable != nil else { return id }
        func cost(_ r: Rigid) -> Double? {
            var c = 0.0
            if useMag, let ref {
                guard let e = residual(s, r, ref) else { return nil }   // 重叠不够的候选不比
                c += e
            }
            c += config.outsideWeight * (1 - inside(s, r))
            let sh = (r.dx * r.dx + r.dy * r.dy).squareRoot() / config.priorShiftCm, ro = r.rotDeg / config.priorRotDeg
            return c + config.priorWeight * (sh * sh + ro * ro)
        }
        var best = (cost(id) ?? .infinity, id)
        let ns = Int((config.maxShiftCm / config.shiftStepCm).rounded()), nr = Int((config.maxRotDeg / config.rotStepDeg).rounded())
        for ir in -nr...nr {
            for ix in -ns...ns {
                for iy in -ns...ns {
                    var r = id
                    r.rotDeg = Double(ir) * config.rotStepDeg
                    r.dx = Double(ix) * config.shiftStepCm
                    r.dy = Double(iy) * config.shiftStepCm
                    if let c = cost(r), c < best.0 { best = (c, r) }
                }
            }
        }
        return best.1
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[s.count / 2]
    }
}

import Foundation

/// 一次「建图采集」会话的数据（App 里从会话目录的 csv 读出来）。
public struct SurveySession {
    public struct Pose {
        public var tMs: Int64
        /// ARKit 平面坐标 (x, z)，cm
        public var a: Point2
        public var normal: Bool
        public init(tMs: Int64, a: Point2, normal: Bool) { self.tMs = tMs; self.a = a; self.normal = normal }
    }

    public struct Anchor {
        public var tMs: Int64
        /// start / reanchor 是真值；heading / end 不是；align 的 heading 字段是 ARKit → 地图的旋转 φ（自动起点写的）
        public var kind: String
        public var map: Point2
        public var ar: Point2
        public var heading: Double?
        public init(tMs: Int64, kind: String, map: Point2, ar: Point2, heading: Double?) {
            self.tMs = tMs; self.kind = kind; self.map = map; self.ar = ar; self.heading = heading
        }
    }

    public var name: String
    public var imu: [IMUSample]
    /// 原始磁力计（µT，设备坐标系，未去偏置）。没有时用 imu 里的校准磁场。
    public var raw: [(tMs: Int64, v: (Double, Double, Double))]
    public var poses: [Pose]
    public var anchors: [Anchor]
    /// 采集时质量打分判为差的时段（毫秒，含前后扩展，见 CollectionQualityMonitor / quality.json）：这些时刻的样本不用
    public var qualityDrops: [ClosedRange<Int64>] = []
    /// App 自己标定的磁力计硬铁偏置（µT，设备系；画 8 字校准 / 存档，见 `SurveySessionLoader.appBias`）。
    /// 有就用它去偏置，不用「原始 − iOS 校准」的中位数：iOS 校准在店里会漂几十 µT（Tesco 2026-11-25：
    /// 一次会话里 z 在 −379～−619 之间晃，中位数和画 8 字的差 36 µT，同一条通道一去一回 |B| 差 15 µT）
    public var appBias: (Double, Double, Double)?

    /// 这个时刻采集时被判为质量差
    public func qualityDropped(_ t: Int64) -> Bool { qualityDrops.contains { $0.contains(t) } }

    public init(name: String, imu: [IMUSample], raw: [(tMs: Int64, v: (Double, Double, Double))],
                poses: [Pose], anchors: [Anchor]) {
        self.name = name; self.imu = imu; self.raw = raw; self.poses = poses; self.anchors = anchors
    }
}

/// 一次会话的建图结果说明。
public struct SurveySessionReport {
    public var name: String
    public var samplesUsed = 0
    public var dropped: [String: Int] = [:]
    public var magSource = "calibrated"
    public var bias: (Double, Double, Double)?
    /// 轨迹离最近通道中心线的距离中位数（cm）：自动贴通道之前 / 之后
    public var corridorResidualBefore: Double?
    public var corridorResidualAfter: Double?
    public var warnings: [String] = []
    /// 对齐后的轨迹（地图坐标，约 10 Hz），给界面画、给回放当真值
    public var track: [(tMs: Int64, p: Point2)] = []
    /// 和已有数据对齐时减掉的整体偏移（µT）；没对齐（第一个会话或共同格子不够）为 nil
    public var offsetUT: MagneticFeature?
    /// prepare 返回的每个样本的时间（和样本一一对应）
    public var sampleTimes: [Int64] = []
}

/// 在手机上把建图采集会话变成磁场图（与 tools/magmap.py 同一套算法，另加「自动贴通道」）。
///
/// 1. 锚点分段对齐：ARKit 轨迹 → 地图坐标（起点 + 朝向必需，途中的长按修正可选）；
/// 2. 自动贴通道：按 10 m 一段，估一个小的旋转 + 平移，让轨迹贴到最近的通道中心线上（通道在地图里是准的），
///    吸收 ARKit 的累积漂移和朝向误差。所以途中不修正也能建图；
/// 3. 磁场用「原始磁力计 − 会话偏置中位数」，不受 iOS 重新校准影响；
/// 4. 丢掉跟踪受限、站着不动的样本，累积进网格。
/// 非线程安全，放在后台队列里一次性用。
public final class SurveyMapBuilder {
    public let field: MagneticFieldBuilder
    public let crosses: [CrossSegment]

    /// 最后一个真值锚点之后最多信任多长路程（cm）。有自动贴通道时可以放得比较大。
    public var tailMaxCm: Double = 15_000
    public var minSpeedCmS: Double = 30
    /// 自动贴通道：每段长度（cm）、只用离通道这么近的轨迹点（cm）
    public var snapWindowCm: Double = 1000
    public var snapMaxDistCm: Double = 200
    public var snapEnabled = true
    /// 新会话加进已有数据前，先对齐整体偏移（见 add 第 5 步）
    public var alignSessionOffset = true
    /// 至少要这么多共同格子（各自 ≥ 5 个样本）才对齐
    public var minCommonCells = 20
    /// 贴通道时，离中心线 半宽 − 这个（cm）以内都算在通道里，不往正中拉
    public var snapBandMarginCm = 30.0
    /// 贴通道之前先按时间顺序跑一遍在线贴通道（和采集时手机上一样）。
    /// 分段贴通道每 10 m 独立估、平移有上限，修不了长直路上累积的朝向误差：
    /// 实测 124 m 主通道，朝向差 5°，末端横向偏 11 m、磁场数据画到了货架里，定位就乱飘。
    /// 先按顺序累积修正朝向，再分段细调，就一直在通道里（合成真值，漂移 10°/分钟、不长按：P90 133 → 59 cm）。
    public var lockEnabled = true
    public var lockLateralGain = 0.3
    /// 只用这些时刻的样本（云端质量筛选用；nil = 都用）
    public var sampleFilter: ((Int64) -> Bool)?
    /// 标签锚定的轨迹修正（时间 → 平移，见 TagTrajectoryCorrector）：贴完通道后加上，再贴一次通道
    public var correction: ((Int64) -> Point2)?

    public init(widthCm: Double, heightCm: Double, crosses: [CrossSegment], cellCm: Double = 50) {
        field = MagneticFieldBuilder(widthCm: widthCm, heightCm: heightCm, cellCm: cellCm)
        self.crosses = crosses
    }

    /// 增量建图：接着已有的统计往上加
    public init(field: MagneticFieldBuilder, crosses: [CrossSegment]) {
        self.field = field
        self.crosses = crosses
    }

    public func build() -> MagneticFieldMap { field.build() }

    /// 本会话和已有数据的整体偏移：共同格子里各特征「本会话均值 − 已有均值」的中位。共同格子不够时 nil。
    private func sessionOffset(_ samples: [(Point2, MagneticFeature)]) -> MagneticFeature? {
        let tmp = MagneticFieldBuilder(widthCm: field.widthCm, heightCm: field.heightCm, cellCm: field.cellCm)
        for (p, f) in samples { _ = tmp.add(position: p, feature: f) }
        let a = tmp.snapshot(), b = field.snapshot()
        var d: [[Double]] = [[], [], []]
        for k in a.counts.indices where a.counts[k] >= 5 && b.counts[k] >= 5 {
            for c in 0..<3 { d[c].append(a.means[k * 3 + c] - b.means[k * 3 + c]) }
        }
        guard d[0].count >= minCommonCells else { return nil }
        func med(_ x: [Double]) -> Double { let s = x.sorted(); return s[s.count / 2] }
        return MagneticFeature(total: med(d[0]), vertical: med(d[1]), horizontal: med(d[2]))
    }

    // MARK: - 一次会话

    @discardableResult
    /// 一个会话：对齐、贴通道、算磁场特征，返回带位置的样本（不累积）。多会话云端融合先把所有会话都算出来，
    /// 统一解出各会话的偏移再累积（见 MultiSessionFusion）。
    public func prepare(_ s: SurveySession) -> (SurveySessionReport, [(Point2, MagneticFeature)]) {
        var rep = SurveySessionReport(name: s.name)
        let poses = s.poses.sorted { $0.tMs < $1.tMs }
        guard poses.count > 30 else { rep.warnings.append("ARKit 位姿太少"); return (rep, []) }
        let segs = segments(s.anchors.sorted { $0.tMs < $1.tMs }, poses, &rep)
        guard !segs.isEmpty else { return (rep, []) }

        // 1. 每个位姿换到地图坐标
        var cum = [0.0]
        for i in 1..<poses.count { cum.append(cum[i - 1] + poses[i].a.distance(to: poses[i - 1].a)) }
        var mapped: [(t: Int64, p: Point2, path: Double, ok: Bool)] = []
        var segIdx = 0
        for (i, ps) in poses.enumerated() {
            while segIdx + 1 < segs.count && ps.tMs >= segs[segIdx + 1].t0 { segIdx += 1 }
            let sg = segs[segIdx]
            guard ps.tMs >= sg.t0, ps.tMs <= sg.t1 || sg.tail else { continue }
            if sg.tail, cum[i] - sg.path0 > tailMaxCm { continue }
            mapped.append((ps.tMs, sg.toMap(ps.a, t: ps.tMs), cum[i], ps.normal))
        }
        guard mapped.count > 10 else { rep.warnings.append("对齐后没有可用的轨迹"); return (rep, []) }

        // 2. 自动贴通道
        if snapEnabled && !crosses.isEmpty {
            let before = mapped.compactMap { $0.ok ? nearestCorridor($0.p)?.dist : nil }
            rep.corridorResidualBefore = median(before)
            if lockEnabled { lockToCorridors(&mapped) }
            snapToCorridors(&mapped)
            if let corr = correction {
                for i in mapped.indices { let d = corr(mapped[i].t); mapped[i].p = Point2(mapped[i].p.x + d.x, mapped[i].p.y + d.y) }
                snapToCorridors(&mapped)
            }
            let after = mapped.compactMap { $0.ok ? nearestCorridor($0.p)?.dist : nil }
            rep.corridorResidualAfter = median(after)
        }
        var lastT: Int64?
        for m in mapped where m.ok && (lastT == nil || m.t - lastT! >= 100) { rep.track.append((m.t, m.p)); lastT = m.t }

        // 3. 磁场特征
        let feats = features(s, &rep)

        // 4. 按时间插值位置，过滤后累积
        let times = mapped.map { $0.t }
        func posAt(_ t: Int64) -> (Point2, Bool)? {
            var lo = 0, hi = times.count - 1
            guard t >= times[lo], t <= times[hi] else { return nil }
            while hi - lo > 1 { let m = (lo + hi) / 2; if times[m] <= t { lo = m } else { hi = m } }
            let a = mapped[lo], b = mapped[hi]
            guard b.t - a.t <= 200 else { return nil }
            let f = b.t > a.t ? Double(t - a.t) / Double(b.t - a.t) : 0
            return (Point2(a.p.x + (b.p.x - a.p.x) * f, a.p.y + (b.p.y - a.p.y) * f), a.ok && b.ok)
        }
        var samples: [(Point2, MagneticFeature)] = []
        for (t, f) in feats {
            guard let (p, ok) = posAt(t) else { rep.dropped["不在对齐范围内", default: 0] += 1; continue }
            guard ok else { rep.dropped["ARKit 跟踪受限", default: 0] += 1; continue }
            guard let (q, _) = posAt(t - 500), p.distance(to: q) / 0.5 >= minSpeedCmS else {
                rep.dropped["站着不动", default: 0] += 1
                continue
            }
            if s.qualityDropped(t) { rep.dropped["采集时质量差丢掉", default: 0] += 1; continue }
            if let keep = sampleFilter, !keep(t) { rep.dropped["质量筛选丢掉", default: 0] += 1; continue }
            samples.append((p, f))
            rep.sampleTimes.append(t)
        }
        return (rep, samples)
    }

    @discardableResult
    public func add(_ s: SurveySession) -> SurveySessionReport {
        var (rep, samples) = prepare(s)
        guard !samples.isEmpty else { return rep }
        // 5. 会话整体偏移对齐：实测两次采集同一处整体能差 10～16 µT（磁力计偏置每次估得不一样），
        //    直接平均会把地图糊掉。和已有数据有足够多共同格子时，减去「本会话 − 已有」的中位差再累积。
        if alignSessionOffset, let off = sessionOffset(samples) {
            rep.offsetUT = off
            samples = samples.map { ($0.0, $0.1 - off) }
            if abs(off.total) > 3 || abs(off.vertical) > 3 || abs(off.horizontal) > 3 {
                rep.warnings.append(String(format: "这次整体比已有数据偏 |B| %+.1f、Bz %+.1f、Bh %+.1f µT，已对齐", off.total, off.vertical, off.horizontal))
            }
        }
        for (p, f) in samples where field.add(position: p, feature: f) { rep.samplesUsed += 1 }
        return rep
    }

    // MARK: 锚点分段（与 magmap.py 相同）

    private struct Segment {
        var t0: Int64, t1: Int64
        var p: Point2, a: Point2
        var phi: Double
        var resid: Point2
        var tail: Bool
        var path0: Double = 0

        func toMap(_ ar: Point2, t: Int64) -> Point2 {
            let d = ar - a
            let c = cos(phi), s = sin(phi)
            var f = 0.0
            if !tail, t1 > t0 { f = min(max(Double(t - t0) / Double(t1 - t0), 0), 1) }
            return Point2(p.x + d.x * c - d.y * s + f * resid.x, p.y + d.x * s + d.y * c + f * resid.y)
        }
    }

    private func segments(_ anchors: [SurveySession.Anchor], _ poses: [SurveySession.Pose],
                          _ rep: inout SurveySessionReport) -> [Segment] {
        let truth = anchors.filter { $0.kind == "start" || $0.kind == "reanchor" }
        guard !truth.isEmpty else { rep.warnings.append("没有起点锚点（长按定点）"); return [] }
        // 首段旋转：设朝向锚点 + 之后走出 1.5 m 的方向
        var phiPrev: Double?
        // 自动起点（地磁定位）直接给出 ARKit → 地图的旋转
        if let al = anchors.first(where: { $0.kind == "align" && $0.heading != nil }) { phiPrev = al.heading }
        for h in anchors where phiPrev == nil && h.kind == "heading" && h.heading != nil {
            guard let i0 = poses.firstIndex(where: { $0.tMs >= h.tMs }) else { continue }
            let a0 = poses[i0].a
            if let j = poses[i0...].firstIndex(where: { $0.a.distance(to: a0) >= 150 }) {
                let d = poses[j].a - a0
                let hd = h.heading!
                phiPrev = atan2(cos(hd), sin(hd)) - atan2(d.y, d.x)
                break
            }
        }
        var out: [Segment] = []
        for (i, a) in truth.enumerated() {
            if i + 1 < truth.count {
                let n = truth[i + 1]
                let dm = n.map - a.map, da = n.ar - a.ar
                var phi = phiPrev
                if dm.length >= 500, da.length > 1 {
                    let scale = dm.length / da.length
                    if scale >= 0.9 && scale <= 1.1 {
                        phi = atan2(dm.y, dm.x) - atan2(da.y, da.x)
                    } else {
                        rep.warnings.append("锚点间距与 ARKit 位移之比 \(String(format: "%.2f", scale)) 超出范围，这一段的旋转沿用上一段")
                    }
                }
                guard let ph = phi else { rep.warnings.append("缺少朝向，无法对齐第一段"); continue }
                let c = cos(ph), s = sin(ph)
                let end = Point2(da.x * c - da.y * s, da.x * s + da.y * c)
                out.append(Segment(t0: a.tMs, t1: n.tMs, p: a.map, a: a.ar, phi: ph, resid: dm - end, tail: false))
                phiPrev = ph
            } else {
                guard let ph = phiPrev else { rep.warnings.append("缺少朝向（设朝向后要直走 1.5 m）"); continue }
                out.append(Segment(t0: a.tMs, t1: poses.last!.tMs, p: a.map, a: a.ar, phi: ph, resid: .zero, tail: true))
            }
        }
        // 尾段从哪个路程开始算
        if let lastIdx = out.indices.last, out[lastIdx].tail {
            var cum = 0.0
            for i in 1..<poses.count {
                if poses[i].tMs > out[lastIdx].t0 { break }
                cum += poses[i].a.distance(to: poses[i - 1].a)
            }
            out[lastIdx].path0 = cum
        }
        return out
    }

    // MARK: 自动贴通道

    /// 按时间顺序用 CorridorLock 修正轨迹：累积一个刚体变换，每次修正绕当前点转一点、平移一点。
    private func lockToCorridors(_ mapped: inout [(t: Int64, p: Point2, path: Double, ok: Bool)]) {
        let lock = CorridorLock(crosses: crosses)
        lock.lateralGain = lockLateralGain
        var th = 0.0, tr = Point2.zero          // 当前变换：p' = R(th) p + tr
        for i in mapped.indices {
            let p0 = mapped[i].p
            var p = Point2(p0.x * cos(th) - p0.y * sin(th) + tr.x, p0.x * sin(th) + p0.y * cos(th) + tr.y)
            if mapped[i].ok {
                if let fix = lock.update(p) {
                    // 新变换 = 绕 p 转 dPhi，再平移 shift
                    let c = cos(fix.dPhi), s = sin(fix.dPhi)
                    func f(_ q: Point2) -> Point2 { let r = q - p; return Point2(p.x + r.x * c - r.y * s, p.y + r.x * s + r.y * c) + fix.shift }
                    let newTr = f(tr)
                    th += fix.dPhi
                    tr = newTr
                    p = p + fix.shift
                }
            } else {
                lock.reset()
            }
            mapped[i].p = p
        }
    }

    /// 最近的通道中心线。给了行进方向 `along`（单位向量）时，只考虑和它方向差不多（25° 以内）的通道：
    /// 沿主通道走的时候不会被一路横穿过去的货架通道吸过去。
    private func nearestCorridor(_ p: Point2, along: Point2? = nil) -> (dist: Double, foot: Point2, normal: Point2, half: Double)? {
        var best: (Double, Point2, Point2, Double)?
        for c in crosses {
            let d = c.b - c.a
            let l2 = d.dot(d)
            guard l2 > 1 else { continue }
            if let u = along, abs(u.dot(d)) < 0.906 * l2.squareRoot() { continue }
            let t = min(max((p - c.a).dot(d) / l2, 0), 1)
            let q = Point2(c.a.x + d.x * t, c.a.y + d.y * t)
            let dist = p.distance(to: q)
            if best == nil || dist < best!.0 {
                let l = l2.squareRoot()
                best = (dist, q, Point2(-d.y / l, d.x / l), max(c.lineWidth, 0) / 2)
            }
        }
        return best.map { ($0.0, $0.1, $0.2, $0.3) }
    }

    /// 按路程分段，每段估一个小的 (旋转 θ, 平移 tx, ty)，最小化轨迹点到通道中心线的垂直距离；
    /// 段与段之间按路程线性插值，避免接缝处跳变。沿通道方向的平移看不出来，靠正则项保持不动。
    private func snapToCorridors(_ mapped: inout [(t: Int64, p: Point2, path: Double, ok: Bool)]) {
        guard let first = mapped.first, let last = mapped.last else { return }
        let total = last.path - first.path
        let nWin = max(Int((total / snapWindowCm).rounded(.up)), 1)
        // 每个点的行进方向（前后各 1 m）；拐弯、原地转的点没有方向，不参与贴通道
        var dirs = [Point2?](repeating: nil, count: mapped.count)
        var lo = 0, hi = 0
        for i in mapped.indices {
            while lo < i && mapped[i].path - mapped[lo].path > 100 { lo += 1 }
            while hi + 1 < mapped.count && mapped[hi].path - mapped[i].path < 100 { hi += 1 }
            let d = mapped[hi].p - mapped[lo].p
            let span = mapped[hi].path - mapped[lo].path
            if span > 120, d.length > 0.9 * span { dirs[i] = d * (1 / d.length) }
        }
        var corr: [(center: Double, theta: Double, t: Point2, pivot: Point2)] = []
        for w in 0..<nWin {
            let lo = first.path + Double(w) * snapWindowCm, hi = lo + snapWindowCm
            let idx = mapped.indices.filter { mapped[$0].ok && mapped[$0].path >= lo && mapped[$0].path < hi }
            guard idx.count >= 10 else { continue }
            let pivot = idx.reduce(Point2.zero) { $0 + mapped[$1].p } * (1 / Double(idx.count))
            var theta = 0.0, tr = Point2.zero
            for _ in 0..<6 {
                // 正规方程 A x = b，x = (θ, tx, ty)
                var A = [[Double]](repeating: [0, 0, 0], count: 3), b = [0.0, 0, 0]
                let lam = [2e5, 0.05, 0.05]               // 正则：旋转很少、平移适度
                for k in 0..<3 { A[k][k] += lam[k] }
                for i in idx {
                    let p0 = mapped[i].p
                    let rel = p0 - pivot
                    let c = cos(theta), s = sin(theta)
                    let p = Point2(pivot.x + rel.x * c - rel.y * s + tr.x, pivot.y + rel.x * s + rel.y * c + tr.y)
                    guard let u = dirs[i], let nc = nearestCorridor(p, along: u), nc.dist <= snapMaxDistCm else { continue }
                    let n = nc.normal
                    // 残差：人不一定走正中，通道里（离中心线 半宽 − snapBandMarginCm 以内）不算误差，出界的部分才算
                    var e = n.dot(p - nc.foot)
                    let band = max(nc.half - snapBandMarginCm, 0)
                    guard abs(e) > band else { continue }
                    e -= e > 0 ? band : -band
                    let rr = p - pivot
                    let jt = n.dot(Point2(-rr.y, rr.x))         // ∂e/∂θ
                    let row = [jt, n.x, n.y]
                    for r in 0..<3 { for q in 0..<3 { A[r][q] += row[r] * row[q] }; b[r] -= row[r] * e }
                }
                guard let dx = solve3(A, b) else { break }
                theta += dx[0]; tr = tr + Point2(dx[1], dx[2])
                if abs(dx[0]) < 1e-5 && abs(dx[1]) < 0.1 && abs(dx[2]) < 0.1 { break }
            }
            // 太大的修正不可信（可能贴错了通道），截断
            theta = min(max(theta, -0.17), 0.17)
            if tr.length > 250 { tr = tr * (250 / tr.length) }
            corr.append(((lo + hi) / 2, theta, tr, pivot))
        }
        guard !corr.isEmpty else { return }
        for i in mapped.indices {
            let s = mapped[i].path
            // 找相邻两段的修正，按路程插值（作用到「点相对各自段中心」的结果上）
            var j = 0
            while j + 1 < corr.count && corr[j + 1].center <= s { j += 1 }
            func apply(_ k: Int) -> Point2 {
                let c = corr[k], rel = mapped[i].p - c.pivot
                let co = cos(c.theta), si = sin(c.theta)
                return Point2(c.pivot.x + rel.x * co - rel.y * si + c.t.x, c.pivot.y + rel.x * si + rel.y * co + c.t.y)
            }
            if s <= corr[0].center || corr.count == 1 {
                mapped[i].p = apply(0)
            } else if j + 1 >= corr.count {
                mapped[i].p = apply(corr.count - 1)
            } else {
                let f = (s - corr[j].center) / (corr[j + 1].center - corr[j].center)
                let a = apply(j), b = apply(j + 1)
                mapped[i].p = Point2(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
            }
        }
    }

    private func solve3(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        var m = A.enumerated().map { $0.element + [b[$0.offset]] }
        for c in 0..<3 {
            guard let piv = (c..<3).max(by: { abs(m[$0][c]) < abs(m[$1][c]) }), abs(m[piv][c]) > 1e-12 else { return nil }
            m.swapAt(c, piv)
            for r in 0..<3 where r != c {
                let f = m[r][c] / m[c][c]
                for k in c..<4 { m[r][k] -= f * m[c][k] }
            }
        }
        return (0..<3).map { m[$0][3] / m[$0][$0] }
    }

    // MARK: 磁场特征

    func features(_ s: SurveySession, _ rep: inout SurveySessionReport) -> [(Int64, MagneticFeature)] {
        let ex = MagneticFeatureExtractor()
        var out: [(Int64, MagneticFeature)] = []
        let imu = s.imu.sorted { $0.tMs < $1.tMs }
        guard s.raw.count > 100 else {
            for x in imu { if let f = ex.process(x) { out.append((x.tMs, f)) } }
            rep.magSource = "calibrated"
            return out
        }
        let raw = s.raw.sorted { $0.tMs < $1.tMs }
        if let b = s.appBias, HardIronCheck.medianField(raw: raw.map { $0.v }, bias: [b.0, b.1, b.2]).map(HardIronCheck.plausibleUT.contains) == true {
            // App 标定的偏置：扣掉之后 |B| 在地磁正常范围才用（偏置在录制前就变了的话退回下面的老办法）
            rep.bias = b
            rep.magSource = "raw:app-bias"
            return rawFeatures(raw, imu: imu, bias: b, ex: ex)
        }
        // 偏置 = 原始 − 校准 的中位数（整次会话）
        var dx: [Double] = [], dy: [Double] = [], dz: [Double] = []
        var j = 0
        for x in imu {
            while j + 1 < raw.count && raw[j + 1].tMs <= x.tMs { j += 1 }
            guard abs(raw[j].tMs - x.tMs) <= 20, IMUSample.calibratedFieldValid((x.mx, x.my, x.mz)) else { continue }
            dx.append(raw[j].v.0 - x.mx); dy.append(raw[j].v.1 - x.my); dz.append(raw[j].v.2 - x.mz)
        }
        guard let bx = median(dx), let by = median(dy), let bz = median(dz) else {
            for x in imu { if let f = ex.process(x) { out.append((x.tMs, f)) } }
            return out
        }
        rep.bias = (bx, by, bz)
        rep.magSource = "raw"
        return rawFeatures(raw, imu: imu, bias: (bx, by, bz), ex: ex)
    }

    /// 原始磁力计扣掉固定偏置出特征（时间顺序：加速度更新重力方向，原始磁力计逐个出特征）
    private func rawFeatures(_ raw: [(tMs: Int64, v: (Double, Double, Double))], imu: [IMUSample],
                             bias b: (Double, Double, Double), ex: MagneticFeatureExtractor) -> [(Int64, MagneticFeature)] {
        var out: [(Int64, MagneticFeature)] = []
        var k = 0
        for r in raw {
            while k < imu.count && imu[k].tMs <= r.tMs { ex.updateGravity(imu[k]); k += 1 }
            guard k > 0 else { continue }
            if let f = ex.process(magnetic: (r.v.0 - b.0, r.v.1 - b.1, r.v.2 - b.2), tMs: r.tMs) { out.append((r.tMs, f)) }
        }
        return out
    }

    private func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s[s.count / 2]
    }
}

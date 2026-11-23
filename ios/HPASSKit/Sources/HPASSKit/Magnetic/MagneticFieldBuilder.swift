import Foundation

/// 现场校准：把「走过已知位置时测到的磁场」累积成网格地图。
///
/// 位置来自操作者在已知点位上点「到达 / 离开」记下的时间：点位之间按匀速直线插值，
/// 在点位上停留的时间用该点位置。多次校准可以反复 `addTrack`，每格用 Welford 在线算法累积。
/// 非线程安全。
public final class MagneticFieldBuilder {
    public let widthCm: Double
    public let heightCm: Double
    public let cellCm: Double
    public let cols: Int
    public let rows: Int
    public private(set) var sampleCount = 0

    private var counts: [Int]
    private var means: [Double]   // 每格 3 个：|B|, Bz, Bh
    private var m2s: [Double]

    /// 时间轴上的一个已知位置。
    public struct Waypoint {
        public var tMs: Int64
        public var position: Point2
        public init(tMs: Int64, position: Point2) {
            self.tMs = tMs
            self.position = position
        }
    }

    public struct TimedFeature {
        public var tMs: Int64
        public var feature: MagneticFeature
        public init(tMs: Int64, feature: MagneticFeature) {
            self.tMs = tMs
            self.feature = feature
        }
    }

    /// 可序列化的累积状态，用来存盘 / 恢复。
    public struct Snapshot: Codable {
        public var widthCm: Double
        public var heightCm: Double
        public var cellCm: Double
        public var counts: [Int]
        public var means: [Double]
        public var m2s: [Double]
    }

    public init(widthCm: Double, heightCm: Double, cellCm: Double = 50) {
        precondition(widthCm > 0 && heightCm > 0 && cellCm > 0)
        self.widthCm = widthCm
        self.heightCm = heightCm
        self.cellCm = cellCm
        cols = Int((widthCm / cellCm).rounded(.up))
        rows = Int((heightCm / cellCm).rounded(.up))
        counts = [Int](repeating: 0, count: cols * rows)
        means = [Double](repeating: 0, count: cols * rows * 3)
        m2s = means
    }

    /// 从存盘状态恢复。尺寸或数组长度对不上时返回 nil。
    public convenience init?(snapshot s: Snapshot) {
        guard s.widthCm > 0, s.heightCm > 0, s.cellCm > 0 else { return nil }
        self.init(widthCm: s.widthCm, heightCm: s.heightCm, cellCm: s.cellCm)
        guard s.counts.count == cols * rows, s.means.count == cols * rows * 3, s.m2s.count == s.means.count else { return nil }
        counts = s.counts
        means = s.means
        m2s = s.m2s
        sampleCount = s.counts.reduce(0, +)
    }

    public func snapshot() -> Snapshot {
        Snapshot(widthCm: widthCm, heightCm: heightCm, cellCm: cellCm, counts: counts, means: means, m2s: m2s)
    }

    public func reset() {
        counts = [Int](repeating: 0, count: cols * rows)
        means = [Double](repeating: 0, count: cols * rows * 3)
        m2s = means
        sampleCount = 0
    }

    /// 累积一个已知位置的特征。位置在地图外返回 false。
    @discardableResult
    /// p 所在格子的下标（地图外为 nil）
    public func cellIndex(_ p: Point2) -> Int? {
        guard p.x >= 0, p.x <= widthCm, p.y >= 0, p.y <= heightCm else { return nil }
        return min(Int(p.y / cellCm), rows - 1) * cols + min(Int(p.x / cellCm), cols - 1)
    }

    public func add(position p: Point2, feature f: MagneticFeature) -> Bool {
        guard p.x >= 0, p.x <= widthCm, p.y >= 0, p.y <= heightCm,
              f.total.isFinite, f.vertical.isFinite, f.horizontal.isFinite else { return false }
        let i = min(Int(p.x / cellCm), cols - 1), j = min(Int(p.y / cellCm), rows - 1)
        let k = j * cols + i
        counts[k] += 1
        let n = Double(counts[k])
        let v = [f.total, f.vertical, f.horizontal]
        for c in 0..<3 {
            let d = v[c] - means[k * 3 + c]
            means[k * 3 + c] += d / n
            m2s[k * 3 + c] += d * (v[c] - means[k * 3 + c])
        }
        sampleCount += 1
        return true
    }

    /// 按时间插值出每个样本的位置并累积。返回实际用到的样本数。
    /// `waypoints` 必须按时间升序；第一个之前、最后一个之后的样本丢弃。
    @discardableResult
    public func addTrack(waypoints: [Waypoint], samples: [TimedFeature]) -> Int {
        guard waypoints.count >= 2 else { return 0 }
        var used = 0
        var seg = 0
        for s in samples.sorted(by: { $0.tMs < $1.tMs }) {
            if s.tMs < waypoints[0].tMs || s.tMs > waypoints[waypoints.count - 1].tMs { continue }
            while seg < waypoints.count - 2 && s.tMs > waypoints[seg + 1].tMs { seg += 1 }
            let a = waypoints[seg], b = waypoints[seg + 1]
            let span = Double(b.tMs - a.tMs)
            let t = span > 0 ? Double(s.tMs - a.tMs) / span : 0
            let p = Point2(a.position.x + (b.position.x - a.position.x) * t,
                           a.position.y + (b.position.y - a.position.y) * t)
            if add(position: p, feature: s.feature) { used += 1 }
        }
        return used
    }

    /// 有足够样本的格子数。
    public func validCells(minSamples: Int = 5) -> Int { counts.reduce(0) { $0 + ($1 >= minSamples ? 1 : 0) } }
    public var totalCells: Int { cols * rows }

    /// 生成地图。样本不足的格子用周围有效格子反距离加权补齐（半径内），补出来的格子标准差放大。
    /// 空格子怎么补：反距离加权，或高斯过程（局部，最近 12 个有数据的格子）
    public enum FillMethod: String { case idw, gp }
    public var fillMethod: FillMethod = MagneticFieldBuilder.defaultFillMethod
    /// 高斯过程的相关长度（cm）：磁场在多远内是相关的
    public var gpLengthCm = MagneticFieldBuilder.defaultGPLengthCm
    /// 评估 / 实验用的全局默认（hpass-eval 的命令行开关改它们；产品不改）
    nonisolated(unsafe) public static var defaultFillMethod: FillMethod = .gp
    nonisolated(unsafe) public static var defaultGPLengthCm = 100.0
    nonisolated(unsafe) public static var defaultFillRadiusCm = 150.0

    public func build(minSamples: Int = 5, fillRadiusCm: Double? = nil, sigmaFloorUT: Double = 0.5) -> MagneticFieldMap {
        let fillRadiusCm = fillRadiusCm ?? Self.defaultFillRadiusCm
        var cells = [MagneticFeature?](repeating: nil, count: cols * rows)
        var sigmas = [MagneticFeature?](repeating: nil, count: cols * rows)
        func sigma(_ k: Int, _ c: Int) -> Double {
            let n = counts[k]
            return max(n > 1 ? (m2s[k * 3 + c] / Double(n - 1)).squareRoot() : 0, sigmaFloorUT)
        }
        for k in 0..<counts.count where counts[k] >= minSamples {
            cells[k] = MagneticFeature(total: means[k * 3], vertical: means[k * 3 + 1], horizontal: means[k * 3 + 2])
            sigmas[k] = MagneticFeature(total: sigma(k, 0), vertical: sigma(k, 1), horizontal: sigma(k, 2))
        }
        let reach = Int((fillRadiusCm / cellCm).rounded(.up))
        let original = cells
        let originalSig = sigmas
        if fillMethod == .gp {
            gpFill(&cells, &sigmas, original: original, originalSig: originalSig, reach: reach, radius: fillRadiusCm)
            return MagneticFieldMap(widthCm: widthCm, heightCm: heightCm, cellCm: cellCm, cells: cells, sigmas: sigmas)
        }
        for j in 0..<rows {
            for i in 0..<cols where original[j * cols + i] == nil {
                var wsum = 0.0
                var dmin = Double.infinity
                var m = MagneticFeature(total: 0, vertical: 0, horizontal: 0)
                var s = MagneticFeature(total: 0, vertical: 0, horizontal: 0)
                for dj in -reach...reach {
                    for di in -reach...reach {
                        let ii = i + di, jj = j + dj
                        guard ii >= 0, ii < cols, jj >= 0, jj < rows, let nm = original[jj * cols + ii] else { continue }
                        let d = Double(di * di + dj * dj).squareRoot() * cellCm
                        guard d > 0, d <= fillRadiusCm else { continue }
                        let w = 1 / (d * d)
                        dmin = min(dmin, d)
                        m = m + nm * w
                        s = s + originalSig[jj * cols + ii]! * w
                        wsum += w
                    }
                }
                if wsum > 0 {
                    cells[j * cols + i] = m * (1 / wsum)
                    // 补出来的格子不太可信，离真实数据越远越不可信：50 cm 处放大 1.5 倍，150 cm 处 2.5 倍
                    sigmas[j * cols + i] = s * ((1 + dmin / 100) / wsum)
                }
            }
        }
        return MagneticFieldMap(widthCm: widthCm, heightCm: heightCm, cellCm: cellCm, cells: cells, sigmas: sigmas)
    }

    /// 局部高斯过程补空格：取半径内最近的至多 12 个有数据格，平方指数核，减去局部均值后做回归；
    /// 预测方差直接加到这格的标准差上（离数据越远越不确定，自然比反距离的经验放大更合理）。
    private func gpFill(_ cells: inout [MagneticFeature?], _ sigmas: inout [MagneticFeature?],
                        original: [MagneticFeature?], originalSig: [MagneticFeature?], reach: Int, radius: Double) {
        let l2 = 2 * gpLengthCm * gpLengthCm
        for j in 0..<rows {
            for i in 0..<cols where original[j * cols + i] == nil {
                var nb: [(Double, Double, MagneticFeature, MagneticFeature)] = []   // dx, dy, 值, 标准差
                for dj in -reach...reach {
                    for di in -reach...reach {
                        let ii = i + di, jj = j + dj
                        guard ii >= 0, ii < cols, jj >= 0, jj < rows, let v = original[jj * cols + ii] else { continue }
                        let dx = Double(di) * cellCm, dy = Double(dj) * cellCm
                        guard dx * dx + dy * dy <= radius * radius else { continue }
                        nb.append((dx, dy, v, originalSig[jj * cols + ii]!))
                    }
                }
                guard !nb.isEmpty else { continue }
                if nb.count > 12 { nb = Array(nb.sorted { $0.0 * $0.0 + $0.1 * $0.1 < $1.0 * $1.0 + $1.1 * $1.1 }.prefix(12)) }
                let n = nb.count
                // 局部均值和方差（信号方差 σf² 用邻居的离散程度，至少 1 µT²）
                var mean = MagneticFeature(total: 0, vertical: 0, horizontal: 0)
                for x in nb { mean = mean + x.2 * (1 / Double(n)) }
                var varSum = 0.0
                for x in nb { let d = x.2 - mean; varSum += (d.total * d.total + d.vertical * d.vertical + d.horizontal * d.horizontal) / 3 }
                let sf2 = max(varSum / Double(n), 1)
                // K + σn² I
                var K = [Double](repeating: 0, count: n * n)
                for a in 0..<n {
                    for b in 0..<n {
                        let dx = nb[a].0 - nb[b].0, dy = nb[a].1 - nb[b].1
                        K[a * n + b] = sf2 * exp(-(dx * dx + dy * dy) / l2)
                    }
                    let s = nb[a].3
                    K[a * n + a] += max((s.total * s.total + s.vertical * s.vertical + s.horizontal * s.horizontal) / 3, 0.25)
                }
                var ks = [Double](repeating: 0, count: n)
                for a in 0..<n { ks[a] = sf2 * exp(-(nb[a].0 * nb[a].0 + nb[a].1 * nb[a].1) / l2) }
                guard let L = Self.cholesky(K, n) else { continue }
                let alpha = Self.cholSolve(L, n, ks)              // (K)^-1 k*
                var pred = mean
                for a in 0..<n { pred = pred + (nb[a].2 - mean) * alpha[a] }
                var v = sf2
                for a in 0..<n { v -= ks[a] * alpha[a] }
                let sd = max(v, 0).squareRoot()
                // 邻居的观测噪声也带上（取平均）
                var sAvg = MagneticFeature(total: 0, vertical: 0, horizontal: 0)
                for x in nb { sAvg = sAvg + x.3 * (1 / Double(n)) }
                cells[j * cols + i] = pred
                sigmas[j * cols + i] = MagneticFeature(total: (sAvg.total * sAvg.total + sd * sd).squareRoot(),
                                                       vertical: (sAvg.vertical * sAvg.vertical + sd * sd).squareRoot(),
                                                       horizontal: (sAvg.horizontal * sAvg.horizontal + sd * sd).squareRoot())
            }
        }
    }

    static func cholesky(_ A: [Double], _ n: Int) -> [Double]? {
        var L = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var s = A[i * n + j]
                for k in 0..<j { s -= L[i * n + k] * L[j * n + k] }
                if i == j {
                    guard s > 1e-12 else { return nil }
                    L[i * n + i] = s.squareRoot()
                } else {
                    L[i * n + j] = s / L[j * n + j]
                }
            }
        }
        return L
    }

    static func cholSolve(_ L: [Double], _ n: Int, _ b: [Double]) -> [Double] {
        var y = b
        for i in 0..<n { for k in 0..<i { y[i] -= L[i * n + k] * y[k] }; y[i] /= L[i * n + i] }
        var x = y
        for i in stride(from: n - 1, through: 0, by: -1) {
            for k in (i + 1)..<n { x[i] -= L[k * n + i] * x[k] }
            x[i] /= L[i * n + i]
        }
        return x
    }
}

extension MagneticFieldMap {
    /// 写回地图 JSON 的 `magField` 节点（与 `StoreDataLoader.loadMagneticField` 对应）。
    public func jsonObject() -> [String: Any] {
        func enc(_ a: [MagneticFeature?]) -> [Any] {
            a.map { f in
                guard let f else { return NSNull() as Any }
                return [round3(f.total), round3(f.vertical), round3(f.horizontal)] as [Double]
            }
        }
        var o: [String: Any] = ["cellCm": cellCm, "cols": cols, "rows": rows, "cells": enc(cells), "sigma": enc(sigmas)]
        if let t = trackingTemperature { o["trackingTemperature"] = (t * 100).rounded() / 100 }
        return o
    }

    private func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}

/// 一张地图的建图累积状态：磁场每格统计 + 蓝牙指纹累积 + 已经加进去的会话。
/// 增量建图时存盘，新会话只往上追加；旧会话删掉也不影响地图。
public struct MapBuildState: Codable {
    public var field: MagneticFieldBuilder.Snapshot
    public var ble: BLEFingerprintBuilder.State
    public var sessions: [String]

    public init(field: MagneticFieldBuilder.Snapshot, ble: BLEFingerprintBuilder.State, sessions: [String]) {
        self.field = field; self.ble = ble; self.sessions = sessions
    }
}

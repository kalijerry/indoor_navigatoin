import Foundation

/// 地图朝向（地图「上方」对应的罗盘方位）：从建图会话自动估。
///
/// 采集时手机朝前拿着走，手机罗盘方向 ≈ 行进方向；对齐好的轨迹给出同一时刻在地图上的行进方向。
/// 两者之差就是地图上方的方位。逐会话取圆周中位，再在会话之间取中位（轨迹偏航的会话会差很多，自然被排除）。
/// 实测某场地：三个正常会话 313° / 319° / 323°，偏航的那个 26°。
public enum MapBearingEstimator {
    /// heading.csv：t_ms,magnetic_deg,true_deg,…（用 true_deg）
    public static func loadHeadings(_ dir: URL) -> [(tMs: Int64, deg: Double)] {
        guard let t = try? String(contentsOf: dir.appendingPathComponent("heading.csv"), encoding: .utf8) else { return [] }
        return t.split(whereSeparator: \.isNewline).dropFirst().compactMap { l in
            let c = l.split(separator: ",")
            guard c.count >= 3, let t = Int64(c[0]), let d = Double(c[2]) else { return nil }
            return (t, d)
        }
    }

    /// 一个会话：返回（方位，中位偏差，段数）；有效段太少返回 nil
    public static func estimate(track: [(tMs: Int64, p: Point2)], headings: [(tMs: Int64, deg: Double)]) -> (deg: Double, devDeg: Double, n: Int)? {
        guard track.count > 20, !headings.isEmpty else { return nil }
        let hs = headings.sorted { $0.tMs < $1.tMs }
        var vals: [Double] = []
        var j = 0
        for k in stride(from: 10, to: track.count, by: 5) {
            let d = track[k].p - track[k - 10].p
            guard d.length > 80 else { continue }
            let t = track[k].tMs
            while j + 1 < hs.count && hs[j + 1].tMs <= t { j += 1 }
            let h = (j + 1 < hs.count && abs(hs[j + 1].tMs - t) < abs(hs[j].tMs - t)) ? hs[j + 1] : hs[j]
            guard abs(h.tMs - t) < 500 else { continue }
            let alpha = atan2(d.x, -d.y) * 180 / .pi
            vals.append(norm(h.deg - alpha))
        }
        guard vals.count >= 30 else { return nil }
        let m = circularMean(vals)
        let dev = vals.map { angDiff($0, m) }.sorted()
        return (m, dev[dev.count / 2], vals.count)
    }

    /// 用 App 冷启动同一套惯导罗盘估「地图 +y 轴的罗盘方位」（= `FusionConfig.magneticDeclinationDeg`，
    /// App 里 `MagMapStore.declinationDeg` = 地图上方方位 + 180）：惯导（罗盘开、磁偏角 0）跑一遍会话，
    /// 每 ~1 m 的推算位移方向和对齐好的轨迹方向之差，取圆周均值。
    ///
    /// 磁力计用「原始 − App 标定的偏置」（`bias`，App 有偏置存档时实时定位就是这样喂惯导的），没有才用 iOS 校准值。
    /// 房间图（办公室、小店）以前不估朝向（只用 heading.csv 估、而且只给有通道的商场图），冷启动只能整圆猜朝向，
    /// 在磁场平、走直线的地方分不清来回两个方向（Tesco 2026-11-25：估计点和真人反着走）。
    public static func estimateDeclination(session s: SurveySession, track: [(tMs: Int64, p: Point2)],
                                           bias: (Double, Double, Double)?) -> (deg: Double, devDeg: Double, n: Int)? {
        guard track.count > 20, !s.imu.isEmpty else { return nil }
        let f = FusionEngine.live(corridors: [], start: .zero, headingRad: nil, compass: true, declinationDeg: 0)
        let raw = s.raw.sorted { $0.tMs < $1.tMs }
        var out: [(tMs: Int64, p: Point2)] = []
        var j = 0
        for var x in s.imu.sorted(by: { $0.tMs < $1.tMs }) {
            if let b = bias, !raw.isEmpty {
                while j + 1 < raw.count && raw[j + 1].tMs <= x.tMs { j += 1 }
                guard abs(raw[j].tMs - x.tMs) <= 30 else { continue }
                x.mx = raw[j].v.0 - b.0; x.my = raw[j].v.1 - b.1; x.mz = raw[j].v.2 - b.2
            }
            if let o = f.process(x) { out.append((o.tMs, o.position)) }
        }
        guard out.count > 20 else { return nil }
        func at(_ t: Int64) -> Point2? {
            var lo = 0, hi = out.count - 1
            guard t >= out[lo].tMs, t <= out[hi].tMs else { return nil }
            while hi - lo > 1 { let m = (lo + hi) / 2; if out[m].tMs <= t { lo = m } else { hi = m } }
            return out[lo].p
        }
        var vals: [Double] = []
        for k in stride(from: 10, to: track.count, by: 5) {
            let d = track[k].p - track[k - 10].p
            guard d.length > 80, let e1 = at(track[k].tMs), let e0 = at(track[k - 10].tMs) else { continue }
            let e = e1 - e0
            guard e.length > 50 else { continue }
            vals.append(norm((atan2(d.x, d.y) - atan2(e.x, e.y)) * 180 / .pi))
        }
        guard vals.count >= 30 else { return nil }
        let m = circularMean(vals)
        let dev = vals.map { angDiff($0, m) }.sorted()
        return (m, dev[dev.count / 2], vals.count)
    }

    /// 惯导罗盘估的（`estimateDeclination`）会话能接受的中位偏差（°）。罗盘稳的场地才给朝向：
    /// Tesco（2026-11-25）6°，冷启动用罗盘后留一法 6.4 → 3.1 m；办公室 11～21°（各会话估的朝向差 37°），
    /// 用罗盘时冷启动有的会话变差（2.5 → 3.4 m），整体不变，所以不给。只在这两个场地上量过，是经验值
    public static let roomMaxDevDeg = 10.0

    /// 多个会话：中位偏差 ≤ maxDevDeg 的会话里，取和其余会话最一致的那一组的圆周均值
    public static func combine(_ xs: [(deg: Double, devDeg: Double, n: Int)], maxDevDeg: Double = 12, agreeDeg: Double = 20) -> Double? {
        let good = xs.filter { $0.devDeg <= maxDevDeg }
        guard !good.isEmpty else { return nil }
        // 找支持者最多的一个，再对它的支持者求均值
        let best = good.max { a, b in
            good.filter { angDiff($0.deg, a.deg) <= agreeDeg }.reduce(0) { $0 + $1.n } < good.filter { angDiff($0.deg, b.deg) <= agreeDeg }.reduce(0) { $0 + $1.n }
        }!
        let sup = good.filter { angDiff($0.deg, best.deg) <= agreeDeg }
        var sx = 0.0, cx = 0.0
        for s in sup { sx += Double(s.n) * sin(s.deg * .pi / 180); cx += Double(s.n) * cos(s.deg * .pi / 180) }
        return norm(atan2(sx, cx) * 180 / .pi)
    }

    static func norm(_ d: Double) -> Double { let r = d.truncatingRemainder(dividingBy: 360); return r < 0 ? r + 360 : r }
    static func angDiff(_ a: Double, _ b: Double) -> Double { abs(norm(a - b + 180) - 180) }
    static func circularMean(_ v: [Double]) -> Double {
        norm(atan2(v.reduce(0) { $0 + sin($1 * .pi / 180) }, v.reduce(0) { $0 + cos($1 * .pi / 180) }) * 180 / .pi)
    }
}

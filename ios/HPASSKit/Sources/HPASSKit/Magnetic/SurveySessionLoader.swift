import Foundation

/// 从会话目录读「建图采集」需要的文件：imu.csv、mag_raw.csv、arkit_pose.csv、anchors.csv（格式见 docs/data-format.md）。
public enum SurveySessionLoader {

    public enum LoadError: Error, CustomStringConvertible {
        case missing(String)
        public var description: String {
            switch self { case .missing(let f): return "会话里缺少 \(f)" }
        }
    }

    /// 是不是建图采集会话（有 ARKit 位姿和锚点）。
    public static func isSurvey(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("arkit_pose.csv").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("anchors.csv").path)
    }

    /// 会话录制时地图的累计原点偏移（meta.json 的 `map_origin_offset_cm`，没有当 [0, 0]）
    public static func originOffset(_ dir: URL) -> Point2 {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let o = m["map_origin_offset_cm"] as? [Any], o.count >= 2,
              let x = MapGeometry.num(o[0]), let y = MapGeometry.num(o[1]) else { return .zero }
        return Point2(x, y)
    }

    /// 会话里的地图坐标要加多少才是地图现在的坐标（地图当前偏移 − 录制时偏移）
    public static func mapShift(_ dir: URL, mapOriginOffsetCm: Point2) -> Point2 {
        mapOriginOffsetCm - originOffset(dir)
    }

    /// requireAnchors = false：实时定位记录没有 anchors.csv
    /// mapOriginOffsetCm：地图现在的累计原点偏移（`StoreMap.originOffsetCm`）；和会话录制时不同时，锚点的地图坐标按差值平移，
    /// AR 坐标不动
    public static func load(_ dir: URL, requireAnchors: Bool = true, mapOriginOffsetCm: Point2 = .zero) throws -> SurveySession {
        let shift = mapShift(dir, mapOriginOffsetCm: mapOriginOffsetCm)
        func rows(_ name: String, required: Bool = true) throws -> [[Substring]] {
            let url = dir.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                if required { throw LoadError.missing(name) }
                return []
            }
            return text.split(separator: "\n").dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false) }
        }
        // 格式 v4 的重力 / 四元数列有就读（IMUSample.fromCSV），v3 照旧只有前 10 列
        let imu = try rows("imu.csv").compactMap { IMUSample.fromCSV($0) }
        let raw = try rows("mag_raw.csv", required: false).compactMap { r -> (tMs: Int64, v: (Double, Double, Double))? in
            guard r.count >= 4, let t = Int64(r[0]), let x = Double(r[1]), let y = Double(r[2]), let z = Double(r[3]) else { return nil }
            return (t, (x, y, z))
        }
        var poses = try rows("arkit_pose.csv").compactMap { r -> SurveySession.Pose? in
            guard r.count >= 9, let t = Int64(r[0]), let x = Double(r[1]), let z = Double(r[3]) else { return nil }
            return SurveySession.Pose(tMs: t, a: Point2(x * 100, z * 100), normal: r[8] == "2")
        }
        let anchors = try rows("anchors.csv", required: requireAnchors).compactMap { r -> SurveySession.Anchor? in
            guard r.count >= 7, let t = Int64(r[0]), let mx = Double(r[2]), let my = Double(r[3]),
                  let ax = Double(r[4]), let az = Double(r[5]) else { return nil }
            return SurveySession.Anchor(tMs: t, kind: String(r[1]), map: Point2(mx, my) + shift, ar: Point2(ax, az),
                                        heading: Double(r[6]))
        }
        // App 0.1.22～0.1.23 的 ARKit 时间戳在手机睡眠后会慢几十秒（ARKitLogger 只在创建时算一次时钟差）：
        // 锚点里记着当时的 AR 坐标，按它把位姿时间对回来，磁场才落在正确位置
        if let off = poseClockOffsetMs(poses: poses, anchors: anchors) {
            poses = poses.map { SurveySession.Pose(tMs: $0.tMs - off, a: $0.a, normal: $0.normal) }
        }
        var session = SurveySession(name: dir.lastPathComponent, imu: imu, raw: raw, poses: poses, anchors: anchors)
        session.qualityDrops = qualityDrops(dir)
        session.appBias = appBias(dir)
        return session
    }

    /// 录制时 App 自己标定的磁力计偏置（µT）：meta.json 的 `mag_bias_ut`（App 0.1.37 起建图会话也写）；
    /// 老会话没有，就从 log.txt 里找「开始录制：<会话名>」之前最近一次「存下本机磁力计偏置（…）：x, y, z µT」
    /// （中间作废过存档就不算）。都没有 = nil（建图退回「原始 − iOS 校准」的中位数）。
    public static func appBias(_ dir: URL) -> (Double, Double, Double)? {
        if let d = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
           let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let b = m["mag_bias_ut"] as? [Any], b.count >= 3,
           let x = MapGeometry.num(b[0]), let y = MapGeometry.num(b[1]), let z = MapGeometry.num(b[2]) {
            return (x, y, z)
        }
        guard let text = try? String(contentsOf: dir.appendingPathComponent("log.txt"), encoding: .utf8) else { return nil }
        return appBias(log: text, session: dir.lastPathComponent)
    }

    static func appBias(log text: String, session: String) -> (Double, Double, Double)? {
        let lines = text.split(separator: "\n").map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains("开始录制：\(session)") }) else { return nil }
        for line in lines[..<start].reversed() {
            if line.contains("偏置存档作废") { return nil }
            guard line.contains("存下本机磁力计偏置"), let r = line.range(of: "）：") else { continue }
            let nums = line[r.upperBound...].replacingOccurrences(of: "µT", with: "")
                .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            return nums.count == 3 ? (nums[0], nums[1], nums[2]) : nil
        }
        return nil
    }

    /// ARKit 位姿时间和锚点（IMU）时间差了多少毫秒：锚点时刻 t 的 AR 坐标应该等于位姿在 t + off 的插值。
    /// 只在差 ≥ 1 秒、对上后锚点误差 ≤ 20 cm、不改时误差 > 50 cm 时返回（正常会话返回 nil）。
    public static func poseClockOffsetMs(poses: [SurveySession.Pose], anchors: [SurveySession.Anchor]) -> Int64? {
        guard poses.count >= 10, anchors.count >= 2 else { return nil }
        let ts = poses.map { $0.tMs }
        func at(_ t: Int64) -> Point2? {
            guard let f = ts.first, let l = ts.last, t >= f, t <= l else { return nil }
            var lo = 0, hi = ts.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if ts[mid] <= t { lo = mid } else { hi = mid }
            }
            let dt = Double(ts[hi] - ts[lo])
            let w = dt > 0 ? Double(t - ts[lo]) / dt : 0
            let a = poses[lo].a, b = poses[hi].a
            return Point2(a.x + (b.x - a.x) * w, a.y + (b.y - a.y) * w)
        }
        func err(_ off: Int64) -> Double? {
            var sum = 0.0, n = 0
            for an in anchors {
                guard let p = at(an.tMs + off) else { continue }
                let dx = p.x - an.ar.x, dy = p.y - an.ar.y
                sum += (dx * dx + dy * dy).squareRoot()
                n += 1
            }
            return n >= 2 ? sum / Double(n) : nil
        }
        if let e0 = err(0), e0 <= 50 { return nil }
        let aMin = anchors.map { $0.tMs }.min()!, aMax = anchors.map { $0.tMs }.max()!
        let lo = ts.first! - aMax, hi = ts.last! - aMin
        guard hi > lo else { return nil }
        var best: (e: Double, off: Int64)?
        var off = lo
        while off <= hi {
            if let e = err(off), best == nil || e < best!.e { best = (e, off) }
            off += 250
        }
        guard var b = best else { return nil }
        var fine = b.off - 250
        while fine <= b.off + 250 {
            if let e = err(fine), e < b.e { b = (e, fine) }
            fine += 10
        }
        guard abs(b.off) >= 1000, b.e <= 20 else { return nil }
        return b.off
    }

    /// 采集时质量打分判为差的时段（quality.json 的 droppedSpansMs；没有 = 旧会话，不丢）
    public static func qualityDrops(_ dir: URL) -> [ClosedRange<Int64>] {
        (CollectionQualityMonitor.Summary.load(dir)?.droppedSpansMs ?? []).compactMap { r in
            r.count >= 2 && r[0] <= r[1] ? r[0]...r[1] : nil
        }
    }

    /// 采集时质量打分判为整个不能用（quality.json 的 kept = false）。返回原因，能用 / 没打分返回 nil
    public static func qualityRejected(_ dir: URL) -> String? {
        guard let q = CollectionQualityMonitor.Summary.load(dir), !q.kept else { return nil }
        return q.reason ?? "采集质量不合格（\(q.score) 分）"
    }
}

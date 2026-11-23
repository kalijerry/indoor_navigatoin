import Foundation

/// 诊断：纯计步推算（不用磁场 / 蓝牙）和参考轨迹逐拍对比，用来把真实 IMU 的推算误差拆成计步数、步长、航向几项
/// （hpass-eval --dr-dump → tools/bench/dr_decompose.py）。惯导引擎和 `.pdrIMU` 回放同一份配置（`SessionEvaluator.replayFusion`），
/// 起点 / 起步朝向的取法也一样（参考轨迹第一个点 + 真值前 1.5 m 方向），量到的就是送进粒子滤波的运动。
public enum DeadReckoningDump {
    public struct Row {
        public var tMs: Int64
        public var position: Point2
        public var headingRad: Double
        public var stepCount: Int
        public var stepLengthM: Double
        public var isMoving: Bool
        public var carryMode: CarryMode
        public var stepK: Double
        /// 参考位置（参考轨迹在这一刻没有点时 nil）
        public var reference: Point2?
    }

    /// 回放一个会话的 IMU，返回参考轨迹开始之后的每一帧惯导输出。
    public static func run(dir: URL, map: StoreMap, carryMotion: Bool) throws -> [Row] {
        let truth = SessionEvaluator.loadTruth(dir)
        let s = try SurveySessionLoader.load(dir, requireAnchors: truth == nil, mapOriginOffsetCm: map.originOffsetCm)
        let ref = truth ?? SurveyMapBuilder(widthCm: map.width, heightCm: map.height, crosses: map.crosses).add(s).track
        guard let r0 = ref.first else { return [] }
        func refAt(_ t: Int64) -> Point2? {
            var lo = 0, hi = ref.count - 1
            guard hi > 0, t >= ref[0].tMs, t <= ref[hi].tMs else { return nil }
            while hi - lo > 1 { let m = (lo + hi) / 2; if ref[m].tMs <= t { lo = m } else { hi = m } }
            return t - ref[lo].tMs > 300 ? nil : ref[lo].p
        }
        let h = SessionEvaluator.truthHeading(ref)
        let f = SessionEvaluator.replayFusion(start: r0.p, headingRad: h ?? 0, carryMotion: carryMotion)
        var seeded = false
        var rows: [Row] = []
        for x in s.imu {
            guard let out = f.process(x), out.tMs >= r0.tMs else { continue }
            if !seeded {
                f.setInitialPosition(r0.p, headingRad: h)
                seeded = true
                continue
            }
            rows.append(Row(tMs: out.tMs, position: out.position, headingRad: out.headingRad, stepCount: out.stepCount,
                            stepLengthM: out.stepLengthM, isMoving: out.isMoving, carryMode: out.carryMode,
                            stepK: f.effectiveStepLengthK, reference: refAt(out.tMs)))
        }
        return rows
    }

    public static let csvHeader = "session,t_ms,x,y,heading_rad,steps,step_len_m,moving,carry_mode,step_k,ref_x,ref_y"

    public static func csvLines(session: String, rows: [Row]) -> [String] {
        rows.map { r in
            let ref = r.reference.map { String(format: "%.1f,%.1f", $0.x, $0.y) } ?? ","
            return "\(session),\(r.tMs)," + String(format: "%.1f,%.1f,%.5f,", r.position.x, r.position.y, r.headingRad)
                + "\(r.stepCount)," + String(format: "%.3f,", r.stepLengthM) + "\(r.isMoving ? 1 : 0),\(r.carryMode.rawValue),"
                + String(format: "%.4f,", r.stepK) + ref
        }
    }
}

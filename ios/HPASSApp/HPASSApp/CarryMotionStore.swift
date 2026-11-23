import Foundation
import HPASSKit

/// 步长 K 在线标定学到的分携带方式比例（HPASSKit StepScaleCalibrator → FusionEngine.onStepScaleLearned），本机存，
/// 下次定位开始时用 FusionEngine.setLearnedStepScales 恢复。线程安全（UserDefaults）。
enum StepScaleStore {
    /// v2：K 只由视觉里程计标定（StepScaleCalibrator.observeVisualOdometry）。v1 存的是旧版粒子步长比例后验学到的 K
    /// （有偏、偏短，跨会话越积越短）：新版不再用后验，摄像头不开就不会再更新，沿用 v1 会把跑偏的 K 永远留住，所以换键不读
    private static let key = "hpass.stepScales.v2"

    static func load() -> [CarryMode: Double] {
        guard let d = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] else { return [:] }
        var out: [CarryMode: Double] = [:]
        for (k, v) in d { if let m = CarryMode(rawValue: k) { out[m] = v } }
        return out
    }

    static func save(mode: CarryMode, scale: Double) {
        var d = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        d[mode.rawValue] = scale
        UserDefaults.standard.set(d, forKey: key)
    }
}

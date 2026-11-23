import Foundation

/// 一次检出的脚步。
struct FusionStepEvent {
    /// 检出时刻（Unix ms）。注意是「峰值下降沿」，相对真实落地滞后约 0.1 s。
    var tMs: Int64
    /// 平滑后的步长（m）。
    var lengthM: Double
    /// 本步加速度动态分量的峰谷差（m/s²），Weinberg 模型的输入。
    var accelRange: Double
}

/// 计步的自适应阈值 / 步频锁参数（`FusionStepDetector.adaptive` 打开时用）。**占位值，待自采 iPhone 数据标定。**
public struct StepDetectorTuning {
    /// 峰值阈值 = clamp(max(peakFactor × σ_dyn(最近 sigmaWindowS 秒), rangeFactor × 最近几步的峰谷差), peakMin, peakMax)。
    /// 幅度大（口袋、摆臂）时阈值跟着抬，脚跟触地的次峰不计成步。
    ///
    /// peakMin 0.7（原来 1.0，沿用固定阈值）：iPhone 看屏走路的步峰小，只有安卓的约 1/3（a_dyn 步峰中位 1.5 vs 4.5 m/s²），
    /// 实测自采 iPhone 步峰的 P2 ≈ 0.80、P5 ≈ 0.93～0.97，下限 1.0 会把慢走 / 端平看屏的步漏掉一截
    /// （办公室慢走采集 19.5% 的时间「走着却没计到步」，推算距离只有真值 0.71）；手拿着站着不动的抖动峰 P90 ≈ 0.64。
    /// 0.7 落在两者之间：办公室「走着没计到步」的时段 19.5% → 2.3%、推算尺度的会话间离散 0.24 → 0.10；安卓（步峰大，阈值由 σ / 峰谷差项决定）不受影响。
    public var peakFactor = 0.5
    public var rangeFactor = 0.35
    public var peakMin = 0.7
    public var peakMax = 2.5
    /// 退出阈值 = exitRatio × 峰值阈值；谷值武装阈值 = −valleyRatio × 峰值阈值（原有 1.0 / 0.6 / −0.6 的比例）。
    public var exitRatio = 0.6
    public var valleyRatio = 0.6
    public var sigmaWindowS = 3.0
    /// 最近几步峰谷差的 EMA 系数；超过 rangeHoldS 秒没有步就清零（停下再走时不被上一段的大幅度卡住）。
    public var rangeAlpha = 0.3
    public var rangeHoldS = 2.0
    /// 步频锁：距上一步不足 cadenceLockRatio × 当前步周期的峰不算步（快走时的双峰）。0 = 不用。
    /// 步周期只用 minPeriodS 以上的间隔估（更短的间隔不是人的步频，是次峰）。
    public var cadenceLockRatio = 0.6
    /// 步频锁只丢间隔短于此（s）的峰：次峰一般在主峰后 0.1～0.35 s。没有这个上限时，慢走（≈1 s/步）或停顿后起步
    /// 把步周期估到 1 s 以上，正常的 0.55 s 步会被一直当次峰丢掉、只数一半（评审）。占位值，待自采 iPhone 双机数据标定
    public var cadenceLockMaxS = 0.45
    public var minPeriodS = 0.35
    /// 步周期 EMA 系数。
    public var periodAlpha = 0.3

    public init() {}
}

/// 步伐检测 + 步长估计 + 运动检测。
///
/// 技术组成：
/// - **去重力加速度模长**：`a_dyn = LPF_fast(|a|) − LPF_slow(LPF_fast(|a|))`。
///   先用快低通压噪声，再减掉慢低通（等效带通），直流的 9.81 自动消掉，
///   而且用模长 |a| 而不是某个轴，所以结果与手机握持姿态无关。
/// - **峰/谷状态机 + 滞回 + 最小间隔**：一步必须「先下冲过谷阈值、再上冲过峰阈值」，
///   并且距上一步不短于 minStepIntervalMs。站立时 a_dyn 远达不到阈值，所以不会误计数。
/// - **Weinberg 步长模型**：`L = k · (a_max − a_min)^(1/4)`（Weinberg 2002），再限幅 + EMA 平滑。
/// - **运动检测**：a_dyn 在 1 s 滑窗内的方差。
/// - **可选（`adaptive`）**：阈值随 a_dyn 的标准差自适应 + 步频锁（见 `StepDetectorTuning`）。关着时和原来完全一样。
///
/// 线程约定：非线程安全，由 FusionEngine 在同一串行队列上驱动。
final class FusionStepDetector {

    // MARK: - 可调常量（每个都注明取值理由）

    /// |a| 快低通时间常数（s）。0.04 s ≈ 4 Hz 截止：
    /// 完整保留 1.5–2.5 Hz 的步伐基频，压掉手抖与传感器高频噪声。
    private let fastTau: Double = 0.04
    /// 慢低通（直流/重力分量）时间常数（s）。1.0 s ≈ 0.16 Hz，远低于最低步频 1.2 Hz，
    /// 对步伐信号的泄漏不到 10%。
    private let slowTau: Double = 1.0

    /// 峰值触发阈值（m/s²）。正常步行竖向加速度峰峰值 2–6 m/s²，
    /// 手持静置的 a_dyn 幅度 < 0.3 m/s²；1.0 取在两者中间，上下都有 3 倍以上裕量。
    private let peakThresh: Double = 1.0
    /// 峰值退出阈值（m/s²）。与 peakThresh 构成 0.4 的滞回带，防止峰顶抖动重复计数。
    private let peakExitThresh: Double = 0.6
    /// 谷值「武装」阈值（m/s²）。一步必须经历一次明显下冲，才算一个完整步伐周期。
    private let valleyThresh: Double = -0.6

    /// Weinberg 系数，单位 m·(m/s²)^(−1/4)。文献常用 0.4–0.5（手持/口袋姿态）。
    /// 0.45 对应峰峰值 4 m/s² 时步长 0.64 m，符合成人常速步行。**这是最需要按人标定的常量。**
    /// 携带模式路径打开时由 FusionEngine 按模式表（`CarryMotionTable`）和在线标定改写。
    var weinbergK: Double = 0.45
    /// 步长下限（m）。小于 0.3 m 基本是原地挪步，不应该推动位置。
    private let minStepLenM: Double = 0.30
    /// 峰谷差下限（m/s²）。低于此值 Weinberg 的四次根不可靠，沿用上一次平滑值。
    private let minRangeForWeinberg: Double = 0.5
    /// 步长 EMA 系数。0.4：跟得上步速变化（2–3 步收敛），又不会被单步噪声带飞。
    private let lenAlpha: Double = 0.4
    /// 还没有有效观测前的默认步长（m）：成人平均步长。
    private let defaultLenM: Double = 0.65

    /// 运动判据：a_dyn 在 1 s 窗内的方差阈值（(m/s²)²）。
    /// 0.2 → σ ≈ 0.45 m/s²；手持静置通常 σ < 0.15，步行时 σ > 1.0。
    private let movingVarThresh: Double = 0.2
    /// 滑窗长度：50 样本 @50 Hz = 1 s，刚好覆盖 1–2 个步伐周期。
    private let windowSize: Int = 50

    /// 自适应阈值 + 步频锁。false = 原有固定阈值（默认）。
    var adaptive = false
    var tuning = StepDetectorTuning()

    // MARK: - 状态

    private var fast: Double = 0
    private var slow: Double = 0
    private var started = false

    private var inPeak = false
    private var armed = false
    private var curMax: Double = 0
    private var curMin: Double = 0

    private var lastStepTMs: Int64 = 0
    private var hasStep = false
    private var smoothedLen: Double = 0.65

    /// 长度等于 windowSize（50）。
    private var window = [Double](repeating: 0, count: 50)
    private var windowIdx = 0
    private var windowFilled = 0

    /// σ 窗按名义 50 Hz 定长（只在 sigmaWindowS 改了时重建）。不能按每个样本自己的 dt 算：
    /// 毫秒时间戳 19/20/21 ms 抖动会让长度在 142～157 之间来回变、每次变都清空窗口（评审）
    private static let nominalHz = 50.0
    private var sigWinS = 3.0
    /// 自适应阈值用的 σ 窗（3 s @ 50 Hz = 150 样本）：环形缓冲 + 运行和。
    private var sigWin = [Double](repeating: 0, count: 150)
    private var sigIdx = 0
    private var sigFilled = 0
    private var sigSum = 0.0
    private var sigSum2 = 0.0
    /// 步周期估计（s）；nil = 还没有两步。
    private(set) var stepPeriodS: Double?
    /// 最近几步峰谷差的 EMA（0 = 没有）。
    private var recentRange: Double = 0
    /// 被步频锁丢掉的峰（诊断 / 测试用）。
    private(set) var cadenceRejects = 0

    /// 最近一次的 a_dyn（调试用）。
    private(set) var lastDyn: Double = 0
    /// 当前生效的峰值阈值（诊断用）。
    private(set) var currentPeakThresh: Double = 1.0

    init() {
        smoothedLen = defaultLenM
    }

    func reset() {
        fast = 0; slow = 0; started = false
        inPeak = false; armed = false
        curMax = 0; curMin = 0
        lastStepTMs = 0; hasStep = false
        smoothedLen = defaultLenM
        window = [Double](repeating: 0, count: windowSize)
        windowIdx = 0; windowFilled = 0
        sigWin = [Double](repeating: 0, count: sigWin.count)
        sigIdx = 0; sigFilled = 0; sigSum = 0; sigSum2 = 0
        stepPeriodS = nil
        recentRange = 0
        cadenceRejects = 0
        lastDyn = 0
        currentPeakThresh = peakThresh
    }

    /// 1 s 窗内 a_dyn 方差是否超过阈值。窗未半满时保守返回 false。
    var isMoving: Bool {
        guard windowFilled >= windowSize / 2 else { return false }
        let n = Double(windowFilled)
        var mean = 0.0
        for i in 0..<windowFilled { mean += window[i] }
        mean /= n
        var v = 0.0
        for i in 0..<windowFilled {
            let d = window[i] - mean
            v += d * d
        }
        v /= n
        return v > movingVarThresh
    }

    /// 推进一个样本；检出脚步时返回事件，否则 nil。
    func update(sample s: IMUSample, dt: Double, minStepIntervalMs: Int64, maxStepLengthM: Double) -> FusionStepEvent? {
        let aNorm = (s.ax * s.ax + s.ay * s.ay + s.az * s.az).squareRoot()
        guard aNorm.isFinite else { return nil }

        if !started {
            fast = aNorm
            slow = aNorm
            started = true
        }
        fast += (aNorm - fast) * FusionMath.lpfAlpha(dt: dt, tau: fastTau)
        slow += (fast - slow) * FusionMath.lpfAlpha(dt: dt, tau: slowTau)
        let dyn = fast - slow
        lastDyn = dyn

        // 运动检测滑窗
        if windowIdx >= 0 && windowIdx < window.count {
            window[windowIdx] = dyn
        }
        windowIdx = (windowIdx + 1) % windowSize
        if windowFilled < windowSize { windowFilled += 1 }

        // 阈值：固定（原有）或随 σ_dyn 自适应
        var peakT = peakThresh, exitT = peakExitThresh, valleyT = valleyThresh
        if adaptive {
            if tuning.sigmaWindowS != sigWinS {
                sigWinS = tuning.sigmaWindowS
                let n = Int(FusionMath.clamp(max(sigWinS, 0.5) * FusionStepDetector.nominalHz, 10, 1000))
                sigWin = [Double](repeating: 0, count: n); sigIdx = 0; sigFilled = 0; sigSum = 0; sigSum2 = 0
            }
            let old = sigWin[sigIdx]
            if sigFilled == sigWin.count { sigSum -= old; sigSum2 -= old * old }
            sigWin[sigIdx] = dyn
            sigSum += dyn; sigSum2 += dyn * dyn
            sigIdx = (sigIdx + 1) % sigWin.count
            if sigFilled < sigWin.count { sigFilled += 1 }
            let m = sigSum / Double(sigFilled)
            let sigma = max(sigSum2 / Double(sigFilled) - m * m, 0).squareRoot()
            if hasStep, Double(s.tMs - lastStepTMs) / 1000 > tuning.rangeHoldS {
                // 停下来了：峰谷差和步周期都重新估（停顿 / 慢起步的长间隔不能把步频锁卡住）
                recentRange = 0
                stepPeriodS = nil
            }
            peakT = FusionMath.clamp(max(tuning.peakFactor * sigma, tuning.rangeFactor * recentRange), tuning.peakMin, tuning.peakMax)
            exitT = tuning.exitRatio * peakT
            valleyT = -tuning.valleyRatio * peakT
        }
        currentPeakThresh = peakT

        // 谷值跟踪 / 武装
        if dyn < curMin { curMin = dyn }
        if dyn <= valleyT { armed = true }

        var event: FusionStepEvent?

        if inPeak {
            if dyn > curMax { curMax = dyn }
            if dyn < exitT {
                // 峰值下降沿：此时 curMax / curMin 已经是本周期的完整峰谷。
                inPeak = false
                let sinceS = hasStep ? Double(s.tMs - lastStepTMs) / 1000 : .infinity
                var intervalOK = !hasStep || (s.tMs - lastStepTMs) >= max(minStepIntervalMs, 0)
                if adaptive, intervalOK, hasStep, let p = stepPeriodS, tuning.cadenceLockRatio > 0,
                   sinceS < tuning.cadenceLockRatio * p, sinceS < tuning.cadenceLockMaxS {
                    intervalOK = false
                    cadenceRejects += 1
                }
                if armed && intervalOK {
                    let range = max(curMax - curMin, 0.0)
                    let raw = range > minRangeForWeinberg ? weinbergK * pow(range, 0.25) : smoothedLen
                    let upper = max(maxStepLengthM, minStepLenM)
                    let clamped = FusionMath.clamp(raw, minStepLenM, upper)
                    smoothedLen = hasStep ? smoothedLen + (clamped - smoothedLen) * lenAlpha : clamped
                    event = FusionStepEvent(tMs: s.tMs, lengthM: smoothedLen, accelRange: range)
                    if adaptive {
                        if hasStep, sinceS.isFinite, sinceS >= tuning.minPeriodS, sinceS <= 1.5 {
                            stepPeriodS = stepPeriodS.map { $0 + (sinceS - $0) * tuning.periodAlpha } ?? sinceS
                        }
                        recentRange = recentRange > 0 ? recentRange + (range - recentRange) * tuning.rangeAlpha : range
                    }
                    lastStepTMs = s.tMs
                    hasStep = true
                }
                armed = false
                curMin = dyn
                curMax = dyn
            }
        } else if dyn > peakT {
            inPeak = true
            curMax = dyn
        }

        return event
    }
}

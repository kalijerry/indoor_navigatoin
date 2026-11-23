import Foundation

/// 步长 K 的在线标定（docs/carry-motion.md）：学到的分携带姿态比例乘在模式表的 K 上（`FusionEngine.applyLearnedStepScale`），
/// App 存在本机、下次定位开始时恢复（StepScaleStore）。App 的实时定位、评估器的 `.pdrIMU` 回放和单元测试的流水线都用这一个类。
/// 只有 `FusionConfig.motion.enabled` 时起作用（分模式 K 只在携带模式路径里有）。
///
/// ## 标定来源：只用无偏的外部参照（视觉里程计）
/// `observeVisualOdometry`：ARKit 跟踪正常、在走路时（可选的摄像头增强、测绘），同一时段惯导推算的净位移和 ARKit 的净位移比，
/// 攒够 `vioBatchCm` 就按比值更新当前携带姿态的 K。ARKit 的尺度误差约 1%，比值是无偏的。
///
/// ## 不再把粒子滤波的步长比例后验写进 K（`learnFromPosterior`，默认关）
/// 原来的做法：收敛后每走 50 m，把粒子步长比例的加权中位数按 alpha 0.5 吸收进 K。实测（hpass-eval --odo-out 的
/// scale_med 和真值净位移比例比）这个后验**有偏、偏短**：墙的信息是单边的——人走到通道尽头才转弯，走过头的粒子撞墙被罚，
/// 走得不够的粒子提前转弯落在空地上不受罚。
/// - 公开 ILC 商场、合成位姿零漂移（步长比例真值恰好 1）：一次回放结束时后验中位数 0.975（−2.5%）；
///   真实安卓计步、K 设成全体会话的平均真值：后验 −4.7%；办公室 iPhone 真值要放大 7%，后验反而往小走（0.98）；
/// - 撞墙原地不动本身不偏（撞墙不扣分时后验 1.000），偏差来自撞墙扣分（−4 还是 −20 一样），去掉墙也没有偏差（但也学不到）；
/// - 后验对真值的响应只有 0.37（每次回放：后验变化 ≈ −0.04 + 0.37 × 真值偏差），每次回放都在上一次学到的 K 上再往短偏一截，
///   跨会话越积越短：公开 ILC 真实安卓计步 116 次回放按时间顺序带着 K（hpass-eval --carry-k），看屏的 K 从 1 一路降到 0.64
///   （真值约 0.91），汇总误差 中位 / P90 / 错定 2.4 m / 7.1 m / 20%（不学）→ 3.1 m / 8.4 m / 28%（学）；
///   自采 iPhone 商场 8 次学到的 K（bag 0.94、upright 0.96）带到办公室（同一台手机），办公室留一法（10 个种子）
///   中位 103 → 114 cm、P90 233 → 247 cm（真值要的是放大约 7%）。
/// 计步器（CMPedometer）的距离也不当参照：自采 iPhone 室内正常步频（≥ 1.6 Hz）时比 ARKit 长约 11%，慢走时只有 0.2～0.9。
/// 所以默认只用视觉里程计标定；`learnFromPosterior` 只留给评估对照（hpass-eval --posterior-k）。
public final class StepScaleCalibrator {
    // MARK: 粒子滤波后验（默认关，见上）

    /// 把粒子步长比例的后验写进 K（原有做法）。默认 false：后验被墙的单边信息压短，跨会话越积越短
    public var learnFromPosterior = false
    /// 每稳定跟踪这么远（cm）吸收一次
    public var everyCm = 5000.0
    /// 粒子步长比例的加权标准差超过这个就不吸收（粒子还没对步长达成一致）
    public var maxSigma = 0.08
    /// 每次只吸收这么大一部分（`applyLearnedStepScale` 的 alpha）
    public var alpha = 0.5
    /// 吸收过几次（诊断；后验和视觉里程计两种来源合计）
    public private(set) var absorbed = 0
    private var walkedCm = 0.0

    // MARK: 视觉里程计标定

    /// 一个窗口：ARKit 净位移到这么远（cm）就收一次（短于这个的窗口里转弯、停顿占比太大，净位移比不准）
    public var vioWindowNetCm = 500.0
    /// 窗口最长（ms）：这么久还没走出 `vioWindowNetCm` 净位移（站着、来回走、慢走）就丢掉重开
    public var vioWindowMaxMs: Int64 = 8000
    /// 两次观测间隔超过这个（ms）就当 ARKit 断过，窗口重开
    public var vioMaxGapMs: Int64 = 1500
    /// 攒够这么多 ARKit 净位移（cm）更新一次 K
    public var vioBatchCm = 2000.0
    /// 每次更新吸收比值的这么大一部分（K × (1 + (比值 − 1) × alpha)）：同一个人同一种拿法每次走路步长也会差约 5%，
    /// 学到的 K 是最近几十米的平均，不追单段
    public var vioAlpha = 0.5
    /// 单个窗口的比值（ARKit / 惯导净位移）超出这个范围（ARKit 重定位跳变、计步大段漏步 / 多步、惯导没在推）就整窗不要：
    /// K 管的是「检出的每一步多长」，漏步不该算进步长。范围同 K 的限幅量级（模式表 K 的 0.6～1.7 倍）
    public var vioRatioRange: ClosedRange<Double> = 0.6...1.6
    /// 视觉里程计标定更新过几次（诊断）
    public private(set) var vioUpdates = 0
    /// 最近一次视觉里程计批次的比值（ARKit / 惯导，诊断）
    public private(set) var lastVIORatio: Double?

    /// 视觉里程计标定只给这些携带姿态学 K（ARKit 能正常跟踪 = 手机拿在手里、摄像头朝前）
    public static let vioModes: Set<CarryMode> = [.texting, .upright]

    private struct VIOWindow { var tMs: Int64; var ar: Point2; var pdr: Point2; var mode: CarryMode }
    private var vioWin: VIOWindow?
    private var vioLastT: Int64?
    private var vioAccAR = 0.0
    private var vioAccPDR = 0.0
    private var vioAccMode: CarryMode?

    public init() {}

    public func reset() {
        walkedCm = 0
        vioWin = nil
        vioLastT = nil
        vioAccAR = 0
        vioAccPDR = 0
        vioAccMode = nil
    }

    /// 每送一次运动增量调一次（粒子滤波后验来源，`learnFromPosterior` 关着时什么都不做）。返回这次吸收进 K 的系数（没吸收返回 nil）。
    @discardableResult
    public func step(deltaCm: Double, engine: FusionEngine, localizer: MagneticLocalizer) -> Double? {
        guard learnFromPosterior, engine.config.motion.enabled, localizer.isConverged, !localizer.lostSuppressed,
              engine.activeCarryMode.isCarryPosture, deltaCm.isFinite else {
            walkedCm = 0
            return nil
        }
        walkedCm += max(deltaCm, 0)
        guard walkedCm >= everyCm else { return nil }
        walkedCm = 0
        let st = localizer.scaleStatistics()
        guard st.sigma <= maxSigma else { return nil }
        let f = engine.applyLearnedStepScale(st.median, for: engine.activeCarryMode, alpha: alpha)
        guard abs(f - 1) > 1e-9 else { return nil }
        localizer.absorbStepScale(f)
        absorbed += 1
        return f
    }

    /// 视觉里程计标定：每个 ARKit 位姿（或每个惯导输出时刻配上最新的 ARKit 位姿）调一次。
    /// - ar: ARKit 水平面位置（cm，ARKit 自己的坐标系）；trackingNormal: ARKit 跟踪状态正常；
    /// - pdr: 同一时刻惯导引擎输出的推算位置（cm，`FusionOutput.position`；只用差）。
    /// 只在手持看屏 / 竖持（`vioModes`）下、一个窗口内携带姿态没变时收。ARKit 跟踪正常说明摄像头看得见场景，
    /// 这时分类器报口袋 / 包里 / 摆臂是误判；拿手持行走学到的 K 写进这些模式，真放进口袋时就用错了。
    /// 粒子的步长比例不动（K 更准了，粒子围着 1 的残差先验照旧）。
    /// 返回这次更新进 K 的系数（没更新返回 nil）。
    @discardableResult
    public func observeVisualOdometry(tMs: Int64, ar: Point2, trackingNormal: Bool, pdr: Point2, engine: FusionEngine) -> Double? {
        let mode = engine.activeCarryMode
        defer { vioLastT = tMs }
        // 惯导输出被投影进通道（没有磁场图时的纯推算）时位移被剪过，不能拿来比
        guard engine.config.motion.enabled, !engine.config.useCorridorConstraint, trackingNormal, Self.vioModes.contains(mode),
              ar.x.isFinite, ar.y.isFinite, pdr.x.isFinite, pdr.y.isFinite else {
            vioWin = nil
            return nil
        }
        if let last = vioLastT, tMs - last > vioMaxGapMs { vioWin = nil }
        if vioAccMode != mode {
            // 换了携带姿态：之前攒的属于另一个 K，丢掉
            vioAccMode = mode
            vioAccAR = 0
            vioAccPDR = 0
        }
        guard let w = vioWin, w.mode == mode else {
            vioWin = VIOWindow(tMs: tMs, ar: ar, pdr: pdr, mode: mode)
            return nil
        }
        let netAR = ar.distance(to: w.ar)
        if netAR >= vioWindowNetCm {
            // 单个窗口的比值离谱（计步大段漏步 / 惯导没在推、ARKit 跳变）不是步长的问题，整窗不要
            let netPDR = pdr.distance(to: w.pdr)
            if tMs - w.tMs <= vioWindowMaxMs, netPDR > 0, vioRatioRange.contains(netAR / netPDR) {
                vioAccAR += netAR
                vioAccPDR += netPDR
            }
            vioWin = VIOWindow(tMs: tMs, ar: ar, pdr: pdr, mode: mode)
        } else if tMs - w.tMs > vioWindowMaxMs {
            vioWin = VIOWindow(tMs: tMs, ar: ar, pdr: pdr, mode: mode)
        }
        guard vioAccAR >= vioBatchCm, vioAccPDR > 0 else { return nil }
        let r = vioAccAR / vioAccPDR
        vioAccAR = 0
        vioAccPDR = 0
        lastVIORatio = r
        let f = engine.applyLearnedStepScale(r, for: mode, alpha: vioAlpha)
        guard abs(f - 1) > 1e-9 else { return nil }
        vioUpdates += 1
        absorbed += 1
        // 窗口起点的惯导位置是按旧 K 推的：重开，下一个窗口全按新 K
        vioWin = nil
        return f
    }
}

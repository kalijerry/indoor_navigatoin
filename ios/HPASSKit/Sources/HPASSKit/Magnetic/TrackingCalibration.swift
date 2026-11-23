import Foundation

/// 每个粒子自己估偏移的地磁似然（`MagneticConfig.particleOffsetFilter`）的一个分量。滤波器和地图标定（`TrackingCalibration`）共用，
/// 保证标定量的就是滤波器用的那个似然。
///
/// 模型：残差 r = 读数 − 地图 = 偏移 b + 白噪声，b 沿路随机游走。`priorVar` = 预测后的偏移方差 P + q，
/// 新息 ν = r − b̂，方差 S = P + q + R + 格子方差；返回 t4(ν² / S)（ν = 4，未乘特征权重 / 温度），
/// 并就地用卡尔曼增益更新 b̂（|ν| 截到 3σ：离群读数只按 3σ 拉偏移）。
enum ParticleOffsetModel {
    @inline(__always)
    static func component(residual r: Double, offset b: inout Double, priorVar pm: Double, whiteVar wv: Double,
                          cellSigma s: Double) -> Double {
        let sv = pm + wv + s * s
        let v = r - b
        let c = 3 * sv.squareRoot()
        b += pm / sv * min(max(v, -c), c)
        return -2.5 * log(1 + v * v / sv / 4)
    }

    /// 共用方差的卡尔曼更新（只按白噪声 R，不含各处的格子方差）
    @inline(__always)
    static func posterior(priorVar pm: Double, whiteVar wv: Double) -> Double { pm * wv / (pm + wv) }
}

/// 地磁跟踪似然的地图级标定：这张图上「每个粒子自己估偏移」的似然该除多大的温度（`MagneticFieldMap.trackingTemperature`）。
///
/// 为什么要按图标定：同一个似然在不同的图上可信度差几十倍。量过（tools/bench/mag_info.py，参考位置上的读数 vs 地图）：
/// 合成小场地（地图 = 真值场）把真值路径平移 1 m，8 m 一段的对数似然比平均十几 nat、几乎从不反向；
/// 公开商场（真值是稀疏路标点线性插值）、自采门店平移 0.5～3 m 残差几乎不变（没有米级信息），自采办公室在两者之间。
/// 固定一个温度，要么在好图上白白丢掉信息（原来的跟踪档：合成场地上只用到约百分之一），要么在差图上被噪声带偏（公开商场变差）。
///
/// 标定量（错设模型的「方差 / 均值」一致性，Godambe 式的幅度校正）：留出的会话沿它自己的参考轨迹每 50 cm 一个读数，
/// 和用其余会话建的图比；参考路径 vs 平移 d 的路径（d = 0.5 / 1 / 2 m，四个方向），每 8 m 一个窗口（每 2 m 滑一次）
/// 算对数似然比 LLR（似然同滤波器，不除温度）。模型对时（小差别的高斯近似）LLR 的方差 = 2 × 均值；
/// 实测方差大得多就说明似然过度自信，T*_d = Var / (2 · 均值)，取各个 d 里最大的（粒子云里各种距离的假设都有，按最难的那个折）。
/// 均值用单侧 95% 下界（按 32 m 一段分批算标准误，段内窗口高度相关）：没有米级信息的图上均值≈0，
/// 碰巧偏正一点就会算出一个小温度（比如公开商场：均值 0.02 nat、标准误 0.04 时 T 从 8 到无穷都可能），按下界算就稳了。
/// 下界 ≤ 0（参考路径不比平移的明显好）或窗口太少 → 不标定（nil）。
public enum TrackingCalibration {
    public struct Sample {
        public var feature: MagneticFeature
        public var reference: Point2
        public init(feature: MagneticFeature, reference: Point2) {
            self.feature = feature
            self.reference = reference
        }
    }

    public struct Result: Codable {
        /// 标定出的温度（≥ 1）
        public var temperature: Double
        /// 每个平移距离：窗口数、平均 LLR、该距离要的温度
        public var perDistance: [Distance]
        public struct Distance: Codable {
            public var distanceCm: Double
            public var windows: Int
            public var meanLLR: Double
            /// 平均 LLR 的单侧 95% 下界（温度按它算）
            public var meanLLRLower: Double
            public var temperature: Double
        }
    }

    /// 平移距离（cm）
    public static let displacementsCm: [Double] = [50, 100, 200]
    /// 窗口长（次更新，每次 50 cm）和滑动步长；每条序列前面这么多次更新不用（偏移估计还在收敛）
    public static let windowUpdates = 16
    public static let windowStride = 4
    public static let burnInUpdates = 20
    /// 每个平移距离至少要这么多个窗口才标定
    public static let minWindows = 40
    /// 算平均 LLR 的标准误时按这么多次更新（32 m，比残差相关长度 6 m 长得多）分一批，批与批之间当独立
    public static let batchUpdates = 64
    /// 标出的温度超过这个：这张图对跟踪几乎没有可用信息（每次更新的信息不到标称的十分之一），跟踪照旧用原来的似然
    /// （Lab：公开商场 / 自采办公室上粒子偏移似然在温度 12～34 时和原来的似然差不多，见 docs/benchmark.md）
    public static let maxTemperature: Double = 10

    /// 一折：用其余会话建的图 + 留出会话的序列
    public struct Fold {
        /// 不含这些序列所在会话的图
        public var field: MagneticFieldMap
        /// 留出会话沿参考轨迹每 `MagneticConfig.updateDistanceCm` 一个的（读数, 参考位置）
        public var sequences: [[Sample]]
        public init(field: MagneticFieldMap, sequences: [[Sample]]) {
            self.field = field
            self.sequences = sequences
        }
    }

    /// - Parameters:
    ///   - folds: 交叉验证的各折（窗口合在一起统计）
    ///   - config: 用其中的特征权重和 `particleOffsetWalkVarUT2` / `particleOffsetWhiteVarUT2`（和跟踪档同一份）
    public static func calibrate(folds: [Fold], config: MagneticConfig = .tracking(odometry: .pdr)) -> Result? {
        let w = config.featureWeights
        let q = max(config.particleOffsetWalkVarUT2, 0), wv = max(config.particleOffsetWhiteVarUT2, 1e-6)
        // 一条路径的逐次对数似然（没有地图数据的为 nil）
        func logLik(_ field: MagneticFieldMap, _ seq: [Sample], shift: Point2) -> [Double?] {
            var b: (Double, Double, Double)?
            var p = (0.0, 0.0, 0.0)
            var out = [Double?](repeating: nil, count: seq.count)
            for (k, s) in seq.enumerated() {
                guard let m = field.sample(at: s.reference + shift) else { continue }
                let r0 = s.feature.total - m.mean.total, r1 = s.feature.vertical - m.mean.vertical
                let r2 = s.feature.horizontal - m.mean.horizontal
                guard var o = b else { b = (r0, r1, r2); p = (wv, wv, wv); out[k] = 0; continue }
                let pm = (p.0 + q, p.1 + q, p.2 + q)
                out[k] = w.0 * ParticleOffsetModel.component(residual: r0, offset: &o.0, priorVar: pm.0, whiteVar: wv, cellSigma: m.sigma.total)
                    + w.1 * ParticleOffsetModel.component(residual: r1, offset: &o.1, priorVar: pm.1, whiteVar: wv, cellSigma: m.sigma.vertical)
                    + w.2 * ParticleOffsetModel.component(residual: r2, offset: &o.2, priorVar: pm.2, whiteVar: wv, cellSigma: m.sigma.horizontal)
                b = o
                p = (ParticleOffsetModel.posterior(priorVar: pm.0, whiteVar: wv), ParticleOffsetModel.posterior(priorVar: pm.1, whiteVar: wv),
                     ParticleOffsetModel.posterior(priorVar: pm.2, whiteVar: wv))
            }
            return out
        }
        let runs = folds.flatMap { f in f.sequences.filter { $0.count >= burnInUpdates + windowUpdates }.map { (f.field, $0) } }
        let bases = runs.map { logLik($0.0, $0.1, shift: .zero) }
        var per: [Result.Distance] = []
        var worst = 1.0
        for d in displacementsCm {
            var llr: [Double] = []
            var batch: [Int] = []          // 每个窗口属于哪一批（序列 × 32 m 一段；四个方向同一批）
            for (ri, ((field, seq), base)) in zip(runs, bases).enumerated() {
                for a in 0..<4 {
                    let ang = Double(a) * Double.pi / 2
                    let alt = logLik(field, seq, shift: Point2(d * cos(ang), d * sin(ang)))
                    var s0 = burnInUpdates
                    while s0 + windowUpdates <= seq.count {
                        var x = 0.0, ok = true
                        for k in s0..<(s0 + windowUpdates) {
                            guard let u = base[k], let v = alt[k] else { ok = false; break }
                            x += u - v
                        }
                        if ok { llr.append(x); batch.append(ri * 1_000_000 + s0 / batchUpdates) }
                        s0 += windowStride
                    }
                }
            }
            guard llr.count >= minWindows else { return nil }
            let n = Double(llr.count)
            let mean = llr.reduce(0, +) / n
            let v = llr.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
            // 分批的标准误：Var(均值) = Σ_批 (批内和 − 批内个数 × 均值)² / N² × C / (C − 1)
            var dev: [Int: Double] = [:]
            for (x, b) in zip(llr, batch) { dev[b, default: 0] += x - mean }
            let c = Double(dev.count)
            guard c >= 2 else { return nil }
            let se = (dev.values.reduce(0) { $0 + $1 * $1 } / (n * n) * c / (c - 1)).squareRoot()
            let lower = mean - 1.645 * se
            guard lower > 0 else { return nil }
            let t = max(v / (2 * lower), 1)
            per.append(.init(distanceCm: d, windows: llr.count, meanLLR: mean, meanLLRLower: lower, temperature: t))
            worst = max(worst, t)
        }
        return Result(temperature: worst, perDistance: per)
    }
}

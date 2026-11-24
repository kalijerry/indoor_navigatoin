import Foundation

/// 磁场观测的新鲜度门（NAV-005）。
///
/// App 的原始磁力计模式下，磁力计回调把最新特征存起来，IMU 回调每次直接拿「最新的那个」喂给定位器，
/// 不看它是什么时候的：磁力计停了、回调被后台调度拖住、回来时时间戳乱了，旧特征会被一遍遍当成新的磁场证据，
/// 定位器把它们平均进下一次观测更新，粒子被拉向「旧位置的磁场长这样的地方」。
///
/// 这里给每个特征带上时间戳和序号：
/// - `offer`：时间戳不比上一个新（乱序 / 重复）直接丢弃；
/// - `current(at:)`：特征比 IMU 时刻老 `maxAgeMs` 以上（磁力计停了）返回 nil，调用方这一刻就只用计步；
///   也不返回比 IMU 时刻「新」太多的特征（时钟错位）。
/// 磁力计 50 Hz、IMU 100 Hz，正常情况下同一个特征会被相邻的一两个 IMU 样本用到（采样保持），这是正常的；
/// 门只挡超时的。
public struct MagObservationGate {
    public struct Observation: Equatable {
        public var feature: MagneticFeature
        public var tMs: Int64
        public var sequence: Int
    }

    /// 特征最多比 IMU 时刻老多少（ms）
    public var maxAgeMs: Int64
    /// 特征最多比 IMU 时刻新多少（ms）：两路时钟有点抖可以，差太多说明时间戳乱了
    public var maxLeadMs: Int64
    public private(set) var latest: Observation?
    /// 被丢弃的乱序 / 重复观测个数（诊断）
    public private(set) var rejectedOutOfOrder = 0
    /// 因为超时没给出特征的次数（诊断）
    public private(set) var staleCount = 0
    private var seq = 0

    public init(maxAgeMs: Int64 = 100, maxLeadMs: Int64 = 100) {
        self.maxAgeMs = maxAgeMs
        self.maxLeadMs = maxLeadMs
    }

    /// 送一个新特征。时间戳不比上一个新时丢弃，返回 false。
    @discardableResult
    public mutating func offer(_ f: MagneticFeature, tMs: Int64) -> Bool {
        if let l = latest, tMs <= l.tMs {
            rejectedOutOfOrder += 1
            return false
        }
        seq += 1
        latest = Observation(feature: f, tMs: tMs, sequence: seq)
        return true
    }

    /// IMU 时刻 tMs 可用的磁场特征；没有新鲜的返回 nil。
    public mutating func current(at tMs: Int64) -> MagneticFeature? {
        guard let l = latest else { return nil }
        let age = tMs - l.tMs
        guard age <= maxAgeMs, age >= -maxLeadMs else {
            staleCount += 1
            return nil
        }
        return l.feature
    }

    /// 停止 / 重新开始定位时清空
    public mutating func reset() {
        latest = nil
        rejectedOutOfOrder = 0
        staleCount = 0
    }
}

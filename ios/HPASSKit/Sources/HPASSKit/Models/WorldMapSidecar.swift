import Foundation

/// 视觉特征地图（ARWorldMap）旁边的小说明：这张特征地图的 AR 坐标系怎么对应到地图坐标。
///
/// 关键：特征地图只在「它保存时的 AR 坐标系」里有意义。房间扫描时的坐标系 + 地图里的 `arAlign` 是一对；
/// 只有「载入了这张特征地图并且认出了房间」的会话，AR 坐标系才和它一致，这样的会话刷新出来的特征地图
/// 才能沿用同一个 `arAlign`。没认出房间的会话坐标系是另一套，它存的特征地图不能顶替。
/// 云端融合只收 `arAlign` 和地图 JSON 里的 `arAlign` 等价的特征地图（见 tools/cloud_build.py，规则与这里一致）。
public struct WorldMapSidecar: Codable, Equatable {
    public struct Align: Codable, Equatable {
        public var phi: Double
        public var pRefX: Double
        public var pRefY: Double
        public var aRefX: Double
        public var aRefY: Double

        public init(_ t: MapARTransform) {
            phi = t.phi; pRefX = t.pRef.x; pRefY = t.pRef.y; aRefX = t.aRef.x; aRefY = t.aRef.y
        }
        public var transform: MapARTransform {
            MapARTransform(pRef: Point2(pRefX, pRefY), aRef: Point2(aRefX, aRefY), phi: phi)
        }
    }

    public static let fileName = "worldmap.json"

    public var version: Int = 1
    /// 生成时间（Unix 毫秒）
    public var createdMs: Int64
    /// scan = 房间扫描时存的；refreshed = 认出房间后的会话刷新的；stored = 本机已有的原样带上；cloud = 云端包里的
    public var source: String
    public var mapId: String?
    public var arAlign: Align
    /// 特征地图文件大小（字节）
    public var bytes: Int?
    /// 本机用：这份特征地图是否已经随会话传到后台（nil 当作没传）
    public var uploaded: Bool?

    public init(createdMs: Int64, source: String, mapId: String?, arAlign: MapARTransform, bytes: Int? = nil, uploaded: Bool? = nil) {
        self.createdMs = createdMs; self.source = source; self.mapId = mapId
        self.arAlign = Align(arAlign); self.bytes = bytes; self.uploaded = uploaded
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ d: Data) -> WorldMapSidecar? { try? JSONDecoder().decode(WorldMapSidecar.self, from: d) }

    /// 这份特征地图能不能用在 `mapAlign` 这张地图上：两个变换把 AR 平面上几个点映到地图上的位置一致（容差 cm）。
    /// 不直接比 pRef / aRef，因为同一个映射可以有不同的锚点写法。
    public func isCompatible(with mapAlign: MapARTransform, tolCm: Double = 2) -> Bool {
        WorldMapSidecar.equivalent(arAlign.transform, mapAlign, tolCm: tolCm)
    }

    public static func equivalent(_ a: MapARTransform, _ b: MapARTransform, tolCm: Double = 2) -> Bool {
        // 原点和相距 10 m 的两点：位置、旋转都对得上才算等价
        for p in [Point2(0, 0), Point2(1000, 0), Point2(0, 1000)] where a.toMap(p).distance(to: b.toMap(p)) > tolCm { return false }
        return true
    }
}

/// 会话结束时要不要把当前的视觉特征地图存下来（刷新本机的 + 随会话上传），以及大小限制。
public enum WorldMapPolicy {
    /// 超过这个大小在报告里警告
    public static let warnBytes = 8 * 1024 * 1024
    /// 超过这个大小不收（不刷新、不打进包）
    public static let maxBytes = 15 * 1024 * 1024
    /// 会话至少这么久（秒）才刷新：太短的覆盖没增加，还白占上传流量
    public static let minSessionSec = 30.0
    /// 相机落在地图外这么远（cm）以上，认为认错了
    public static let insideMarginCm = 300.0

    public struct Input {
        public var isRoom: Bool
        public var hasAlign: Bool
        /// 本机有这张地图的特征地图
        public var hasStored: Bool
        /// 这次会话启动时载入了它
        public var loadedStored: Bool
        /// 这次会话认出过房间（ARKit 从「重定位中」变成正常）
        public var relocalized: Bool
        /// 此刻跟踪正常
        public var trackingNormal: Bool
        /// ARKit 的建图状态够不够（mapped / extending）
        public var mappedEnough: Bool
        /// 此刻相机换到地图坐标后在地图范围内
        public var insideMap: Bool
        public var durationSec: Double
        /// 本机这份特征地图已经传到后台了
        public var storedUploaded: Bool

        public init(isRoom: Bool, hasAlign: Bool, hasStored: Bool, loadedStored: Bool, relocalized: Bool,
                    trackingNormal: Bool, mappedEnough: Bool, insideMap: Bool, durationSec: Double, storedUploaded: Bool) {
            self.isRoom = isRoom; self.hasAlign = hasAlign; self.hasStored = hasStored; self.loadedStored = loadedStored
            self.relocalized = relocalized; self.trackingNormal = trackingNormal; self.mappedEnough = mappedEnough
            self.insideMap = insideMap; self.durationSec = durationSec; self.storedUploaded = storedUploaded
        }
    }

    public enum Decision: Equatable {
        /// 取当前特征地图，替换本机的并随会话上传
        case refresh
        /// 不刷新，但本机这份还没传过：原样放进会话目录上传一次
        case uploadStored(reason: String)
        case skip(reason: String)
    }

    public static func decide(_ i: Input) -> Decision {
        guard i.isRoom else { return .skip(reason: "不是房间地图") }
        guard i.hasAlign else { return .skip(reason: "地图没有 AR 对齐信息") }
        guard i.hasStored else { return .skip(reason: "本机没有视觉特征地图") }
        func fallback(_ why: String) -> Decision {
            i.storedUploaded ? .skip(reason: why) : .uploadStored(reason: why)
        }
        guard i.loadedStored else { return fallback("这次没载入视觉特征地图") }
        guard i.relocalized else { return fallback("没认出房间（AR 坐标系和特征地图不是同一个），不刷新") }
        guard i.durationSec >= minSessionSec else { return fallback("会话太短（\(Int(i.durationSec)) 秒）") }
        guard i.trackingNormal else { return fallback("结束时 ARKit 跟踪不正常") }
        guard i.mappedEnough else { return fallback("ARKit 特征点还不够（建图状态不足）") }
        guard i.insideMap else { return fallback("结束时相机位置落在地图外，可能认错了") }
        return .refresh
    }

    /// 相机的地图坐标在地图范围（加边距）内
    public static func isInside(_ p: Point2, widthCm: Double, heightCm: Double, marginCm: Double = insideMarginCm) -> Bool {
        p.x >= -marginCm && p.y >= -marginCm && p.x <= widthCm + marginCm && p.y <= heightCm + marginCm
    }

    /// 大小检查：nil = 可以用；否则是不能用的原因
    public static func sizeProblem(_ bytes: Int) -> String? {
        bytes > maxBytes ? String(format: "太大（%.1f MB，上限 %d MB）", Double(bytes) / 1_048_576, maxBytes / 1024 / 1024) : nil
    }
}

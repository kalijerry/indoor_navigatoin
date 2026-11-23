import Foundation

/// 云端地图包：一张地图定位要用的全部东西打成一个压缩文件，客户端拉下来就能用。
///
/// 内容：说明（名字、版本、来源…）+ 场地 / 房间地图 JSON + 磁场图（只存有数据的格，均值和标准差量化成
/// 0.01 µT 的 int16）+ 蓝牙标签位置 + 房间的视觉特征地图（可选）。整体再用 zlib 压缩。
/// 一万多平方米的场地全采满估算：磁场约 350 KB、标签约 300 KB、地图约 50 KB，压缩后 1 MB 以内。
///
/// 格式（压缩前，小端）："HPMP" + u16 版本 + 5 段（u32 长度 + 内容）：说明 JSON、地图 JSON、磁场、蓝牙、视觉特征地图，
/// 后面可选第 6 段：采集涂色（CoveragePaint.serialized，哪里采过，换手机也能接着补采）；
/// 第 7 段：标签位置表原文（CSV：标签 → 通道 / 段 / 层 / 商品条码 / 货架图，找标签用）；
/// 第 8 段：方向图 JSON（DirectionCoverage.File）。旧包没有这几段。
public enum MapPackage {
    public struct Meta: Codable, Equatable {
        public var id: String
        public var name: String
        /// store / room
        public var kind: String
        /// 版本：生成时间（Unix 毫秒），越大越新
        public var version: Int64
        public var source: String?
        public var mapUpBearingDeg: Double?
        public var magSource: String?
        public var fieldCells: Int?
        public var bleTags: Int?
        /// 谁生成的：cloud = 云端（GitHub Actions）融合的正式版本；phone = 手机上生成后手动上传的
        public var origin: String?
        /// 融合用了几个会话
        public var sessions: Int?
        /// 磁场图的跟踪似然标定（`MagneticFieldMap.trackingTemperature`；磁场段的二进制格式不变，放在说明里）
        public var trackingTemperature: Double?

        public init(id: String, name: String, kind: String, version: Int64, source: String? = nil,
                    mapUpBearingDeg: Double? = nil, magSource: String? = nil) {
            self.id = id; self.name = name; self.kind = kind; self.version = version; self.source = source
            self.mapUpBearingDeg = mapUpBearingDeg; self.magSource = magSource
        }
    }

    public struct Contents {
        public var meta: Meta
        public var mapJSON: Data
        public var field: MagneticFieldMap?
        public var ble: BLEFingerprintMap?
        public var worldMap: Data?
        /// 采集涂色（CoveragePaint.serialized）
        public var paint: Data?
        /// 标签位置表 CSV 原文
        public var tagCSV: Data?
        /// 方向图 JSON（DirectionCoverage.File）
        public var direction: Data?
    }

    public enum PackageError: Error, CustomStringConvertible {
        case badFormat(String)
        /// 这个平台没有 zlib 压缩（Foundation 的 NSData.compressed 只在苹果平台有）
        case unsupportedPlatform
        public var description: String {
            switch self {
            case .badFormat(let s): return "地图包格式不对：\(s)"
            case .unsupportedPlatform: return "这个平台不支持地图包压缩（只在苹果平台可用）"
            }
        }
    }

    static let magic = Array("HPMP".utf8)
    static let formatVersion: UInt16 = 1

    // MARK: 打包

    public static func encode(meta m: Meta, mapJSON: Data, field: MagneticFieldMap?, ble: BLEFingerprintMap?,
                              worldMap: Data?, paint: Data? = nil, tagCSV: Data? = nil, direction: Data? = nil) throws -> Data {
        var meta = m
        meta.fieldCells = field?.coveredCells
        meta.trackingTemperature = field?.trackingTemperature
        meta.bleTags = ble?.tags.count
        var out = Data(magic)
        out.append(le(formatVersion))
        func section(_ d: Data) { out.append(le(UInt32(d.count))); out.append(d) }
        section(try JSONEncoder().encode(meta))
        section(mapJSON)
        section(field.map(encodeField) ?? Data())
        section(ble.map(encodeBLE) ?? Data())
        section(worldMap ?? Data())
        section(paint ?? Data())
        section(tagCSV ?? Data())
        section(direction ?? Data())
        return try zlib(out, compress: true)
    }

    /// 苹果平台用 Foundation 的 zlib；其他平台（Windows / Linux 上编译评估工具）不支持地图包。
    static var compressionAvailable: Bool {
        #if canImport(Darwin)
        return true
        #else
        return false
        #endif
    }

    private static func zlib(_ data: Data, compress: Bool) throws -> Data {
        #if canImport(Darwin)
        return compress ? try (data as NSData).compressed(using: .zlib) as Data
                        : try (data as NSData).decompressed(using: .zlib) as Data
        #else
        throw PackageError.unsupportedPlatform
        #endif
    }

    public static func decode(_ compressed: Data) throws -> Contents {
        let d = try zlib(compressed, compress: false)
        var r = Reader(d)
        guard try r.bytes(4) == Data(magic) else { throw PackageError.badFormat("开头不是 HPMP") }
        let v: UInt16 = try r.int()
        guard v == formatVersion else { throw PackageError.badFormat("不认识的版本 \(v)") }
        func section() throws -> Data { let n: UInt32 = try r.int(); return try r.bytes(Int(n)) }
        let meta = try JSONDecoder().decode(Meta.self, from: try section())
        let mapJSON = try section()
        let f = try section(), b = try section(), w = try section()
        let p = r.atEnd ? Data() : try section()
        let e = r.atEnd ? Data() : try section()
        let dc = r.atEnd ? Data() : try section()
        var field = f.isEmpty ? nil : try decodeField(f)
        field?.trackingTemperature = meta.trackingTemperature.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return Contents(meta: meta, mapJSON: mapJSON,
                        field: field,
                        ble: b.isEmpty ? nil : try decodeBLE(b),
                        worldMap: w.isEmpty ? nil : w,
                        paint: p.isEmpty ? nil : p,
                        tagCSV: e.isEmpty ? nil : e,
                        direction: dc.isEmpty ? nil : dc)
    }

    // MARK: 磁场：宽、高、格大小（f32）+ 有数据的格数（u32）+ 每格：下标 u32 + 6 × i16（均值、标准差，单位 0.01 µT）

    static func q(_ v: Double) -> Int16 { Int16(clamping: Int((v * 100).rounded())) }

    static func encodeField(_ f: MagneticFieldMap) -> Data {
        var d = Data()
        d.append(le(Float32(f.widthCm).bitPattern)); d.append(le(Float32(f.heightCm).bitPattern)); d.append(le(Float32(f.cellCm).bitPattern))
        let idx = f.cells.indices.filter { f.cells[$0] != nil && f.sigmas[$0] != nil }
        d.append(le(UInt32(idx.count)))
        for k in idx {
            let m = f.cells[k]!, s = f.sigmas[k]!
            d.append(le(UInt32(k)))
            for v in [m.total, m.vertical, m.horizontal, s.total, s.vertical, s.horizontal] { d.append(le(UInt16(bitPattern: q(v)))) }
        }
        return d
    }

    static func decodeField(_ d: Data) throws -> MagneticFieldMap {
        var r = Reader(d)
        let w = Double(Float32(bitPattern: try r.int())), h = Double(Float32(bitPattern: try r.int()))
        let c = Double(Float32(bitPattern: try r.int()))
        guard w > 0, h > 0, c > 0 else { throw PackageError.badFormat("磁场尺寸") }
        let cols = Int((w / c).rounded(.up)), rows = Int((h / c).rounded(.up))
        var cells = [MagneticFeature?](repeating: nil, count: cols * rows), sig = cells
        let n: UInt32 = try r.int()
        for _ in 0..<n {
            let k = Int(try r.int() as UInt32)
            var v = [Double](repeating: 0, count: 6)
            for i in 0..<6 { v[i] = Double(Int16(bitPattern: try r.int())) / 100 }
            guard k < cells.count else { throw PackageError.badFormat("磁场格子下标越界") }
            cells[k] = MagneticFeature(total: v[0], vertical: v[1], horizontal: v[2])
            sig[k] = MagneticFeature(total: v[3], vertical: v[4], horizontal: v[5])
        }
        return MagneticFieldMap(widthCm: w, heightCm: h, cellCm: c, cells: cells, sigmas: sig)
    }

    // MARK: 蓝牙：标签数 u32 + 每个：编号（u8 长度 + UTF-8）、x、y（f32 cm）、最强信号 i8、样本数 u16
    // 定位只用标签位置（格子指纹太稀，不用，不打包）

    static func encodeBLE(_ b: BLEFingerprintMap) -> Data {
        var d = Data()
        d.append(le(Float32(b.cellCm).bitPattern))
        d.append(le(UInt32(b.tags.count)))
        for (id, t) in b.tags.sorted(by: { $0.key < $1.key }) {
            let s = Data(id.utf8.prefix(255))
            d.append(UInt8(s.count)); d.append(s)
            d.append(le(Float32(t.x).bitPattern)); d.append(le(Float32(t.y).bitPattern))
            d.append(UInt8(bitPattern: Int8(clamping: Int(t.maxRssi.rounded()))))
            d.append(le(UInt16(clamping: t.samples)))
        }
        return d
    }

    static func decodeBLE(_ d: Data) throws -> BLEFingerprintMap {
        var r = Reader(d)
        let cell = Double(Float32(bitPattern: try r.int()))
        let n: UInt32 = try r.int()
        var tags: [String: BLEFingerprintMap.Tag] = [:]
        for _ in 0..<n {
            let len = Int(try r.int() as UInt8)
            guard let id = String(data: try r.bytes(len), encoding: .utf8) else { throw PackageError.badFormat("标签编号") }
            let x = Double(Float32(bitPattern: try r.int())), y = Double(Float32(bitPattern: try r.int()))
            let rssi = Double(Int8(bitPattern: try r.int()))
            let samples = Int(try r.int() as UInt16)
            tags[id] = .init(x: x, y: y, maxRssi: rssi, samples: samples)
        }
        return BLEFingerprintMap(cellCm: cell, cells: [], tags: tags)
    }

    // MARK: 工具

    static func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    struct Reader {
        let d: Data
        var o: Int
        init(_ d: Data) { self.d = d; o = d.startIndex }
        var atEnd: Bool { o >= d.endIndex }
        mutating func bytes(_ n: Int) throws -> Data {
            guard n >= 0, o + n <= d.endIndex else { throw PackageError.badFormat("数据不完整") }
            defer { o += n }
            return d.subdata(in: o..<o + n)
        }
        mutating func int<T: FixedWidthInteger>() throws -> T {
            let b = try bytes(MemoryLayout<T>.size)
            var v: T = 0
            _ = withUnsafeMutableBytes(of: &v) { b.copyBytes(to: $0) }
            return T(littleEndian: v)
        }
    }
}

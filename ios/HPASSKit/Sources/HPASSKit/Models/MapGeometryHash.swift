import Foundation

/// 地图几何指纹（NAV-001）。
///
/// 之前各处缓存用「数量 / id」判断地图有没有变（通道条数、货架数、门墙个数、单元 id），
/// 挪了一面墙、一扇门、一个货架或者改了通道走向但数量不变时，可走区域、房间图、路径规划器、货架射线模型
/// 都会继续用旧几何。这里按**实际坐标**算一个稳定的 64 位哈希（FNV-1a），坐标量化到 0.1 mm，
/// 跨进程 / 跨设备都一样（不用 Swift 的随机化 Hasher）。
public struct MapGeometryHasher {
    private var h: UInt64 = 0xcbf2_9ce4_8422_2325

    public init() {}

    public mutating func add(_ v: UInt64) {
        var x = v
        for _ in 0..<8 {
            h ^= x & 0xff
            h = h &* 0x0000_0100_0000_01b3
            x >>= 8
        }
    }

    public mutating func add(_ v: Int) { add(UInt64(bitPattern: Int64(v))) }

    public mutating func add(_ d: Double) {
        guard d.isFinite else { add(UInt64.max); return }
        // 0.1 mm 量化：浮点的最后一位噪声（读 JSON、平移再平移回来）不算变化
        add(UInt64(bitPattern: Int64((d * 100).rounded())))
    }

    public mutating func add(_ p: Point2) { add(p.x); add(p.y) }

    public mutating func add(_ s: String) {
        add(s.utf8.count)
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01b3 }
    }

    public mutating func add(_ s: String?) {
        if let s { add(1); add(s) } else { add(0) }
    }

    public mutating func add(_ poly: [Point2]) {
        add(poly.count)
        for p in poly { add(p) }
    }

    public var value: UInt64 { h }
    public var hex: String { String(format: "%016llx", h) }
}

extension StoreMap {
    /// 影响**定位和导航**的全部几何的指纹：尺寸、货架（位置 / 尺寸 / 旋转）、通道（端点 / 宽度）、
    /// 地面多边形、单元（id / 类别 / 多边形）、不可走多边形、墙 / 门 / 开口等其他元素、原点平移、AR 变换和坐标系 id。
    /// 任何一项改了（哪怕数量不变）值就变；缓存（可走区域、房间图、规划器、射线模型）应以它为键。
    public var geometryHash: String {
        var g = MapGeometryHasher()
        g.add(width); g.add(height)
        g.add(shelves.count)
        for s in shelves {
            g.add(s.code); g.add(s.x); g.add(s.y); g.add(s.width); g.add(s.height); g.add(s.rotation)
            g.add(s.subsection); g.add(s.heightCm ?? -1)
        }
        g.add(crosses.count)
        for c in crosses { g.add(c.code); g.add(c.a); g.add(c.b); g.add(c.lineWidth) }
        g.add(others.count)
        for o in others { g.add(o.shapeType); g.add(o.x); g.add(o.y); g.add(o.width); g.add(o.height); g.add(o.rotation) }
        g.add(floor.count)
        for p in floor { g.add(p) }
        g.add(units.count)
        for u in units { g.add(u.id); g.add(u.category); g.add(u.polygon) }
        g.add(obstacleFloor.count)
        for p in obstacleFloor { g.add(p) }
        g.add(originOffsetCm)
        if let a = arAlign { g.add(1); g.add(a.pRef); g.add(a.aRef); g.add(a.phi) } else { g.add(0) }
        g.add(frameId)
        return g.hex
    }
}

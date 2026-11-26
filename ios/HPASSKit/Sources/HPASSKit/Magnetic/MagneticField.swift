import Foundation

/// 手动定的点位（地图 JSON 的 `markPoints`），单位 cm。
public struct MarkPoint: Hashable {
    public var id: String
    public var x: Double
    public var y: Double

    public init(id: String, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }

    public var position: Point2 { Point2(x, y) }
}

/// 网格化的地磁场地图：每格存三个特征的均值和标准差。坐标系与场地地图一致（cm，y 向下）。
///
/// JSON 里挂在地图根节点的 `magField` 下，由 `tools/magmap.py` 生成：
/// `{ "cellCm": 50, "cols": 20, "rows": 20, "cells": [[|B|,Bz,Bh] | null, …], "sigma": [[…] | null, …] }`
/// 数组按行优先，下标 = row * cols + col。
public struct MagneticFieldMap {
    public let widthCm: Double
    public let heightCm: Double
    public let cellCm: Double
    public let cols: Int
    public let rows: Int
    let cells: [MagneticFeature?]
    let sigmas: [MagneticFeature?]
    /// 跟踪似然的地图标定（`TrackingCalibration`，建图时用建图会话交叉验证量出）：「每个粒子自己估偏移」的似然在这张图上
    /// 该除的温度。nil = 没标定（老地图 / 会话太少 / 图上没有米级信息），跟踪照旧用原来的似然。
    /// 存在地图 JSON 的 magField.trackingTemperature 和地图包的说明里。
    public var trackingTemperature: Double?

    /// 有数据格子的 |B| 分位数区间（lo、hi 是 0～1）。不到 20 格时 nil。App 用它核对本机磁力计偏置（磁吸附件 / 磁性保护壳）
    public func totalPercentiles(_ lo: Double, _ hi: Double) -> ClosedRange<Double>? {
        let v = cells.compactMap { $0?.total }.sorted()
        guard v.count >= 20 else { return nil }
        func q(_ p: Double) -> Double { v[min(max(Int(Double(v.count - 1) * p + 0.5), 0), v.count - 1)] }
        let a = q(min(lo, hi)), b = q(max(lo, hi))
        return a...b
    }

    public init(widthCm: Double, heightCm: Double, cellCm: Double,
                cells: [MagneticFeature?], sigmas: [MagneticFeature?]) {
        precondition(cellCm > 0 && widthCm > 0 && heightCm > 0)
        self.widthCm = widthCm
        self.heightCm = heightCm
        self.cellCm = cellCm
        self.cols = Int((widthCm / cellCm).rounded(.up))
        self.rows = Int((heightCm / cellCm).rounded(.up))
        precondition(cells.count == cols * rows && sigmas.count == cols * rows,
                     "magField 的格子数与 cols×rows 不一致")
        self.cells = cells
        self.sigmas = sigmas
    }

    /// 有数据的格子数。
    public var coveredCells: Int { cells.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }
    public var totalCells: Int { cols * rows }

    public func contains(_ p: Point2) -> Bool {
        p.x >= 0 && p.x <= widthCm && p.y >= 0 && p.y <= heightCm
    }

    /// 在 p 处做双线性插值（以格子中心为采样点）。周围有效格子的权重不足 0.25 时返回 nil。
    /// 地图在 p 处的 1 m 起伏（µT）：所在格子和 8 个方向 1 m 外的格子三个分量差的 RMS 的平均（至少 2 个方向有数据）。
    /// 衡量「挪 1 m 读数会变多少」：越小磁场越平、地磁越分不出位置。没有数据时 nil。
    /// 有数据区域的边上只有一侧邻居，会显得平一些（4 µT/m 的均匀梯度里最外一圈约 1.9 µT）
    public func localContrast(at p: Point2) -> Double? {
        guard p.x >= 0, p.y >= 0 else { return nil }
        let i = Int(p.x / cellCm), j = Int(p.y / cellCm)
        guard i < cols, j < rows, let f = cells[j * cols + i] else { return nil }
        let n = max(Int((100 / cellCm).rounded()), 1)
        var sum = 0.0, cnt = 0
        for (di, dj) in [(n, 0), (-n, 0), (0, n), (0, -n), (n, n), (-n, -n), (n, -n), (-n, n)] {
            let ii = i + di, jj = j + dj
            guard ii >= 0, jj >= 0, ii < cols, jj < rows, let g = cells[jj * cols + ii] else { continue }
            let l = (Double(di * di + dj * dj)).squareRoot() * cellCm / 100
            let d0 = g.total - f.total, d1 = g.vertical - f.vertical, d2 = g.horizontal - f.horizontal
            sum += ((d0 * d0 + d1 * d1 + d2 * d2) / 3).squareRoot() / max(l, 1)
            cnt += 1
        }
        return cnt >= 2 ? sum / Double(cnt) : nil
    }

    /// 整张图的平坦度：各格 1 m 起伏（`localContrast`）的中位数，和起伏 < `flatThresholdUT` 的格子占比。
    /// 实测（docs/flat-field-localization.md）：办公室中位 4.4 µT、平的 11%；Tesco 1.2 µT、84%；10 月门店 1.8 µT、57%。
    /// 起伏中位 < 2 µT 的图上地磁对跟踪几乎没帮助（留一法关掉地磁误差不变），冷启动要走 ~20 m 才认得出位置。格子不到 20 个时 nil
    public static let flatThresholdUT: Double = 2
    public func flatness() -> (contrastMedianUT: Double, flatShare: Double, cells: Int)? {
        var cs: [Double] = []
        for j in 0..<rows {
            for i in 0..<cols where cells[j * cols + i] != nil {
                if let c = localContrast(at: Point2((Double(i) + 0.5) * cellCm, (Double(j) + 0.5) * cellCm)) { cs.append(c) }
            }
        }
        guard cs.count >= 20 else { return nil }
        cs.sort()
        let flat = Double(cs.filter { $0 < Self.flatThresholdUT }.count) / Double(cs.count)
        return (cs[cs.count / 2], flat, cs.count)
    }

    public func sample(at p: Point2) -> (mean: MagneticFeature, sigma: MagneticFeature)? {
        guard contains(p) else { return nil }
        let fx = p.x / cellCm - 0.5
        let fy = p.y / cellCm - 0.5
        let i0 = Int(fx.rounded(.down)), j0 = Int(fy.rounded(.down))
        let tx = fx - Double(i0), ty = fy - Double(j0)

        var wsum = 0.0
        var mean = MagneticFeature(total: 0, vertical: 0, horizontal: 0)
        var sig = MagneticFeature(total: 0, vertical: 0, horizontal: 0)
        for (di, wx) in [(0, 1 - tx), (1, tx)] {
            for (dj, wy) in [(0, 1 - ty), (1, ty)] {
                let w = wx * wy
                guard w > 0 else { continue }
                let i = min(max(i0 + di, 0), cols - 1)
                let j = min(max(j0 + dj, 0), rows - 1)
                let k = j * cols + i
                guard let m = cells[k], let s = sigmas[k] else { continue }
                mean = mean + m * w
                sig = sig + s * w
                wsum += w
            }
        }
        guard wsum >= 0.25 else { return nil }
        return (mean * (1 / wsum), sig * (1 / wsum))
    }
}

// MARK: - 解析

extension StoreDataLoader {

    /// 从地图 JSON 读地磁场。没有 `magField` 返回 nil；有但格式不对则抛错。
    public static func loadMagneticField(_ data: Data) throws -> MagneticFieldMap? {
        guard let root = try unwrap(data) as? [String: Any] else {
            throw StoreDataError.unsupportedFormat("地图根节点不是对象")
        }
        guard let mf = root["magField"] as? [String: Any] else { return nil }
        guard let w = num(root["width"]), let h = num(root["height"]), w > 0, h > 0 else {
            throw StoreDataError.unsupportedFormat("地图缺少 width / height")
        }
        guard let cell = num(mf["cellCm"]), cell > 0 else {
            throw StoreDataError.unsupportedFormat("magField 缺少 cellCm")
        }
        func feats(_ key: String) throws -> [MagneticFeature?] {
            guard let arr = mf[key] as? [Any] else {
                throw StoreDataError.unsupportedFormat("magField 缺少 \(key) 数组")
            }
            return try arr.map { item -> MagneticFeature? in
                if item is NSNull { return nil }
                guard let v = item as? [Any], v.count == 3,
                      let a = num(v[0]), let b = num(v[1]), let c = num(v[2]) else {
                    throw StoreDataError.unsupportedFormat("magField.\(key) 的元素必须是 [|B|, Bz, Bh] 或 null")
                }
                return MagneticFeature(total: a, vertical: b, horizontal: c)
            }
        }
        let cells = try feats("cells")
        let sigmas = try feats("sigma")
        let cols = Int((w / cell).rounded(.up)), rows = Int((h / cell).rounded(.up))
        guard cells.count == cols * rows, sigmas.count == cols * rows else {
            throw StoreDataError.unsupportedFormat("magField 格子数 \(cells.count) 与 \(cols)×\(rows) 不一致")
        }
        var field = MagneticFieldMap(widthCm: w, heightCm: h, cellCm: cell, cells: cells, sigmas: sigmas)
        field.trackingTemperature = num(mf["trackingTemperature"]).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return field
    }

    /// 地图里磁场的来源：`raw`（原始磁力计减会话偏置中位数）或 `calibrated`（iOS 校准后，旧地图）。
    public static func loadMagSource(_ data: Data) -> String {
        guard let root = try? unwrap(data) as? [String: Any] else { return "calibrated" }
        return root["magSource"] as? String ?? "calibrated"
    }

    /// 从地图 JSON 读手动定的点位（`markPoints`）。没有就返回空数组。
    public static func loadMarkPoints(_ data: Data) throws -> [MarkPoint] {
        guard let root = try unwrap(data) as? [String: Any] else {
            throw StoreDataError.unsupportedFormat("地图根节点不是对象")
        }
        let list = root["markPoints"] as? [[String: Any]] ?? []
        return list.compactMap { e in
            guard let id = e["id"].map({ str($0) }), let x = num(e["x"]), let y = num(e["y"]) else { return nil }
            return MarkPoint(id: id, x: x, y: y)
        }
    }
}

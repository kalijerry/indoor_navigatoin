import Foundation
import HPASSKit

/// 地磁模式用的「一张地图」：10×10 m 的范围、手动定的点位、校准得到的磁场网格，全放在一个 JSON 里。
///
/// 文件在 `Documents/magmap.json`，格式兼容场地地图（`width` `height` `mapElementList`），
/// 额外字段：`markPoints`（点位）、`magField`（校准结果，定位用）、`magStats`（累积统计，继续校准用）。
@MainActor
final class MagMapStore: ObservableObject {
    static let shared = MagMapStore()

    @Published private(set) var widthCm: Double = 1000
    @Published private(set) var heightCm: Double = 1000
    @Published var floorName = "测试区 10×10 m"
    @Published private(set) var points: [MarkPoint] = []
    @Published private(set) var field: MagneticFieldMap?
    /// 当前磁场图从哪来（例如「2 个会话：…，10-06 16:20」），界面上显示，删除时清掉
    @Published private(set) var fieldSource: String? = UserDefaults.standard.string(forKey: "magFieldSource")
    /// 蓝牙自动指纹（建图采集时顺便录的标签信号，和磁场图一起生成）；定位时当粗定位
    @Published private(set) var bleMap: BLEFingerprintMap? = MagMapStore.loadBLE()

    nonisolated static var bleURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ble-fingerprint.json")
    }

    private static func loadBLE() -> BLEFingerprintMap? {
        guard let d = try? Data(contentsOf: bleURL) else { return nil }
        return try? JSONDecoder().decode(BLEFingerprintMap.self, from: d)
    }

    private func setBLE(_ m: BLEFingerprintMap?) {
        bleMap = m
        if let m, let d = try? JSONEncoder().encode(m) { try? d.write(to: Self.bleURL, options: .atomic) }
        else { try? FileManager.default.removeItem(at: Self.bleURL) }
    }
    @Published private(set) var sampleCount = 0
    @Published private(set) var validCells = 0
    @Published private(set) var lastError: String?

    /// 场地地图里的通道（来自「场地数据」页导入的地图），用于通道约束。
    @Published private(set) var crosses: [CrossSegment] = []
    /// 地图的真实朝向：地图 +y 轴的磁罗盘方位角（度）。第一次「定点 + 设朝向」时自动记下，之后冷启动用。
    /// 地图朝向：地图「上方」（−y）指向的罗盘方位（度，顺时针，0 = 北）。由用户填写，例如 316。
    @Published private(set) var mapUpBearingDeg: Double?
    /// 融合引擎用的「地图 +y 轴的罗盘方位」= 上方 + 180°。
    var declinationDeg: Double? { mapUpBearingDeg.map { ($0 + 180).truncatingRemainder(dividingBy: 360) } }
    private var walkableCache: WalkableMap?
    /// 有房间单元（map.json 的 units / floorPolygons + 门 / 墙）的地图：可走区域带房间图（不经门不能换房间、房间级输出、静止冻结）
    private var roomMap: StoreMap?
    /// 当前采用的场地地图的几何指纹（`StoreMap.geometryHash`）。可走区域 / 房间图 / 射线模型的缓存以它为键；
    /// 导航规划器也用它判断要不要重建（MagneticEngine.navigate）。空 = 还没采用过地图
    private(set) var geometryHash = ""
    private var shelves: [ShelfRect] = []
    /// 房间扫描的地图：能走的地面（没有通道时用它当可走区域）
    @Published private(set) var floor: [[Point2]] = []
    private var raycasterCache: ShelfRaycaster?

    /// 磁场图的来源：电脑上 tools/magmap.py 建的是 raw（原始磁力计减偏置），App 里按点位校准的是 calibrated。
    @Published private(set) var magSource = "calibrated"

    private var builder = MagneticFieldBuilder(widthCm: 1000, heightCm: 1000)
    /// 导入的地图里自带的磁场（没有累积统计，只能用来定位）。
    private var importedField: MagneticFieldMap?

    nonisolated static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("magmap.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL) {
            do { try load(data) } catch {
                lastError = "读取已保存的地磁地图失败：\(error)"
                AppLog.e("地磁", lastError ?? "")
            }
        }
    }

    // MARK: 场地地图

    /// 采用「场地数据」页导入的地图：尺寸、通道。尺寸变了就清掉不再对得上的校准数据和点位。
    func adopt(map: StoreMap?) {
        guard let m = map, m.width > 0, m.height > 0 else { return }
        let sameSize = abs(m.width - widthCm) < 1 && abs(m.height - heightCm) < 1
        // 几何指纹按实际坐标算（货架 / 通道 / 门 / 墙 / 房间多边形 / 原点平移 / AR 变换）：
        // 原来按通道条数、单元 id、门墙个数判断，挪了门、墙、货架或改了通道走向但数量不变时缓存不失效（NAV-001）
        let geo = m.geometryHash
        let geometryChanged = geo != geometryHash
        geometryHash = geo
        crosses = m.crosses
        floor = m.floor
        let units = m.roomUnits.filter { $0.isWalkable && $0.polygon.count >= 3 }
        roomMap = units.isEmpty ? nil : m
        // 只有标准货架（Shelf-001…100）是实物；虚拟货架和 107 / 401 / Shelf-4-… 等不参与
        shelves = m.physicalShelves
        if geometryChanged {
            walkableCache = nil
            raycasterCache = nil
            AppLog.i("地磁", "地图几何变了（\(geo)）：可走区域 / 房间图 / 障碍物射线模型重建")
        }
        if sameSize { return }
        widthCm = m.width
        heightCm = m.height
        walkableCache = nil
        builder = MagneticFieldBuilder(widthCm: widthCm, heightCm: heightCm)
        importedField = nil
        points = points.filter { $0.x <= widthCm && $0.y <= heightCm }
        refreshField()
        save()
        AppLog.i("地磁", "采用场地地图：\(Int(widthCm)) × \(Int(heightCm)) cm，\(crosses.count) 条通道")
    }

    /// 可走区域（由通道栅格化，首次使用时生成并缓存）。没有通道时为 nil。
    func walkableMap() -> WalkableMap? {
        if let w = walkableCache { return w }
        if let rm = roomMap, let w = WalkableMap(roomsOf: rm) {
            walkableCache = w
            AppLog.i("地磁", "可走区域（房间图）：\(w.rooms?.rooms.count ?? 0) 个单元、\(w.rooms?.doors.count ?? 0) 扇门、\(w.rooms?.openSeams ?? 0) 段没墙的分界，不经门不能换房间")
            return w
        }
        if crosses.isEmpty && !floor.isEmpty {
            let w = WalkableMap(floor: floor, obstacles: shelves, widthCm: widthCm, heightCm: heightCm)
            walkableCache = w
            AppLog.i("地磁", "可走区域（房间地面 − 家具）：\(w.walkableCellCount) 格，\(Fmt.f(w.walkableAreaM2, 1)) m²")
            return w
        }
        guard !crosses.isEmpty else { return nil }
        let w = WalkableMap(crosses: crosses, widthCm: widthCm, heightCm: heightCm)
        walkableCache = w
        AppLog.i("地磁", "可走区域：\(w.walkableCellCount) 格，\(Int(w.walkableAreaM2)) m²")
        return w
    }

    /// 货架射线投射（深度相机横向距离用），首次使用时生成并缓存。没有货架时为 nil。
    func raycaster() -> ShelfRaycaster? {
        if let r = raycasterCache { return r }
        guard !shelves.isEmpty else { return nil }
        let r = ShelfRaycaster(shelves: shelves, widthCm: widthCm, heightCm: heightCm)
        raycasterCache = r
        AppLog.i("地磁", "障碍物射线投射：\(r.shelfCount) 个障碍物")
        return r
    }

    /// 切换地图之后：工作区文件已经换成新地图的，丢掉内存里的旧状态，从文件重新读。
    func reloadFromDisk() {
        points = []
        mapUpBearingDeg = nil
        importedField = nil
        magSource = "calibrated"
        crosses = []
        floor = []
        shelves = []
        roomMap = nil
        geometryHash = ""
        walkableCache = nil
        raycasterCache = nil
        builder = MagneticFieldBuilder(widthCm: widthCm, heightCm: heightCm)
        if let data = try? Data(contentsOf: Self.fileURL) {
            do { try load(data) } catch { lastError = "读取地图工作区失败：\(error)" }
        } else {
            refreshField()
        }
        fieldSource = UserDefaults.standard.string(forKey: "magFieldSource")
        bleMap = Self.loadBLE()
    }

    func setMapUpBearing(_ deg: Double?) {
        let norm = deg.map { (($0.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) }
        guard norm != mapUpBearingDeg else { return }
        mapUpBearingDeg = deg.map { (($0.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) }
        save()
        AppLog.i("地磁", "地图朝向：" + (mapUpBearingDeg.map { "上方指向 \(Fmt.f($0, 0))°" } ?? "未设置"))
    }

    /// 用场地地图做底，还是没有场地地图时的小测试区。
    /// 有场地地图（通道）或房间地图（地面）
    var usesStoreMap: Bool { !crosses.isEmpty || !floor.isEmpty }

    // MARK: 点位

    /// 在 p（cm）处放一个点，吸附到 10 cm，编号自动递增。
    @discardableResult
    func addPoint(at p: Point2) -> MarkPoint {
        let x = min(max((p.x / 10).rounded() * 10, 0), widthCm)
        let y = min(max((p.y / 10).rounded() * 10, 0), heightCm)
        var n = (points.compactMap { Int($0.id) }.max() ?? 0) + 1
        while points.contains(where: { $0.id == String(n) }) { n += 1 }
        let mp = MarkPoint(id: String(n), x: x, y: y)
        points.append(mp)
        save()
        AppLog.i("地磁", "放置点位 \(mp.id)：x \(Int(x)) y \(Int(y)) cm")
        return mp
    }

    func deletePoint(id: String) {
        points.removeAll { $0.id == id }
        save()
        AppLog.i("地磁", "删除点位 \(id)")
    }

    func clearPoints() {
        points = []
        save()
    }

    func point(id: String) -> MarkPoint? { points.first { $0.id == id } }

    // MARK: 校准结果

    /// 并入一遍校准数据，返回实际用到的样本数。
    @discardableResult
    func addCalibration(waypoints: [MagneticFieldBuilder.Waypoint],
                        samples: [MagneticFieldBuilder.TimedFeature]) -> Int {
        let used = builder.addTrack(waypoints: waypoints, samples: samples)
        magSource = "calibrated"                 // App 里按点位校准用的是 iOS 校准后磁场
        refreshField()
        save()
        AppLog.i("地磁", "并入校准数据：\(used) 个样本，累计 \(builder.sampleCount)，有效格 \(validCells)/\(builder.totalCells)")
        return used
    }

    /// 启用手机上（SurveyMapBuilder）建出来的磁场图：替换当前磁场数据，来源是原始磁力计减偏置。
    func applyBuilt(_ f: MagneticFieldMap, source: String? = nil, ble: BLEFingerprintMap? = nil) {
        builder.reset()
        importedField = f
        magSource = "raw"
        setFieldSource(source)
        setBLE(ble)
        try? FileManager.default.removeItem(at: MagneticEngine.monitorURL)   // 地图换了，变化检测从头攒
        refreshField()
        save()
    }

    /// 删除当前磁场图（手机上生成的、导入的、点位校准累计的都清掉）。点位、地图朝向保留。
    func deleteField() {
        builder.reset()
        importedField = nil
        setFieldSource(nil)
        setBLE(nil)
        try? FileManager.default.removeItem(at: SurveyMapService.stateURL)
        try? FileManager.default.removeItem(at: MagneticEngine.monitorURL)
        refreshField()
        save()
        AppLog.w("地磁", "已删除磁场图（连同蓝牙指纹和累积统计）")
    }

    private func setFieldSource(_ s: String?) {
        fieldSource = s
        UserDefaults.standard.set(s, forKey: "magFieldSource")
    }

    func clearCalibration() {
        builder.reset()
        importedField = nil
        refreshField()
        save()
        AppLog.i("地磁", "已清空校准数据")
    }

    private func refreshField() {
        if builder.sampleCount > 0 {
            field = builder.build()
        } else {
            field = importedField
        }
        sampleCount = builder.sampleCount
        validCells = field?.coveredCells ?? 0
    }

    // MARK: 导入 / 导出

    /// 导入地图 JSON（网页编辑器导出的，或本 App 导出的）。
    func importMap(_ data: Data) throws {
        let oldPoints = points
        try load(data)
        // 电脑上建出来的磁场图（magmap.json）通常不带点位；这时保留 App 里已经放好的点位，别清空
        if points.isEmpty && !oldPoints.isEmpty { points = oldPoints }
        save()
        AppLog.i("地磁", "导入地图：\(points.count) 个点位，" + (field == nil ? "无磁场数据" : "含磁场数据 \(validCells) 格"))
    }

    func exportData() throws -> Data {
        var root: [String: Any] = [
            "mapId": 1, "floorId": 1, "floorName": floorName,
            "width": widthCm, "height": heightCm,
            "mapElementList": [Any](),
            "markPoints": points.map { ["id": $0.id, "x": Int($0.x.rounded()), "y": Int($0.y.rounded())] as [String: Any] },
        ]
        if let d = mapUpBearingDeg { root["mapUpBearingDeg"] = d }
        if let f = field { root["magField"] = f.jsonObject() }
        root["magSource"] = builder.sampleCount > 0 ? "calibrated" : magSource
        if builder.sampleCount > 0 {
            let snap = try JSONEncoder().encode(builder.snapshot())
            root["magStats"] = try JSONSerialization.jsonObject(with: snap)
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private func save() {
        do { try exportData().write(to: Self.fileURL, options: .atomic) } catch {
            lastError = "保存地图失败：\(error.localizedDescription)"
            AppLog.e("地磁", lastError ?? "")
        }
    }

    private func load(_ data: Data) throws {
        let map = try StoreDataLoader.loadMap(data)
        guard map.width > 0, map.height > 0 else {
            throw StoreDataError.unsupportedFormat("地图缺少 width / height（单位 cm）")
        }
        widthCm = map.width
        heightCm = map.height
        floorName = map.floorName ?? floorName
        points = try StoreDataLoader.loadMarkPoints(data)
        if let root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
           let d = root["mapUpBearingDeg"] as? Double {
            // 旧版本存过一个错误的「magDeclinationDeg」（常常是 0），不再读取
            mapUpBearingDeg = d
        }
        walkableCache = nil
        importedField = try StoreDataLoader.loadMagneticField(data)
        magSource = importedField != nil ? StoreDataLoader.loadMagSource(data) : "calibrated"

        builder = MagneticFieldBuilder(widthCm: widthCm, heightCm: heightCm)
        if let root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
           let stats = root["magStats"],
           let raw = try? JSONSerialization.data(withJSONObject: stats),
           let snap = try? JSONDecoder().decode(MagneticFieldBuilder.Snapshot.self, from: raw),
           let restored = MagneticFieldBuilder(snapshot: snap) {
            builder = restored
        }
        refreshField()
        lastError = nil
    }
}

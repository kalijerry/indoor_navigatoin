import Foundation
import HPASSKit
import SwiftUI

/// 地图库：场地地图、扫描的房间……可以随时切换。
///
/// 每张地图有自己的一套「工作区」：磁场图和点位（magmap.json）、采集进度（survey-coverage.json）、
/// 涂色（survey-paint.bin）、磁场图来源说明。切换时把当前这套收进旧地图的目录，再把新地图那套放回来，
/// 所以换来换去不会互相覆盖。建图采集会话里记着地图编号，生成磁场图时只列出当前地图的会话。
///
/// 目录：Documents/maps/<id>/map.json、meta.json、workspace/…
@MainActor
final class MapLibrary: ObservableObject {
    static let shared = MapLibrary()

    struct Entry: Identifiable, Codable, Equatable {
        var id: String
        var name: String
        /// store = 场地地图（通道），room = 房间扫描
        var kind: String
        var created: Date
        /// 本机这张地图对应的云端版本（上传或下载时记下，生成时间 Unix 毫秒）
        var cloudVersion: Int64?
        /// 从云端装上时的说明（来源、会话数、磁场格数、蓝牙标签数…）
        var cloudInfo: MapPackage.Meta?
        /// 是云端融合的正式版本
        var isCloudFused: Bool { cloudInfo?.origin == "cloud" }
        var isRoom: Bool { kind == "room" }
        /// 这张地图用不用蓝牙（标签）：nil = 按类型——场地用，房间 / 办公室不用（标签可能堆在一处，会把位置拉过去）
        var useBLE: Bool?
        var bleEnabled: Bool { useBLE ?? !isRoom }
        /// 云端这个版本的包没装：本机几何更新（接着扫 / 重扫过），等云端用新几何重新生成
        var skippedCloudVersion: Int64?
    }

    /// 本机墓碑：删掉的地图（云端那份不再自动下载 / 更新）
    struct Tombstone: Codable, Equatable {
        var deletedAtMs: Int64
        /// 删除时本机对应的云端版本
        var cloudVersion: Int64?
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var activeId: String?
    @Published var lastError: String?
    @Published private(set) var tombstones: [String: Tombstone] = [:]
    /// 地图几何改了（接着扫、关掉 / 删除扫描段、改单元、删地图、装云端包）就加 1，详情页据此重读
    @Published var geometryRevision = 0

    var active: Entry? { entries.first { $0.id == activeId } }

    /// 地图库列出的地图：两种模式都是全部（本机扫描、导入的也要能看到、能管理），云端正式版在前
    var visibleEntries: [Entry] { entries.filter(\.isCloudFused) + entries.filter { !$0.isCloudFused } }

    /// 没有在用的地图时，挑一张云端正式版用上（不会把用户自己选的本机地图换掉）
    func ensureCloudActive() {
        guard active == nil, let e = entries.first(where: \.isCloudFused) else { return }
        try? activate(e.id)
    }

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("maps", isDirectory: true)
    }
    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    /// 工作区文件（都在 Documents 根目录，按地图收放）
    static let workspaceFiles = ["magmap.json", "survey-coverage.json", "survey-paint.bin", "ble-fingerprint.json", "build-state.json", "live-monitor.json"]
    static let fieldSourceKey = "magFieldSource"
    private static let activeKey = "mapLibraryActive"
    private static var tombstoneURL: URL { root.appendingPathComponent(".tombstones.json") }

    func dir(_ id: String) -> URL { Self.root.appendingPathComponent(id, isDirectory: true) }
    /// 工作区目录：在用的地图在 Documents 根目录，其余在地图目录的 workspace/
    func workspaceDir(_ id: String) -> URL {
        id == activeId ? Self.docs : dir(id).appendingPathComponent("workspace", isDirectory: true)
    }
    func mapURL(_ id: String) -> URL { dir(id).appendingPathComponent("map.json") }
    /// 云端融合确认过的采集涂色（地图包带的）
    func cloudPaintURL(_ id: String) -> URL { dir(id).appendingPathComponent("cloud-paint.bin") }
    /// 云端融合确认过的方向图（每条通道每 1 m 两个方向走过没有）
    func cloudDirectionURL(_ id: String) -> URL { dir(id).appendingPathComponent("cloud-coverage.json") }
    static let worldMapFile = "worldmap.arexperience"
    /// 这张地图的视觉特征地图（房间扫描时存的）；没有为 nil
    func worldMapURL(_ id: String) -> URL? {
        let u = dir(id).appendingPathComponent(Self.worldMapFile)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    var activeWorldMapURL: URL? { activeId.flatMap(worldMapURL) }
    /// 这张地图的目录（特征地图和它的说明 worldmap.json 放这里）
    func mapDir(_ id: String) -> URL { dir(id) }

    private init() {
        load()
        migrateIfNeeded()
    }

    private func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let dirs = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        entries = dirs.compactMap { d in
            guard let data = try? Data(contentsOf: d.appendingPathComponent("meta.json")) else { return nil }
            return try? dec.decode(Entry.self, from: data)
        }.sorted { $0.created < $1.created }
        activeId = UserDefaults.standard.string(forKey: Self.activeKey)
        if let a = activeId, !entries.contains(where: { $0.id == a }) { activeId = nil }
        tombstones = (try? Data(contentsOf: Self.tombstoneURL)).flatMap { try? dec.decode([String: Tombstone].self, from: $0) } ?? [:]
    }

    // MARK: 墓碑

    /// 本机删掉过、现在也没有的地图
    func isDeleted(_ id: String) -> Bool { tombstones[id] != nil && !entries.contains { $0.id == id } }

    func clearTombstone(_ id: String) {
        guard tombstones.removeValue(forKey: id) != nil else { return }
        saveTombstones()
    }

    private func saveTombstones() {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(tombstones).write(to: Self.tombstoneURL, options: .atomic)
    }

    /// 第一次用地图库：把现在「场地数据」里的地图收进来当第一张，当前工作区就归它
    private func migrateIfNeeded() {
        guard entries.isEmpty else { return }
        let cur = StoreDataStore.shared.url(for: .map)
        guard let data = try? Data(contentsOf: cur), let m = try? StoreDataLoader.loadMap(data) else { return }
        let isRoom = m.crosses.isEmpty && !m.floor.isEmpty
        if let e = try? add(data: data, name: m.floorName ?? (isRoom ? "房间" : "场地地图"), kind: isRoom ? "room" : "store") {
            setActive(e.id)
            AppLog.i("地图库", "已把当前地图收进地图库：\(e.name)")
        }
    }

    // MARK: 增删改

    /// 新地图的编号：kind_时间（和已有的、墓碑里的、目录都不重）
    func newMapId(kind: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        var id = "\(kind)_\(df.string(from: Date()))"
        while entries.contains(where: { $0.id == id }) || tombstones[id] != nil
                || FileManager.default.fileExists(atPath: dir(id).path) { id += "_1" }
        return id
    }

    /// 加一张地图（不切换）。
    @discardableResult
    func add(data: Data, name: String, kind: String, extraFiles: [URL] = [], id fixedId: String? = nil) throws -> Entry {
        _ = try StoreDataLoader.loadMap(data)            // 先确认能解析
        let id = fixedId ?? newMapId(kind: kind)
        let e = Entry(id: id, name: name, kind: kind, created: Date())
        try FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
        try data.write(to: mapURL(id))
        for f in extraFiles { try? FileManager.default.copyItem(at: f, to: dir(id).appendingPathComponent(f.lastPathComponent)) }
        try writeMeta(e)
        entries.append(e)
        AppLog.i("地图库", "加入地图：\(name)（\(kind == "room" ? "房间" : "场地")）")
        return e
    }

    /// 加一张地图并切换过去。
    @discardableResult
    func importAndActivate(data: Data, name: String, kind: String, extraFiles: [URL] = []) throws -> Entry {
        let e = try add(data: data, name: name, kind: kind, extraFiles: extraFiles)
        try activate(e.id)
        return e
    }

    /// 这张地图开 / 关蓝牙（定位、采集都跟着变；云端融合按地图类型）
    func setBLE(_ id: String, _ on: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].useBLE = on
        try? writeMeta(entries[i])
        AppLog.i("地图库", "「\(entries[i].name)」蓝牙：\(on ? "开" : "关")")
    }

    /// 在用的地图用不用蓝牙（没有地图库条目时按场地处理）
    var activeBLEEnabled: Bool { active?.bleEnabled ?? true }

    func rename(_ id: String, to name: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        entries[i].name = n
        try? writeMeta(entries[i])
    }

    /// 删掉 `id` 之后接着用哪张：云端正式版优先，其次最近建的
    func nextActiveCandidate(excluding id: String) -> Entry? {
        let rest = entries.filter { $0.id != id }
        return rest.first(where: \.isCloudFused) ?? rest.max { $0.created < $1.created }
    }

    /// 删除一张地图（在用的也能删：先切到下一张，没有别的就清空当前地图）。
    ///
    /// 删掉地图目录（地图、扫描段、特征地图、建图进度、定位数据）。采集会话**不删**：本机没有「已上传」标记，
    /// 删了会丢掉还没上传的采集。记一条本机墓碑：这张地图云端那份不再自动下载 / 更新（云端列表里可以「重新下载」）。
    /// 正在定位 / 采集：在用的地图不能删、不能换（换工作区会把引擎底下的磁场图、涂色换掉，
    /// 之后写盘的采集数据会落到下一张地图里）
    static var enginesBusy: Bool { AppEngines.shared.magnetic.phase != .idle || AppEngines.shared.survey.isRunning }

    /// 删掉了返回 true；没删（正在用、切换失败）返回 false，原因在 lastError
    @discardableResult
    func delete(_ id: String) -> Bool {
        guard let e = entries.first(where: { $0.id == id }) else { return false }
        if id == activeId && Self.enginesBusy {
            lastError = "「\(e.name)」正在定位或采集，先停下来再删除"
            return false
        }
        if id == activeId {
            if let next = nextActiveCandidate(excluding: id) {
                do { try activate(next.id) } catch {
                    lastError = "删除前切换到「\(next.name)」失败：\(error.localizedDescription)"
                    return false
                }
            } else {
                deactivate()
            }
        }
        try? FileManager.default.removeItem(at: dir(id))
        entries.removeAll { $0.id == id }
        tombstones[id] = Tombstone(deletedAtMs: Fmt.nowMs(), cloudVersion: e.cloudVersion)
        saveTombstones()
        lastError = nil
        geometryRevision += 1
        AppLog.w("地图库", "已删除地图「\(e.name)」（\(id)）；采集记录保留，云端那份不再自动下载")
        return true
    }

    /// 不用任何地图：清掉 Documents 根目录的工作区和「场地数据」里的地图（否则下次启动又被收成一张图）
    func deactivate() {
        let fm = FileManager.default
        for f in Self.workspaceFiles { try? fm.removeItem(at: Self.docs.appendingPathComponent(f)) }
        UserDefaults.standard.removeObject(forKey: Self.fieldSourceKey)
        activeId = nil
        UserDefaults.standard.removeObject(forKey: Self.activeKey)
        StoreDataStore.shared.delete(.map)
        MagMapStore.shared.reloadFromDisk()
        MagMapStore.shared.adopt(map: nil)
        AppLog.i("地图库", "现在没有在用的地图")
    }

    /// 场地数据页下载 / 更新了地图：同步进当前这张
    func syncActive(_ data: Data) {
        guard let a = activeId else { return }
        if (try? Data(contentsOf: mapURL(a))) != data { try? data.write(to: mapURL(a)) }
    }

    // MARK: 切换

    func activate(_ id: String) throws {
        guard id != activeId else { return }
        guard let e = entries.first(where: { $0.id == id }) else { return }
        let data = try Data(contentsOf: mapURL(id))
        if let old = activeId { stashWorkspace(to: old) }
        restoreWorkspace(from: id)
        MagMapStore.shared.reloadFromDisk()
        setActive(id)
        try StoreDataStore.shared.save(data, as: .map)
        // reloadFromDisk 清掉了通道 / 货架，马上按场地地图补回来（同一张图时页面收不到「地图变了」，不会自己补）
        MagMapStore.shared.adopt(map: StoreDataStore.shared.map)
        lastError = nil
        AppLog.i("地图库", "切换地图：\(e.name)")
    }

    func setActive(_ id: String) {
        activeId = id
        UserDefaults.standard.set(id, forKey: Self.activeKey)
    }

    private func stashWorkspace(to id: String) {
        let fm = FileManager.default
        let ws = dir(id).appendingPathComponent("workspace", isDirectory: true)
        try? fm.removeItem(at: ws)
        try? fm.createDirectory(at: ws, withIntermediateDirectories: true)
        for f in Self.workspaceFiles {
            let src = Self.docs.appendingPathComponent(f)
            if fm.fileExists(atPath: src.path) { try? fm.moveItem(at: src, to: ws.appendingPathComponent(f)) }
        }
        if let s = UserDefaults.standard.string(forKey: Self.fieldSourceKey) {
            try? Data(s.utf8).write(to: ws.appendingPathComponent("field-source.txt"))
        }
    }

    private func restoreWorkspace(from id: String) {
        let fm = FileManager.default
        let ws = dir(id).appendingPathComponent("workspace", isDirectory: true)
        for f in Self.workspaceFiles {
            let dst = Self.docs.appendingPathComponent(f)
            try? fm.removeItem(at: dst)
            let src = ws.appendingPathComponent(f)
            if fm.fileExists(atPath: src.path) { try? fm.copyItem(at: src, to: dst) }
        }
        let s = (try? Data(contentsOf: ws.appendingPathComponent("field-source.txt"))).flatMap { String(data: $0, encoding: .utf8) }
        UserDefaults.standard.set(s, forKey: Self.fieldSourceKey)
    }

    // MARK: 云端地图包

    /// 把当前在用的地图打成云端包（地图 + 磁场 + 蓝牙 + 视觉特征地图）
    func packageActive() throws -> (MapPackage.Meta, Data) {
        guard let id = activeId, let e = active else { throw StoreDataError.unsupportedFormat("没有在用的地图") }
        let store = MagMapStore.shared
        let mapJSON = try Data(contentsOf: mapURL(id))
        var meta = MapPackage.Meta(id: id, name: e.name, kind: e.kind, version: Fmt.nowMs(), source: store.fieldSource,
                                   mapUpBearingDeg: store.mapUpBearingDeg, magSource: store.magSource)
        meta.origin = "phone"
        meta.fieldCells = store.field?.coveredCells
        meta.bleTags = store.bleMap?.tags.count
        let wm = worldMapURL(id).flatMap { try? Data(contentsOf: $0) }
        let data = try MapPackage.encode(meta: meta, mapJSON: mapJSON, field: store.field, ble: store.bleMap, worldMap: wm)
        return (meta, data)
    }

    /// 上传成功后记下版本
    func markUploaded(_ id: String, version: Int64) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].cloudVersion = version
        try? writeMeta(entries[i])
    }

    /// map.json 里的几何版本（接着扫 / 重扫 / 改单元时递增）；老地图没有
    static func geometryVersion(of json: Data?) -> Int64? {
        guard let d = json, let root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let v = root["geometryVersion"] as? NSNumber else { return nil }
        return v.int64Value
    }

    /// 装上一个云端包：本机没有就新建（同一个编号），有就更新地图、磁场、蓝牙。在用的那张立刻生效。
    ///
    /// 本机的几何比包里的新（手机刚接着扫 / 重扫过，云端还没用新几何重新生成）→ 整包不装：包里的磁场图、涂色
    /// 是按旧几何的，装上也会因尺寸不符被清掉。返回 false，并让本机地图重新上传。
    @discardableResult
    func install(_ c: MapPackage.Contents) throws -> Bool {
        let m = c.meta
        let fm = FileManager.default
        if let i = entries.firstIndex(where: { $0.id == m.id }) {
            let localJSON = try? Data(contentsOf: mapURL(m.id))
            let localGV = Self.geometryVersion(of: localJSON), pkgGV = Self.geometryVersion(of: c.mapJSON)
            if let l = localGV, (pkgGV ?? 0) < l {
                entries[i].skippedCloudVersion = m.version
                try? writeMeta(entries[i])
                Telemetry.shared.invalidateUploadedMap(m.id)
                if m.id == activeId { Telemetry.shared.mapChanged() }
                AppLog.w("地图库", "「\(entries[i].name)」本机的地图比云端这一版新（接着扫 / 重扫过），这次不装，"
                         + "等云端用新地图重新生成；本机地图会重新上传")
                return false
            }
            // 云端几何和本机注册表不是同一版：注册表作废，下次需要时按新的 map.json 重新生成
            if localJSON != c.mapJSON, let reg = (try? Data(contentsOf: registryURL(m.id))).flatMap(ScanRegistry.decode),
               reg.geometryVersion != pkgGV {
                try? fm.removeItem(at: registryURL(m.id))
                try? fm.removeItem(at: scansDir(m.id))
                AppLog.w("地图库", "「\(entries[i].name)」云端的地图和本机扫描段不是同一版，扫描段按云端地图重新开始")
            }
            try c.mapJSON.write(to: mapURL(m.id))
            // 名字：用户在本机改过的不覆盖（只在第一次装的时候用云端的名字）
            entries[i].cloudVersion = m.version
            entries[i].cloudInfo = m
            entries[i].skippedCloudVersion = nil
            try writeMeta(entries[i])
        } else {
            var e = try add(data: c.mapJSON, name: m.name, kind: m.kind, id: m.id)
            e.cloudVersion = m.version
            e.cloudInfo = m
            if let i = entries.firstIndex(where: { $0.id == m.id }) { entries[i] = e }
            try writeMeta(e)
        }
        if let wm = c.worldMap {
            try wm.write(to: dir(m.id).appendingPathComponent(Self.worldMapFile))
            WorldMapKeeper.noteInstalled(id: m.id, mapJSON: c.mapJSON, bytes: wm.count, createdMs: m.version)
        }
        // 工作区：在用的地图写到 Documents 根目录，否则写进这张地图的 workspace 目录
        let isActive = m.id == activeId
        let ws = isActive ? Self.docs : dir(m.id).appendingPathComponent("workspace", isDirectory: true)
        try fm.createDirectory(at: ws, withIntermediateDirectories: true)
        let parsed = try StoreDataLoader.loadMap(c.mapJSON)
        var root: [String: Any] = ["mapId": 1, "floorId": 1, "floorName": parsed.floorName ?? m.name,
                                   "width": parsed.width, "height": parsed.height,
                                   "mapElementList": [Any](), "markPoints": [Any](), "magSource": m.magSource ?? "raw"]
        // 手机上手填的地图朝向优先（云端对房间图会自动估一个，不能把手填的冲掉）；没手填就用云端包的，云端也没有就保留本机的。
        // 放的点位，云端包里没有就保留本机的
        let oldRoot = (try? Data(contentsOf: ws.appendingPathComponent("magmap.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if oldRoot?["mapUpBearingManual"] as? Bool == true, let b = oldRoot?["mapUpBearingDeg"] as? Double {
            root["mapUpBearingDeg"] = b
            root["mapUpBearingManual"] = true
        } else if let b = m.mapUpBearingDeg ?? (oldRoot?["mapUpBearingDeg"] as? Double) {
            root["mapUpBearingDeg"] = b
        }
        if let pts = oldRoot?["markPoints"] { root["markPoints"] = pts }
        if let f = c.field { root["magField"] = f.jsonObject() }
        try JSONSerialization.data(withJSONObject: root).write(to: ws.appendingPathComponent("magmap.json"), options: .atomic)
        let bleURL = ws.appendingPathComponent("ble-fingerprint.json")
        if let b = c.ble { try JSONEncoder().encode(b).write(to: bleURL, options: .atomic) } else { try? fm.removeItem(at: bleURL) }
        // 采集涂色：云端确认的（只算质量筛选合格、进了磁场图的数据）单独存在地图目录里，换地图、重装后拉一次都在。
        // 本机涂色只表示「上次融合之后本机又采的、待云端确认」，装上新版本就清掉（之前的会话已经由云端判过了）。
        if let p = c.paint {
            try p.write(to: cloudPaintURL(m.id), options: .atomic)
            try? fm.removeItem(at: ws.appendingPathComponent("survey-paint.bin"))
        }
        if let d = c.direction {
            try d.write(to: cloudDirectionURL(m.id), options: .atomic)
            try? fm.removeItem(at: ws.appendingPathComponent("survey-coverage.json"))
        }
        // 标签位置表（标签 → 绑定的货架、商品）：包里带了就用包里的（比单独拉的新）
        if let e = c.tagCSV, m.kind == "store" {
            do { try StoreDataStore.shared.installTagLocations(e) } catch { AppLog.w("地图库", "标签位置表：\(error)") }
        }
        // 增量统计和变化检测是针对旧图的，清掉
        for f in ["build-state.json", "live-monitor.json"] { try? fm.removeItem(at: ws.appendingPathComponent(f)) }
        let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm"
        let src = "云端 \(df.string(from: Date(timeIntervalSince1970: Double(m.version) / 1000)))：" + (m.source ?? "")
        if isActive {
            UserDefaults.standard.set(src, forKey: Self.fieldSourceKey)
            MagMapStore.shared.reloadFromDisk()
            try StoreDataStore.shared.save(c.mapJSON, as: .map)
            MagMapStore.shared.adopt(map: StoreDataStore.shared.map)
            // 通道补回来之后再让采集页重读云端涂色 / 方向图
            if c.paint != nil || c.direction != nil {
                NotificationCenter.default.post(name: .surveyPaintFileChanged, object: nil)
            }
        } else {
            try Data(src.utf8).write(to: ws.appendingPathComponent("field-source.txt"))
        }
        // 没有在用的地图时直接用上；已经有在用的就不换（不会把用户正在用的本机地图换掉）
        if activeId == nil { try? activate(m.id) }
        geometryRevision += 1
        AppLog.i("地图库", "装上云端地图：\(m.name)（磁场 \(m.fieldCells ?? 0) 格，蓝牙 \(m.bleTags ?? 0) 个标签）")
        return true
    }

    /// 改 / 加地图库条目（扫描流程用）
    func upsert(_ e: Entry) {
        if let i = entries.firstIndex(where: { $0.id == e.id }) { entries[i] = e } else { entries.append(e) }
        try? writeMeta(e)
    }

    func writeMeta(_ e: Entry) throws {
        try JSONEncoder().encode(e).write(to: dir(e.id).appendingPathComponent("meta.json"))
    }
}

/// 切换地图的菜单（地磁页、场地数据页、房间扫描页都用）
struct MapPickerMenu: View {
    @ObservedObject private var lib = MapLibrary.shared
    var disabled = false
    @State private var error: String?

    var body: some View {
        Menu {
            ForEach(lib.visibleEntries) { e in
                Button {
                    do { try lib.activate(e.id) } catch { self.error = error.localizedDescription }
                } label: {
                    if e.id == lib.activeId {
                        Label(e.name, systemImage: "checkmark")
                    } else {
                        Label(e.name, systemImage: e.isRoom ? "cube.transparent" : "building.2")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: lib.active?.isRoom == true ? "cube.transparent" : "map")
                Text(lib.active?.name ?? "选择地图").lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.footnote.weight(.semibold))
        }
        .disabled(disabled || lib.visibleEntries.isEmpty)
        .alert("切换失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }
}

/// 地图库管理：列表、切换、改名、删除
struct MapLibrarySection: View {
    /// 版本说明：云端融合 MM-dd HH:mm · N 个会话 / 本机
    static func versionText(_ e: MapLibrary.Entry) -> String {
        guard let i = e.cloudInfo else { return e.cloudVersion != nil ? "已上传（本机生成）" : "本机" }
        return (i.origin == "cloud" ? "云端融合 " : "手机上传 ") + CloudMapsSection.date(i.version)
            + (i.sessions.map { " · \($0) 个会话" } ?? "")
    }

    /// 来源徽标：云端正式版 / 本机
    static func originText(_ e: MapLibrary.Entry) -> String { e.isCloudFused ? "云端正式版" : "本机" }

    @ObservedObject private var lib = MapLibrary.shared
    @State private var renaming: MapLibrary.Entry?
    @State private var newName = ""
    @State private var confirmDelete: MapLibrary.Entry?

    var body: some View {
        Section {
            if lib.visibleEntries.isEmpty {
                Text("地图库是空的：从云端下载，或者到「房间扫描」扫一张。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(lib.visibleEntries) { e in
                HStack {
                    Image(systemName: e.isRoom ? "cube.transparent" : "building.2").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(e.name)
                        Text(Self.originText(e) + " · " + (e.isRoom ? "房间" : "场地") + " · " + Self.versionText(e) + (e.bleEnabled ? "" : " · 不用蓝牙"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if e.id == lib.activeId {
                        Text("在用").font(.caption.bold()).foregroundStyle(.green)
                    } else {
                        Button("切换") { try? lib.activate(e.id) }.buttonStyle(.bordered).disabled(MapLibrary.enginesBusy)
                    }
                }
                .swipeActions {
                    Button("删除", role: .destructive) { confirmDelete = e }
                        .disabled(e.id == lib.activeId && MapLibrary.enginesBusy)
                    Button("改名") { renaming = e; newName = e.name }.tint(.blue)
                    Button(e.bleEnabled ? "关蓝牙" : "开蓝牙") { lib.setBLE(e.id, !e.bleEnabled) }.tint(.orange)
                }
            }
            if let err = lib.lastError { Text(err).font(.footnote).foregroundStyle(.red) }
        } header: { Text("地图库") } footer: {
            Text("每张地图有自己的磁场图、点位、采集进度，切换不会互相覆盖。左滑改名 / 删除（在用的也能删，会先换到别的地图）/ 开关蓝牙（房间、办公室默认不用蓝牙）。")
        }
        .alert("改名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名字", text: $newName)
            Button("保存") { if let r = renaming { lib.rename(r.id, to: newName) }; renaming = nil }
            Button("取消", role: .cancel) { renaming = nil }
        }
        .mapDeleteConfirmation($confirmDelete)
    }
}

extension MapLibrary {
    /// 删除确认框里的说明：会删掉什么、留下什么、在用的会换到哪张
    func deleteDescription(_ e: Entry) -> String {
        var parts = ["会删掉这张地图本身、它的扫描段、视觉特征地图、建图进度和定位数据。采集记录保留（还没上传的不会丢）。"]
        if e.id == activeId {
            if let n = nextActiveCandidate(excluding: e.id) {
                parts.append("它正在使用，删除后自动换到「\(n.name)」。")
            } else {
                parts.append("它正在使用，删除后暂时没有地图，可以下载或重新扫描。")
            }
        }
        if e.cloudInfo != nil || e.cloudVersion != nil {
            parts.append("云端那份不会被删除，但以后不再自动下载到这台手机；需要时在云端列表里点「重新下载」。")
        }
        return parts.joined(separator: "\n")
    }
}

/// 删除地图的确认框（地图库、场地数据页、地图详情共用同一个）
struct MapDeleteConfirmation: ViewModifier {
    @Binding var entry: MapLibrary.Entry?
    var onDeleted: () -> Void = {}
    @ObservedObject private var lib = MapLibrary.shared

    func body(content: Content) -> some View {
        content.confirmationDialog("删除「\(entry?.name ?? "")」？",
                                   isPresented: Binding(get: { entry != nil }, set: { if !$0 { entry = nil } }),
                                   titleVisibility: .visible) {
            Button("删除这张地图", role: .destructive) {
                if let e = entry {
                    AppLog.tap("删除地图", e.name)
                    if lib.delete(e.id) {
                        Haptics.success()
                        onDeleted()
                    } else {
                        Haptics.warning()
                    }
                }
                entry = nil
            }
            Button("取消", role: .cancel) { entry = nil }
        } message: {
            Text(entry.map(lib.deleteDescription) ?? "")
        }
    }
}

extension View {
    func mapDeleteConfirmation(_ entry: Binding<MapLibrary.Entry?>, onDeleted: @escaping () -> Void = {}) -> some View {
        modifier(MapDeleteConfirmation(entry: entry, onDeleted: onDeleted))
    }
}

extension Notification.Name {
    /// 在用地图的云端涂色更新了（本机待确认的涂色已清掉），采集页要重新读
    static let surveyPaintFileChanged = Notification.Name("surveyPaintFileChanged")
}

/// 云端地图：上传当前地图、看云端有哪些、下载 / 更新
@MainActor
final class CloudMaps: ObservableObject {
    static let shared = CloudMaps()
    @Published private(set) var list: [Telemetry.CloudMap] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?

    func refresh(autoUpdate: Bool = true) async {
        guard Telemetry.shared.enabled else { return }
        do {
            let all = try await Telemetry.shared.listPackages()
            // 正常模式只看云端融合的正式版本
            list = AppMode.shared.developer ? all : all.filter(\.isCloudFused)
            message = nil
            // 标签位置表：本机没有就从后台拿（找标签、蓝牙底图用）
            if !StoreDataStore.shared.hasTagLocations, let d = await Telemetry.shared.downloadTagLocations() {
                try? StoreDataStore.shared.installTagLocations(d)
            }
            // 本机已有、云端更新了的地图自动更新（在用的那张正在定位 / 采集时也会立刻生效，所以只在空闲时调用）；
            // 正常模式下本机没有的云端正式地图也自动装上（重装 App 后不用一张张点下载，采集人员一打开就有地图和已采涂色）
            // 本机删掉过的（墓碑）不自动装、不自动更新，只在列表里显示「已删除 · 重新下载」；
            // 本机几何比云端新、这一版已经跳过的也不再下载（等云端用新地图重新生成）
            if autoUpdate {
                let lib = MapLibrary.shared
                for c in list where !lib.isDeleted(c.id) {
                    if let e = lib.entries.first(where: { $0.id == c.id }) {
                        if let s = e.skippedCloudVersion, s >= c.version { continue }
                        // 旧版 App 装的包没存云端涂色 / 方向图：同一版本也重新装一次
                        let missing = c.kind == "store" && !FileManager.default.fileExists(atPath: lib.cloudPaintURL(c.id).path)
                        if (e.cloudVersion ?? 0) < c.version || missing { await download(c, explicit: false) }
                    } else if !AppMode.shared.developer && c.isCloudFused {
                        await download(c, explicit: false)
                    }
                }
            }
        } catch {
            // 列表在屏幕外被滚走 / 页面切换时请求会被系统取消，不算失败
            if Self.isCancelled(error) { return }
            message = "取云端列表失败：\(error)"
        }
    }

    func uploadActive() async {
        busy = true
        defer { busy = false }
        do {
            let (meta, data) = try MapLibrary.shared.packageActive()
            try await Telemetry.shared.uploadPackage(data, meta: meta)
            MapLibrary.shared.markUploaded(meta.id, version: meta.version)
            message = "已上传「\(meta.name)」（\(data.count / 1024) KB）"
            AppLog.i("地图库", message ?? "")
            await refresh(autoUpdate: false)
        } catch {
            message = "上传失败：\(error)"
            AppLog.w("地图库", message ?? "")
        }
    }

    /// - Parameter explicit: 用户点的「下载 / 重新下载」：清掉本机墓碑再装
    func download(_ c: Telemetry.CloudMap, explicit: Bool = true) async {
        busy = true
        defer { busy = false }
        do {
            if explicit { MapLibrary.shared.clearTombstone(c.id) }
            let d = try await Telemetry.shared.downloadPackage(c.id)
            let contents = try MapPackage.decode(d)
            if try MapLibrary.shared.install(contents) {
                message = "已装上「\(c.name)」（\(d.count / 1024) KB）"
            } else {
                message = "「\(c.name)」本机的地图比云端这一版新（接着扫 / 重扫过），没有装。本机地图会自动上传；"
                    + "下次运行云端融合时会按新地图重建，之后这里会自动更新"
            }
        } catch {
            if Self.isCancelled(error) { return }
            message = "下载失败：\(error)"
            AppLog.w("地图库", message ?? "")
        }
    }

    static func isCancelled(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    enum Status: Equatable {
        case missing, deleted(newer: Bool), localNewer, latest, outdated
        /// 按钮文字；nil = 不显示按钮
        var action: String? {
            switch self {
            case .missing: return "下载"
            case .deleted: return "重新下载"
            case .outdated: return "更新"
            case .latest, .localNewer: return nil
            }
        }
        var text: String {
            switch self {
            case .missing: return "本机没有"
            case .deleted(let newer): return newer ? "已删除 · 云端有新版本" : "已删除"
            case .localNewer: return "本机较新"
            case .latest: return "最新"
            case .outdated: return "有更新"
            }
        }
    }

    /// 本机状态：没有 / 删掉了 / 本机较新 / 旧 / 最新
    func status(_ c: Telemetry.CloudMap) -> Status {
        let lib = MapLibrary.shared
        guard let e = lib.entries.first(where: { $0.id == c.id }) else {
            if let t = lib.tombstones[c.id] { return .deleted(newer: (t.cloudVersion ?? 0) < c.version) }
            return .missing
        }
        if let s = e.skippedCloudVersion, s >= c.version { return .localNewer }
        return (e.cloudVersion ?? 0) >= c.version ? .latest : .outdated
    }
}

struct CloudMapsSection: View {
    @ObservedObject private var cloud = CloudMaps.shared
    @ObservedObject private var lib = MapLibrary.shared
    @ObservedObject private var tel = Telemetry.shared
    var busyElsewhere = false

    var body: some View {
        Section {
            if !tel.enabled {
                Text("先在「设置 → 云端连接」填地址和口令并打开连接。").font(.footnote).foregroundStyle(.secondary)
            } else {
                if AppMode.shared.developer {
                    Button { Task { await cloud.uploadActive() } } label: {
                        Label("上传本机生成的地图（临时，云端融合后会被替换）", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(cloud.busy || lib.activeId == nil || busyElsewhere)
                }
                Button { Task { await cloud.refresh() } } label: { Label("刷新云端列表", systemImage: "arrow.clockwise") }
                    .disabled(cloud.busy)
                ForEach(cloud.list) { c in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(c.name.isEmpty ? c.id : c.name)
                            Text((c.isCloudFused ? "云端融合 " : "手机上传 ") + Self.date(c.version)
                                 + (c.sessions.map { $0 > 0 ? " · \($0) 个会话" : "" } ?? "")
                                 + " · \(c.size / 1024) KB · 磁场 \(c.fieldCells ?? 0) 格 · 蓝牙 \(c.bleTags ?? 0)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        let st = cloud.status(c)
                        if let a = st.action {
                            VStack(alignment: .trailing, spacing: 2) {
                                Button(a) { Task { await cloud.download(c) } }
                                    .buttonStyle(.bordered).disabled(cloud.busy || busyElsewhere)
                                if case .deleted = st { Text(st.text).font(.caption2).foregroundStyle(.secondary) }
                            }
                        } else {
                            Text(st.text).font(.caption).foregroundStyle(st == .latest ? Color.green : Color.secondary)
                        }
                    }
                }
                if let m = cloud.message { Text(m).font(.footnote).foregroundStyle(.secondary) }
            }
        } header: { Text("云端地图") } footer: {
            Text("正式版本由云端融合：手机把会话上传到后台（采集结束自动传，旧会话在「采集」页一键上传），云端把所有手机、所有分片的会话融合成一张图（各会话的磁场偏移一起解），这里下载；本机已有的地图云端更新了会自动更新。手动上传的是本机生成的版本，会被下一次云端融合替换。全场一张图压缩后约 0.5～1 MB。")
        }
        // 不用 .task：List 里的分段滚出屏幕就会取消它，请求被取消；放到独立任务里跑完
        .onAppear { Task { await cloud.refresh() } }
    }

    static func date(_ ms: Int64) -> String {
        let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm"
        return df.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

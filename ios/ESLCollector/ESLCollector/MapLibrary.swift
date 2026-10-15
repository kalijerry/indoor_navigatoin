import Foundation
import HPASSKit
import SwiftUI

/// 地图库：门店地图、扫描的房间……可以随时切换。
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
        /// store = 门店地图（通道），room = 房间扫描
        var kind: String
        var created: Date
        /// 本机这张地图对应的云端版本（上传或下载时记下，生成时间 Unix 毫秒）
        var cloudVersion: Int64?
        /// 从云端装上时的说明（来源、会话数、磁场格数、蓝牙价签数…）
        var cloudInfo: MapPackage.Meta?
        /// 是云端融合的正式版本
        var isCloudFused: Bool { cloudInfo?.origin == "cloud" }
        var isRoom: Bool { kind == "room" }
        /// 这张地图用不用蓝牙（价签）：nil = 按类型——门店用，房间 / 办公室不用（价签可能堆在一处，会把位置拉过去）
        var useBLE: Bool?
        var bleEnabled: Bool { useBLE ?? !isRoom }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var activeId: String?
    @Published private(set) var lastError: String?

    var active: Entry? { entries.first { $0.id == activeId } }

    /// 当前模式下能看到的地图：正常模式只有云端融合的
    var visibleEntries: [Entry] { AppMode.shared.developer ? entries : entries.filter(\.isCloudFused) }

    /// 正常模式下，当前地图不是云端融合的就换到一张云端融合的（没有就不动，界面提示去下载）
    func ensureCloudActive() {
        guard !AppMode.shared.developer, active?.isCloudFused != true,
              let e = entries.first(where: \.isCloudFused) else { return }
        try? activate(e.id)
    }

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("maps", isDirectory: true)
    }
    private static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    /// 工作区文件（都在 Documents 根目录，按地图收放）
    private static let workspaceFiles = ["magmap.json", "survey-coverage.json", "survey-paint.bin", "ble-fingerprint.json", "build-state.json", "live-monitor.json"]
    private static let fieldSourceKey = "magFieldSource"
    private static let activeKey = "mapLibraryActive"

    private func dir(_ id: String) -> URL { Self.root.appendingPathComponent(id, isDirectory: true) }
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
    }

    /// 第一次用地图库：把现在「门店数据」里的地图收进来当第一张，当前工作区就归它
    private func migrateIfNeeded() {
        guard entries.isEmpty else { return }
        let cur = StoreDataStore.shared.url(for: .map)
        guard let data = try? Data(contentsOf: cur), let m = try? StoreDataLoader.loadMap(data) else { return }
        let isRoom = m.crosses.isEmpty && !m.floor.isEmpty
        if let e = try? add(data: data, name: m.floorName ?? (isRoom ? "房间" : "门店地图"), kind: isRoom ? "room" : "store") {
            setActive(e.id)
            AppLog.i("地图库", "已把当前地图收进地图库：\(e.name)")
        }
    }

    // MARK: 增删改

    /// 加一张地图（不切换）。
    @discardableResult
    func add(data: Data, name: String, kind: String, extraFiles: [URL] = [], id fixedId: String? = nil) throws -> Entry {
        _ = try StoreDataLoader.loadMap(data)            // 先确认能解析
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        var id = fixedId ?? "\(kind)_\(df.string(from: Date()))"
        while fixedId == nil && entries.contains(where: { $0.id == id }) { id += "_1" }
        let e = Entry(id: id, name: name, kind: kind, created: Date())
        try FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
        try data.write(to: mapURL(id))
        for f in extraFiles { try? FileManager.default.copyItem(at: f, to: dir(id).appendingPathComponent(f.lastPathComponent)) }
        try writeMeta(e)
        entries.append(e)
        AppLog.i("地图库", "加入地图：\(name)（\(kind == "room" ? "房间" : "门店")）")
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

    /// 在用的地图用不用蓝牙（没有地图库条目时按门店处理）
    var activeBLEEnabled: Bool { active?.bleEnabled ?? true }

    func rename(_ id: String, to name: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        entries[i].name = n
        try? writeMeta(entries[i])
    }

    /// 删除（当前在用的不能删）。会话文件不删。
    func delete(_ id: String) {
        guard id != activeId else { lastError = "当前在用的地图不能删除，先切换到别的地图"; return }
        try? FileManager.default.removeItem(at: dir(id))
        entries.removeAll { $0.id == id }
        AppLog.w("地图库", "已删除地图 \(id)")
    }

    /// 门店数据页下载 / 更新了地图：同步进当前这张
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
        // reloadFromDisk 清掉了通道 / 货架，马上按门店地图补回来（同一张图时页面收不到「地图变了」，不会自己补）
        MagMapStore.shared.adopt(map: StoreDataStore.shared.map)
        lastError = nil
        AppLog.i("地图库", "切换地图：\(e.name)")
    }

    private func setActive(_ id: String) {
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

    /// 装上一个云端包：本机没有就新建（同一个编号），有就更新地图、磁场、蓝牙。在用的那张立刻生效。
    func install(_ c: MapPackage.Contents) throws {
        let m = c.meta
        let fm = FileManager.default
        if let i = entries.firstIndex(where: { $0.id == m.id }) {
            try c.mapJSON.write(to: mapURL(m.id))
            entries[i].name = m.name
            entries[i].cloudVersion = m.version
            entries[i].cloudInfo = m
            try writeMeta(entries[i])
        } else {
            var e = try add(data: c.mapJSON, name: m.name, kind: m.kind, id: m.id)
            e.cloudVersion = m.version
            e.cloudInfo = m
            if let i = entries.firstIndex(where: { $0.id == m.id }) { entries[i] = e }
            try writeMeta(e)
        }
        if let wm = c.worldMap { try wm.write(to: dir(m.id).appendingPathComponent(Self.worldMapFile)) }
        // 工作区：在用的地图写到 Documents 根目录，否则写进这张地图的 workspace 目录
        let isActive = m.id == activeId
        let ws = isActive ? Self.docs : dir(m.id).appendingPathComponent("workspace", isDirectory: true)
        try fm.createDirectory(at: ws, withIntermediateDirectories: true)
        let parsed = try StoreDataLoader.loadMap(c.mapJSON)
        var root: [String: Any] = ["mapId": 1, "floorId": 1, "floorName": parsed.floorName ?? m.name,
                                   "width": parsed.width, "height": parsed.height,
                                   "mapElementList": [Any](), "markPoints": [Any](), "magSource": m.magSource ?? "raw"]
        // 手机上填的地图朝向、放的点位，云端包里没有就保留本机的
        let oldRoot = (try? Data(contentsOf: ws.appendingPathComponent("magmap.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if let b = m.mapUpBearingDeg ?? (oldRoot?["mapUpBearingDeg"] as? Double) { root["mapUpBearingDeg"] = b }
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
        // 价签位置表（价签 → 绑定的货架、商品）：包里带了就用包里的（比单独拉的新）
        if let e = c.eslCSV, m.kind == "store" {
            do { try StoreDataStore.shared.installEslLocations(e) } catch { AppLog.w("地图库", "价签位置表：\(error)") }
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
        if !AppMode.shared.developer && active?.isCloudFused != true && m.origin == "cloud" { try? activate(m.id) }
        AppLog.i("地图库", "装上云端地图：\(m.name)（磁场 \(m.fieldCells ?? 0) 格，蓝牙 \(m.bleTags ?? 0) 个价签）")
    }

    private func writeMeta(_ e: Entry) throws {
        try JSONEncoder().encode(e).write(to: dir(e.id).appendingPathComponent("meta.json"))
    }
}

/// 切换地图的菜单（地磁页、门店数据页、房间扫描页都用）
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

    @ObservedObject private var lib = MapLibrary.shared
    @State private var renaming: MapLibrary.Entry?
    @State private var newName = ""

    var body: some View {
        Section {
            if lib.visibleEntries.isEmpty {
                Text(AppMode.shared.developer ? "地图库是空的：导入门店地图，或者到「房间扫描」扫一个房间。"
                     : "还没有云端地图：在下面「云端地图」里下载。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(lib.visibleEntries) { e in
                HStack {
                    Image(systemName: e.isRoom ? "cube.transparent" : "building.2").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(e.name)
                        Text((e.isRoom ? "房间" : "门店") + " · " + Self.versionText(e) + (e.bleEnabled ? "" : " · 不用蓝牙"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if e.id == lib.activeId {
                        Text("在用").font(.caption.bold()).foregroundStyle(.green)
                    } else {
                        Button("切换") { try? lib.activate(e.id) }.buttonStyle(.bordered)
                    }
                }
                .swipeActions {
                    if AppMode.shared.developer {
                        if e.id != lib.activeId { Button("删除", role: .destructive) { lib.delete(e.id) } }
                        Button("改名") { renaming = e; newName = e.name }.tint(.blue)
                    }
                    Button(e.bleEnabled ? "关蓝牙" : "开蓝牙") { lib.setBLE(e.id, !e.bleEnabled) }.tint(.orange)
                }
            }
            if let err = lib.lastError { Text(err).font(.footnote).foregroundStyle(.red) }
        } header: { Text("地图库") } footer: {
            Text("每张地图有自己的磁场图、点位、采集进度和采集会话，切换不会互相覆盖。左滑改名 / 删除 / 开关蓝牙（房间、办公室默认不用蓝牙）。")
        }
        .alert("改名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名字", text: $newName)
            Button("保存") { if let r = renaming { lib.rename(r.id, to: newName) }; renaming = nil }
            Button("取消", role: .cancel) { renaming = nil }
        }
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
            // 价签位置表：本机没有就从后台拿（找价签、蓝牙底图用）
            if !StoreDataStore.shared.hasEslLocations, let d = await Telemetry.shared.downloadEslLocations() {
                try? StoreDataStore.shared.installEslLocations(d)
            }
            // 本机已有、云端更新了的地图自动更新（在用的那张正在定位 / 采集时也会立刻生效，所以只在空闲时调用）；
            // 正常模式下本机没有的云端正式地图也自动装上（重装 App 后不用一张张点下载，采集人员一打开就有地图和已采涂色）
            if autoUpdate {
                for c in list {
                    if let e = MapLibrary.shared.entries.first(where: { $0.id == c.id }) {
                        // 旧版 App 装的包没存云端涂色 / 方向图：同一版本也重新装一次
                        let missing = c.kind == "store" && !FileManager.default.fileExists(atPath: MapLibrary.shared.cloudPaintURL(c.id).path)
                        if (e.cloudVersion ?? 0) < c.version || missing { await download(c) }
                    } else if !AppMode.shared.developer && c.isCloudFused {
                        await download(c)
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

    func download(_ c: Telemetry.CloudMap) async {
        busy = true
        defer { busy = false }
        do {
            let d = try await Telemetry.shared.downloadPackage(c.id)
            let contents = try MapPackage.decode(d)
            try MapLibrary.shared.install(contents)
            message = "已装上「\(c.name)」（\(d.count / 1024) KB）"
        } catch {
            if Self.isCancelled(error) { return }
            message = "下载失败：\(error)"
            AppLog.w("地图库", message ?? "")
        }
    }

    static func isCancelled(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// 本机状态：没有 / 旧 / 最新
    func status(_ c: Telemetry.CloudMap) -> String {
        guard let e = MapLibrary.shared.entries.first(where: { $0.id == c.id }) else { return "本机没有" }
        let v = e.cloudVersion ?? 0
        return v >= c.version ? "已是最新" : "有更新"
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
                Text("先在「门店数据 → 云端后台」填地址和口令并打开连接。").font(.footnote).foregroundStyle(.secondary)
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
                        if st == "已是最新" {
                            Text(st).font(.caption).foregroundStyle(.green)
                        } else {
                            Button(st == "本机没有" ? "下载" : "更新") { Task { await cloud.download(c) } }
                                .buttonStyle(.bordered).disabled(cloud.busy || busyElsewhere)
                        }
                    }
                }
                if let m = cloud.message { Text(m).font(.footnote).foregroundStyle(.secondary) }
            }
        } header: { Text("云端地图") } footer: {
            Text("正式版本由云端融合：手机把会话上传到后台（采集结束自动传，旧会话在「采集」页一键上传），云端把所有手机、所有分片的会话融合成一张图（各会话的磁场偏移一起解），这里下载；本机已有的地图云端更新了会自动更新。手动上传的是本机生成的版本，会被下一次云端融合替换。全店一张图压缩后约 0.5～1 MB。")
        }
        // 不用 .task：List 里的分段滚出屏幕就会取消它，请求被取消；放到独立任务里跑完
        .onAppear { Task { await cloud.refresh() } }
    }

    static func date(_ ms: Int64) -> String {
        let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm"
        return df.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

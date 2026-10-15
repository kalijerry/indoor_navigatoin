import HPASSKit
import RoomPlan
import simd
import SwiftUI

/// 家具类别的中文名（RoomPlan 的类别英文名 → 中文）
enum RoomCategory {
    static func label(_ en: String) -> String {
        [
            "bed": "床", "table": "桌子", "sofa": "沙发", "chair": "椅子", "storage": "柜子",
            "television": "电视", "toilet": "马桶", "bathtub": "浴缸", "sink": "水槽",
            "refrigerator": "冰箱", "washerDryer": "洗衣机", "stove": "灶台", "oven": "烤箱",
            "dishwasher": "洗碗机", "fireplace": "壁炉", "stairs": "楼梯",
        ][en] ?? en
    }
}

/// 一次房间扫描的结果（存在 Documents/room-scans/<名字>/）
struct RoomScanItem: Identifiable {
    let dir: URL
    var id: String { dir.lastPathComponent }
    var mapURL: URL { dir.appendingPathComponent("map.json") }
    var usdzURL: URL { dir.appendingPathComponent("room.usdz") }
    /// 加进地图库时的编号
    var libraryId: String? {
        (try? String(contentsOf: dir.appendingPathComponent("library_id.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 房间扫描：用 Apple RoomPlan（激光雷达）扫出墙、门、窗、家具，生成 2D / 3D 地图。
///
/// 结果存成和门店地图同一种 JSON（墙 / 门 / 窗 / 家具 / 地面多边形），「设为当前地图」之后，
/// 地磁定位页的建图采集、涂色、定位都直接在这个房间里用（可走区域 = 地面 − 家具）。
/// RoomCaptureView 的代理（协议要求 NSCoding，单独放一个小对象，不和界面状态混在一起）
final class RoomCaptureDelegate: NSObject, RoomCaptureViewDelegate {
    var onResult: ((CapturedRoom, Error?) -> Void)?

    override init() { super.init() }
    required init?(coder: NSCoder) { super.init() }
    func encode(with coder: NSCoder) {}

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool { true }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        onResult?(processedResult, error)
    }
}

@MainActor
final class RoomScanModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning, processing, done, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var result: StoreMap?
    @Published private(set) var resultItem: RoomScanItem?
    @Published private(set) var summary = ""
    @Published private(set) var items: [RoomScanItem] = []
    var name = ""

    private let delegate = RoomCaptureDelegate()
    private(set) lazy var captureView: RoomCaptureView = {
        let v = RoomCaptureView(frame: .zero)
        v.delegate = delegate
        return v
    }()

    static var isSupported: Bool { RoomCaptureSession.isSupported }

    static var rootURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("room-scans", isDirectory: true)
    }

    init() {
        refresh()
        delegate.onResult = { [weak self] room, error in
            Task { @MainActor in self?.handle(room, error: error) }
        }
    }

    func refresh() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Self.rootURL, includingPropertiesForKeys: nil)) ?? []
        items = dirs.filter { fm.fileExists(atPath: $0.appendingPathComponent("map.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map(RoomScanItem.init)
    }

    func start() {
        guard Self.isSupported else { phase = .failed("这台设备不支持房间扫描（需要激光雷达）"); return }
        SensorArbiter.shared.claim("房间扫描") { [weak self] in self?.cancel() }
        result = nil
        resultItem = nil
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        phase = .scanning
        AppLog.i("房间扫描", "开始扫描")
    }

    /// 扫完：停下来，RoomPlan 会先处理（几秒），处理完回调 didPresent
    func finish() {
        guard phase == .scanning else { return }
        phase = .processing
        pendingWorldMap = nil
        // 先存视觉特征地图（定位时用来认出这个房间），再停扫描
        captureView.captureSession.arSession.getCurrentWorldMap { [weak self] map, err in
            let data = map.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
            Task { @MainActor in
                guard let self else { return }
                self.pendingWorldMap = data
                if data == nil { AppLog.w("房间扫描", "没拿到视觉特征地图：\(err?.localizedDescription ?? "未知原因")，视觉定位不可用") }
                self.captureView.captureSession.stop()
            }
        }
    }

    private var pendingWorldMap: Data?

    func cancel() {
        if phase == .scanning || phase == .processing { captureView.captureSession.stop() }
        phase = .idle
        SensorArbiter.shared.release("房间扫描")
    }

    private func handle(_ room: CapturedRoom, error: Error?) {
        SensorArbiter.shared.release("房间扫描")
        if let error {
            phase = .failed("处理失败：\(error.localizedDescription)")
            AppLog.e("房间扫描", "处理失败：\(error.localizedDescription)")
            return
        }
        do {
            let input = Self.input(from: room)
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd_HHmmss"
            let stamp = df.string(from: Date())
            let title = name.trimmingCharacters(in: .whitespaces).isEmpty ? "房间 \(stamp)" : name
            let (json, map) = try RoomMapBuilder.build(input, name: title)
            let dir = Self.rootURL.appendingPathComponent("room_\(stamp)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try json.write(to: dir.appendingPathComponent("map.json"))
            try? room.export(to: dir.appendingPathComponent("room.usdz"))
            if let raw = try? JSONEncoder().encode(room) { try? raw.write(to: dir.appendingPathComponent("captured_room.json")) }
            if let wm = pendingWorldMap {
                try? wm.write(to: dir.appendingPathComponent(MapLibrary.worldMapFile))
                // 记下这份特征地图对应的 AR 对齐（之后的会话认出房间才能刷新它）
                WorldMapKeeper.noteScanned(dir: dir, align: map.arAlign, bytes: wm.count)
            }
            result = map
            resultItem = RoomScanItem(dir: dir)
            // 直接加进地图库并切换过去：到「地磁定位」页就是这个房间
            addToLibrary(RoomScanItem(dir: dir), name: title)
            let furniture = Dictionary(grouping: input.objects, by: \.category)
                .map { "\(RoomCategory.label($0.key)) \($0.value.count)" }.sorted().joined(separator: "、")
            let area = WalkableMap(floor: map.floor, obstacles: map.physicalShelves, widthCm: map.width, heightCm: map.height).walkableAreaM2
            summary = "墙 \(input.walls.count) 面、门 \(input.doors.count)、窗 \(input.windows.count)；家具：\(furniture.isEmpty ? "无" : furniture)；"
                + "可走 \(Fmt.f(area, 1)) m²；地图 \(Fmt.f(map.width / 100, 1)) × \(Fmt.f(map.height / 100, 1)) m；"
            + (pendingWorldMap != nil ? "视觉定位可用" : "没有视觉特征地图（视觉定位不可用）")
            phase = .done
            refresh()
            AppLog.i("房间扫描", "完成：\(dir.lastPathComponent)，\(summary)")
        } catch {
            phase = .failed("生成地图失败：\(error)")
            AppLog.e("房间扫描", "生成地图失败：\(error)")
        }
    }

    @Published private(set) var libraryMessage: String?

    /// 加进地图库（已经在库里就只切换）
    func addToLibrary(_ it: RoomScanItem, name: String? = nil) {
        let lib = MapLibrary.shared
        do {
            if let id = it.libraryId, lib.entries.contains(where: { $0.id == id }) {
                try lib.activate(id)
            } else {
                let d = try Data(contentsOf: it.mapURL)
                let n = name ?? (try? StoreDataLoader.loadMap(d))?.floorName ?? it.id
                let wm = it.dir.appendingPathComponent(MapLibrary.worldMapFile)
                let side = it.dir.appendingPathComponent(WorldMapSidecar.fileName)
                let extra = FileManager.default.fileExists(atPath: wm.path)
                    ? [wm] + (FileManager.default.fileExists(atPath: side.path) ? [side] : []) : []
                let e = try lib.importAndActivate(data: d, name: n, kind: "room", extraFiles: extra)
                try? Data(e.id.utf8).write(to: it.dir.appendingPathComponent("library_id.txt"))
            }
            libraryMessage = "已加入地图库并切换到这个房间。到「地磁定位」页建图采集、定位。"
        } catch {
            libraryMessage = "加入地图库失败：\(error.localizedDescription)"
        }
    }

    /// 打开以前扫过的一个房间
    func open(_ it: RoomScanItem) {
        guard let d = try? Data(contentsOf: it.mapURL), let m = try? StoreDataLoader.loadMap(d) else { return }
        result = m
        resultItem = it
        summary = "\(m.floorName ?? it.id)：家具 \(m.physicalShelves.count) 件，地图 \(Fmt.f(m.width / 100, 1)) × \(Fmt.f(m.height / 100, 1)) m"
        phase = .done
    }

    func delete(_ it: RoomScanItem) {
        try? FileManager.default.removeItem(at: it.dir)
        if resultItem?.id == it.id { result = nil; resultItem = nil; phase = .idle }
        refresh()
    }

    // MARK: RoomPlan → 平面数据

    static func input(from room: CapturedRoom) -> RoomMapBuilder.Input {
        func item(_ cat: String, _ t: simd_float4x4, _ d: simd_float3) -> RoomMapBuilder.Item {
            let c: simd_float4 = t.columns.3
            let x: simd_float4 = t.columns.0
            let center = Point2(Double(c.x), Double(c.z))
            let yaw: Double = atan2(Double(x.z), Double(x.x))
            let w = Double(d.x), dep = Double(d.z), h = Double(d.y)
            return RoomMapBuilder.Item(category: cat, center: center, width: w, depth: dep, height: h, yaw: yaw)
        }
        var inp = RoomMapBuilder.Input()
        inp.walls = room.walls.map { item("wall", $0.transform, $0.dimensions) }
        inp.doors = room.doors.map { item("door", $0.transform, $0.dimensions) }
        inp.windows = room.windows.map { item("window", $0.transform, $0.dimensions) }
        inp.openings = room.openings.map { item("opening", $0.transform, $0.dimensions) }
        inp.objects = room.objects.map { item(String(describing: $0.category), $0.transform, $0.dimensions) }
        if #available(iOS 17.0, *) {
            inp.floors = room.floors.map { f in
                f.polygonCorners.map { (pc: simd_float3) -> Point2 in
                    let local = simd_float4(pc.x, pc.y, pc.z, 1)
                    let w: simd_float4 = f.transform * local
                    return Point2(Double(w.x), Double(w.z))
                }
            }.filter { $0.count >= 3 }
        }
        return inp
    }
}

/// RoomPlan 自带的扫描界面（实时显示扫到的墙和家具，扫完显示 3D 结果）
struct RoomCaptureContainer: UIViewRepresentable {
    let model: RoomScanModel
    func makeUIView(context: Context) -> RoomCaptureView { model.captureView }
    func updateUIView(_ v: RoomCaptureView, context: Context) {}
}

struct RoomScanView: View {
    @StateObject private var model = RoomScanModel()
    @ObservedObject private var lib = MapLibrary.shared
    @StateObject private var model3D = Store3DModel()
    @State private var show3D = false

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .scanning, .processing:
                    scanning
                default:
                    list
                }
            }
            .navigationTitle("房间扫描")
        }
    }

    private var scanning: some View {
        ZStack(alignment: .bottom) {
            RoomCaptureContainer(model: model).ignoresSafeArea()
            VStack(spacing: 8) {
                if model.phase == .processing {
                    HStack { ProgressView(); Text("正在生成模型……") }
                        .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Text("慢慢绕房间走一圈：摄像头扫过每一面墙、门窗和家具。家具要扫到轮廓。")
                        .font(.footnote).padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("取消", role: .cancel) { model.cancel() }.buttonStyle(.bordered)
                        Button("扫完了") { model.finish() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
        }
    }

    private var list: some View {
        List {
            if !RoomScanModel.isSupported {
                Text("这台设备不支持房间扫描（需要带激光雷达的 iPhone / iPad Pro）。").foregroundStyle(.orange)
            }
            Section {
                TextField("房间名（例如 酒店 1203）", text: $model.name)
                Button {
                    model.start()
                } label: {
                    Label("开始扫描", systemImage: "viewfinder").frame(maxWidth: .infinity).fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!RoomScanModel.isSupported)
                if case .failed(let e) = model.phase { Text(e).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text("用激光雷达扫出墙、门、窗和家具，自动生成 2D 平面图和 3D 模型。设为当前地图之后，到「地磁定位」页就能在这个房间里建图采集（涂色范围 = 地面 − 家具）和定位。")
            }

            if let m = model.result, let it = model.resultItem {
                Section {
                    Picker("显示", selection: $show3D) {
                        Text("2D 平面").tag(false)
                        Text("3D").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Group {
                        if show3D, let sc = model3D.scene {
                            Store3DView(scene: sc, follow: false)
                        } else {
                            MapCanvas(map: m, fingerprints: [], showFingerprints: false)
                        }
                    }
                    .frame(height: 320)
                    .onAppear { model3D.ensure(map: m) }
                    .onChange(of: model.resultItem?.id) { _ in if let r = model.result { model3D.ensure(map: r) } }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(model.summary).font(.footnote)
                    if let id = it.libraryId, id == lib.activeId {
                        Label("当前在用这张地图", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button { model.addToLibrary(it) } label: {
                            Label(it.libraryId.map { id in lib.entries.contains { $0.id == id } } == true
                                  ? "切换到这个房间" : "加入地图库并切换", systemImage: "arrow.triangle.swap")
                        }
                    }
                    if FileManager.default.fileExists(atPath: it.usdzURL.path) {
                        ShareLink(item: it.usdzURL) { Label("导出 3D 模型（USDZ）", systemImage: "cube") }
                    }
                    ShareLink(item: it.mapURL) { Label("导出 2D 地图（JSON）", systemImage: "map") }
                    if let msg = model.libraryMessage { Text(msg).font(.footnote).foregroundStyle(.green) }
                } header: { Text(m.floorName ?? it.id) }
            }

            MapLibrarySection()

            if !model.items.isEmpty {
                Section("扫过的房间") {
                    ForEach(model.items) { it in
                        Button(it.id) { model.open(it) }
                            .swipeActions { Button("删除", role: .destructive) { model.delete(it) } }
                    }
                }
            }
        }
    }
}

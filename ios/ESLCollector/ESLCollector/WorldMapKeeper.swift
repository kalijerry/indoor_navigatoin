import ARKit
import Foundation
import HPASSKit
import simd
import SwiftUI

/// 房间的视觉特征地图（ARWorldMap）的保管：本机存哪、什么时候能刷新、怎么随会话传到云端。
///
/// 坐标系是关键。特征地图只在它保存时的 AR 坐标系里有意义，房间扫描时的坐标系 + 地图里的 `arAlign` 是一对。
/// - 载入了特征地图、并且 ARKit 经过「重定位中」又恢复正常（认出了房间）的会话，AR 坐标系就是特征地图的坐标系，
///   它刷新出来的特征地图沿用同一个 `arAlign`，覆盖更多，可以顶替本机的。
/// - 没认出房间的会话是另一套坐标系，它存的特征地图和 `arAlign` 对不上，**不能**顶替，也不上传。
///   这种会话最多把本机已有的那份原样带上传一次（说明里仍记原来的 `arAlign` 和生成时间）。
/// 每份特征地图旁边放一个 `worldmap.json`（`WorldMapSidecar`），云端融合据此挑选并核对 `arAlign`。
@MainActor
enum WorldMapKeeper {
    static let tag = "视觉特征地图"

    /// 在用的房间地图：有特征地图文件和 arAlign 才返回
    static var usable: (id: String, url: URL, align: MapARTransform)? {
        let lib = MapLibrary.shared
        guard let id = lib.activeId, lib.active?.isRoom == true, let url = lib.worldMapURL(id),
              let align = StoreDataStore.shared.map?.arAlign else { return nil }
        return (id, url, align)
    }

    /// 读在用地图的特征地图给 ARKit；不能用返回 nil
    static func loadActive() -> ARWorldMap? {
        guard ARKitLogger.isSupported, let u = usable else { return nil }
        return ARKitLogger.loadWorldMap(u.url)
    }

    static func sidecarURL(_ id: String) -> URL {
        MapLibrary.shared.mapDir(id).appendingPathComponent(WorldMapSidecar.fileName)
    }

    static func readSidecar(_ id: String) -> WorldMapSidecar? {
        (try? Data(contentsOf: sidecarURL(id))).flatMap(WorldMapSidecar.decode)
    }

    /// 房间扫描完：在扫描目录里写说明（加进地图库时跟着特征地图一起复制过去）
    static func noteScanned(dir: URL, align: MapARTransform?, bytes: Int) {
        guard let align else { return }
        let s = WorldMapSidecar(createdMs: Fmt.nowMs(), source: "scan", mapId: nil, arAlign: align, bytes: bytes, uploaded: false)
        try? s.encoded().write(to: dir.appendingPathComponent(WorldMapSidecar.fileName))
    }

    /// 装了云端包（带特征地图）：说明记成云端来源，已经在云端，不用再传
    static func noteInstalled(id: String, mapJSON: Data, bytes: Int, createdMs: Int64) {
        let url = sidecarURL(id)
        guard let align = (try? StoreDataLoader.loadMap(mapJSON))?.arAlign else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let s = WorldMapSidecar(createdMs: createdMs, source: "cloud", mapId: id, arAlign: align, bytes: bytes, uploaded: true)
        try? s.encoded().write(to: url)
    }

    /// 一次会话结束时的特征地图处理。会话结束的那一刻 `make`（同步判断），之后 `await finish` 做保存和上传。
    @MainActor
    final class Plan {
        private let ar: ARKitLogger
        private let runId: Int
        private let sessionDir: URL?
        private let name: String
        private let mapId: String?
        private let align: MapARTransform?
        private let decision: WorldMapPolicy.Decision
        private var attachedCreatedMs: Int64?

        /// 要先取特征地图再暂停 ARKit
        var defersStop: Bool { decision == .refresh }

        /// - Parameter minAgeMin: 本机的特征地图比这个新就不刷新（实时定位用，免得每次都传几 MB）
        static func make(ar: ARKitLogger, sessionDir: URL?, name: String, minAgeMin: Double? = nil) -> Plan {
            let lib = MapLibrary.shared
            let id = lib.activeId
            let align = StoreDataStore.shared.map?.arAlign
            let stored = id.flatMap(lib.worldMapURL)
            let side = id.flatMap(WorldMapKeeper.readSidecar)
            // 相机此刻在地图上的位置（用 arAlign；只在认出房间之后才有意义）
            let snap = ar.worldMapSnapshot()
            var inside = false
            if let cam = snap.camera, let t = align, let m = StoreDataStore.shared.map {
                inside = WorldMapPolicy.isInside(t.toMap(Point2(Double(cam.columns.3.x) * 100, Double(cam.columns.3.z) * 100)),
                                                 widthCm: m.width, heightCm: m.height)
            }
            let input = WorldMapPolicy.Input(
                isRoom: lib.active?.isRoom == true, hasAlign: align != nil, hasStored: stored != nil,
                loadedStored: ar.loadedWorldMap, relocalized: ar.frameSharedWithWorldMap,
                trackingNormal: snap.trackingNormal, mappedEnough: snap.mappedEnough, insideMap: inside,
                durationSec: ar.runStartedAt.map { Date().timeIntervalSince($0) } ?? 0,
                storedUploaded: side?.uploaded ?? false)
            var d = WorldMapPolicy.decide(input)
            if d == .refresh, let mins = minAgeMin, let s = side,
               Double(Fmt.nowMs() - s.createdMs) < mins * 60_000 {
                d = .skip(reason: "\(Int(mins)) 分钟内刚刷新过")
            }
            return Plan(ar: ar, sessionDir: sessionDir, name: name, mapId: id, align: align, decision: d)
        }

        private init(ar: ARKitLogger, sessionDir: URL?, name: String, mapId: String?, align: MapARTransform?,
                     decision: WorldMapPolicy.Decision) {
            self.ar = ar; self.runId = ar.runId; self.sessionDir = sessionDir; self.name = name
            self.mapId = mapId; self.align = align; self.decision = decision
        }

        /// 保存（需要时）并上传；`upload` 返回是否成功。需要先取特征地图的话，取完才暂停 ARKit。
        func finish(upload: (() async -> Bool)?) async {
            switch decision {
            case .refresh:
                await refresh()
                ar.stopIfCurrent(runId)
            case .uploadStored(let why):
                AppLog.i(WorldMapKeeper.tag, "\(name)：不刷新（\(why)）；本机这份还没传过，原样随会话上传一次")
                attachStored()
            case .skip(let why):
                // 非房间（门店）不打扰
                if why != "不是房间地图" { AppLog.i(WorldMapKeeper.tag, "\(name)：不刷新（\(why)）") }
            }
            if let upload {
                let ok = await upload()
                if ok, let ms = attachedCreatedMs, let id = mapId { WorldMapKeeper.markUploaded(id, createdMs: ms) }
            }
        }

        private func refresh() async {
            guard let dir = sessionDir, let id = mapId, let align else { return }
            let (data, why) = await capture()
            guard ar.runId == runId else {
                AppLog.w(WorldMapKeeper.tag, "\(name)：取特征地图期间 ARKit 又开始了新的一轮，不保存")
                attachStored()
                return
            }
            guard let data else {
                AppLog.w(WorldMapKeeper.tag, "\(name)：没取到特征地图（\(why ?? "未知原因")），保留原来的")
                attachStored()
                return
            }
            if let p = WorldMapPolicy.sizeProblem(data.count) {
                AppLog.w(WorldMapKeeper.tag, "\(name)：新的特征地图\(p)，不替换，保留原来的")
                attachStored()
                return
            }
            let now = Fmt.nowMs()
            let side = WorldMapSidecar(createdMs: now, source: "refreshed", mapId: id, arAlign: align, bytes: data.count, uploaded: false)
            do {
                let meta = try side.encoded()
                // 会话目录（随会话上传）+ 本机这张地图
                try data.write(to: dir.appendingPathComponent(MapLibrary.worldMapFile), options: .atomic)
                try meta.write(to: dir.appendingPathComponent(WorldMapSidecar.fileName), options: .atomic)
                let mapDir = MapLibrary.shared.mapDir(id)
                try data.write(to: mapDir.appendingPathComponent(MapLibrary.worldMapFile), options: .atomic)
                try meta.write(to: WorldMapKeeper.sidecarURL(id), options: .atomic)
                attachedCreatedMs = now
                AppLog.i(WorldMapKeeper.tag, "\(name)：认出房间后刷新了特征地图（\(String(format: "%.1f", Double(data.count) / 1_048_576)) MB），"
                         + "沿用原来的 AR 对齐，已替换本机的并放进会话目录" + (data.count > WorldMapPolicy.warnBytes ? "（超过 8 MB，下载会偏慢）" : ""))
            } catch {
                AppLog.e(WorldMapKeeper.tag, "\(name)：保存特征地图失败：\(error.localizedDescription)")
            }
        }

        /// 取当前特征地图，最多等 6 秒
        private func capture() async -> (Data?, String?) {
            guard ar.runId == runId else { return (nil, "ARKit 已经开始了新的一轮") }
            return await withCheckedContinuation { (cont: CheckedContinuation<(Data?, String?), Never>) in
                let once = Once<(Data?, String?)> { cont.resume(returning: $0) }
                let done: @Sendable (Data?, String?) -> Void = { data, why in once.fire((data, why)) }
                ar.captureWorldMap(done)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { once.fire((nil, "超时")) }
            }
        }

        /// 本机已有的那份原样放进会话目录（说明里仍是它自己的 arAlign 和生成时间，不会冒充新的）
        private func attachStored() {
            guard let dir = sessionDir, let id = mapId, let align, let src = MapLibrary.shared.worldMapURL(id),
                  attachedCreatedMs == nil else { return }
            let size = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if let p = WorldMapPolicy.sizeProblem(size) {
                AppLog.w(WorldMapKeeper.tag, "\(name)：本机特征地图\(p)，不上传")
                return
            }
            var side = WorldMapKeeper.readSidecar(id)
            if side == nil {
                // 没有说明：房间扫描时存的（旧版本）。坐标系就是地图的 arAlign
                let made = (try? src.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                side = WorldMapSidecar(createdMs: Int64(made.timeIntervalSince1970 * 1000), source: "scan", mapId: id, arAlign: align, bytes: size)
            }
            guard var s = side, s.isCompatible(with: align) else {
                AppLog.w(WorldMapKeeper.tag, "\(name)：本机特征地图的 AR 对齐和当前地图对不上，不上传")
                return
            }
            s.source = s.source == "cloud" ? "cloud" : "stored"
            s.mapId = id
            s.bytes = size
            s.uploaded = nil
            do {
                try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent(MapLibrary.worldMapFile))
                try s.encoded().write(to: dir.appendingPathComponent(WorldMapSidecar.fileName))
                attachedCreatedMs = s.createdMs
            } catch {
                AppLog.w(WorldMapKeeper.tag, "\(name)：复制特征地图失败：\(error.localizedDescription)")
            }
        }
    }

    /// 上传成功后，把本机这份标记成已传（只认同一份：生成时间一致）
    static func markUploaded(_ id: String, createdMs: Int64) {
        guard var s = readSidecar(id), s.createdMs == createdMs, s.uploaded != true else { return }
        s.uploaded = true
        try? s.encoded().write(to: sidecarURL(id), options: .atomic)
    }
}

/// 回调只触发一次（取特征地图的完成和超时谁先到算谁）
private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let body: @Sendable (T) -> Void
    init(_ body: @escaping @Sendable (T) -> Void) { self.body = body }
    func fire(_ v: T) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body(v) }
    }
}

/// 房间里实时定位、等视觉认出房间时的提示：怎么做、等了多久、超时了怎么办、认出 / 没认出几次。
struct VisualRelocalizeBanner: View {
    @ObservedObject var engine: MagneticEngine

    var body: some View {
        if engine.searching, engine.visualAvailable, engine.arRunningNow, let start = engine.visualSearchStarted {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let sec = max(0, ctx.date.timeIntervalSince(start))
                let timedOut = sec >= MagneticEngine.visualTimeoutSec
                VStack(alignment: .leading, spacing: 6) {
                    Text("对着房间慢慢转一圈，认出房间就自动定位").font(.callout.weight(.semibold))
                    ProgressView(value: min(sec, MagneticEngine.visualTimeoutSec), total: MagneticEngine.visualTimeoutSec)
                    if timedOut {
                        Text("已经 \(Int(sec)) 秒还没认出来，还在继续试。换个位置，对着墙角、门窗、家具多的方向再慢慢转；光线太暗或房间变动大会认不出。实在不行可以长按地图手动定点。")
                            .font(.footnote).foregroundStyle(.orange)
                    } else {
                        Text("正在认房间…（\(Int(sec)) / \(Int(MagneticEngine.visualTimeoutSec)) 秒）"
                             + (MagMapStore.shared.field != nil ? "，同时也在用地磁找" : ""))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("本次：认出 \(engine.visualFixes) 次，超时没认出 \(engine.visualTimeouts) 次")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

import Foundation
import HPASSKit
import UIKit

/// 云端后台（server/telemetry，Cloudflare）：
/// - WebSocket 实时发日志、定位 / 采集状态（每秒最多 2 次），断网时先攒着，连上再批量补发；
/// - HTTP 上传采集会话（zip）和当前地图（看板画地图用）。
///
/// 地址和口令在「门店数据 → 云端后台」里填，口令存钥匙串。只在 App 前台工作。
@MainActor
final class Telemetry: ObservableObject {
    static let shared = Telemetry()

    enum Status: Equatable { case off, connecting, connected, failed(String) }

    @Published private(set) var status: Status = .off
    @Published private(set) var queued = 0
    @Published private(set) var sent = 0
    @Published private(set) var lastUpload: String?
    @Published var serverURL: String = UserDefaults.standard.string(forKey: "telemetryURL") ?? "" {
        didSet { UserDefaults.standard.set(serverURL, forKey: "telemetryURL") }
    }
    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: "telemetryEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "telemetryEnabled")
            enabled ? connect() : disconnect()
            if enabled { Task { await CloudMaps.shared.refresh() } }     // 刚连上（比如重装后）就把云端地图装上
        }
    }
    /// 采集结束自动上传会话
    @Published var autoUpload: Bool = UserDefaults.standard.object(forKey: "telemetryAutoUpload") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoUpload, forKey: "telemetryAutoUpload") }
    }

    var token: String {
        get { Keychain.get("telemetryToken") ?? "" }
        set { Keychain.set(newValue.isEmpty ? nil : newValue, for: "telemetryToken"); objectWillChange.send() }
    }

    private var task: URLSessionWebSocketTask?
    private var buffer: [[String: Any]] = []
    private var retry = 2.0
    private var pingTimer: Timer?
    private var flushTimer: Timer?
    private var lastState = Date.distantPast
    private var uploadedMaps: Set<String> = []
    private static let maxBuffer = 3000

    let deviceName: String = {
        let id = UIDevice.current.identifierForVendor?.uuidString.prefix(4) ?? "0000"
        return "iPhone-\(id)"
    }()

    private init() {
        flushTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.enabled == true && self?.status != .connected { self?.connect() } }
        }
        if enabled { connect() }
    }

    private var base: URL? {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("/") { s.removeLast() }
        if !s.hasPrefix("http") { s = "https://" + s }
        return URL(string: s)
    }

    // MARK: 连接

    func connect() {
        guard enabled, let b = base, !token.isEmpty else {
            status = enabled ? .failed("先填地址和口令") : .off
            return
        }
        task?.cancel(with: .goingAway, reason: nil)
        var c = URLComponents(url: b.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
        c.scheme = b.scheme == "http" ? "ws" : "wss"
        c.queryItems = [.init(name: "role", value: "device"), .init(name: "device", value: deviceName),
                        .init(name: "token", value: token)]
        guard let u = c.url else { status = .failed("地址不对"); return }
        let t = URLSession.shared.webSocketTask(with: u)
        task = t
        status = .connecting
        t.resume()
        // 先发 hello；连接成功与否以第一次 ping 的结果为准
        send(raw: hello(), force: true)
        t.sendPing { [weak self] err in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                if let err {
                    self.fail(err.localizedDescription)
                } else {
                    self.status = .connected
                    self.retry = 2
                    self.uploadActiveMapIfNeeded()
                    self.flush()
                }
            }
        }
        receive(t)
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let t = self.task else { return }
                t.sendPing { err in if let err { Task { @MainActor in self.fail(err.localizedDescription) } } }
            }
        }
    }

    func disconnect() {
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        status = .off
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] r in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                if case .failure(let e) = r { self.fail(e.localizedDescription) } else { self.receive(t) }
            }
        }
    }

    private func fail(_ msg: String) {
        guard status != .off else { return }
        status = .failed(msg)
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        let wait = retry
        retry = min(retry * 2, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            Task { @MainActor in if self?.enabled == true && self?.task == nil { self?.connect() } }
        }
    }

    // MARK: 发送

    private func hello() -> [String: Any] {
        let lib = MapLibrary.shared
        return ["type": "hello", "t": Fmt.nowMs(), "model": UIDevice.current.model + " " + UIDevice.current.systemVersion,
                "app": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                "mapId": lib.activeId ?? "", "mapName": lib.active?.name ?? ""]
    }

    private func send(raw m: [String: Any], force: Bool = false) {
        guard enabled else { return }
        buffer.append(m)
        if buffer.count > Self.maxBuffer { buffer.removeFirst(buffer.count - Self.maxBuffer) }
        queued = buffer.count
        if force { flush(force: true) }
    }

    /// 每秒一次：把攒着的消息作为一个 JSON 数组发出去
    private func flush(force: Bool = false) {
        guard let t = task, status == .connected || force, !buffer.isEmpty else { return }
        let batch = Array(buffer.prefix(300))
        guard let d = try? JSONSerialization.data(withJSONObject: batch), let s = String(data: d, encoding: .utf8) else {
            buffer.removeFirst(batch.count); return
        }
        buffer.removeFirst(batch.count)
        queued = buffer.count
        t.send(.string(s)) { [weak self] err in
            Task { @MainActor in
                guard let self else { return }
                if let err {
                    self.buffer.insert(contentsOf: batch, at: 0)      // 没发出去，放回去下次再发
                    self.queued = self.buffer.count
                    self.fail(err.localizedDescription)
                } else {
                    self.sent += batch.count
                }
            }
        }
    }

    /// AppLog 每条日志都转过来
    func log(_ e: LogEntry) {
        guard enabled else { return }
        send(raw: ["type": "log", "t": e.tMs, "level": e.level.wire, "cat": e.category, "msg": e.message])
    }

    /// 定位 / 采集状态（每秒最多 2 次）
    func state(mode: String, position: Point2?, uncertaintyCm: Double?, headingRad: Double?, loc: String,
               src: String? = nil, ble: Int? = nil, paint: Double? = nil, extra: [String: Any] = [:]) {
        guard enabled, Date().timeIntervalSince(lastState) >= 0.5 else { return }
        lastState = Date()
        var m: [String: Any] = ["type": "state", "t": Fmt.nowMs(), "mode": mode, "loc": loc,
                                "mapId": MapLibrary.shared.activeId ?? "", "mapName": MapLibrary.shared.active?.name ?? ""]
        if let p = position { m["x"] = (p.x * 10).rounded() / 10; m["y"] = (p.y * 10).rounded() / 10 }
        if let u = uncertaintyCm { m["unc"] = u.rounded() }
        if let h = headingRad { m["heading"] = (h * 1000).rounded() / 1000 }
        if let s = src { m["src"] = s }
        if let b = ble { m["ble"] = b }
        if let p = paint { m["paint"] = (p * 1000).rounded() / 1000 }
        for (k, v) in extra { m[k] = v }
        send(raw: m)
    }

    /// 换了地图：重新打招呼，看板换地图
    func mapChanged() {
        guard enabled else { return }
        send(raw: hello())
        uploadActiveMapIfNeeded()
    }

    // MARK: 上传

    private func request(_ path: String, method: String) -> URLRequest? {
        guard let b = base, !token.isEmpty else { return nil }
        var r = URLRequest(url: b.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 300
        return r
    }

    private func uploadActiveMapIfNeeded() {
        let lib = MapLibrary.shared
        guard let id = lib.activeId, !uploadedMaps.contains(id),
              let data = try? Data(contentsOf: lib.mapURL(id)), var r = request("api/maps/\(id)", method: "PUT") else { return }
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.uploadTask(with: r, from: data) { [weak self] _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            Task { @MainActor in if ok { self?.uploadedMaps.insert(id) } }
        }.resume()
    }

    /// 上传一个会话目录（打包成 zip）
    func upload(sessionDir dir: URL) async -> Bool {
        guard enabled, var r = request("api/sessions/\(dir.lastPathComponent).zip", method: "PUT") else { return false }
        do {
            let zip = try SessionsView.zip(dir)
            r.setValue("application/zip", forHTTPHeaderField: "Content-Type")
            let (_, resp) = try await URLSession.shared.upload(for: r, fromFile: zip)
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            lastUpload = ok ? "已上传 \(dir.lastPathComponent)" : "上传失败（HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)）"
            AppLog.i("后台", lastUpload ?? "")
            return ok
        } catch {
            lastUpload = "上传失败：\(error.localizedDescription)"
            AppLog.w("后台", lastUpload ?? "")
            return false
        }
    }

    // MARK: 云端地图包

    struct CloudMap: Decodable, Identifiable {
        var id: String
        var name: String
        var kind: String
        var version: Int64
        var size: Int
        var fieldCells: Int?
        var bleTags: Int?
        var origin: String?
        var sessions: Int?
        var isCloudFused: Bool { origin == "cloud" }
    }

    /// 后台的价签位置表（正常模式下从这里拿，不用自己导入）
    func downloadEslLocations() async -> Data? {
        guard let r = request("api/esl/locations.csv", method: "GET") else { return nil }
        guard let res = try? await URLSession.shared.data(for: r), (res.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return res.0
    }

    enum CloudError: Error, CustomStringConvertible {
        case notConfigured, http(Int, String)
        var description: String {
            switch self {
            case .notConfigured: return "先在「云端后台」填地址和口令"
            case .http(let c, let m): return "HTTP \(c)：\(m)"
            }
        }
    }

    /// 价签位置表传到后台（云端融合当蓝牙底图）
    func uploadEslLocations(_ data: Data) async {
        guard enabled, var r = request("api/esl/locations.csv", method: "PUT") else { return }
        r.setValue("text/csv; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let resp = try? await URLSession.shared.upload(for: r, from: data).1
        if (resp as? HTTPURLResponse)?.statusCode == 200 {
            AppLog.i("后台", "价签位置表已上传")
        }
    }

    /// 通用 GET（精度测试取云端报告用）
    func getData(_ path: String) async throws -> Data {
        guard var r = request(path, method: "GET") else { throw CloudError.notConfigured }
        r.timeoutInterval = 30
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw CloudError.http(code, String(data: d, encoding: .utf8) ?? "") }
        return d
    }

    /// 后台会话列表的请求（没配地址时 nil）
    func sessionsRequest() -> URLRequest? { request("api/sessions", method: "GET") }

    func listPackages() async throws -> [CloudMap] {
        guard let r = request("api/packages", method: "GET") else { throw CloudError.notConfigured }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw CloudError.http(code, String(data: d, encoding: .utf8) ?? "") }
        return try JSONDecoder().decode([CloudMap].self, from: d)
    }

    func uploadPackage(_ data: Data, meta: MapPackage.Meta) async throws {
        guard var r = request("api/packages/\(meta.id)", method: "PUT") else { throw CloudError.notConfigured }
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.setValue(meta.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "", forHTTPHeaderField: "X-Map-Name")
        r.setValue(meta.kind, forHTTPHeaderField: "X-Map-Kind")
        r.setValue("\(meta.version)", forHTTPHeaderField: "X-Map-Version")
        r.setValue("\(meta.fieldCells ?? 0)", forHTTPHeaderField: "X-Field-Cells")
        r.setValue("\(meta.bleTags ?? 0)", forHTTPHeaderField: "X-Ble-Tags")
        r.setValue(meta.origin ?? "phone", forHTTPHeaderField: "X-Map-Origin")
        let (d, resp) = try await URLSession.shared.upload(for: r, from: data)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw CloudError.http(code, String(data: d, encoding: .utf8) ?? "") }
    }

    func downloadPackage(_ id: String) async throws -> Data {
        guard let r = request("api/packages/\(id)", method: "GET") else { throw CloudError.notConfigured }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw CloudError.http(code, String(data: d, encoding: .utf8) ?? "") }
        return d
    }

    var statusText: String {
        switch status {
        case .off: return "关闭"
        case .connecting: return "连接中…"
        case .connected: return "已连接（已发 \(sent) 条）"
        case .failed(let m): return "断开：\(m)（会自动重连）"
        }
    }
}

extension LogLevel {
    /// 发给后台的级别名
    var wire: String {
        switch self {
        case .debug: return "debug"
        case .info: return "info"
        case .warn: return "warn"
        case .error: return "error"
        }
    }
}

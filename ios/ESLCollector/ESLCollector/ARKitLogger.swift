import ARKit
import Foundation
import simd

/// 一次 LiDAR 深度得到的通道横向距离（相机水平朝向的左右两侧最近的墙）。
struct DepthLateral {
    var tMs: Int64
    /// 左、右两侧最近的货架面到相机的水平距离（cm）；这一侧点太少时为 nil
    var leftCm: Double?
    var rightCm: Double?
    var leftPoints: Int
    var rightPoints: Int
    /// 相机朝向在 ARKit 水平面上的单位向量 (x, z)
    var forwardAR: (x: Double, z: Double)
}

/// 视觉里程计（ARKit 世界跟踪，16 Pro 上带 LiDAR）：
/// - 30 Hz 回调平面位置（cm），可选写 `arkit_pose.csv`；
/// - 打开 `wantsDepth` 时，约 10 Hz 把 LiDAR 深度图转成通道左右的货架距离。
///
/// ARKit 世界系：重力对齐，x 右、y 上、z 朝向观察者。俯视（从 +y 往下看）时 x 向右、z 向下，
/// 与门店地图的 x 向右、y 向下是同一个手性，所以 (x, z) → 地图 (x, y) 只需要一次平面旋转加平移。
final class ARKitLogger: NSObject, ARSessionDelegate {

    /// 回调：Unix 毫秒、x 厘米、z 厘米、跟踪状态（0 不可用 1 受限 2 正常）。在内部串行队列上调用。
    var onPose: (@Sendable (Int64, Double, Double, Int) -> Void)?
    var onLateral: (@Sendable (DepthLateral) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    /// 地面高度（ARKit 世界 y，米）变化时回调。
    var onFloor: (@Sendable (Double) -> Void)?
    /// 带视觉特征地图启动后，ARKit 认出了这个地方（从「重定位中」变成正常）时回调：此刻相机的位姿。
    /// 之后 ARKit 的世界坐标就是特征地图保存时的坐标。跟丢再认出来会再回调。
    var onRelocalized: (@Sendable (simd_float4x4) -> Void)?
    /// 每秒约 2 帧的相机画面（货架标签识别用）；在 ARKit 的队列上调，别久占
    var onFrame: ((ARFrame, Int64) -> Void)?
    private var usingWorldMap = false
    private var relocalizing = false
    // 认出房间后先等位姿稳定再回调：ARKit 刚认出时可能先给一个错的匹配，零点几秒后再跳到对的位置（实测跳了 13 m）。
    // 只在 ARKit 的回调队列上读写。
    private var relocPending = false
    private var relocStableFrames = 0
    private var relocConfirmed = false
    private var lastNormalPose: SIMD3<Float>?
    /// 连续这么多帧（30 Hz）没有跳变才算认稳了
    private static let relocStableNeeded = 30
    /// 相邻两帧（1/30 秒）位姿跳这么远（米）= ARKit 重新校正了坐标系
    private static let relocJumpM: Float = 0.5
    // 这一轮（start 到 stop）的视觉特征地图状态；回调在 ARKit 队列，界面线程读，加锁
    private let runLock = NSLock()
    private var _runId = 0
    private var _startedAt: Date?
    private var _sawRelocalizing = false
    private var _frameShared = false

    /// 给 AR 叠加画面共用的会话（ARSCNView.session = 它）。
    let session = ARSession()
    private var floorY: Float?
    private var wantsMesh = false
    private let queue = DispatchQueue(label: "arkit.logger", qos: .userInitiated)
    private var writer: CSVWriter?
    private var lateralWriter: CSVWriter?
    private var frameCounter = 0
    private var wantsDepth = false
    private let epochOffset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime

    /// 深度相机在左右两侧找墙时用到的参数
    private let assumedHoldHeightM: Float = 1.3     // 手持高度：相机离地面
    private let bandLowM: Float = 0.5               // 取地面以上 0.5 m ...
    private let bandHighM: Float = 1.5              // ... 1.5 m 的水平切片，避开地面和顶棚
    private let forwardMinM: Float = 0.8            // 只用相机前方 0.8 ... 4 m 内的点
    private let forwardMaxM: Float = 4.0
    private let minSidePoints = 25

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }
    static var supportsLiDAR: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }
    static var supportsMesh: Bool { ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) }

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    /// - Parameters:
    ///   - dir: 写 `arkit_pose.csv` 的目录；nil 不写。
    ///   - lateralFileURL: 写深度横向距离的 csv；nil 不写。
    ///   - wantsDepth: 是否取 LiDAR 深度（设备不支持时静默忽略）。
    /// - Parameter wantsMesh: 打开 LiDAR 场景重建（网格），结束时可以用 `exportMesh` 导出。
    func start(dir: URL?, wantsDepth: Bool = false, lateralFile: URL? = nil, wantsMesh: Bool = false,
               worldMap: ARWorldMap? = nil) throws {
        floorY = nil
        self.wantsMesh = wantsMesh && Self.supportsMesh
        if let dir {
            writer = try CSVWriter(url: dir.appendingPathComponent("arkit_pose.csv"),
                                   header: "t_ms,x_m,y_m,z_m,qx,qy,qz,qw,tracking,limited_reason")
        }
        self.wantsDepth = wantsDepth && Self.supportsLiDAR
        if self.wantsDepth, let lateralFile {
            lateralWriter = try CSVWriter(url: lateralFile,
                                          header: "t_ms,left_cm,right_cm,left_n,right_n,fwd_ar_x,fwd_ar_z")
        }
        frameCounter = 0
        let cfg = makeConfig(worldMap: worldMap)
        usingWorldMap = worldMap != nil
        relocalizing = worldMap != nil
        queue.sync { relocPending = false; relocStableFrames = 0; relocConfirmed = false; lastNormalPose = nil }
        runLock.lock()
        _runId += 1
        _startedAt = Date()
        _sawRelocalizing = false
        _frameShared = false
        runLock.unlock()
        session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
    }

    private func makeConfig(worldMap: ARWorldMap?) -> ARWorldTrackingConfiguration {
        let cfg = ARWorldTrackingConfiguration()
        cfg.worldAlignment = .gravity
        cfg.planeDetection = [.horizontal]                  // 用来找地面高度（AR 叠加要把地图贴在地上）
        if wantsMesh { cfg.sceneReconstruction = .mesh }
        cfg.environmentTexturing = .none
        if wantsDepth { cfg.frameSemantics = .sceneDepth }
        cfg.initialWorldMap = worldMap
        return cfg
    }

    /// 载入了特征地图但一直没认出房间（不在这个房间 / 环境变化太大）：ARKit 会一直停在「重新定位中」，
    /// 位姿不可用、走路也不动。丢掉特征地图、按普通模式重新跟踪（写文件不中断，坐标系重新开始）。
    func dropWorldMap() {
        guard usingWorldMap else { return }
        usingWorldMap = false
        relocalizing = false
        runLock.lock()
        _sawRelocalizing = false
        _frameShared = false
        runLock.unlock()
        queue.async { self.relocPending = false; self.relocConfirmed = false; self.lastNormalPose = nil }
        session.run(makeConfig(worldMap: nil), options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
        queue.sync {
            writer?.close()
            writer = nil
            lateralWriter?.close()
            lateralWriter = nil
        }
    }

    /// 认出房间后的位姿稳定检查（30 Hz）：
    /// - 刚认出：连续 1 秒没有跳变才回调 onRelocalized（期间 ARKit 自己纠正的跳变会让计时重来）；
    /// - 已经认稳之后又突然跳一大步（ARKit 又校正了一次坐标系）：重新计时，稳了再回调一次，让定位跟着改。
    private func checkRelocalization(_ camera: ARCamera, _ m: simd_float4x4) {
        guard case .normal = camera.trackingState else { lastNormalPose = nil; return }
        let p = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        if let lp = lastNormalPose, simd_distance(p, lp) > Self.relocJumpM {
            if relocConfirmed || relocPending { relocPending = true; relocStableFrames = 0 }
        }
        lastNormalPose = p
        guard relocPending else { return }
        relocStableFrames += 1
        if relocStableFrames >= Self.relocStableNeeded {
            relocPending = false
            relocConfirmed = true
            onRelocalized?(m)
        }
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        guard usingWorldMap else { return }
        switch camera.trackingState {
        case .limited(.relocalizing):
            relocalizing = true
            runLock.lock(); _sawRelocalizing = true; runLock.unlock()
        case .normal:
            if relocalizing {
                relocalizing = false
                // 确实经过「重定位中」再恢复正常，才算 AR 坐标系和特征地图一致（刷新特征地图的前提）
                runLock.lock(); if _sawRelocalizing { _frameShared = true }; runLock.unlock()
                // 先不回调：等位姿稳定 1 秒（见 didUpdate frame）
                relocPending = true
                relocStableFrames = 0
            }
        default:
            break
        }
    }

    // MARK: 视觉特征地图的保存

    /// 这一轮的编号（每次 start 加 1）；异步保存完要先核对，免得碰到下一轮
    var runId: Int { runLock.lock(); defer { runLock.unlock() }; return _runId }
    var runStartedAt: Date? { runLock.lock(); defer { runLock.unlock() }; return _startedAt }
    /// 这一轮载入了特征地图
    var loadedWorldMap: Bool { usingWorldMap }
    /// 这一轮认出过房间：AR 坐标系和载入的特征地图是同一个
    var frameSharedWithWorldMap: Bool { runLock.lock(); defer { runLock.unlock() }; return _frameShared }

    /// 此刻的状态：跟踪是否正常、建图状态够不够（mapped / extending）、相机位姿
    func worldMapSnapshot() -> (trackingNormal: Bool, mappedEnough: Bool, camera: simd_float4x4?) {
        guard let f = session.currentFrame else { return (false, false, nil) }
        var normal = false
        if case .normal = f.camera.trackingState { normal = true }
        let mapped = f.worldMappingStatus == .mapped || f.worldMappingStatus == .extending
        return (normal, mapped, f.camera.transform)
    }

    /// 取当前特征地图（归档好的字节）。回调在主线程以外的线程也可能发生。
    func captureWorldMap(_ done: @escaping @Sendable (Data?, String?) -> Void) {
        session.getCurrentWorldMap { map, err in
            guard let map else { done(nil, err?.localizedDescription ?? "未知原因"); return }
            do {
                done(try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true), nil)
            } catch {
                done(nil, error.localizedDescription)
            }
        }
    }

    /// 仍是这一轮才暂停（异步保存期间如果又开始了新的一轮，别把新的停掉）
    func stopIfCurrent(_ id: Int) {
        guard runId == id else { return }
        stop()
    }

    /// 读视觉特征地图文件
    static func loadWorldMap(_ url: URL) -> ARWorldMap? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: d)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCounter += 1
        guard frameCounter % 2 == 0 else { return }          // 60 Hz → 30 Hz
        let t = Int64(((epochOffset + frame.timestamp) * 1000).rounded())
        let m = frame.camera.transform
        let p = m.columns.3
        if usingWorldMap { checkRelocalization(frame.camera, m) }
        let q = simd_quatf(m)
        var state = 0
        var reason = 0
        switch frame.camera.trackingState {
        case .normal: state = 2
        case .limited(let r):
            state = 1
            switch r {
            case .initializing: reason = 1
            case .excessiveMotion: reason = 2
            case .insufficientFeatures: reason = 3
            case .relocalizing: reason = 4
            @unknown default: reason = 9
            }
        case .notAvailable: state = 0
        }
        writer?.append([
            "\(t)", Fmt.f(Double(p.x), 4), Fmt.f(Double(p.y), 4), Fmt.f(Double(p.z), 4),
            Fmt.f(Double(q.vector.x), 5), Fmt.f(Double(q.vector.y), 5), Fmt.f(Double(q.vector.z), 5),
            Fmt.f(Double(q.vector.w), 5), "\(state)", "\(reason)",
        ].joined(separator: ","))
        onPose?(t, Double(p.x) * 100, Double(p.z) * 100, state)
        if frameCounter % 30 == 0, state == 2, let f = onFrame { f(frame, t) }

        // 深度：30 Hz 里每 3 帧取一次，约 10 Hz
        if wantsDepth, state == 2, frameCounter % 6 == 0, let depth = frame.sceneDepth {
            if let lat = lateral(from: depth, camera: frame.camera, t: t) {
                lateralWriter?.append([
                    "\(t)", lat.leftCm.map { Fmt.f($0, 1) } ?? "", lat.rightCm.map { Fmt.f($0, 1) } ?? "",
                    "\(lat.leftPoints)", "\(lat.rightPoints)",
                    Fmt.f(lat.forwardAR.x, 4), Fmt.f(lat.forwardAR.z, 4),
                ].joined(separator: ","))
                onLateral?(lat)
            }
        }
    }

    // MARK: 地面

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { updateFloor(anchors) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { updateFloor(anchors) }

    /// 地面 = 最低的、面积够大的水平面；有 LiDAR 时优先用分类为「地面」的平面。
    private func updateFloor(_ anchors: [ARAnchor]) {
        var best = floorY
        for case let p as ARPlaneAnchor in anchors where p.alignment == .horizontal {
            let y = p.transform.columns.3.y + p.center.y
            let area = p.planeExtent.width * p.planeExtent.height
            let isFloor = ARPlaneAnchor.isClassificationSupported && p.classification == .floor
            guard isFloor || area > 1.0 else { continue }
            if best == nil || y < best! - 0.05 || (isFloor && abs(y - best!) < 0.3) { best = y }
        }
        if let b = best, b != floorY {
            floorY = b
            onFloor?(Double(b))
        }
    }

    // MARK: 网格导出

    /// 把当前所有 LiDAR 网格（ARKit 世界坐标，米）写成二进制 PLY。返回（顶点数，三角形数）。
    /// 在会话暂停之前调用。没开网格或没有网格时返回 (0, 0)，不写文件。
    @discardableResult
    func exportMesh(to url: URL) throws -> (vertices: Int, faces: Int) {
        guard wantsMesh, let anchors = session.currentFrame?.anchors.compactMap({ $0 as? ARMeshAnchor }), !anchors.isEmpty else {
            return (0, 0)
        }
        var nv = 0, nf = 0
        for a in anchors { nv += a.geometry.vertices.count; nf += a.geometry.faces.count }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        let header = "ply\nformat binary_little_endian 1.0\ncomment ARKit world, meters, y up\nelement vertex \(nv)\nproperty float x\nproperty float y\nproperty float z\nelement face \(nf)\nproperty list uchar int vertex_indices\nend_header\n"
        h.write(Data(header.utf8))
        // 顶点：每个锚点的局部坐标乘锚点变换，换到世界坐标
        for a in anchors {
            let src = a.geometry.vertices
            var buf = Data(capacity: src.count * 12)
            let base = src.buffer.contents().advanced(by: src.offset)
            for i in 0..<src.count {
                let p = base.advanced(by: i * src.stride).assumingMemoryBound(to: (Float, Float, Float).self).pointee
                let w = a.transform * SIMD4<Float>(p.0, p.1, p.2, 1)
                var v = (w.x, w.y, w.z)
                withUnsafeBytes(of: &v) { buf.append(contentsOf: $0) }
            }
            h.write(buf)
        }
        // 面：索引加上前面锚点的顶点数
        var offset: Int32 = 0
        for a in anchors {
            let f = a.geometry.faces
            var buf = Data(capacity: f.count * 13)
            let base = f.buffer.contents()
            let per = f.indexCountPerPrimitive
            for i in 0..<f.count {
                var n = UInt8(per)
                buf.append(&n, count: 1)
                for k in 0..<per {
                    let p = base.advanced(by: (i * per + k) * f.bytesPerIndex)
                    var idx: Int32 = (f.bytesPerIndex == 4 ? Int32(p.assumingMemoryBound(to: UInt32.self).pointee)
                                                            : Int32(p.assumingMemoryBound(to: UInt16.self).pointee)) + offset
                    withUnsafeBytes(of: &idx) { buf.append(contentsOf: $0) }
                }
            }
            h.write(buf)
            offset += Int32(a.geometry.vertices.count)
        }
        return (nv, nf)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        onError?("ARKit 出错：\(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        onError?("ARKit 被打断（来电、切后台等），位置不可信，请回到最近的已知点长按修正")
    }

    // MARK: 深度 → 左右货架距离

    /// 深度图的每个像素反投影到世界系，取地面以上 0.5～1.5 m 的水平切片，
    /// 把点分到相机水平朝向的左右两侧，每侧取第 20 百分位的横向距离当「墙」。
    ///
    /// 注意：深度图和相机内参是传感器方向（横屏），ARKit 的 `camera.transform` 对应同一个传感器坐标系，
    /// 所以下面的反投影都在传感器坐标系里做，不需要处理手机竖屏旋转。
    /// **这一步没有在真机上验证过**，所以默认只记录、不参与定位；用 `hpass-replay` 对照地图核对之后再打开。
    private func lateral(from depth: ARDepthData, camera: ARCamera, t: Int64) -> DepthLateral? {
        let map = depth.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
              let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)

        // 内参按 capturedImage 的分辨率给出，缩放到深度图
        let imgW = Float(camera.imageResolution.width), imgH = Float(camera.imageResolution.height)
        let k = camera.intrinsics
        let sx = Float(w) / imgW, sy = Float(h) / imgH
        let fx = k[0][0] * sx, fy = k[1][1] * sy, cx = k[2][0] * sx, cy = k[2][1] * sy
        guard fx > 1, fy > 1 else { return nil }

        let tr = camera.transform
        let camPos = SIMD3<Float>(tr.columns.3.x, tr.columns.3.y, tr.columns.3.z)
        // 相机朝向：传感器坐标系里相机看向 −z，换到世界系再压平到水平面
        let look = -SIMD3<Float>(tr.columns.2.x, tr.columns.2.y, tr.columns.2.z)
        var fwd = SIMD2<Float>(look.x, look.z)
        let fn = simd_length(fwd)
        guard fn > 0.35 else { return nil }          // 相机几乎朝上或朝下，水平朝向不可靠
        fwd /= fn
        let leftDir = SIMD2<Float>(fwd.y, -fwd.x)    // 俯视（x 右、z 下）时，前进方向的左手边

        let floorY = camPos.y - assumedHoldHeightM
        var left: [Float] = [], right: [Float] = []
        let step = 4
        for v in stride(from: 0, to: h, by: step) {
            let row = base.advanced(by: v * rowBytes).assumingMemoryBound(to: Float32.self)
            for u in stride(from: 0, to: w, by: step) {
                let d = row[u]
                guard d.isFinite, d > 0.2, d < 5.5 else { continue }
                // 传感器坐标系：x 右，y 上，z 朝向观察者；图像 v 向下
                let pc = SIMD4<Float>((Float(u) - cx) * d / fx, -(Float(v) - cy) * d / fy, -d, 1)
                let pw = tr * pc
                let y = pw.y - floorY
                guard y >= bandLowM, y <= bandHighM else { continue }
                let rel = SIMD2<Float>(pw.x - camPos.x, pw.z - camPos.z)
                let along = simd_dot(rel, fwd)
                guard along >= forwardMinM, along <= forwardMaxM else { continue }
                let side = simd_dot(rel, leftDir)
                if side > 0.25 { left.append(side) } else if side < -0.25 { right.append(-side) }
            }
        }
        func wall(_ a: [Float]) -> Double? {
            guard a.count >= minSidePoints else { return nil }
            let s = a.sorted()
            return Double(s[s.count / 5]) * 100
        }
        let l = wall(left), r = wall(right)
        if l == nil && r == nil { return nil }
        return DepthLateral(tMs: t, leftCm: l, rightCm: r, leftPoints: left.count, rightPoints: right.count,
                            forwardAR: (Double(fwd.x), Double(fwd.y)))
    }
}

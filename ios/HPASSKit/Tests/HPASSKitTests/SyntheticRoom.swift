import Foundation
import HPASSKit

/// 合成一个小房间 + 几段走过的会话（写成真实的会话目录），测房间地图（没有通道）上的建图和测试评估。
/// 只用公开接口，所以临时可执行目标也能直接用这个文件。
enum SyntheticRoom {
    /// 6 m × 5 m 的房间，一张 1 m × 1 m 的桌子
    static func map() throws -> StoreMap {
        var inp = RoomMapBuilder.Input()
        inp.walls = [
            .init(category: "wall", center: Point2(3, 0), width: 6, depth: 0, height: 2.6, yaw: 0),
            .init(category: "wall", center: Point2(3, 5), width: 6, depth: 0, height: 2.6, yaw: .pi),
            .init(category: "wall", center: Point2(0, 2.5), width: 5, depth: 0, height: 2.6, yaw: .pi / 2),
            .init(category: "wall", center: Point2(6, 2.5), width: 5, depth: 0, height: 2.6, yaw: -.pi / 2),
        ]
        inp.objects = [.init(category: "table", center: Point2(4.5, 3.5), width: 1, depth: 1, height: 0.75, yaw: 0)]
        return try RoomMapBuilder.build(inp, name: "合成房间").map
    }

    /// 地图坐标（cm）处的磁场（设备平放不转，设备系 = 世界系）
    static func field(_ p: Point2) -> (Double, Double, Double) {
        (20 + 8 * sin(p.x / 90) + 5 * cos(p.y / 70), 5 + 6 * sin(p.y / 80 + p.x / 200), -43 + 7 * sin(p.x / 110 + p.y / 95))
    }

    /// 路线：第一段要沿 +y 直走 1.5 m 以上（设朝向用），然后按 waypoints 折线走
    static func writeSession(_ dir: URL, waypoints: [Point2], phi: Double = 0.6, speed: Double = 100) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a0 = Point2(37, -12), p0 = waypoints[0]
        func ar(_ p: Point2) -> Point2 {
            let d = p - p0, c = cos(-phi), s = sin(-phi)
            return Point2(a0.x + d.x * c - d.y * s, a0.y + d.x * s + d.y * c)
        }
        var pts: [Point2] = []                                   // 10 ms 一个点
        for i in 1..<waypoints.count {
            let a = waypoints[i - 1], b = waypoints[i]
            let n = max(Int(a.distance(to: b) / speed * 100), 1)
            for k in 0..<n { pts.append(a + (b - a) * (Double(k) / Double(n))) }
        }
        pts.append(waypoints.last!)
        let T0: Int64 = 1_700_000_000_000
        var imu = "t_ms,ax,ay,az,gx,gy,gz,mx,my,mz\n", raw = "t_ms,x,y,z\n", pose = "t_ms,x,y,z,qx,qy,qz,qw,state\n"
        let bias = (80.0, -110.0, -650.0)
        for (i, p) in pts.enumerated() {
            let t = T0 + Int64(i * 10), f = field(p)
            if i % 2 == 0 { imu += "\(t),0,0,9.81,0,0,0,\(f.0),\(f.1),\(f.2)\n" }
            raw += "\(t),\(f.0 + bias.0),\(f.1 + bias.1),\(f.2 + bias.2)\n"
            if i % 3 == 0 { let a = ar(p); pose += "\(t),\(a.x / 100),0,\(a.y / 100),0,0,0,1,2\n" }
        }
        let anchors = "t_ms,kind,map_x_cm,map_y_cm,ar_x_cm,ar_z_cm,heading_rad,note\n"
            + "\(T0),start,\(p0.x),\(p0.y),\(ar(p0).x),\(ar(p0).y),,\n"
            + "\(T0 + 5),heading,\(p0.x),\(p0.y),\(ar(p0).x),\(ar(p0).y),0,\n"
        try imu.write(to: dir.appendingPathComponent("imu.csv"), atomically: true, encoding: .utf8)
        try raw.write(to: dir.appendingPathComponent("mag_raw.csv"), atomically: true, encoding: .utf8)
        try pose.write(to: dir.appendingPathComponent("arkit_pose.csv"), atomically: true, encoding: .utf8)
        try anchors.write(to: dir.appendingPathComponent("anchors.csv"), atomically: true, encoding: .utf8)
    }

    /// 建图路线：竖着来回扫（x = 200…600，每 100 cm 一趟）
    static var buildRoute: [Point2] {
        var w = [Point2(200, 150)]
        for (i, x) in stride(from: 200.0, through: 600, by: 100).enumerated() {
            let up = i % 2 == 0
            if i > 0 { w.append(Point2(x, w.last!.y)) }
            w.append(Point2(x, up ? 450 : 150))
        }
        return w
    }

    /// 测试路线：先竖着走 1 m，再横着扫（和建图路线不同）
    static var testRoute: [Point2] {
        var w = [Point2(250, 150), Point2(250, 250)]
        for (i, y) in stride(from: 250.0, through: 450, by: 100).enumerated() {
            let right = i % 2 == 0
            if i > 0 { w.append(Point2(w.last!.x, y)) }
            w.append(Point2(right ? 600 : 250, y))
        }
        return w
    }

    /// 建图 + 评估，返回报告
    static func run() throws -> (EvalReport, StoreMap) {
        let map = try Self.map()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synroom_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let b1 = root.appendingPathComponent("build1"), t1 = root.appendingPathComponent("test1")
        try writeSession(b1, waypoints: buildRoute)
        try writeSession(t1, waypoints: testRoute)
        let built = try SessionEvaluator.buildMaps(sessions: [b1], map: map)
        let rep = try SessionEvaluator.evaluate(dir: t1, map: map, field: built.field, ble: nil,
                                                walkable: SessionEvaluator.walkable(map))
        return (rep, map)
    }
}

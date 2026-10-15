import XCTest
@testable import HPASSKit

/// 房间地图没有通道：测试会话的参考轨迹 = 自己的 ARKit + 起点锚点对齐（不贴通道、不做价签修正），
/// 可走区域取地面多边形。这里用合成房间走一遍建图 + 评估，确认整条路能走通。
final class RoomEvaluateTests: XCTestCase {
    func testRoomMapEvaluatesWithoutCorridors() throws {
        let (rep, map) = try SyntheticRoom.run()
        XCTAssertTrue(map.crosses.isEmpty)
        XCTAssertNotNil(SessionEvaluator.walkable(map))
        XCTAssertGreaterThan(rep.refPoints, 20)
        XCTAssertGreaterThan(rep.points, 0)
        XCTAssertGreaterThan(rep.inMapShare ?? 0, 0.5)
        XCTAssertNotNil(rep.medianCm)
    }
}

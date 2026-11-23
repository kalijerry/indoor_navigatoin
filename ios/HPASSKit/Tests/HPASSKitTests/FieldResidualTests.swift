import XCTest
@testable import HPASSKit

/// 磁场图交叉验证（hpass-eval --residuals → tools/bench/map_cv.py）用的诊断：
/// - 没有 truth.csv 的会话（自采建图会话，留一法）给了地图时用它自己的对齐结果当参考，和 evaluate 一样；不给地图时照旧不出残差；
/// - 每条残差带参考位置；
/// - 补空格半径的全局默认（hpass-eval --fill-radius）只在没显式给半径时起作用。
final class FieldResidualTests: XCTestCase {
    func testResidualsForSessionWithoutTruthUseOwnAlignment() throws {
        let map = try SyntheticRoom.map()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fieldres_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let b1 = root.appendingPathComponent("build1"), t1 = root.appendingPathComponent("test1")
        try SyntheticRoom.writeSession(b1, waypoints: SyntheticRoom.buildRoute)
        // 留出的会话：先沿 +y 直走 3 m（设朝向要 ≥ 1.5 m 直线），整体磁场偏几 µT（残差统计时按会话减掉）
        try SyntheticRoom.writeSession(t1, waypoints: [Point2(300, 150), Point2(300, 450), Point2(500, 450), Point2(500, 150)],
                                       magOffset: (3, 2, -2))
        let field = try SessionEvaluator.buildMaps(sessions: [b1], map: map).field

        // 老行为：没有 truth.csv、不给地图 → 没有参考，不出残差
        XCTAssertTrue(try SessionEvaluator.residualSamples(dir: t1, field: field).isEmpty)

        let rs = try SessionEvaluator.residualSamples(dir: t1, field: field, map: map)
        XCTAssertGreaterThan(rs.count, 10)
        // 参考位置在房间里、沿路每 50 cm 一条
        for r in rs {
            XCTAssertTrue(r.reference.x >= 0 && r.reference.x <= map.width && r.reference.y >= 0 && r.reference.y <= map.height)
        }
        XCTAssertGreaterThan(rs.last!.pathCm - rs.first!.pathCm, 400)
        // 合成场：测试路线和建图路线交叉的地方地图有值；参考位置对的话实测和地图强相关（三个分量合起来）
        let withMap = rs.filter { $0.mean != nil }
        XCTAssertGreaterThan(withMap.count, rs.count / 3)
        func corr(_ a: [Double], _ b: [Double]) -> Double {
            let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
            var sab = 0.0, saa = 0.0, sbb = 0.0
            for i in a.indices { sab += (a[i] - ma) * (b[i] - mb); saa += (a[i] - ma) * (a[i] - ma); sbb += (b[i] - mb) * (b[i] - mb) }
            return sab / (saa * sbb).squareRoot()
        }
        let c = [corr(withMap.map(\.feature.total), withMap.map { $0.mean!.total }),
                 corr(withMap.map(\.feature.vertical), withMap.map { $0.mean!.vertical }),
                 corr(withMap.map(\.feature.horizontal), withMap.map { $0.mean!.horizontal })]
        XCTAssertGreaterThan(c.reduce(0, +) / 3, 0.8)
    }

    func testDefaultFillRadiusOnlyAppliesWhenNotGiven() {
        let b = MagneticFieldBuilder(widthCm: 1000, heightCm: 200, cellCm: 50)
        for x in stride(from: 25.0, through: 475, by: 5) {
            for _ in 0..<2 { _ = b.add(position: Point2(x, 125), feature: MagneticFeature(total: 50 + x / 100, vertical: -40, horizontal: 20)) }
        }
        let saved = MagneticFieldBuilder.defaultFillRadiusCm
        defer { MagneticFieldBuilder.defaultFillRadiusCm = saved }
        let measured = b.build(fillRadiusCm: 0).coveredCells
        let normal = b.build().coveredCells
        XCTAssertGreaterThan(normal, measured)                       // 默认 150 cm 会补
        MagneticFieldBuilder.defaultFillRadiusCm = 0
        XCTAssertEqual(b.build().coveredCells, measured)              // 全局默认改成 0：不补
        XCTAssertEqual(b.build(fillRadiusCm: 150).coveredCells, normal) // 显式给的半径优先
    }
}

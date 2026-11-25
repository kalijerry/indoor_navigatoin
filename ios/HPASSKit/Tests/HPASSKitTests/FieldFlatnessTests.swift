import XCTest
@testable import HPASSKit

final class FieldFlatnessTests: XCTestCase {
    /// gradUTPerM：|B| / Bz / Bh 每米都变这么多（沿 x）
    private func field(gradUTPerM g: Double) -> MagneticFieldMap {
        let w = 1000.0, h = 1000.0, cell = 50.0
        let cols = Int(w / cell), rows = Int(h / cell)
        var cells: [MagneticFeature?] = [], sig: [MagneticFeature?] = []
        for _ in 0..<rows {
            for i in 0..<cols {
                let v = g * (Double(i) + 0.5) * cell / 100
                cells.append(MagneticFeature(total: 45 + v, vertical: 40 + v, horizontal: 20 + v))
                sig.append(MagneticFeature(total: 1, vertical: 1, horizontal: 1))
            }
        }
        return MagneticFieldMap(widthCm: w, heightCm: h, cellCm: cell, cells: cells, sigmas: sig)
    }

    func testUniformFieldIsFlat() throws {
        let f = try XCTUnwrap(field(gradUTPerM: 0).flatness())
        XCTAssertEqual(f.contrastMedianUT, 0, accuracy: 1e-9)
        XCTAssertEqual(f.flatShare, 1, accuracy: 1e-9)
    }

    func testGradientFieldContrast() throws {
        let m = field(gradUTPerM: 4)
        // 中间一格：x 方向 ±1 m 差 4 µT、y 方向 0、对角线 1.41 m 差 4 µT（按米折成 2.83）→ (4+4+0+0+4×2.83)/8
        let c = try XCTUnwrap(m.localContrast(at: Point2(525, 525)))
        XCTAssertEqual(c, (8 + 4 * 4 / 2.0.squareRoot()) / 8, accuracy: 1e-6)
        let f = try XCTUnwrap(m.flatness())
        XCTAssertGreaterThan(f.contrastMedianUT, MagneticFieldMap.flatThresholdUT)
        // 只有有数据区域最外一圈（一侧没邻居）会落到 2 µT 以下：20 × 20 格里 4 条边上的 64 格 = 16%
        XCTAssertEqual(f.flatShare, 0.16, accuracy: 1e-9)
        XCTAssertNil(m.localContrast(at: Point2(-10, 10)))
    }
}

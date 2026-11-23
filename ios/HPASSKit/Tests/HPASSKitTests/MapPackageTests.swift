import Foundation
import XCTest
@testable import HPASSKit

final class MapPackageTests: XCTestCase {
    func testRoundTrip() throws {
        try XCTSkipUnless(MapPackage.compressionAvailable, "地图包压缩只在苹果平台可用")
        let b = MagneticFieldBuilder(widthCm: 2000, heightCm: 500, cellCm: 50)
        for x in stride(from: 0.0, to: 2000, by: 10) {
            for _ in 0..<6 { _ = b.add(position: Point2(x, 250), feature: MagneticFeature(total: 50 + sin(x / 100), vertical: -38.25, horizontal: 31)) }
        }
        var field = b.build()
        field.trackingTemperature = 3.25
        let ble = BLEFingerprintMap(cellCm: 200, cells: [], tags: ["88-A7-20-91": .init(x: 123.5, y: 456.25, maxRssi: -61, samples: 12)])
        let mapJSON = Data(#"{"width":2000,"height":500,"mapElementList":[]}"#.utf8)
        let meta = MapPackage.Meta(id: "store_x", name: "测试场地", kind: "store", version: 1791361225163, source: "2 个会话")
        let pkg = try MapPackage.encode(meta: meta, mapJSON: mapJSON, field: field, ble: ble, worldMap: Data([1, 2, 3]))
        let c = try MapPackage.decode(pkg)
        XCTAssertEqual(c.meta.name, "测试场地")
        XCTAssertEqual(c.meta.version, 1791361225163)
        XCTAssertEqual(c.meta.fieldCells, field.coveredCells)
        XCTAssertEqual(c.mapJSON, mapJSON)
        XCTAssertEqual(c.worldMap, Data([1, 2, 3]))
        XCTAssertEqual(c.field?.coveredCells, field.coveredCells)
        // 跟踪似然标定放在说明里，解包后回到磁场图上
        XCTAssertEqual(c.meta.trackingTemperature, 3.25)
        XCTAssertEqual(c.field?.trackingTemperature, 3.25)
        let p = Point2(725, 250)
        XCTAssertEqual(c.field!.sample(at: p)!.mean.total, field.sample(at: p)!.mean.total, accuracy: 0.01)
        XCTAssertEqual(c.field!.sample(at: p)!.mean.vertical, -38.25, accuracy: 0.01)
        XCTAssertEqual(c.ble?.tags["88-A7-20-91"]?.x ?? 0, 123.5, accuracy: 0.01)
        XCTAssertEqual(c.ble?.tags["88-A7-20-91"]?.maxRssi ?? 0, -61, accuracy: 0.5)
        XCTAssertThrowsError(try MapPackage.decode(Data([1, 2, 3])))
    }

    func testPaintSectionAndMerge() throws {
        try XCTSkipUnless(MapPackage.compressionAvailable, "地图包压缩只在苹果平台可用")
        let cross = CrossSegment(code: "C1", a: Point2(100, 100), b: Point2(900, 100), lineWidth: 200)
        let a = CoveragePaint(crosses: [cross], widthCm: 1000, heightCm: 400)
        for x in stride(from: 100.0, through: 500, by: 20) { a.paint(at: Point2(x, 100)) }
        let meta = MapPackage.Meta(id: "m", name: "M", kind: "store", version: 1)
        let pkg = try MapPackage.encode(meta: meta, mapJSON: Data("{}".utf8), field: nil, ble: nil, worldMap: nil, paint: a.serialized(), tagCSV: Data("ESL_ID,Aisle\nA,1".utf8))
        let c = try MapPackage.decode(pkg)
        XCTAssertEqual(c.paint, a.serialized())
        XCTAssertEqual(c.tagCSV.map { String(decoding: $0, as: UTF8.self) }, "ESL_ID,Aisle\nA,1")
        // 本机另一段 + 云端这段 → 合并后两段都在
        let b = CoveragePaint(crosses: [cross], widthCm: 1000, heightCm: 400)
        for x in stride(from: 600.0, through: 900, by: 20) { b.paint(at: Point2(x, 100)) }
        let before = b.paintedCells
        XCTAssertTrue(b.merge(c.paint!))
        XCTAssertEqual(b.paintedCells, before + a.paintedCells)
        let m = CoveragePaint(crosses: [cross], widthCm: 1000, heightCm: 400)
        XCTAssertTrue(m.load(CoveragePaint.mergeSerialized(a.serialized(), b.serialized())))
        XCTAssertEqual(m.paintedCells, b.paintedCells)
        // 旧包（5 段，没有涂色和标签表）还能读
        #if canImport(Darwin)
        let old = try MapPackage.encode(meta: meta, mapJSON: Data("{}".utf8), field: nil, ble: nil, worldMap: nil)
        let raw = try (old as NSData).decompressed(using: .zlib) as Data
        let trimmed = try (raw.dropLast(12) as NSData).compressed(using: .zlib) as Data
        let oc = try MapPackage.decode(trimmed)
        XCTAssertNil(oc.paint); XCTAssertNil(oc.tagCSV)
        #endif
    }
}

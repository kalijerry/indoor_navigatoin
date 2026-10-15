import Foundation
import XCTest
@testable import HPASSKit

final class WorldMapTests: XCTestCase {
    let align = MapARTransform(pRef: Point2(120, 80), aRef: Point2(0, 0), phi: -0.6)

    func testSidecarRoundTripAndEquivalence() throws {
        let s = WorldMapSidecar(createdMs: 1_790_000_000_000, source: "refreshed", mapId: "room_1", arAlign: align, bytes: 1234, uploaded: false)
        let d = try s.encoded()
        let back = try XCTUnwrap(WorldMapSidecar.decode(d))
        XCTAssertEqual(back, s)
        XCTAssertTrue(back.isCompatible(with: align))
        // 同一个映射换一个锚点写法：仍然兼容
        let a2 = Point2(300, -150)
        let alt = MapARTransform(pRef: align.toMap(a2), aRef: a2, phi: align.phi)
        XCTAssertTrue(back.isCompatible(with: alt))
        // 旋转差约 2° / 平移差 20 cm：不兼容
        XCTAssertFalse(back.isCompatible(with: MapARTransform(pRef: align.pRef, aRef: align.aRef, phi: align.phi + 0.035)))
        XCTAssertFalse(back.isCompatible(with: MapARTransform(pRef: Point2(140, 80), aRef: align.aRef, phi: align.phi)))
    }

    func testAlignTransformRoundTripMatchesMap() {
        let t = WorldMapSidecar.Align(align).transform
        let a = Point2(432, -219)
        XCTAssertEqual(t.toAR(t.toMap(a)).distance(to: a), 0, accuracy: 1e-6)
        XCTAssertEqual(t.toMap(a).distance(to: align.toMap(a)), 0, accuracy: 1e-9)
    }

    func input(_ edit: (inout WorldMapPolicy.Input) -> Void = { _ in }) -> WorldMapPolicy.Input {
        var i = WorldMapPolicy.Input(isRoom: true, hasAlign: true, hasStored: true, loadedStored: true, relocalized: true,
                                     trackingNormal: true, mappedEnough: true, insideMap: true, durationSec: 120, storedUploaded: false)
        edit(&i)
        return i
    }

    func testPolicy() {
        XCTAssertEqual(WorldMapPolicy.decide(input()), .refresh)
        // 没认出房间：绝不刷新；本机这份没传过就原样上传一次，传过了就跳过
        if case .uploadStored = WorldMapPolicy.decide(input { $0.relocalized = false }) {} else { XCTFail() }
        if case .skip = WorldMapPolicy.decide(input { $0.relocalized = false; $0.storedUploaded = true }) {} else { XCTFail() }
        let edits: [(inout WorldMapPolicy.Input) -> Void] = [
            { $0.trackingNormal = false }, { $0.mappedEnough = false }, { $0.insideMap = false },
            { $0.durationSec = 5 }, { $0.loadedStored = false }, { $0.relocalized = false },
        ]
        for e in edits { XCTAssertNotEqual(WorldMapPolicy.decide(input(e)), .refresh) }
        XCTAssertEqual(WorldMapPolicy.decide(input { $0.isRoom = false }), .skip(reason: "不是房间地图"))
        XCTAssertEqual(WorldMapPolicy.decide(input { $0.hasStored = false }), .skip(reason: "本机没有视觉特征地图"))
        XCTAssertEqual(WorldMapPolicy.decide(input { $0.hasAlign = false }), .skip(reason: "地图没有 AR 对齐信息"))
    }

    func testInsideAndSize() {
        XCTAssertTrue(WorldMapPolicy.isInside(Point2(500, 400), widthCm: 1000, heightCm: 800))
        XCTAssertTrue(WorldMapPolicy.isInside(Point2(-200, 1050), widthCm: 1000, heightCm: 800))
        XCTAssertFalse(WorldMapPolicy.isInside(Point2(-500, 400), widthCm: 1000, heightCm: 800))
        XCTAssertNil(WorldMapPolicy.sizeProblem(WorldMapPolicy.warnBytes))
        XCTAssertNotNil(WorldMapPolicy.sizeProblem(WorldMapPolicy.maxBytes + 1))
    }

    func testPackageCarriesWorldMap() throws {
        let wm = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let meta = MapPackage.Meta(id: "room_x", name: "办公室", kind: "room", version: 1)
        let pkg = try MapPackage.encode(meta: meta, mapJSON: Data("{}".utf8), field: nil, ble: nil, worldMap: wm,
                                        paint: Data([9]), eslCSV: nil, direction: Data([7]))
        let c = try MapPackage.decode(pkg)
        XCTAssertEqual(c.worldMap, wm)
        XCTAssertEqual(c.paint, Data([9]))
        XCTAssertEqual(c.direction, Data([7]))
        let none = try MapPackage.decode(try MapPackage.encode(meta: meta, mapJSON: Data("{}".utf8), field: nil, ble: nil, worldMap: nil))
        XCTAssertNil(none.worldMap)
    }
}

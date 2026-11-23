import XCTest
@testable import HPASSKit

final class MagneticTests: XCTestCase {

    // 合成的磁场：几个正弦分量叠加，3 个特征各有不同的空间结构。
    private func field(_ p: Point2) -> MagneticFeature {
        let x = p.x / 100, y = p.y / 100
        let bz = -43 + 6 * sin(0.9 * x + 0.4 * y) + 4 * sin(0.5 * x - 1.1 * y + 1)
        let bh = 25 + 7 * sin(0.7 * x - 0.6 * y + 2) + 3 * sin(1.3 * x + 0.8 * y)
        return MagneticFeature(total: (bz * bz + bh * bh).squareRoot(), vertical: bz, horizontal: bh)
    }

    private let route = [Point2(100, 100), Point2(900, 100), Point2(900, 300), Point2(100, 300),
                         Point2(100, 500), Point2(900, 500), Point2(900, 700), Point2(100, 700)]

    private func calibrate() -> MagneticFieldBuilder {
        let b = MagneticFieldBuilder(widthCm: 1000, heightCm: 1000)
        var t: Int64 = 0
        var wps: [MagneticFieldBuilder.Waypoint] = []
        var samples: [MagneticFieldBuilder.TimedFeature] = []
        for (k, p) in route.enumerated() {
            wps.append(.init(tMs: t, position: p))
            t += 2000
            wps.append(.init(tMs: t, position: p))
            guard k + 1 < route.count else { break }
            let q = route[k + 1]
            let dur = Int64(p.distance(to: q) / 120 * 1000)
            for ms in stride(from: t - 2000, to: t + dur, by: 40) {
                let dt = Double(ms - (t - 2000))
                let pos = dt < 2000 ? p : Point2(p.x + (q.x - p.x) * (dt - 2000) / Double(dur),
                                                 p.y + (q.y - p.y) * (dt - 2000) / Double(dur))
                samples.append(.init(tMs: ms, feature: field(pos)))
            }
            t += dur
        }
        XCTAssertGreaterThan(b.addTrack(waypoints: wps, samples: samples), 500)
        return b
    }

    func testFeaturesIgnorePhoneOrientation() {
        // 同一个世界系磁场，手机朝向不同：特征必须一致
        let world = (20.0, 5.0, -43.0)
        func sample(tilt: Double, yaw: Double, t: Int64) -> IMUSample {
            // 先绕 x 倾斜，再绕 z 转航向
            func rot(_ v: (Double, Double, Double)) -> (Double, Double, Double) {
                let (x, y, z) = v
                let y1 = y * cos(tilt) - z * sin(tilt), z1 = y * sin(tilt) + z * cos(tilt)
                return (x * cos(yaw) - y1 * sin(yaw), x * sin(yaw) + y1 * cos(yaw), z1)
            }
            let a = rot((0, 0, 9.81)), m = rot(world)
            return IMUSample(tMs: t, ax: a.0, ay: a.1, az: a.2, gx: 0, gy: 0, gz: 0, mx: m.0, my: m.1, mz: m.2)
        }
        var results: [MagneticFeature] = []
        for (tilt, yaw) in [(0.0, 0.0), (0.5, 1.2), (-0.6, 3.0)] {
            let ex = MagneticFeatureExtractor()
            var last: MagneticFeature?
            for i in 0..<100 { last = ex.process(sample(tilt: tilt, yaw: yaw, t: Int64(i * 20))) }
            results.append(last!)
        }
        for r in results {
            XCTAssertEqual(r.total, results[0].total, accuracy: 0.05)
            XCTAssertEqual(r.vertical, results[0].vertical, accuracy: 0.05)
            XCTAssertEqual(r.horizontal, results[0].horizontal, accuracy: 0.05)
        }
        XCTAssertEqual(results[0].vertical, -43, accuracy: 0.05)
    }

    func testBuilderFillsGapsAndSamplesBilinear() {
        let map = calibrate().build()
        XCTAssertGreaterThan(map.coveredCells, map.totalCells * 2 / 3)   // 补齐后大部分区域有数据
        let on = Point2(500, 100)                              // 在走过的线上
        let s = map.sample(at: on)!
        XCTAssertEqual(s.mean.vertical, field(on).vertical, accuracy: 1.5)
        XCTAssertNil(map.sample(at: Point2(-10, 50)))          // 地图外
    }

    func testJSONRoundTrip() throws {
        let map = calibrate().build()
        let root: [String: Any] = ["width": 1000, "height": 1000, "mapElementList": [Any](),
                                   "markPoints": [["id": "1", "x": 100, "y": 200]],
                                   "magField": map.jsonObject()]
        let data = try JSONSerialization.data(withJSONObject: root)
        let back = try XCTUnwrap(try StoreDataLoader.loadMagneticField(data))
        XCTAssertEqual(back.cols, map.cols)
        XCTAssertEqual(back.coveredCells, map.coveredCells)
        XCTAssertNil(back.trackingTemperature)              // 没标定的图不写这一项，读回来也没有
        var cal = map
        cal.trackingTemperature = 3.456
        let d2 = try JSONSerialization.data(withJSONObject: ["width": 1000, "height": 1000, "mapElementList": [Any](), "magField": cal.jsonObject()])
        XCTAssertEqual(try XCTUnwrap(try StoreDataLoader.loadMagneticField(d2)).trackingTemperature ?? 0, 3.46, accuracy: 1e-9)
        XCTAssertEqual(try StoreDataLoader.loadMarkPoints(data), [MarkPoint(id: "1", x: 100, y: 200)])
        let none = try JSONSerialization.data(withJSONObject: ["width": 1000, "height": 1000, "mapElementList": [Any]()])
        XCTAssertNil(try StoreDataLoader.loadMagneticField(none))
    }

    func testSnapshotRestoresBuilder() throws {
        let b = calibrate()
        let data = try JSONEncoder().encode(b.snapshot())
        let restored = try XCTUnwrap(MagneticFieldBuilder(snapshot: try JSONDecoder().decode(MagneticFieldBuilder.Snapshot.self, from: data)))
        XCTAssertEqual(restored.sampleCount, b.sampleCount)
        XCTAssertEqual(restored.validCells(), b.validCells())
    }

    /// 沿校准过的路线走，惯导带 4% 步长误差和 6° 航向偏差，滤波应该把位置拉回真值附近。
    func testLocalizerTracksWithBiasedPDR() {
        let map = calibrate().build()
        let loc = MagneticLocalizer(field: map, seed: 7)
        loc.reset(start: route[0])
        var errors: [Double] = []
        for k in 0..<(route.count - 1) {
            let a = route[k], b = route[k + 1]
            let n = Int(a.distance(to: b) / 70)
            for s in 1...n {
                let d = Point2((b.x - a.x) / Double(n), (b.y - a.y) / Double(n))
                let truth = Point2(a.x + d.x * Double(s), a.y + d.y * Double(s))
                let ang = 6.0 * Double.pi / 180
                let biased = Point2((d.x * cos(ang) - d.y * sin(ang)) * 1.04, (d.x * sin(ang) + d.y * cos(ang)) * 1.04)
                errors.append(loc.step(delta: biased, feature: field(truth)).position.distance(to: truth))
            }
        }
        errors.sort()
        XCTAssertLessThan(errors[errors.count / 2], 80)
        XCTAssertLessThan(errors[Int(Double(errors.count) * 0.9)], 150)
    }

    func testLocalizerWithoutObservationStaysUncertain() {
        let map = calibrate().build()
        let loc = MagneticLocalizer(field: map, seed: 3)
        let est = loc.estimate()                               // 均匀撒点、没有任何观测
        XCTAssertLessThan(est.confidence, 0.3)
    }

    /// 手动设航向后，不论是否开启罗盘修正，静止时航向都应保持在手动值（罗盘指向别处）。
    func testManualHeadingIsKept() {
        for useMag in [false, true] {
            var cfg = FusionConfig()
            cfg.useCorridorConstraint = false
            cfg.useMagneticHeading = useMag
            let f = FusionEngine(corridors: [], config: cfg)
            f.setInitialPosition(Point2(500, 500), headingRad: nil)
            var t: Int64 = 0
            func feed(_ n: Int) -> FusionOutput? {
                var last: FusionOutput?
                for _ in 0..<n {
                    t += 20
                    let s = IMUSample(tMs: t, ax: 0, ay: 0, az: 9.81, gx: 0, gy: 0, gz: 0, mx: 20, my: 0, mz: -40)
                    if let o = f.process(s) { last = o }
                }
                return last
            }
            _ = feed(200)                       // 罗盘自动初始化
            f.setHeading(1.0)
            let out = feed(1500)                // 30 s
            XCTAssertNotNil(out)
            XCTAssertEqual(out?.headingRad ?? 0, 1.0, accuracy: 0.05, "useMagneticHeading=\(useMag)")
        }
    }
}

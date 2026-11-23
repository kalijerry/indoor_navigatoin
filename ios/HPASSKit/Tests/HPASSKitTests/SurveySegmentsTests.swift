import XCTest
@testable import HPASSKit

final class SurveySegmentsTests: XCTestCase {
    /// 合成磁场：|B| 和 Bz 在 1～2 m 尺度上变化（同 SessionRegistrationTests）
    private func field(_ p: Point2) -> (t: Double, v: Double) {
        (45 + 6 * sin(p.x / 70) + 5 * cos(p.y / 55) + 3 * sin((p.x - p.y) / 90), 30 + 4 * cos(p.x / 60 + p.y / 110))
    }

    /// 一个 L 形：向右 12 m，再向下 8 m（10 Hz，1 m/s）
    private func lTrack(t0: Int64 = 0) -> [(tMs: Int64, p: Point2)] {
        var out: [(tMs: Int64, p: Point2)] = []
        var t = t0
        for i in 0...120 { out.append((t, Point2(200 + Double(i) * 10, 300))); t += 100 }
        for i in 1...80 { out.append((t, Point2(1400, 300 + Double(i) * 10))); t += 100 }
        return out
    }

    func testSplitsAtTurnAndKeepsMinimumLength() {
        let spans = SurveySegments.split(lTrack())
        XCTAssertEqual(spans.count, 2, "\(spans)")
        XCTAssertEqual(spans[0].lengthCm, 1200, accuracy: 60)
        XCTAssertEqual(spans[1].lengthCm, 800, accuracy: 60)
        XCTAssertEqual(spans[0].t1Ms, spans[1].t0Ms)
    }

    func testSplitsLongStraightWalk() {
        let track = (0...500).map { (tMs: Int64($0) * 100, p: Point2(100 + Double($0) * 10, 200)) }   // 50 m
        let spans = SurveySegments.split(track)
        XCTAssertEqual(spans.count, 3)
        XCTAssertTrue(spans.allSatisfy { $0.lengthCm <= 2000 })
    }

    private func piece(_ id: String, _ pts: [Point2], shift: Point2 = .zero, offset: Double = 0, noise: Double = 0, seed: UInt64 = 1) -> SurveySegments.Piece {
        var g = SplitMix(seed)
        return .init(id: id, session: id, samples: pts.map { p in
            let f = field(p)
            let q = Point2(p.x + shift.x, p.y + shift.y)
            return (q, f.t + offset + noise * g.gauss(), f.v + offset + noise * g.gauss())
        }, deleted: false)
    }

    private var corridor: [Point2] { (0...60).map { Point2(300 + Double($0) * 25, 500) } }   // 15 m，25 cm 一个

    func testLonePathIsGrayAndConsistentPairIsGreen() {
        let one = SurveySegments.consistency([piece("a", corridor)])
        XCTAssertEqual(one[0].grade, .gray)
        let two = SurveySegments.consistency([piece("a", corridor, noise: 0.5, seed: 1), piece("b", corridor, offset: 0.3, noise: 0.5, seed: 2)])
        XCTAssertEqual(two.map(\.grade), [.green, .green], "\(two)")
    }

    func testMisplacedSecondPathTurnsBothNonGreenAndThirdPathSingsOutCulprit() {
        // 第二遍画偏了 1.5 m（沿走廊方向）：两遍都对不上
        let a = piece("a", corridor, noise: 0.3, seed: 1)
        let bad = piece("b", corridor, shift: Point2(150, 0), noise: 0.3, seed: 2)
        let two = SurveySegments.consistency([a, bad])
        XCTAssertTrue(two.allSatisfy { $0.grade == .red || $0.grade == .yellow }, "\(two)")
        // 第三遍和 a 一致：a、c 回到绿，b 留红，并建议往回挪约 1.5 m
        let c = piece("c", corridor, noise: 0.3, seed: 3)
        let three = SurveySegments.consistency([a, bad, c])
        XCTAssertEqual(three[0].grade, .green, "\(three[0])")
        XCTAssertEqual(three[2].grade, .green, "\(three[2])")
        XCTAssertEqual(three[1].grade, .red, "\(three[1])")
        XCTAssertEqual(three[1].suggestDx ?? 0, -150, accuracy: 30)
        XCTAssertEqual(three[1].suggestDy ?? 0, 0, accuracy: 30)
        XCTAssertNotNil(three[1].conflicts["a"])
    }

    func testTieBreakBlamesPathFartherFromTruthPoint() {
        var a = piece("a", corridor, noise: 0.3, seed: 1); a.driftM = 3
        var b = piece("b", corridor, shift: Point2(150, 0), noise: 0.3, seed: 2); b.driftM = 40
        let r = SurveySegments.consistency([a, b])
        XCTAssertEqual(r[0].likelyWrong, false, "\(r[0])")
        XCTAssertEqual(r[1].likelyWrong, true, "\(r[1])")
        b.driftM = 6   // 差不到 5 m：分不出
        XCTAssertNil(SurveySegments.consistency([a, b])[1].likelyWrong)
    }

    func testDeletedPieceIsNotAReference() {
        var bad = piece("b", corridor, shift: Point2(150, 0))
        bad.deleted = true
        let r = SurveySegments.consistency([piece("a", corridor), bad])
        XCTAssertEqual(r[0].grade, .gray, "删掉的段不能当参考")
    }

    func testEditApplyAndInverse() {
        let e = SurveySegments.Edit(session: "s", t0Ms: 0, t1Ms: 10, dx: 30, dy: -20, rotDeg: 12, pivotX: 100, pivotY: 50)
        let p = Point2(321, 654)
        let q = e.inverse(e.apply(p))
        XCTAssertEqual(q.x, p.x, accuracy: 1e-6); XCTAssertEqual(q.y, p.y, accuracy: 1e-6)
        let set = SurveySegments.EditSet(edits: [e, .init(session: "s", t0Ms: 20, t1Ms: 30, deleted: true)])
        let se = set.session("s")!
        XCTAssertNotNil(se.pinned(5)); XCTAssertNil(se.pinned(25)); XCTAssertTrue(se.deleted(25)); XCTAssertFalse(se.deleted(5))
        XCTAssertNil(set.session("other"))
        // 看板存的格式：没有 version、没转过的段没有 rotDeg
        let j = #"{"edits":[{"session":"s","t0Ms":1,"t1Ms":9,"dx":5,"dy":6},{"session":"s","t0Ms":10,"t1Ms":20,"deleted":true}]}"#
        let d = try! SurveySegments.EditSet.load(Data(j.utf8))
        XCTAssertEqual(d.edits.count, 2); XCTAssertEqual(d.edits[0].rotDeg, 0); XCTAssertTrue(d.edits[1].isDeleted)
    }
}

/// 可复现的随机数（测试用）
private struct SplitMix {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> Double {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
    mutating func gauss() -> Double { (-2 * log(max(next(), 1e-12))).squareRoot() * cos(2 * .pi * next()) }
}

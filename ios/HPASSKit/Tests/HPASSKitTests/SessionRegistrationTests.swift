import XCTest
@testable import HPASSKit

final class SessionRegistrationTests: XCTestCase {
    /// 合成磁场：|B| 和 Bz 在 1～2 m 尺度上变化
    private func field(_ p: Point2) -> MagneticFeature {
        let t = 45 + 6 * sin(p.x / 70) + 5 * cos(p.y / 55) + 3 * sin((p.x - p.y) / 90)
        let v = 30 + 4 * cos(p.x / 60 + p.y / 110)
        return MagneticFeature(total: t, vertical: v, horizontal: (max(t * t - v * v, 0)).squareRoot())
    }

    /// 绕一个 6 m × 16 m 的长方形走一圈（1 m/s，50 Hz）
    private func loop() -> [(p: Point2, tMs: Int64)] {
        let corners = [Point2(300, 200), Point2(900, 200), Point2(900, 1800), Point2(300, 1800), Point2(300, 200)]
        var out: [(Point2, Int64)] = []
        var t: Int64 = 0
        for k in 0..<(corners.count - 1) {
            let a = corners[k], b = corners[k + 1]
            let n = Int(a.distance(to: b) / 2)
            for i in 0..<n {
                let f = Double(i) / Double(n)
                out.append((Point2(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f), t))
                t += 20
            }
        }
        return out
    }

    /// 真轨迹按「起点偏 + 朝向偏」歪掉后的会话
    private func session(_ name: String, shift: Point2, rotDeg: Double, offsetUT: Double = 0) -> SessionRegistration.Session {
        let path = loop()
        let piv = path[0].p, th = rotDeg * .pi / 180
        let samples = path.map { x -> (p: Point2, f: MagneticFeature, tMs: Int64) in
            let d = x.p - piv
            let q = Point2(piv.x + d.x * cos(th) - d.y * sin(th) + shift.x, piv.y + d.x * sin(th) + d.y * cos(th) + shift.y)
            return (q, field(x.p) + MagneticFeature(total: offsetUT, vertical: offsetUT, horizontal: 0), x.tMs)
        }
        return .init(name: name, samples: samples)
    }

    /// 两遍修正后同一个真实位置的距离（中位，cm）
    private func misalignment(_ a: SessionRegistration.Session, _ ra: SessionRegistration.Rigid,
                              _ b: SessionRegistration.Session, _ rb: SessionRegistration.Rigid) -> Double {
        let d = zip(a.samples, b.samples).map { ra.apply($0.0.p).distance(to: rb.apply($0.1.p)) }.sorted()
        return d[d.count / 2]
    }

    func testAlignsMisplacedPassToOthers() {
        let s = [session("a", shift: .zero, rotDeg: 0),
                 session("b", shift: .zero, rotDeg: 0, offsetUT: -3),
                 session("c", shift: Point2(75, -50), rotDeg: -3, offsetUT: 4)]
        let reg = SessionRegistration(widthCm: 1200, heightCm: 2000, walkable: nil)
        let r = reg.solve(s)
        let before = misalignment(s[0], .identity(pivot: s[0].samples[0].p), s[2], .identity(pivot: s[2].samples[0].p))
        let after = misalignment(s[0], r[0], s[2], r[2])
        XCTAssertGreaterThan(before, 80)
        XCTAssertLessThan(after, 30, "c 没对齐到 a / b：\(r)")
        XCTAssertLessThan(misalignment(s[0], r[0], s[1], r[1]), 20)
        XCTAssertLessThan(r[2].residualAfter ?? 99, 1.5)
    }

    /// 只有两遍时同时更新不能来回「换位置」
    func testTwoPassesConvergeInsteadOfSwapping() {
        let s = [session("a", shift: .zero, rotDeg: 0), session("b", shift: Point2(-75, 50), rotDeg: 2)]
        let r = SessionRegistration(widthCm: 1200, heightCm: 2000, walkable: nil).solve(s)
        let before = misalignment(s[0], .identity(pivot: s[0].samples[0].p), s[1], .identity(pivot: s[1].samples[0].p))
        XCTAssertLessThan(misalignment(s[0], r[0], s[1], r[1]), before / 3, "\(r)")
    }

    /// 路上定过位置的遍不挪（只当参考）；别的遍照样对齐到它
    func testMultiplyAnchoredPassStaysPut() {
        var s = [session("a", shift: .zero, rotDeg: 0),
                 session("b", shift: Point2(-60, 40), rotDeg: 2, offsetUT: 3)]
        s[0].fixed = true
        let r = SessionRegistration(widthCm: 1200, heightCm: 2000, walkable: nil).solve(s)
        XCTAssertTrue(r[0].isIdentity, "\(r[0])")
        XCTAssertLessThan(misalignment(s[0], r[0], s[1], r[1]), 30, "\(r[1])")
        // 只有路上定过位置的遍：一个都不挪
        var t = s
        t[1].fixed = true
        XCTAssertTrue(SessionRegistration(widthCm: 1200, heightCm: 2000, walkable: nil).solve(t).allSatisfy(\.isIdentity))
    }

    func testMultiplyAnchoredDetection() {
        func a(_ kind: String, _ x: Double) -> SurveySession.Anchor {
            .init(tMs: 0, kind: kind, map: Point2(x, 100), ar: .zero, heading: nil)
        }
        XCTAssertFalse(SessionRegistration.Session.isMultiplyAnchored([a("align", 0), a("start", 100), a("heading", 400)]))
        XCTAssertFalse(SessionRegistration.Session.isMultiplyAnchored([a("start", 100), a("reanchor", 120)]))   // 原地再点一次
        XCTAssertTrue(SessionRegistration.Session.isMultiplyAnchored([a("start", 100), a("reanchor", 900)]))
        XCTAssertFalse(SessionRegistration.Session.isMultiplyAnchored([]))
    }

    /// 和别的遍没有重叠时只按可走区域：穿墙的轨迹被拉回地板上
    func testPullsLonePassBackOntoFloor() {
        let floor = [[Point2(250, 150), Point2(950, 150), Point2(950, 1850), Point2(250, 1850)]]
        let wm = WalkableMap(floor: floor, obstacles: [], widthCm: 1200, heightCm: 2000)
        let s = [session("a", shift: Point2(150, 0), rotDeg: 0)]
        let r = SessionRegistration(widthCm: 1200, heightCm: 2000, walkable: wm).solve(s)
        XCTAssertLessThan(r[0].insideBefore, 0.8)
        XCTAssertGreaterThan(r[0].insideAfter, 0.9)
        XCTAssertLessThan(r[0].dx, -80)
        XCTAssertNil(r[0].residualAfter)
    }

    func testIdentityApplyAndCodable() throws {
        let r = SessionRegistration.Rigid(dx: 10, dy: -5, rotDeg: 90, pivotX: 100, pivotY: 100, residualBefore: 3, residualAfter: 2,
                                          insideBefore: 0.9, insideAfter: 1)
        let q = r.apply(Point2(200, 100))
        XCTAssertEqual(q.x, 110, accuracy: 1e-9)
        XCTAssertEqual(q.y, 195, accuracy: 1e-9)
        let back = try JSONDecoder().decode(SessionRegistration.Rigid.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
        XCTAssertTrue(SessionRegistration.Rigid.identity(pivot: .zero).isIdentity)
    }
}

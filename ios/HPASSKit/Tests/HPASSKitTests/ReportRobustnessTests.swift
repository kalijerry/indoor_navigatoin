import XCTest
@testable import HPASSKit

/// 报的位置稳不稳、报的不确定度诚不诚实：评估器的标定 / 跳点统计（LocalizationEvaluator → EvalReport → tools/lab/lab.py）
final class ReportRobustnessTests: XCTestCase {
    private func est(_ p: Point2, unc: Double, converged: Bool = true) -> MagneticEstimate {
        MagneticEstimate(position: p, uncertaintyCm: unc, confidence: 1, effectiveRatio: 1, updates: 1, converged: converged)
    }

    /// 相邻两个有把握的点之间估计 / 参考走过的路、> 3 m 的跳；没把握的点打断连续（不算跳，也不算路）；不确定度和误差一一对应
    func testEvaluatorPathRatioJumpsAndUncertainty() {
        let ev = LocalizationEvaluator()
        ev.add(estimate: est(Point2(0, 0), unc: 100), reference: Point2(0, 0))
        ev.add(estimate: est(Point2(0, 20), unc: 100), reference: Point2(0, 20))       // 跟着走 20 cm
        ev.add(estimate: est(Point2(0, 420), unc: .infinity), reference: Point2(0, 40)) // 跳 4 m，不确定度没报
        ev.add(estimate: est(Point2(0, 900), unc: 50, converged: false), reference: Point2(0, 60))   // 没把握：打断
        ev.add(estimate: est(Point2(0, 80), unc: 50), reference: Point2(0, 80))         // 重新开始，不算从 420 跳回来
        ev.add(estimate: est(Point2(0, 100), unc: 50), reference: Point2(0, 100))
        XCTAssertEqual(ev.errors.count, 5)
        XCTAssertEqual(ev.uncertainties, [100, 100, -1, 50, 50])
        XCTAssertEqual(ev.bigJumps, 1)
        XCTAssertEqual(ev.estPathCm, 20 + 400 + 20, accuracy: 1e-9)
        XCTAssertEqual(ev.refPathFixCm, 20 + 20 + 20, accuracy: 1e-9)
        XCTAssertEqual(ev.jumps, 1)
    }
}

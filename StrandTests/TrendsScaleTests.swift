import XCTest
import StrandDesign
import WhoopStore
@testable import Strand

/// Trends screen unit/scale regressions (synthetic data only).
///
/// 1. "Week in review" Rest used `efficiency × 100`. Imported WHOOP rows already carry efficiency on a
///    0–100 axis, so the card showed 9343. Rest must be the 0–100 `sleep_performance` score instead.
/// 2. The "Daily signals" Effort chart plotted the stored 0–100 values (axis up to 40+) while its stats
///    were converted to the WHOOP 0–21 scale. The plotted series must use the displayed scale.
final class TrendsScaleTests: XCTestCase {

    private func day(_ key: String, efficiency: Double?) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: 420, efficiency: efficiency, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                    strain: nil, exerciseCount: nil)
    }

    // MARK: Rest

    func testRestUsesSleepPerformanceNotImportedEfficiencyPercent() throws {
        // Imported rows: efficiency already 0–100 (93.4), sleep_performance 79.
        let d = day("2026-07-20", efficiency: 93.4)
        let rest = try XCTUnwrap(TrendsMetrics.restScore(for: d, performanceByDay: ["2026-07-20": 79]))
        XCTAssertEqual(rest, 79, accuracy: 0.001)
        XCTAssertLessThanOrEqual(rest, 100)
    }

    func testRestUsesSleepPerformanceForComputedFractionEfficiency() throws {
        // On-device rows: efficiency is a 0–1 fraction; the score still comes from sleep_performance.
        let d = day("2026-10-14", efficiency: 0.91)
        let rest = try XCTUnwrap(TrendsMetrics.restScore(for: d, performanceByDay: ["2026-10-14": 72.5]))
        XCTAssertEqual(rest, 72.5, accuracy: 0.001)
    }

    func testRestIsNilWithoutPerformanceScore() {
        let d = day("2026-07-21", efficiency: 90)
        XCTAssertNil(TrendsMetrics.restScore(for: d, performanceByDay: [:]))
    }

    // MARK: Effort

    func testEffortPlottedConvertsToWhoopScaleSoChartMatchesStats() {
        let stored = TrendPoint(date: Date(timeIntervalSince1970: 0), value: 100.0 / 21.0 * 10.0)
        let whoop = TrendsMetrics.effortPlotted(stored, scale: .whoop)
        XCTAssertEqual(whoop.value, 10.0, accuracy: 0.0001)
        // Same number the stats print for that stored value.
        XCTAssertEqual(String(format: "%.1f", whoop.value),
                       UnitFormatter.effortDisplay(stored.value, scale: .whoop))
        XCTAssertEqual(whoop.date, stored.date)
    }

    func testEffortPlottedLeavesHundredScaleUntouched() {
        let stored = TrendPoint(date: Date(timeIntervalSince1970: 86_400), value: 47.6)
        XCTAssertEqual(TrendsMetrics.effortPlotted(stored, scale: .hundred).value, 47.6, accuracy: 0.0001)
    }

    func testEffortPlottedMaxNeverExceedsScaleCeiling() {
        let points = [0.0, 23.3, 98.1, 100].map {
            TrendPoint(date: Date(timeIntervalSince1970: $0 * 1000), value: $0)
        }
        let plotted = points.map { TrendsMetrics.effortPlotted($0, scale: .whoop).value }
        XCTAssertLessThanOrEqual(plotted.max() ?? 0, 21.0 + 1e-9)
    }
}

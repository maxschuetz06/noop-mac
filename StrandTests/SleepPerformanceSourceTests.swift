import XCTest
import WhoopStore
@testable import Strand

/// Pins the Sleep hero source badge: the score comes from the newest day that HAS a score, so its
/// provenance must be resolved from that same day, not from `days.last` (which can be a later day
/// without sleep data, e.g. today before the first night is scored).
final class SleepPerformanceSourceTests: XCTestCase {

    private func day(_ key: String, asleep: Double?) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: asleep, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                    strain: nil, exerciseCount: nil)
    }

    func testImportedNightIsWhoopEvenWhenLaterDayHasNoSleep() {
        let days = [day("2026-07-22", asleep: 452), day("2026-07-23", asleep: 395),
                    day("2026-10-14", asleep: nil)]   // newest row has no sleep and no import
        let imported = ["2026-07-22": ImportedSleepFigures(performancePct: 80),
                        "2026-07-23": ImportedSleepFigures(performancePct: 79)]
        let points = SleepPerformanceResolver.points(days: days, imported: imported, needMin: 450)
        XCTAssertEqual(points.last?.value, 79)
        XCTAssertEqual(points.last?.day, "2026-07-23")
        XCTAssertEqual(SleepPerformanceResolver.source(of: points), .whoop)
        XCTAssertEqual(SleepPerformanceResolver.source(of: points).badge, "Whoop")
    }

    func testComputedNightIsOnDevice() {
        let days = [day("2026-07-23", asleep: 395), day("2026-10-13", asleep: 420)]
        let imported = ["2026-07-23": ImportedSleepFigures(performancePct: 79)]
        let points = SleepPerformanceResolver.points(days: days, imported: imported, needMin: 450)
        XCTAssertEqual(points.last?.day, "2026-10-13")
        XCTAssertEqual(SleepPerformanceResolver.source(of: points), .onDevice)
        XCTAssertEqual(SleepPerformanceResolver.source(of: points).badge, "On-device")
    }

    func testNoScoreFallsBackToOnDevice() {
        let points = SleepPerformanceResolver.points(days: [day("2026-10-14", asleep: nil)],
                                                     imported: [:], needMin: 450)
        XCTAssertTrue(points.isEmpty)
        XCTAssertEqual(SleepPerformanceResolver.source(of: points), .onDevice)
    }

    func testNightSourceKeyedByWakeDay() {
        let imported = ["2026-07-23": ImportedSleepFigures(performancePct: 79)]
        XCTAssertEqual(SleepPerformanceResolver.nightSource(wakeDay: "2026-07-23", imported: imported), .whoop)
        XCTAssertEqual(SleepPerformanceResolver.nightSource(wakeDay: "2026-07-24", imported: imported), .onDevice)
    }
}

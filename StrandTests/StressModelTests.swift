import XCTest
import WhoopStore
@testable import Strand

/// Pins the Stress screen's headline-day resolution. An imported WHOOP export ends months before
/// "today", and the daily-metric table gets empty rows for the days since — the screen used to
/// anchor on `days.last` (an empty row), find no stored/derived value and show the empty state
/// although 285 imported day-stress values existed.
final class StressModelTests: XCTestCase {

    private func row(_ day: String, rhr: Int? = nil, hrv: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv,
                    recovery: nil, strain: nil, exerciseCount: nil)
    }

    private func dayString(_ offset: Int, from start: String = "2026-06-01") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        let base = f.date(from: start)!
        return f.string(from: base.addingTimeInterval(Double(offset) * 86_400))
    }

    /// 40 imported days (2026-06-01…2026-07-10) with stress + RHR/HRV, then empty rows for "today"
    /// and a few days in between — exactly the shape of an import that ends long before now.
    private func importedThenEmpty() -> (days: [DailyMetric], stored: [(day: String, value: Double)]) {
        var days: [DailyMetric] = []
        var stored: [(day: String, value: Double)] = []
        for i in 0..<40 {
            let d = dayString(i)
            days.append(row(d, rhr: 55 + i % 4, hrv: 60 + Double(i % 5)))
            stored.append((d, Double(i % 31) / 10.0))      // 0.0…3.0
        }
        for d in ["2026-10-07", "2026-10-09", "2026-10-14"] { days.append(row(d)) }
        return (days, stored)
    }

    func testEmptyTrailingRows_fallBackToLatestImportedDay() throws {
        let (days, stored) = importedThenEmpty()
        let model = try XCTUnwrap(StressModel(days: days, stored: stored, todayKey: "2026-10-14"),
                                  "imported stress history must not yield an empty state")
        XCTAssertEqual(model.scoreDay, "2026-07-10")
        XCTAssertFalse(model.isToday)
        XCTAssertTrue(model.usingStored)
        XCTAssertEqual(model.score, stored.last!.value, accuracy: 0.0001)
        XCTAssertEqual(model.fullTrend.count, 40, "trend shows the whole imported history")
        XCTAssertEqual(model.rhrToday, 55 + 39 % 4)
    }

    func testStoredOnlyHistory_withoutAnyDailyRows() throws {
        let stored = [("2026-07-08", 1.1), ("2026-07-09", 2.4)]
        let model = try XCTUnwrap(StressModel(days: [], stored: stored, todayKey: "2026-10-14"))
        XCTAssertEqual(model.scoreDay, "2026-07-09")
        XCTAssertEqual(model.score, 2.4, accuracy: 0.0001)
        XCTAssertEqual(model.band.title, "HIGH")
        XCTAssertEqual(model.fullTrend.count, 2)
        XCTAssertNil(model.rhrToday)
    }

    func testTodayWithStoredValue_staysTheHeadline() throws {
        var (days, stored) = importedThenEmpty()
        stored.append(("2026-10-14", 0.4))
        days[days.count - 1] = row("2026-10-14", rhr: 52, hrv: 70)
        let model = try XCTUnwrap(StressModel(days: days, stored: stored, todayKey: "2026-10-14"))
        XCTAssertEqual(model.scoreDay, "2026-10-14")
        XCTAssertTrue(model.isToday)
        XCTAssertEqual(model.score, 0.4, accuracy: 0.0001)
    }

    func testOnDeviceDerivation_whenTodayHasSignalButNoStoredValue() throws {
        var days: [DailyMetric] = (0..<30).map { row(dayString($0), rhr: 55 + $0 % 3, hrv: 60 + Double($0 % 4)) }
        days.append(row("2026-07-01", rhr: 70, hrv: 30))   // RHR up, HRV down → high load
        let model = try XCTUnwrap(StressModel(days: days, stored: [], todayKey: "2026-07-01"))
        XCTAssertEqual(model.scoreDay, "2026-07-01")
        XCTAssertTrue(model.isToday)
        XCTAssertFalse(model.usingStored)
        XCTAssertGreaterThan(model.score, 2.0)
    }

    func testNoSignalAtAll_isNil() {
        XCTAssertNil(StressModel(days: [row("2026-10-14")], stored: [], todayKey: "2026-10-14"))
        XCTAssertNil(StressModel(days: [], stored: [], todayKey: "2026-10-14"))
    }

    /// An old headline day must never be described as "today", even when its RHR/HRV deltas exist.
    func testOldHeadlineDay_explanationNeverSaysToday() throws {
        let (days, stored) = importedThenEmpty()
        let model = try XCTUnwrap(StressModel(days: days, stored: stored, todayKey: "2026-10-14"))
        XCTAssertFalse(model.isToday)
        XCTAssertFalse(model.explanation.lowercased().contains("today"), model.explanation)
        for band in [StressBand.low, .medium, .high] {
            for (r, h) in [(5.0, -5.0), (-5.0, 5.0), (nil, nil), (0.0, 0.0)] as [(Double?, Double?)] {
                let text = StressMath.explanation(band: band, rhrDelta: r, hrvDelta: h,
                                                  usingStored: true, isCurrent: false)
                XCTAssertFalse(text.lowercased().contains("today"), text)
                XCTAssertTrue(text.contains("latest recorded day"), text)
            }
        }
    }
}

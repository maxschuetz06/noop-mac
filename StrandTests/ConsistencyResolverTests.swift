import XCTest
import WhoopStore
@testable import Strand

/// Pins the "newest day that HAS a value" rule for the Sleep consistency tile and the Recovery
/// contributors card: a trailing row without data (today before the first night is scored, or any day
/// after an import's end) must neither switch the tile to the approximation nor blank the contributors.
final class ConsistencyResolverTests: XCTestCase {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func day(_ key: String, asleep: Double? = nil, hrv: Double? = nil, rhr: Int? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: asleep, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil,
                    strain: nil, exerciseCount: nil)
    }

    /// Epoch seconds of "yyyy-MM-dd" + hour:minute in UTC.
    private func ts(_ date: String, _ hour: Int, _ minute: Int = 0) -> Int {
        let p = date.split(separator: "-").map { Int($0)! }
        let comps = DateComponents(year: p[0], month: p[1], day: p[2], hour: hour, minute: minute)
        return Int(utc.date(from: comps)!.timeIntervalSince1970)
    }

    private func session(bed: Int, wake: Int) -> CachedSleepSession {
        CachedSleepSession(startTs: bed, endTs: wake, efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
    }

    private func wakeDay(_ s: CachedSleepSession) -> String {
        let f = DateFormatter()
        f.calendar = utc; f.timeZone = utc.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
    }

    private func points(days: [DailyMetric], imported: [String: ImportedSleepFigures],
                        sessions: [CachedSleepSession]) -> [SleepConsistencyResolver.Point] {
        SleepConsistencyResolver.points(days: days, imported: imported, sessions: sessions,
                                        calendar: utc, dayKey: wakeDay)
    }

    func testImportedConsistencyWinsWhenTrailingDayIsEmpty() {
        let days = [day("2026-07-22", asleep: 452), day("2026-07-23", asleep: 395),
                    day("2026-10-14")]   // newest row: no sleep, no import
        let imported = ["2026-07-22": ImportedSleepFigures(consistencyPct: 70),
                        "2026-07-23": ImportedSleepFigures(consistencyPct: 64)]
        // Bedtimes would approximate to something else entirely — the import must still win.
        let sessions = [session(bed: ts("2026-07-20", 22), wake: ts("2026-07-21", 6)),
                        session(bed: ts("2026-07-21", 23, 30), wake: ts("2026-07-22", 7)),
                        session(bed: ts("2026-07-23", 2), wake: ts("2026-07-23", 9))]
        let pts = points(days: days, imported: imported, sessions: sessions)
        XCTAssertEqual(pts.map(\.value), [70, 64])
        XCTAssertEqual(pts.last?.day, "2026-07-23")
        XCTAssertEqual(pts.last?.source, .whoop)
    }

    func testApproximationFillsOnlyDaysWithoutImport() {
        // Five identical 23:00 bedtimes → spread 0 → approximate score 100 once the window holds 3.
        let sessions = (20...24).map { d in
            session(bed: ts("2026-07-\(d - 1)", 23), wake: ts("2026-07-\(d)", 7))
        }
        let days = ["2026-07-21", "2026-07-22", "2026-07-23", "2026-07-24", "2026-10-14"].map { day($0) }
        let imported = ["2026-07-22": ImportedSleepFigures(consistencyPct: 64)]
        let pts = points(days: days, imported: imported, sessions: sessions)
        XCTAssertEqual(pts.map(\.day), ["2026-07-22", "2026-07-23", "2026-07-24"])
        XCTAssertEqual(pts.map(\.value), [64, 100, 100])
        XCTAssertEqual(pts.map(\.source), [.whoop, .onDevice, .onDevice])
    }

    func testApproximationMatchesBedtimeSpreadFormula() {
        // 22:00, 23:00, 00:00 → 1320, 1380, 1440 min; SD = √2400; score = 100·(1 − SD/120).
        let sessions = [session(bed: ts("2026-07-20", 22), wake: ts("2026-07-21", 6)),
                        session(bed: ts("2026-07-21", 23), wake: ts("2026-07-22", 7)),
                        session(bed: ts("2026-07-23", 0), wake: ts("2026-07-23", 8))]
        let approx = SleepConsistencyResolver.approximateByDay(sessions: sessions, calendar: utc, dayKey: wakeDay)
        XCTAssertEqual(approx.count, 1)
        XCTAssertEqual(approx["2026-07-23"] ?? -1, 100 * (1 - 2400.0.squareRoot() / 120), accuracy: 1e-9)
    }

    func testTooFewSessionsAndNoImportYieldsNothing() {
        let sessions = [session(bed: ts("2026-07-20", 22), wake: ts("2026-07-21", 6)),
                        session(bed: ts("2026-07-21", 22), wake: ts("2026-07-22", 6))]
        XCTAssertTrue(points(days: [day("2026-07-22")], imported: [:], sessions: sessions).isEmpty)
    }

    func testContributorAnchorSkipsTrailingEmptyDays() {
        let days = [day("2026-07-21", asleep: 430, hrv: 50, rhr: 52),
                    day("2026-07-22", asleep: 452, hrv: 55, rhr: 51),
                    day("2026-07-23", asleep: 395, hrv: 48, rhr: 53),
                    day("2026-10-07"), day("2026-10-14")]
        let anchor = RecoveryContributorAnchor.resolve(days: days)
        XCTAssertEqual(anchor.latest?.day, "2026-07-23")
        XCTAssertEqual(anchor.prior.map(\.day), ["2026-07-21", "2026-07-22"])
    }

    func testContributorAnchorWithoutAnyDataHasNoLatest() {
        let anchor = RecoveryContributorAnchor.resolve(days: [day("2026-10-14")])
        XCTAssertNil(anchor.latest)
        XCTAssertEqual(anchor.prior.count, 1)
    }

    func testContributorAnchorIsLastDayWhenItHasData() {
        let days = [day("2026-10-13", hrv: 50), day("2026-10-14", hrv: 52)]
        let anchor = RecoveryContributorAnchor.resolve(days: days)
        XCTAssertEqual(anchor.latest?.day, "2026-10-14")
        XCTAssertEqual(anchor.prior.map(\.day), ["2026-10-13"])
    }
}

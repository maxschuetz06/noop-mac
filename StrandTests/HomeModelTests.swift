import XCTest
import WhoopStore
@testable import Strand

/// Pure derivations behind the redesigned home screen: windows, insights and the day timeline.
final class HomeModelTests: XCTestCase {

    private func key(_ daysBack: Int, from anchor: String = "2026-10-19") -> String {
        let d = HomeModel.dayParser.date(from: anchor)!
        return HomeModel.dayParser.string(from: Calendar.current.date(byAdding: .day, value: -daysBack, to: d)!)
    }

    private func day(_ daysBack: Int, hrv: Double? = nil, rhr: Int? = nil, sleep: Double? = nil) -> DailyMetric {
        DailyMetric(day: key(daysBack), totalSleepMin: sleep, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil,
                    strain: nil, exerciseCount: nil)
    }

    /// 35 days oldest → newest: baseline values for days 34…7, recent values for 6…0.
    private func history(recentHrv: Double, baseHrv: Double, recentRhr: Int, baseRhr: Int,
                         recentSleep: Double, baseSleep: Double) -> [DailyMetric] {
        (0..<35).reversed().map { back in
            back < 7 ? day(back, hrv: recentHrv, rhr: recentRhr, sleep: recentSleep)
                     : day(back, hrv: baseHrv, rhr: baseRhr, sleep: baseSleep)
        }
    }

    func testWeekChangeComparesLastSevenDaysWithThePriorFourWeeks() throws {
        let days = history(recentHrv: 60, baseHrv: 50, recentRhr: 55, baseRhr: 55, recentSleep: 420, baseSleep: 420)
        let pct = try XCTUnwrap(HomeModel.weekChangePercent(days, dayKey: key(0)) { $0.avgHrv })
        XCTAssertEqual(pct, 20, accuracy: 0.001)
    }

    func testNoInsightsWithoutEnoughData() {
        let days = [day(0, hrv: 60, rhr: 50, sleep: 400), day(1, hrv: 58, rhr: 51, sleep: 410)]
        XCTAssertTrue(HomeModel.insights(days: days, sleeps: [], dayKey: key(0)).isEmpty)
    }

    func testInsightsReflectRealChanges() {
        let days = history(recentHrv: 60, baseHrv: 50, recentRhr: 60, baseRhr: 55, recentSleep: 450, baseSleep: 420)
        let insights = HomeModel.insights(days: days, sleeps: [], dayKey: key(0))
        let byTopic = Dictionary(uniqueKeysWithValues: insights.map { ($0.topic, $0) })
        XCTAssertEqual(byTopic[.hrv]?.tone, .positive)
        XCTAssertEqual(resolved(byTopic[.hrv]?.title, "en_US"), "Your HRV is 20 % above your average")
        XCTAssertEqual(resolved(byTopic[.hrv]?.title, "de_DE"), "Deine HRV liegt 20 % über deinem Schnitt")
        XCTAssertEqual(resolved(byTopic[.sleep]?.title, "en_US"), "You're sleeping 30 min longer this week")
        XCTAssertEqual(resolved(byTopic[.sleep]?.title, "de_DE"), "Du schläfst diese Woche 30 min länger")
        XCTAssertEqual(resolved(byTopic[.sleep]?.detail, "de_DE"), "Im Schnitt 7 h 30 min pro Nacht")
        XCTAssertEqual(byTopic[.restingHr]?.tone, .caution)
        XCTAssertNil(byTopic[.bedtime], "no sleep sessions → no bedtime insight")
    }

    func testFutureRowsNeverEnterTheWindow() {
        var days = history(recentHrv: 50, baseHrv: 50, recentRhr: 55, baseRhr: 55, recentSleep: 420, baseSleep: 420)
        days.append(DailyMetric(day: "2026-10-25", totalSleepMin: 900, efficiency: nil, deepMin: nil, remMin: nil,
                                lightMin: nil, disturbances: nil, restingHr: 99, avgHrv: 500, recovery: nil,
                                strain: nil, exerciseCount: nil))
        let pct = HomeModel.weekChangePercent(days, dayKey: key(0)) { $0.avgHrv }
        XCTAssertEqual(pct ?? .nan, 0, accuracy: 0.001)
    }

    func testBedtimeSpreadHandlesMidnightCrossing() throws {
        let anchor = HomeModel.dayParser.date(from: key(0))!
        // Onsets alternating 23:30 and 00:30 → ±30 min around 00:00, not ±12 h.
        let sleeps: [CachedSleepSession] = (0..<6).map { i in
            let night = Calendar.current.date(byAdding: .day, value: -i, to: anchor)!
            let onset = Calendar.current.date(bySettingHour: 0, minute: 30, second: 0, of: night)!
                .addingTimeInterval(i.isMultiple(of: 2) ? -3600 : 0)
            let s = Int(onset.timeIntervalSince1970)
            return CachedSleepSession(startTs: s, endTs: s + 7 * 3600, efficiency: nil, restingHr: nil,
                                      avgHrv: nil, stagesJSON: nil)
        }
        let spread = try XCTUnwrap(HomeModel.bedtimeSpreadMinutes(sleeps: sleeps, dayKey: key(0)))
        XCTAssertEqual(spread, 30)
    }

    func testTimelineClipsToTheDayAndMarksRunningItems() {
        let dayStart = HomeModel.dayParser.date(from: key(0))!
        let t0 = Int(dayStart.timeIntervalSince1970)
        let sleep = CachedSleepSession(startTs: t0 - 2 * 3600, endTs: t0 + 7 * 3600, efficiency: nil, restingHr: nil,
                                       avgHrv: nil, stagesJSON: nil)
        let old = CachedSleepSession(startTs: t0 - 30 * 3600, endTs: t0 - 23 * 3600, efficiency: nil, restingHr: nil,
                                     avgHrv: nil, stagesJSON: nil)
        let run = WorkoutRow(startTs: t0 + 17 * 3600, endTs: t0 + 18 * 3600, sport: "running", source: "x",
                             durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                             distanceM: nil, zonesJSON: nil, notes: nil)
        let now = Date(timeIntervalSince1970: TimeInterval(t0 + 17 * 3600 + 600))
        let items = HomeModel.timeline(dayStart: dayStart, sleeps: [old, sleep], workouts: [run], now: now)
        XCTAssertEqual(items.map(\.kind), [.sleep, .workout])
        XCTAssertEqual(items[0].status, .completed)
        XCTAssertEqual(items[1].status, .running)
        XCTAssertEqual(resolved(items[1].title, "en_US"), "Run")
        XCTAssertEqual(resolved(items[1].title, "de_DE"), "Laufen")
        XCTAssertEqual(resolved(items[0].title, "de_DE"), "Schlaf")
    }

    func testUnmappedSportShowsTheStoredLabelUntranslated() {
        // "Strength Training" and "Rowing" are also catalog keys elsewhere; a stored label must not hit them.
        for (stored, shown) in [("strength training", "Strength Training"), ("Rowing", "Rowing"),
                                ("padel tennis", "Padel Tennis")] {
            XCTAssertEqual(resolved(HomeModel.sportName(stored), "de_DE"), shown)
        }
    }

    /// Resolves a model string in a fixed language so assertions don't depend on the test host's language.
    private func resolved(_ resource: LocalizedStringResource?, _ localeID: String) -> String? {
        guard var resource else { return nil }
        resource.locale = Locale(identifier: localeID)
        return String(localized: resource)
    }
}

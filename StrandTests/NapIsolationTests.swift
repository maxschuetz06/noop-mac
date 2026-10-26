import XCTest
import Foundation
import WhoopStore
import WhoopProtocol
import StrandAnalytics
@testable import Strand

/// Imported WHOOP-export naps (`isNap`) are stored and shown but must never act as "the night": they may
/// not change the learned habitual midsleep that steers the main-night pick, nor therefore the night's
/// computed sleep duration / efficiency / vitals.
final class NapIsolationTests: XCTestCase {

    private let imported = "my-whoop", computed = "my-whoop-noop"

    private func midnightUTC(_ day: String) -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return Int(f.date(from: day)!.timeIntervalSince1970)
    }

    /// A still, low-HR night ending 06:00 UTC on `endDay` (same recipe as the AnalyticsEngine tests).
    private func rawNight(endDay: String, hours: Int) -> (hr: [HRSample], rr: [RRInterval], gravity: [GravitySample]) {
        let end = midnightUTC(endDay) + 6 * 3600
        let start = end - hours * 3600
        var hr: [HRSample] = [], rr: [RRInterval] = [], grav: [GravitySample] = []
        for t in start..<end {
            hr.append(HRSample(ts: t, bpm: 50))
            grav.append(GravitySample(ts: t, x: 0, y: 0, z: 1))
        }
        var toggle = false
        for t in stride(from: start, to: end, by: 2) {
            rr.append(RRInterval(ts: t, rrMs: toggle ? 1205 : 1195))
            toggle.toggle()
        }
        return (hr, rr, grav)
    }

    private func session(startTs: Int, hours: Double, isNap: Bool) -> CachedSleepSession {
        CachedSleepSession(startTs: startTs, endTs: startTs + Int(hours * 3600), efficiency: 0.9,
                           restingHr: nil, avgHrv: nil, stagesJSON: nil, isNap: isNap)
    }

    func testNapOnTheSameDateDoesNotChangeTheNightsComputedSleep() async throws {
        let store = try await WhoopStore.inMemory()
        let base = midnightUTC("2026-08-01")

        // 13 imported nights (23:00 → 07:00 UTC): one short of the 14-distinct-day habitual threshold, so
        // the learned habitual midsleep is nil (cold-start) for the baseline.
        let nightDays = (0..<13).map { base + $0 * 86_400 }
        try await store.upsertSleepSessions(
            nightDays.map { session(startTs: $0 - 3600, hours: 8, isNap: false) }, deviceId: imported)

        func habitual() async -> Int? {
            await IntelligenceEngine.computeHabitualMidsleep(
                store: store, importedId: imported, computedId: computed,
                windowStart: 0, windowEnd: Int.max, offsetSec: 0)
        }
        let before = await habitual()
        XCTAssertNil(before, "13 distinct nights stay under the habitual threshold")

        // Imported naps: on the SAME dates as three nights (14:00 UTC) AND on three further dates. If naps
        // counted as sleep blocks they'd lift the distinct-day count to 16 and flip the habitual to non-nil.
        let napStarts = [0, 1, 2, 13, 14, 15].map { base + $0 * 86_400 + 14 * 3600 }
        try await store.upsertSleepSessions(
            napStarts.map { session(startTs: $0, hours: 1, isNap: true) }, deviceId: imported)

        let after = await habitual()
        XCTAssertEqual(after, before, "naps must not feed the habitual-midsleep learner")

        // Non-vacuity: reading WITH naps would have changed the habitual — so the exclusion is what held.
        let withNaps = try await store.sleepSessions(deviceId: imported, from: 0, to: Int.max, limit: 4000,
                                                     includeNaps: true)
        let blocks = withNaps.map { s -> SleepStageTotals.HistoryBlock in
            let mid = s.effectiveStartTs + (s.endTs - s.effectiveStartTs) / 2
            return SleepStageTotals.HistoryBlock(start: s.effectiveStartTs, end: s.endTs,
                                                 dayKey: AnalyticsEngine.dayString(mid, offsetSec: 0))
        }
        XCTAssertNotNil(SleepStageTotals.habitualMidsleepSec(blocks, offsetSec: 0),
                        "sanity: with the naps included the learner WOULD have crossed the threshold")

        // The night's computed sleep (duration, efficiency, vitals, stages) is identical with and without
        // the naps present, because both runs receive the same (nap-free) habitual value.
        let day = "2026-08-05"
        let raw = rawNight(endDay: day, hours: 7)
        func analyze(habitual: Int?) -> AnalyticsEngine.DayResult {
            AnalyticsEngine.analyzeDay(day: day, hr: raw.hr, rr: raw.rr, gravity: raw.gravity,
                                       profile: UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male"),
                                       habitualMidsleepSec: habitual)
        }
        let withoutNapRun = analyze(habitual: before)
        let withNapRun = analyze(habitual: after)
        XCTAssertNotNil(withNapRun.daily.totalSleepMin)
        XCTAssertEqual(withNapRun.daily, withoutNapRun.daily)
        XCTAssertEqual(withNapRun.cachedSleep, withoutNapRun.cachedSleep)
    }

    func testDefaultStoreReadsHideNapsFromEveryNightlyConsumer() async throws {
        let store = try await WhoopStore.inMemory()
        let base = midnightUTC("2026-08-01")
        let night = session(startTs: base - 3600, hours: 8, isNap: false)
        let nap = session(startTs: base + 14 * 3600, hours: 1, isNap: true)   // same calendar day as the wake
        try await store.upsertSleepSessions([night, nap], deviceId: imported)

        let seen = try await store.sleepSessions(deviceId: imported, from: 0, to: Int.max, limit: 100)
        XCTAssertEqual(seen, [night])
        let napsOnly = try await store.sleepNaps(deviceId: imported, from: 0, to: Int.max, limit: 100)
        XCTAssertEqual(napsOnly, [nap])
    }
}

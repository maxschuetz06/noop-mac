import XCTest
import Foundation
import WhoopStore
import WhoopProtocol
@testable import StrandAnalytics
@testable import Strand

/// The main-thread optimisations must not change a single computed result. Each test runs the OLD
/// implementation (reproduced here verbatim, or kept in the production code as a `…ViaFoundation`
/// reference) against the new one on the perf dataset — the copy of `NOOP_PERF_DB` when set, otherwise the
/// deterministic synthetic 400-day database — plus fuzzed / malformed inputs.
@MainActor
final class PerfEqualityTests: XCTestCase {

    // MARK: - WorkoutSource.dedupCrossSource (was quadratic in string work)

    /// The original implementation, verbatim: `sportKey` evaluated for every pair.
    static func referenceDedup(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        func sameActivity(_ a: WorkoutRow, _ b: WorkoutRow) -> Bool {
            guard WorkoutSource.sportKey(a.sport) == WorkoutSource.sportKey(b.sport) else { return false }
            let overlap = min(a.endTs, b.endTs) - max(a.startTs, b.startTs)
            guard overlap > 0 else { return false }
            let shorter = max(1, min(a.endTs - a.startTs, b.endTs - b.startTs))
            return Double(overlap) > 0.5 * Double(shorter)
        }
        var kept: [WorkoutRow] = []
        outer: for row in rows {
            for i in kept.indices where sameActivity(kept[i], row) {
                kept[i] = WorkoutSource.preferred(kept[i], row)
                continue outer
            }
            kept.append(row)
        }
        return kept
    }

    func testDedupCrossSourceMatchesReferenceOnDatasetWorkouts() async throws {
        let env = try await PerfEnvironment.make()
        defer { env.cleanup() }
        let now = Int(Date().timeIntervalSince1970)
        let lo = now - 4000 * 86_400, hi = now + 86_400
        var rows: [WorkoutRow] = []
        for dev in ["my-whoop", "apple-health", "my-whoop-noop", "lifting"] {
            rows += (try? await env.store.workouts(deviceId: dev, from: lo, to: hi, limit: 5000)) ?? []
        }
        XCTAssertGreaterThan(rows.count, 100, "the perf dataset must carry a realistic workout history")

        XCTAssertEqual(WorkoutSource.dedupCrossSource(rows), Self.referenceDedup(rows))

        // Cross-source duplicates of the same history: the same sessions re-imported under other sources
        // with drifted windows, spelled differently ("TraditionalStrengthTraining" vs spaced), plus extras.
        var dup = rows
        for (i, r) in rows.enumerated() where i % 3 == 0 {
            dup.append(WorkoutRow(startTs: r.startTs + 40, endTs: r.endTs + 25,
                                  sport: r.sport.replacingOccurrences(of: " ", with: ""),
                                  source: i % 2 == 0 ? "apple-health" : "lifting",
                                  durationS: r.durationS, energyKcal: r.energyKcal, avgHr: nil, maxHr: nil,
                                  strain: nil, distanceM: nil, zonesJSON: nil, notes: nil))
        }
        var shuffleRNG = SeededRNG(seed: 11)
        dup.shuffle(using: &shuffleRNG)
        let deduped = WorkoutSource.dedupCrossSource(dup)
        XCTAssertEqual(deduped, Self.referenceDedup(dup))
        XCTAssertLessThan(deduped.count, dup.count, "the duplicated sessions must actually collapse")
    }

    func testDedupCrossSourceMatchesReferenceOnFuzzedRows() {
        var rng = SeededRNG(seed: 99)
        let sports = ["Running", "running", "Run ning", "TraditionalStrengthTraining", "Traditional Strength Training",
                      "detected", "Activity", "Yoga", "", "Cycling"]
        let sources = ["whoop", "apple-health", "apple_health", "manual", "my-whoop-noop", "lifting", "activity-file"]
        for round in 0..<40 {
            var rows: [WorkoutRow] = []
            for _ in 0..<(30 + round * 6) {
                let start = 1_700_000_000 + Int(rng.next() % 40_000)
                let dur = Int(rng.next() % 5_000) - 200            // includes zero / negative windows
                rows.append(WorkoutRow(
                    startTs: start, endTs: start + dur,
                    sport: sports[Int(rng.next() % UInt64(sports.count))],
                    source: sources[Int(rng.next() % UInt64(sources.count))],
                    durationS: Double(max(dur, 0)),
                    energyKcal: rng.next() % 2 == 0 ? Double(rng.next() % 900) : nil,
                    avgHr: rng.next() % 3 == 0 ? Int(rng.next() % 150) : nil,
                    maxHr: rng.next() % 3 == 0 ? Int(rng.next() % 200) : nil,
                    strain: rng.next() % 4 == 0 ? Double(rng.next() % 20) : nil,
                    distanceM: rng.next() % 4 == 0 ? Double(rng.next() % 9_000) : nil,
                    zonesJSON: rng.next() % 5 == 0 ? "{\"z1\":1}" : nil, notes: nil))
            }
            XCTAssertEqual(WorkoutSource.dedupCrossSource(rows), Self.referenceDedup(rows), "round \(round)")
        }
    }

    // MARK: - Repository.today memo + localDayKey cache

    func testTodayMemoMatchesResolverAndFollowsDays() async throws {
        let env = try await PerfEnvironment.make()
        defer { env.cleanup() }
        await env.repo.refresh()
        let repo = env.repo

        func fresh() -> DailyMetric? {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            let now = Date()
            return Repository.resolveToday(days: repo.days,
                                           logicalKey: f.string(from: now.addingTimeInterval(-4 * 3_600)),
                                           localKey: f.string(from: now))
        }
        XCTAssertEqual(repo.today, fresh())
        XCTAssertEqual(repo.today, fresh(), "second read is served from the memo and must agree")

        // A write to `days` must drop the memo, never serve the old row.
        let original = repo.days
        let nowKey = Repository.logicalDayKey(Date())
        let localKey = Repository.localDayKey(Date())   // differs from the logical key between 00:00 and 04:00
        repo.days = original.filter { $0.day != nowKey && $0.day != localKey }
        XCTAssertEqual(repo.today, fresh())
        let synthetic = DailyMetric(day: nowKey, totalSleepMin: 400, efficiency: 90, deepMin: 80, remMin: 90,
                                    lightMin: 230, disturbances: 3, restingHr: 50, avgHrv: 70, recovery: 77,
                                    strain: 9, exerciseCount: 1)
        repo.days.append(synthetic)
        XCTAssertEqual(repo.today, synthetic)
        XCTAssertEqual(repo.today, fresh())
        repo.days = []
        XCTAssertNil(repo.today)
    }

    func testLocalDayKeyCacheMatchesFormatter() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        var rng = SeededRNG(seed: 5)
        var dates: [Date] = [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: -86_400 * 400),
                             Date(timeIntervalSince1970: 4_102_444_800), Date()]
        for _ in 0..<3_000 {
            dates.append(Date(timeIntervalSince1970: Double(rng.next() % 2_000_000_000) + Double(rng.next() % 1000) / 1000))
        }
        for _ in 0..<2 {   // second pass = cache hits
            for d in dates { XCTAssertEqual(Repository.localDayKey(d), f.string(from: d)) }
        }
        // Local-midnight neighbours (the places a keyed-by-second cache could go wrong).
        let cal = Calendar.current
        for back in 0..<40 {
            let midnight = cal.startOfDay(for: cal.date(byAdding: .day, value: -back, to: Date())!)
            for off in [-2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0] {
                let d = midnight.addingTimeInterval(off)
                XCTAssertEqual(Repository.localDayKey(d), f.string(from: d))
            }
        }
    }

    // MARK: - DayKeyDateCache (Trends / Compare / Explore history parsing)

    func testDayKeyDateCacheMatchesDateFormatterOnDatasetDays() async throws {
        let env = try await PerfEnvironment.make()
        defer { env.cleanup() }
        await env.repo.refresh()

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        var keys = env.repo.days.map(\.day) + ["", "garbage", "2026-02-30", "2026-13-01", "2026-1-5", "26-01-05", "2026-01-05 "]
        keys += keys   // repeats exercise the cache-hit path
        XCTAssertGreaterThan(env.repo.days.count, 250)
        for k in keys { XCTAssertEqual(DayKeyDateCache.utc.date(k), f.date(from: k), k) }
    }

    // MARK: - StrandAnalytics day math on the dataset's series

    func testCalendarSeriesAndShiftDayMatchFoundationOnDataset() async throws {
        let env = try await PerfEnvironment.make()
        defer { env.cleanup() }
        await env.repo.refresh()

        let days = env.repo.days
        XCTAssertGreaterThan(days.count, 250)
        let series: [[(day: String, value: Double?)]] = [
            days.map { ($0.day, $0.recovery) },
            days.map { ($0.day, $0.avgHrv) },
            days.map { ($0.day, $0.restingHr.map(Double.init)) },
            days.map { ($0.day, $0.skinTempDevC) },
            days.filter { $0.respRateBpm != nil }.map { ($0.day, $0.respRateBpm) },
            Array(days.suffix(30)).map { ($0.day, $0.spo2Pct) },
        ]
        for rows in series {
            XCTAssertEqual(VitalBands.calendarSeries(rows), VitalBands.calendarSeriesViaFoundation(rows))
        }
        for d in days {
            for delta in [-14, -7, -3, -2, -1, 1, 2, 3, 7, 30] {
                XCTAssertEqual(CorrelationEngine.shiftDay(d.day, by: delta),
                               CorrelationEngine.shiftDayViaFoundation(d.day, by: delta), "\(d.day) \(delta)")
            }
        }
    }
}

/// Deterministic generator so the fuzzed inputs are reproducible.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 33)) &* 0xff51afd7ed558ccd
        z = (z ^ (z >> 33)) &* 0xc4ceb9fe1a85ec53
        return z ^ (z >> 33)
    }
}

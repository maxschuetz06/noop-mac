import XCTest
import WhoopProtocol
@testable import WhoopStore

/// #547 — the one-time heal of a DB polluted by a bad-clock strap (pikapik). Before the ingest gate,
/// type-47 records were trusted verbatim, so a broken-clock WHOOP wrote raw rows + computed days dated to
/// scattered garbage (far-past, a bogus 2027, FUTURE dates). `healImplausibleTimestamps` purges those so a
/// rescore recomputes the real days cleanly. Mirrors the Android Room-cleanup tests: SAME bounds, SAME set.
final class TimestampHealTests: XCTestCase {

    // A deterministic "now" well above the 1.7B floor (≈ 2025-06). The heal's future bound = now + 1 day.
    private let now = 1_750_000_000
    private let todayKey = "2025-06-15"   // local day matching `now`; future = any day > this

    private func hr(_ ts: Int, _ bpm: Int) -> HRSample { HRSample(ts: ts, bpm: bpm) }

    func testPurgesImplausibleRawRowsKeepsGood() async throws {
        let store = try await WhoopStore.inMemory()
        // Good rows around "now"; garbage rows far-past, future, and the literal bogus 2027=1827642881.
        let good1 = now - 3600, good2 = now - 7200
        let farPast = 1_250_000_000          // < MIN_PLAUSIBLE_UNIX → drop
        let future = now + 30 * 86_400       // > now + FUTURE_MARGIN → drop
        let bogus2027 = 1_827_642_881        // > now + FUTURE_MARGIN → drop
        _ = try await store.insert(Streams(hr: [
            hr(good1, 55), hr(good2, 58),
            hr(farPast, 99), hr(future, 99), hr(bogus2027, 99),
        ]), deviceId: "my-whoop")

        let result = try await store.healImplausibleTimestamps(now: now, todayLocalDayKey: todayKey)
        XCTAssertEqual(result.rawRowsDeleted, 3, "the 3 garbage HR rows must be purged")
        XCTAssertTrue(result.didChange)

        let survivors = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: 1000)
        XCTAssertEqual(survivors.map(\.ts).sorted(), [good2, good1].sorted())
    }

    func testPurgesFutureAndImplausibleComputedRows() async throws {
        let store = try await WhoopStore.inMemory()
        // dailyMetric rows: a real prior day, a FUTURE day, and an absurd far-past day.
        func day(_ d: String) -> DailyMetric {
            DailyMetric(day: d, totalSleepMin: 721, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                        recovery: 0.5, strain: nil, exerciseCount: nil)
        }
        _ = try await store.upsertDailyMetrics([
            day("2025-06-14"),   // genuine prior day — keep
            day("2025-07-12"),   // FUTURE (> todayKey) — the "12 Jul" carry-over bug — drop
            day("2019-01-01"),   // far-past (< the 2023-11 floor day) — drop
        ], deviceId: "my-whoop-noop")
        // sleepSession rows keyed by startTs: one real, one future.
        _ = try await store.upsertSleepSessions([
            CachedSleepSession(startTs: now - 30_000, endTs: now - 1000, efficiency: nil,
                               restingHr: nil, avgHrv: nil, stagesJSON: nil),
            CachedSleepSession(startTs: now + 30 * 86_400, endTs: now + 30 * 86_400 + 1000,
                               efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil),
        ], deviceId: "my-whoop-noop")

        let result = try await store.healImplausibleTimestamps(now: now, todayLocalDayKey: todayKey)
        XCTAssertEqual(result.computedRowsDeleted, 3, "2 bad daily + 1 future sleep session")

        let days = try await store.dailyMetrics(deviceId: "my-whoop-noop", from: "1900-01-01", to: "2999-12-31")
        XCTAssertEqual(days.map(\.day), ["2025-06-14"], "only the genuine prior day survives")
        let sleeps = try await store.sleepSessions(deviceId: "my-whoop-noop", from: 0, to: Int.max, limit: 1000)
        XCTAssertEqual(sleeps.count, 1)
        XCTAssertEqual(sleeps[0].startTs, now - 30_000)
    }

    func testTodayItselfIsKept() async throws {
        // The future-day filter is strict `> todayKey`, so TODAY's own row (== todayKey) survives.
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertDailyMetrics([
            DailyMetric(day: todayKey, totalSleepMin: 400, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                        recovery: 0.6, strain: nil, exerciseCount: nil),
        ], deviceId: "my-whoop-noop")
        let result = try await store.healImplausibleTimestamps(now: now, todayLocalDayKey: todayKey)
        XCTAssertEqual(result.computedRowsDeleted, 0)
        let days = try await store.dailyMetrics(deviceId: "my-whoop-noop", from: "1900-01-01", to: "2999-12-31")
        XCTAssertEqual(days.map(\.day), [todayKey])
    }

    func testHealIsIdempotentOnCleanDB() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(hr: [hr(now - 100, 60), hr(now - 200, 61)]), deviceId: "my-whoop")
        // First pass: nothing implausible → no change.
        let r1 = try await store.healImplausibleTimestamps(now: now, todayLocalDayKey: todayKey)
        XCTAssertFalse(r1.didChange)
        XCTAssertEqual(r1.rawRowsDeleted, 0)
        // Re-running is harmless and still a no-op.
        let r2 = try await store.healImplausibleTimestamps(now: now, todayLocalDayKey: todayKey)
        XCTAssertFalse(r2.didChange)
        let survivors = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: 1000)
        XCTAssertEqual(survivors.count, 2, "good rows untouched across repeated heals")
    }

    func testBoundaryRowsExactlyOnEdgesAreKept() async throws {
        let store = try await WhoopStore.inMemory()
        let floor = MIN_PLAUSIBLE_UNIX            // exactly the floor — keep
        let ceiling = now + FUTURE_MARGIN          // exactly the ceiling — keep
        _ = try await store.insert(Streams(hr: [
            hr(floor, 50), hr(ceiling, 51),
            hr(floor - 1, 99), hr(ceiling + 1, 99),   // just outside — drop both
        ]), deviceId: "my-whoop")
        let result = try await store.healImplausibleTimestamps(now: now, todayLocalDayKey: todayKey)
        XCTAssertEqual(result.rawRowsDeleted, 2)
        let survivors = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: 1000)
        XCTAssertEqual(survivors.map(\.ts).sorted(), [floor, ceiling])
    }

    func testImportedHistoryBeforeTheFloorSurvivesWhileBogusStrapRowsArePurged() async throws {
        let store = try await WhoopStore.inMemory()
        let farPast = 1_600_000_000   // 2020-09: genuine imported history, but below MIN_PLAUSIBLE_UNIX
        func day(_ d: String) -> DailyMetric {
            DailyMetric(day: d, totalSleepMin: 420, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                        recovery: 0.7, strain: nil, exerciseCount: nil)
        }
        let oldNight = CachedSleepSession(startTs: farPast, endTs: farPast + 28_800, efficiency: nil,
                                          restingHr: nil, avgHrv: nil, stagesJSON: nil)
        // A WHOOP export import lands under the strap id; Apple Health under its own source.
        _ = try await store.upsertDailyMetrics([day("2020-09-13")], deviceId: "my-whoop")
        _ = try await store.upsertSleepSessions([oldNight], deviceId: "my-whoop")
        _ = try await store.upsertDailyMetrics([day("2020-09-13")], deviceId: "apple-health")
        _ = try await store.insert(Streams(hr: [hr(farPast, 60)]), deviceId: "apple-health")
        // Bad-clock strap pollution: a far-past raw row from the strap and the computed day/night it produced.
        _ = try await store.insert(Streams(hr: [hr(farPast, 99), hr(now - 60, 55)]), deviceId: "my-whoop")
        _ = try await store.upsertDailyMetrics([day("2020-09-13")], deviceId: "my-whoop-noop")
        _ = try await store.upsertSleepSessions([oldNight], deviceId: "my-whoop-noop")

        let result = try await store.healImplausibleTimestamps(now: now, todayLocalDayKey: todayKey)

        XCTAssertEqual(result.rawRowsDeleted, 1, "only the strap's far-past raw row")
        XCTAssertEqual(result.computedRowsDeleted, 2, "only the strap-derived computed day + night")
        let importedDays = try await store.dailyMetrics(deviceId: "my-whoop", from: "1900-01-01", to: "2999-12-31")
        XCTAssertEqual(importedDays.map(\.day), ["2020-09-13"])
        let importedNights = try await store.sleepSessions(deviceId: "my-whoop", from: 0, to: Int.max, limit: 10)
        XCTAssertEqual(importedNights.map(\.startTs), [farPast])
        let appleDays = try await store.dailyMetrics(deviceId: "apple-health", from: "1900-01-01", to: "2999-12-31")
        XCTAssertEqual(appleDays.map(\.day), ["2020-09-13"])
        let appleHr = try await store.hrSamples(deviceId: "apple-health", from: 0, to: Int.max, limit: 10)
        XCTAssertEqual(appleHr.map(\.ts), [farPast])
        let strapHr = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: 10)
        XCTAssertEqual(strapHr.map(\.ts), [now - 60])
        let computedDays = try await store.dailyMetrics(deviceId: "my-whoop-noop", from: "1900-01-01", to: "2999-12-31")
        XCTAssertTrue(computedDays.isEmpty)
        let computedNights = try await store.sleepSessions(deviceId: "my-whoop-noop", from: 0, to: Int.max, limit: 10)
        XCTAssertTrue(computedNights.isEmpty)
    }

    func testHealCoversEveryRegisteredBLEWhoopButNoImportedSource() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryQueue)
        func device(_ id: String, brand: String, kind: SourceKind) -> PairedDevice {
            PairedDevice(id: id, brand: brand, model: brand, sourceKind: kind, capabilities: [.hr],
                         status: .paired, addedAt: now, lastSeenAt: now)
        }
        try registry.add(device("whoop-AB12", brand: "Whoop", kind: .liveBLE))
        try registry.add(device("whoop-cloud", brand: "WHOOP", kind: .cloudImport))
        try registry.add(device("polar-h10", brand: "Polar", kind: .liveBLE))
        let farPast = 1_250_000_000
        for id in ["whoop-AB12", "whoop-cloud", "polar-h10"] {
            _ = try await store.insert(Streams(hr: [hr(farPast, 70)]), deviceId: id)
        }

        let result = try await store.healImplausibleTimestamps(now: now, todayLocalDayKey: todayKey)

        XCTAssertEqual(result.rawRowsDeleted, 1)
        let healed = try await store.hrSamples(deviceId: "whoop-AB12", from: 0, to: Int.max, limit: 10)
        XCTAssertTrue(healed.isEmpty, "a second BLE WHOOP strap is strap-derived")
        for id in ["whoop-cloud", "polar-h10"] {
            let kept = try await store.hrSamples(deviceId: id, from: 0, to: Int.max, limit: 10)
            XCTAssertEqual(kept.map(\.ts), [farPast], "\(id) is not a WHOOP strap")
        }
    }
}

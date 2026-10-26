import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// v20 `strapStateSample` (strap-reported wear/sleep state) and the `NOOP_HISTORY_CENSUS` event rows.
final class StrapStateTests: XCTestCase {

    // MARK: - Migration

    func testV20MigratesUpFromAV19DatabaseKeepingExistingRows() async throws {
        let path = NSTemporaryDirectory() + "strapstate-\(UUID().uuidString).sqlite"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let dbq = try DatabaseQueue(path: path)
        try WhoopStore.makeMigrator().migrate(dbq, upTo: "v19-sleep-nap")
        try await dbq.write { db in
            XCTAssertFalse(try db.tableExists("strapStateSample"), "v19 schema must not have the table yet")
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('my-whoop', 1000, 60)")
        }

        let store = try await WhoopStore(path: path)   // applies v20
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("strapStateSample"))
        let pk = try await store.primaryKeyColumns("strapStateSample")
        XCTAssertEqual(pk, ["deviceId", "ts"])
        let cols = try await store.columnNamesForTest(table: "strapStateSample")
        XCTAssertEqual(Set(cols), ["deviceId", "ts", "onWrist", "sleepState"])
        let ddl = try await store.registryQueue.read { db in
            try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'strapStateSample'") ?? ""
        }
        XCTAssertTrue(ddl.uppercased().contains("WITHOUT ROWID"), ddl)

        let hr = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: .max, limit: 10)
        XCTAssertEqual(hr.map(\.ts), [1000], "pre-existing rows survive the migration")
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 20)
    }

    // MARK: - Persist + read

    func testInsertRoundTripDedupAndRangeRead() async throws {
        let store = try await WhoopStore.inMemory()
        let streams: Streams = {
            var s = Streams()
            s.strapState = [
                StrapStateSample(ts: 100, onWrist: 1, sleepState: 0),
                StrapStateSample(ts: 101, onWrist: 1, sleepState: 2),
                StrapStateSample(ts: 102, onWrist: 3, sleepState: 3),
            ]
            return s
        }()
        _ = try await store.insert(streams, deviceId: "my-whoop")
        _ = try await store.insert(streams, deviceId: "my-whoop")   // idempotent (ON CONFLICT DO NOTHING)
        // A different strap's identical timestamps are a distinct row.
        _ = try await store.insert(streams, deviceId: "other")

        let all = try await store.strapStateSamples(deviceId: "my-whoop", from: 0, to: .max, limit: 100)
        XCTAssertEqual(all, streams.strapState)
        let ranged = try await store.strapStateSamples(deviceId: "my-whoop", from: 101, to: 101, limit: 100)
        XCTAssertEqual(ranged, [StrapStateSample(ts: 101, onWrist: 1, sleepState: 2)])
        let limited = try await store.strapStateSamples(deviceId: "my-whoop", from: 0, to: .max, limit: 2)
        XCTAssertEqual(limited.map(\.ts), [100, 101])
        let other = try await store.strapStateSamples(deviceId: "other", from: 0, to: .max, limit: 100)
        XCTAssertEqual(other.count, 3)
    }

    // MARK: - Prune / delete policies shared with the other per-second sample tables

    func testImplausibleTimestampHealPrunesStrapState() async throws {
        let store = try await WhoopStore.inMemory()
        let now = 1_750_000_000
        var s = Streams()
        s.strapState = [
            StrapStateSample(ts: now - 3600, onWrist: 1, sleepState: 0),            // keep
            StrapStateSample(ts: 1_250_000_000, onWrist: 1, sleepState: 0),         // far past → drop
            StrapStateSample(ts: now + 30 * 86_400, onWrist: 1, sleepState: 0),     // future → drop
        ]
        _ = try await store.insert(s, deviceId: "my-whoop")
        let result = try await store.healImplausibleTimestamps(now: now, todayLocalDayKey: "2025-06-15")
        XCTAssertEqual(result.rawRowsDeleted, 2)
        let left = try await store.strapStateSamples(deviceId: "my-whoop", from: 0, to: .max, limit: 10)
        XCTAssertEqual(left.map(\.ts), [now - 3600])
    }

    func testDeleteAllDataClearsStrapStateOnlyForTheTargetDevice() async throws {
        let store = try await WhoopStore.inMemory()
        var s = Streams()
        s.strapState = [StrapStateSample(ts: 100, onWrist: 1, sleepState: 2)]
        _ = try await store.insert(s, deviceId: "apple-health")
        _ = try await store.insert(s, deviceId: "my-whoop")
        try DeviceRegistryStore(dbQueue: store.registryQueue).deleteAllData(deviceId: "apple-health")
        let gone = try await store.strapStateSamples(deviceId: "apple-health", from: 0, to: .max, limit: 10)
        let kept = try await store.strapStateSamples(deviceId: "my-whoop", from: 0, to: .max, limit: 10)
        XCTAssertTrue(gone.isEmpty)
        XCTAssertEqual(kept.count, 1)
    }

    // MARK: - History census event rows

    func testCensusRowRoundTripsAndStaysOutOfStrapEvents() async throws {
        let store = try await WhoopStore.inMemory()
        // A genuine strap event next to the census row.
        _ = try await store.insert(Streams(events: [WhoopEvent(ts: 2000, kind: "WRIST_ON", payload: [:])]),
                                   deviceId: "my-whoop")
        try await store.recordHistoryCensus(deviceId: "my-whoop", ts: 2000,
                                            counts: ["47/v18": 312, "47/v26": 40, "48": 4],
                                            chunks: 3, diagnosticFrames: 5)

        // Raw row shape: kind + sorted-key JSON.
        let row = try await store.registryQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT kind, payloadJSON FROM event WHERE kind = ?",
                             arguments: [WhoopStore.historyCensusEventKind])
        }
        XCTAssertEqual(row?["kind"] as String?, "NOOP_HISTORY_CENSUS")
        XCTAssertEqual(row?["payloadJSON"] as String?,
                       #"{"chunks":3,"counts":{"47\/v18":312,"47\/v26":40,"48":4},"diagnosticFrames":5}"#)

        let records = try await store.historyCensusRecords(deviceId: "my-whoop", from: 0, to: .max, limit: 10)
        XCTAssertEqual(records, [HistoryCensusRecord(ts: 2000, counts: ["47/v18": 312, "47/v26": 40, "48": 4],
                                                     chunks: 3, diagnosticFrames: 5)])

        // UI/analysis filter: `events(...)` returns the strap event only — never the census row.
        let events = try await store.events(deviceId: "my-whoop", from: 0, to: .max, limit: 10)
        XCTAssertEqual(events.map(\.kind), ["WRIST_ON"])
    }

    func testCensusIsWrittenForEmptySessionAndReplacesSameSecond() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.recordHistoryCensus(deviceId: "d", ts: 500, counts: [:], chunks: 0, diagnosticFrames: 0)
        try await store.recordHistoryCensus(deviceId: "d", ts: 500, counts: ["48": 1], chunks: 1, diagnosticFrames: 0)
        let r = try await store.historyCensusRecords(deviceId: "d", from: 0, to: .max, limit: 10)
        XCTAssertEqual(r, [HistoryCensusRecord(ts: 500, counts: ["48": 1], chunks: 1, diagnosticFrames: 0)])
    }

    func testCensusRowsOlderThanRetentionArePrunedOnWrite() async throws {
        let store = try await WhoopStore.inMemory()
        let now = 1_750_000_000
        try await store.recordHistoryCensus(deviceId: "d", ts: now - WhoopStore.historyCensusRetentionSeconds - 10,
                                            counts: ["48": 1], chunks: 1, diagnosticFrames: 0)
        try await store.recordHistoryCensus(deviceId: "d", ts: now - 3600, counts: ["48": 2], chunks: 1, diagnosticFrames: 0)
        // Another device's census is never touched by this device's prune; a real event isn't either.
        try await store.recordHistoryCensus(deviceId: "e", ts: 1, counts: [:], chunks: 0, diagnosticFrames: 0)
        _ = try await store.insert(Streams(events: [WhoopEvent(ts: 5, kind: "WRIST_ON", payload: [:])]), deviceId: "d")
        try await store.recordHistoryCensus(deviceId: "d", ts: now, counts: ["48": 3], chunks: 1, diagnosticFrames: 0)

        let d = try await store.historyCensusRecords(deviceId: "d", from: 0, to: .max, limit: 10)
        XCTAssertEqual(d.map(\.ts), [now - 3600, now])
        let e = try await store.historyCensusRecords(deviceId: "e", from: 0, to: .max, limit: 10)
        XCTAssertEqual(e.count, 1)
        let ev = try await store.events(deviceId: "d", from: 0, to: .max, limit: 10)
        XCTAssertEqual(ev.map(\.kind), ["WRIST_ON"])
    }

    func testRawCsvExportOmitsCensusRows() async throws {
        let store = try await WhoopStore.inMemory()
        let now = Int(Date().timeIntervalSince1970)
        _ = try await store.insert(Streams(events: [WhoopEvent(ts: now - 10, kind: "WRIST_ON", payload: [:])]),
                                   deviceId: "my-whoop")
        try await store.recordHistoryCensus(deviceId: "my-whoop", ts: now - 5, counts: ["48": 1],
                                            chunks: 1, diagnosticFrames: 0)
        let url = try await store.exportRawCSV(deviceId: "my-whoop", since: TimeInterval(now - 100))
        defer { try? FileManager.default.removeItem(at: url) }
        let csv = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(csv.contains("WRIST_ON"))
        XCTAssertFalse(csv.contains("NOOP_HISTORY_CENSUS"))
    }
}

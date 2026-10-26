import XCTest
import GRDB
@testable import WhoopStore

/// v19 `isNap`: naps are stored but never leak into the default (nightly) sleep read.
final class NapStoreTests: XCTestCase {

    func testV19MigrationKeepsV18RowsAndDefaultsIsNapFalse() async throws {
        let path = NSTemporaryDirectory() + "napstore-\(UUID().uuidString).sqlite"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let dbq = try DatabaseQueue(path: path)
        try WhoopStore.makeMigrator().migrate(dbq, upTo: "v18-sleep-motion-state")
        try await dbq.write { db in
            let cols = try db.columns(in: "sleepSession").map(\.name)
            XCTAssertFalse(cols.contains("isNap"), "v18 schema must not have isNap yet")
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency, restingHr, avgHrv,
                                          stagesJSON, userEdited, startTsAdjusted)
                VALUES ('my-whoop', 1000, 29800, 0.91, 52, 64.5, '{"light":300}', 1, 900),
                       ('my-whoop', 90000, 118800, 0.88, NULL, NULL, NULL, 0, NULL)
                """)
        }

        // Opening through WhoopStore applies the remaining migrations (v19).
        let store = try await WhoopStore(path: path)
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(cols.contains("isNap"))

        let rows = try await store.sleepSessions(deviceId: "my-whoop", from: 0, to: .max, limit: 10)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].startTs, 1000)
        XCTAssertEqual(rows[0].endTs, 29800)
        XCTAssertEqual(rows[0].efficiency, 0.91)
        XCTAssertEqual(rows[0].restingHr, 52)
        XCTAssertEqual(rows[0].avgHrv, 64.5)
        XCTAssertEqual(rows[0].stagesJSON, "{\"light\":300}")
        XCTAssertTrue(rows[0].userEdited)
        XCTAssertEqual(rows[0].startTsAdjusted, 900)
        XCTAssertFalse(rows[0].isNap)
        XCTAssertFalse(rows[1].isNap)
    }

    func testNapsAreExcludedByDefaultAndReadableExplicitly() async throws {
        let store = try await WhoopStore.inMemory()
        let night = CachedSleepSession(startTs: 100, endTs: 28_900, efficiency: 0.9, restingHr: nil,
                                       avgHrv: nil, stagesJSON: nil)
        let nap = CachedSleepSession(startTs: 50_000, endTs: 53_600, efficiency: 0.8, restingHr: nil,
                                     avgHrv: nil, stagesJSON: nil, isNap: true)
        try await store.upsertSleepSessions([night, nap], deviceId: "my-whoop")

        let def = try await store.sleepSessions(deviceId: "my-whoop", from: 0, to: .max, limit: 10)
        XCTAssertEqual(def.map(\.startTs), [100])

        let all = try await store.sleepSessions(deviceId: "my-whoop", from: 0, to: .max, limit: 10,
                                                includeNaps: true)
        XCTAssertEqual(all.map(\.startTs), [100, 50_000])
        XCTAssertEqual(all.map(\.isNap), [false, true])

        let naps = try await store.sleepNaps(deviceId: "my-whoop", from: 0, to: .max, limit: 10)
        XCTAssertEqual(naps.map(\.startTs), [50_000])
    }

    func testReimportIsIdempotentOnNaturalKey() async throws {
        let store = try await WhoopStore.inMemory()
        let nap = CachedSleepSession(startTs: 50_000, endTs: 53_600, efficiency: 0.8, restingHr: nil,
                                     avgHrv: nil, stagesJSON: nil, isNap: true)
        try await store.upsertSleepSessions([nap], deviceId: "my-whoop")
        try await store.upsertSleepSessions([nap], deviceId: "my-whoop")
        let all = try await store.sleepSessions(deviceId: "my-whoop", from: 0, to: .max, limit: 10,
                                                includeNaps: true)
        XCTAssertEqual(all.count, 1)
        XCTAssertTrue(all[0].isNap)
    }

    func testCachedSleepSessionDecodesLegacyJSONWithoutIsNap() throws {
        let json = #"{"startTs":1,"endTs":2,"userEdited":false}"#
        let s = try JSONDecoder().decode(CachedSleepSession.self, from: Data(json.utf8))
        XCTAssertFalse(s.isNap)
        let round = try JSONDecoder().decode(CachedSleepSession.self,
                                             from: JSONEncoder().encode(
                                                CachedSleepSession(startTs: 1, endTs: 2, efficiency: nil,
                                                                   restingHr: nil, avgHrv: nil,
                                                                   stagesJSON: nil, isNap: true)))
        XCTAssertTrue(round.isNap)
    }
}

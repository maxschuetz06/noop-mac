import XCTest
import SQLite3
import WhoopProtocol
import WhoopStore
@testable import Strand

/// WHOOP 5 v18 history → `strapStateSample` (decode → persist through the real Backfiller + WhoopStore),
/// the per-session `NOOP_HISTORY_CENSUS` event row, and the Codex mirror carrying both.
@MainActor
final class StrapStatePersistenceTests: XCTestCase {

    private let historyEndHex =
        "aa011c00010023d1316a0284a3266a0a373d00000041b601001000000000000044d21e3d"   // trim=112193
    private let historyStartHex =
        "aa012c0001002cd1312c0184a3266ad7230d0000005200000000000000320000002600000001000000000000000b010034497926"
    private let v18Hex =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"
    private let baseUnix = 1_780_916_150

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    /// CRC-valid v18 records, consecutive seconds, with the given @81 status bytes.
    private func v18(statuses: [UInt8]) -> [[UInt8]] {
        let template = bytes(v18Hex)
        let payloadEnd = (Int(template[2]) | (Int(template[3]) << 8)) + 8 - 4
        return statuses.enumerated().map { i, status in
            var f = template
            let ts = UInt32(baseUnix + i)
            for k in 0..<4 { f[15 + k] = UInt8((ts >> (8 * UInt32(k))) & 0xFF) }
            f[81] = status
            let c = crc32(Array(f[8..<payloadEnd]))
            for k in 0..<4 { f[payloadEnd + k] = UInt8((c >> (8 * UInt32(k))) & 0xFF) }
            return f
        }
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("strapstate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func offload(_ b: Backfiller, _ data: [[UInt8]]) async {
        b.begin(family: .whoop5)
        await b.ingest(bytes(historyStartHex))
        for f in data { await b.ingest(f) }
        await b.ingest(bytes(historyEndHex))
    }

    private func makeBackfiller(store: BackfillStoreWriting, log: ((String) -> Void)? = nil) -> Backfiller {
        let b = Backfiller(store: store, deviceId: "my-whoop", ackTrim: { _, _ in }, log: log,
                           rejectedSink: { _, _, _ in true })
        b.clockRef = ClockRef(device: baseUnix, wall: baseUnix)
        return b
    }

    private func scalar(_ path: String, _ sql: String) -> Int {
        var h: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &h, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(h) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(h, sql, -1, &stmt, nil), SQLITE_OK, sql)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - decode → persist → census → mirror

    func testV18StatusByteIsPersistedWithTheOtherStreamsAndCensusAndMirrorCarryBoth() async throws {
        let dbPath = dir.appendingPathComponent("whoop.sqlite").path
        let store = try await WhoopStore(path: dbPath)
        let b = makeBackfiller(store: store)
        // 0x00 → onwrist 0 / state 0 · 0x2D → onwrist 1 / state 2 · 0x33 → onwrist 3 / state 3.
        await offload(b, v18(statuses: [0x00, 0x2D, 0x33]))

        let state = try await store.strapStateSamples(deviceId: "my-whoop", from: 0, to: .max, limit: 10)
        XCTAssertEqual(state, [
            StrapStateSample(ts: baseUnix, onWrist: 0, sleepState: 0),
            StrapStateSample(ts: baseUnix + 1, onWrist: 1, sleepState: 2),
            StrapStateSample(ts: baseUnix + 2, onWrist: 3, sleepState: 3),
        ])
        // Same insert transaction as the other per-second streams.
        let hr = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: .max, limit: 10)
        XCTAssertEqual(hr.map(\.ts), [baseUnix, baseUnix + 1, baseUnix + 2])

        // Session end → exactly one census row.
        let snapshot = b.sessionCensusSnapshot()
        XCTAssertEqual(snapshot.counts, ["47/v18": 3])
        let ok = await b.persistSessionCensus(snapshot, ts: 1_780_920_000)
        XCTAssertTrue(ok)
        let census = try await store.historyCensusRecords(deviceId: "my-whoop", from: 0, to: .max, limit: 10)
        XCTAssertEqual(census, [HistoryCensusRecord(ts: 1_780_920_000, counts: ["47/v18": 3],
                                                    chunks: 1, diagnosticFrames: 0)])

        // The Codex mirror is an online backup of the whole database → both are readable from it.
        try await store.checkpointWAL()
        let mirrored = try AutoBackupEngine.mirror(sourcePath: dbPath, into: dir.appendingPathComponent("NOOP-Daten"))
        XCTAssertEqual(scalar(mirrored.path, "SELECT COUNT(*) FROM strapStateSample"), 3)
        XCTAssertEqual(scalar(mirrored.path, "SELECT SUM(onWrist * 10 + sleepState) FROM strapStateSample"), 0 + 12 + 33)
        XCTAssertEqual(scalar(mirrored.path, "SELECT COUNT(*) FROM event WHERE kind = 'NOOP_HISTORY_CENSUS'"), 1)
    }

    // MARK: - census event write

    private final class CensusSpy: BackfillStoreWriting {
        var rows: [(deviceId: String, ts: Int, counts: [String: Int], chunks: Int, diag: Int)] = []
        var fail = false
        struct Boom: Error {}
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            (streams.hr.count, streams.rr.count, streams.events.count, streams.battery.count,
             streams.spo2.count, streams.skinTemp.count, streams.resp.count, streams.gravity.count)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
        func setCursor(_ name: String, _ value: Int) async throws {}
        func cursor(_ name: String) async throws -> Int? { nil }
        func recordHistoryCensus(deviceId: String, ts: Int, counts: [String: Int],
                                 chunks: Int, diagnosticFrames: Int) async throws {
            if fail { throw Boom() }
            rows.append((deviceId, ts, counts, chunks, diagnosticFrames))
        }
    }

    func testEmptySessionStillWritesOneCensusRow() async {
        let spy = CensusSpy()
        let b = makeBackfiller(store: spy)
        await offload(b, [])
        let wrote = await b.persistSessionCensus(b.sessionCensusSnapshot(), ts: 42)
        XCTAssertTrue(wrote)
        XCTAssertEqual(spy.rows.count, 1)
        XCTAssertEqual(spy.rows[0].deviceId, "my-whoop")
        XCTAssertEqual(spy.rows[0].ts, 42)
        XCTAssertTrue(spy.rows[0].counts.isEmpty)
        XCTAssertEqual(spy.rows[0].chunks, 1)
    }

    func testSnapshotIsUnaffectedByTheNextSessionBegin() async {
        let spy = CensusSpy()
        let b = makeBackfiller(store: spy)
        await offload(b, v18(statuses: [0x00, 0x00]))
        let snapshot = b.sessionCensusSnapshot()
        b.begin(family: .whoop5)   // next session resets the live counters
        XCTAssertTrue(b.sessionCensus.isEmpty)
        _ = await b.persistSessionCensus(snapshot, ts: 7)
        XCTAssertEqual(spy.rows.first?.counts, ["47/v18": 2])
        XCTAssertEqual(spy.rows.first?.chunks, 1)
    }

    func testCensusWriteFailureIsLoggedAndNeverThrows() async {
        let spy = CensusSpy()
        spy.fail = true
        var lines: [String] = []
        let b = makeBackfiller(store: spy, log: { lines.append($0) })
        let wrote = await b.persistSessionCensus(b.sessionCensusSnapshot(), ts: 1)
        XCTAssertFalse(wrote)
        XCTAssertTrue(spy.rows.isEmpty)
        XCTAssertTrue(lines.contains { $0.contains("couldn't store the record census row") })
    }
}

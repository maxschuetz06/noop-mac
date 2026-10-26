import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

/// The Backfiller's per-session history-frontier progress signal that feeds the auto-continue decision:
/// "did this session newly persist a history-only row (gravity / strap state / …) newer than where the
/// history frontier stood when the session started?". Frames are CONSTRUCTED (no captured data); only the
/// START/END control frames are the already-checked-in metadata fixtures.
@MainActor
final class BackfillerHistoryFrontierTests: XCTestCase {

    private enum Fx {
        static let historyEndHex =
            "aa011c00010023d1316a0284a3266a0a373d00000041b601001000000000000044d21e3d"
        static let historyStartHex =
            "aa012c0001002cd1312c0184a3266ad7230d0000005200000000000000320000002600000001000000000000000b010034497926"

        static func bytes(_ s: String) -> [UInt8] {
            var out = [UInt8](); var i = s.startIndex
            while i < s.endIndex {
                let j = s.index(i, offsetBy: 2)
                out.append(UInt8(s[i..<j], radix: 16)!); i = j
            }
            return out
        }

        /// Synthetic CRC-valid v18 record: HR 64, gravity (0.1, -0.2, 0.97), wear/sleep byte 0x21.
        static func v18(unix: Int) -> [UInt8] {
            var f = [UInt8](repeating: 0, count: 124)
            f[0] = 0xAA; f[1] = 0x01
            f[2] = UInt8(116 & 0xff); f[3] = 0
            f[4] = 0x01; f[5] = 0x00
            f[8] = 47; f[9] = 18
            for k in 0..<4 { f[15 + k] = UInt8((UInt32(unix) >> (8 * UInt32(k))) & 0xff) }
            f[22] = 64
            for (off, v) in [(45, Float(0.10)), (49, Float(-0.20)), (53, Float(0.97))] {
                let b = v.bitPattern
                for k in 0..<4 { f[off + k] = UInt8((b >> (8 * UInt32(k))) & 0xff) }
            }
            f[81] = 0x21
            let h = crc16Modbus(Array(f[0..<6]))
            f[6] = UInt8(h & 0xff); f[7] = UInt8((h >> 8) & 0xff)
            let c = crc32(Array(f[8..<120]))
            for k in 0..<4 { f[120 + k] = UInt8((c >> (8 * UInt32(k))) & 0xff) }
            return f
        }
    }

    private final class SpyStore: BackfillStoreWriting {
        var startFrontier: Int?
        /// false ⇒ behave like a store that already holds every row (all inserts are conflicts → 0 new rows).
        var insertsAreNew = true
        var frontierReads = 0
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            guard insertsAreNew else { return (0, 0, 0, 0, 0, 0, 0, 0) }
            return (streams.hr.count, streams.rr.count, streams.events.count, streams.battery.count,
                    streams.spo2.count, streams.skinTemp.count, streams.resp.count, streams.gravity.count)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
        func setCursor(_ name: String, _ value: Int) async throws {}
        func cursor(_ name: String) async throws -> Int? { nil }
        func latestHistoryTs(deviceId: String) async throws -> Int? { frontierReads += 1; return startFrontier }
    }

    private var t0: Int { Int(Date().timeIntervalSince1970) - 7200 }

    private func offload(_ store: SpyStore, records: [[UInt8]]) async -> Backfiller {
        let b = Backfiller(store: store, deviceId: "t", ackTrim: { _, _ in }, enableRawCapture: false,
                           log: { _ in }, rejectedSink: { _, _, _ in true })
        b.clockRef = ClockRef(device: t0, wall: t0)
        b.begin(family: .whoop5)
        await b.ingest(Fx.bytes(Fx.historyStartHex))
        for f in records { await b.ingest(f) }
        await b.ingest(Fx.bytes(Fx.historyEndHex))
        return b
    }

    private func records(_ n: Int, from start: Int) -> [[UInt8]] { (0..<n).map { Fx.v18(unix: start + $0) } }

    func testSessionNewerThanTheStartingFrontierAdvancesIt() async {
        let store = SpyStore(); store.startFrontier = t0 - 1000
        let b = await offload(store, records: records(17, from: t0))
        XCTAssertGreaterThan(b.sessionRowsPersisted, 0)
        XCTAssertEqual(b.sessionNewestHistoryTs, t0 + 16)
        XCTAssertTrue(b.sessionHistoryFrontierAdvanced)
        XCTAssertEqual(store.frontierReads, 1, "the baseline is read once per session, before the first insert")
    }

    func testNoHistoryRowsYetCountsAnyPersistedHistoryRowAsAdvance() async {
        let store = SpyStore(); store.startFrontier = nil
        let b = await offload(store, records: records(5, from: t0))
        XCTAssertTrue(b.sessionHistoryFrontierAdvanced)
    }

    func testResentChunkTheStoreAlreadyHoldsIsNotProgress() async {
        let store = SpyStore(); store.startFrontier = t0 + 16     // frontier already at the chunk's newest record
        store.insertsAreNew = false                               // every insert is a conflict → 0 new rows
        let b = await offload(store, records: records(17, from: t0))
        XCTAssertEqual(b.sessionRowsPersisted, 0)
        XCTAssertNil(b.sessionNewestHistoryTs)
        XCTAssertFalse(b.sessionHistoryFrontierAdvanced)
    }

    func testRowsOlderThanTheFrontierDoNotMoveIt() async {
        let store = SpyStore(); store.startFrontier = t0 + 10_000   // newer history already persisted
        let b = await offload(store, records: records(17, from: t0))
        XCTAssertGreaterThan(b.sessionRowsPersisted, 0, "rows are new, but behind the frontier")
        XCTAssertFalse(b.sessionHistoryFrontierAdvanced)
    }

    func testProgressStateResetsOnTheNextSession() async {
        let store = SpyStore(); store.startFrontier = t0 - 1000
        let b = await offload(store, records: records(3, from: t0))
        XCTAssertTrue(b.sessionHistoryFrontierAdvanced)
        b.begin(family: .whoop5)
        XCTAssertNil(b.sessionNewestHistoryTs)
        XCTAssertFalse(b.sessionHistoryFrontierAdvanced)
        XCTAssertEqual(b.sessionChunkWorkSeconds, 0)
    }

    // MARK: pure helpers

    func testNewestHistoryTsIgnoresRealtimeCapableStreams() {
        var s = Streams(hr: [HRSample(ts: 9_999, bpm: 60)], rr: [RRInterval(ts: 9_999, rrMs: 900)],
                        gravity: [GravitySample(ts: 50, x: 0, y: 0, z: 1)],
                        events: [WhoopEvent(ts: 9_999, kind: "x", payload: [:])])
        XCTAssertEqual(Backfiller.newestHistoryTs(of: s), 50)
        s.strapState = [StrapStateSample(ts: 70, onWrist: 1, sleepState: 0)]
        XCTAssertEqual(Backfiller.newestHistoryTs(of: s), 70)
        XCTAssertNil(Backfiller.newestHistoryTs(of: Streams(hr: [HRSample(ts: 1, bpm: 60)])))
    }

    func testSessionTimingLineReportsChunkCommitCost() {
        let line = Backfiller.sessionTimingLine(chunks: 4, elapsed: 8.0, chunkWork: 0.4, maxChunkWork: 0.2)
        XCTAssertEqual(line, "Backfill: session timing — 4 chunk(s) in 8.0 s (2.00 s/chunk); our commit work 0.40 s total, slowest chunk 0.20 s.")
        XCTAssertTrue(Backfiller.sessionTimingLine(chunks: 0, elapsed: 1, chunkWork: 0, maxChunkWork: 0).contains("0 chunk(s)"))
    }
}

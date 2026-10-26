import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

/// History forensics in `Backfiller`: a per-session record census (what the strap handed over, by packet
/// type / layout version) and a bounded raw sample (`histdiag-` rawBatch) of the records that did NOT
/// become sensor rows. Pins that the sample is observation-only — it never reorders or blocks the
/// decoded-insert → cursor → ack invariant — and that a v26-only chunk is no longer reported as
/// "console output".
@MainActor
final class BackfillerCensusDiagnosticTests: XCTestCase {

    // MARK: - Fixtures (real WHOOP 5 capture for v18/START/END; synthetic envelopes for bulk layouts)

    private enum Fx {
        static let historyEndHex =
            "aa011c00010023d1316a0284a3266a0a373d00000041b601001000000000000044d21e3d"   // trim=112193
        static let historyStartHex =
            "aa012c0001002cd1312c0184a3266ad7230d0000005200000000000000320000002600000001000000000000000b010034497926"
        static let v18Hex =
            "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"
        static let baseUnix = 1_780_916_150
        static let endTrim: UInt32 = 112193

        static func bytes(_ s: String) -> [UInt8] {
            var out = [UInt8](); var i = s.startIndex
            while i < s.endIndex {
                let j = s.index(i, offsetBy: 2)
                out.append(UInt8(s[i..<j], radix: 16)!); i = j
            }
            return out
        }

        /// CRC-valid v18 records with consecutive timestamps.
        static func v18(_ count: Int) -> [[UInt8]] {
            let template = bytes(v18Hex)
            let payloadEnd = (Int(template[2]) | (Int(template[3]) << 8)) + 8 - 4
            return (0..<count).map { i in
                var f = template
                let ts = UInt32(baseUnix + i)
                for k in 0..<4 { f[15 + k] = UInt8((ts >> (8 * UInt32(k))) & 0xFF) }
                let c = crc32(Array(f[8..<payloadEnd]))
                for k in 0..<4 { f[payloadEnd + k] = UInt8((c >> (8 * UInt32(k))) & 0xFF) }
                return f
            }
        }

        /// CRC-valid type-47 envelope with layout `version` and a plausible unix @15 (no HR / gravity fields).
        static func bulk(total: Int, version: UInt8, index: Int) -> [UInt8] {
            var f = [UInt8](repeating: 0, count: total)
            f[0] = 0xAA; f[1] = 0x01
            let declared = total - 8
            f[2] = UInt8(declared & 0xff); f[3] = UInt8((declared >> 8) & 0xff)
            f[4] = 0x01; f[5] = 0x00
            f[8] = 47; f[9] = version
            let ts = UInt32(baseUnix + index)
            for k in 0..<4 { f[15 + k] = UInt8((ts >> (8 * UInt32(k))) & 0xff) }
            let h = crc16Modbus(Array(f[0..<6]))
            f[6] = UInt8(h & 0xff); f[7] = UInt8((h >> 8) & 0xff)
            let end = total - 4
            let c = crc32(Array(f[8..<end]))
            for k in 0..<4 { f[end + k] = UInt8((c >> (8 * UInt32(k))) & 0xff) }
            return f
        }
    }

    // MARK: - Spy

    private final class SpyStore: BackfillStoreWriting {
        var events: [String] = []
        var rawBatches: [(meta: RawBatchMeta, frames: [[UInt8]])] = []
        var failInsert = false
        var failRaw = false
        struct Boom: Error {}

        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            if failInsert { throw Boom() }
            events.append("insert")
            return (streams.hr.count, streams.rr.count, streams.events.count, streams.battery.count,
                    streams.spo2.count, streams.skinTemp.count, streams.resp.count, streams.gravity.count)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {
            if failRaw { throw Boom() }
            events.append("raw:\(meta.batchId)")
            rawBatches.append((meta, frames))
        }
        func setCursor(_ name: String, _ value: Int) async throws { events.append("setCursor") }
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    private final class LogBox { var lines: [String] = [] }

    private func makeBackfiller(store: SpyStore, rawCapture: Bool = false, box: LogBox) -> Backfiller {
        let ack: (UInt32, [UInt8]) -> Void = { trim, _ in store.events.append("ack:\(trim)") }
        let b = Backfiller(store: store, deviceId: "t", ackTrim: ack, enableRawCapture: rawCapture,
                           log: { box.lines.append($0) }, rejectedSink: { _, _, _ in true })
        b.clockRef = ClockRef(device: Fx.baseUnix, wall: Fx.baseUnix)
        return b
    }

    private func offload(_ b: Backfiller, _ data: [[UInt8]]) async {
        b.begin(family: .whoop5)
        await b.ingest(Fx.bytes(Fx.historyStartHex))
        for f in data { await b.ingest(f) }
        await b.ingest(Fx.bytes(Fx.historyEndHex))
    }

    // MARK: - Tests

    func testCensusAndBoundedRawSampleOfNonDecodedRecordsBeforeCursorAndAck() async {
        let store = SpyStore(), box = LogBox()
        let b = makeBackfiller(store: store, box: box)
        let v26 = (0..<5).map { Fx.bulk(total: 88, version: 26, index: 100 + $0) }
        let v20 = (0..<3).map { Fx.bulk(total: 2140, version: 20, index: 200 + $0) }
        await offload(b, Fx.v18(10) + v26 + v20)

        XCTAssertEqual(b.sessionCensus.count("47/v18"), 10)
        XCTAssertEqual(b.sessionCensus.count("47/v26"), 5)
        XCTAssertEqual(b.sessionCensus.count("47/v20"), 3)
        XCTAssertEqual(b.sessionChunks, 1)

        // The raw sample: ≤2 per label, none of the decoded v18 records, one rawBatch with the histdiag prefix.
        XCTAssertEqual(store.rawBatches.count, 1)
        let batch = store.rawBatches[0]
        XCTAssertTrue(batch.meta.batchId.hasPrefix(WhoopStore.diagnosticRawPrefix))
        XCTAssertEqual(batch.frames, [v26[0], v26[1], v20[0], v20[1]])
        XCTAssertEqual(batch.meta.frameCount, 4)
        XCTAssertEqual(batch.meta.byteSize, 88 * 2 + 2140 * 2)
        XCTAssertEqual(b.sessionDiagnosticFrames, 4)

        // Observation only: decoded insert → diagnostic raw → cursor → ack, exactly once each.
        XCTAssertEqual(store.events, ["insert", "raw:\(batch.meta.batchId)", "setCursor", "ack:\(Fx.endTrim)"])

        let line = Backfiller.sessionCensusLine(census: b.sessionCensus, chunks: b.sessionChunks,
                                                diagnosticFrames: b.sessionDiagnosticFrames)
        XCTAssertEqual(line, "Backfill: record census — 47/v18×10, 47/v20×3, 47/v26×5 in 1 chunk(s); 18 type-47 sensor record(s). Kept 4 raw diagnostic frame(s) of non-decoded records.")
    }

    func testV26OnlyChunkIsNotReportedAsConsoleOutputAndStillAcks() async {
        let store = SpyStore(), box = LogBox()
        let b = makeBackfiller(store: store, box: box)
        await offload(b, (0..<6).map { Fx.bulk(total: 88, version: 26, index: $0) })

        XCTAssertFalse(box.lines.contains { $0.contains("console/diagnostic output") },
                       "type-47 records arrived — not console output")
        XCTAssertTrue(box.lines.contains { $0.contains("47/v26×6") && $0.contains("decoded to no sensor rows") })
        XCTAssertEqual(store.rawBatches.count, 1)
        XCTAssertEqual(store.rawBatches[0].frames.count, 2)
        XCTAssertEqual(store.events.last, "ack:\(Fx.endTrim)")
    }

    func testEmptySessionStillProducesACensusLine() async {
        let store = SpyStore(), box = LogBox()
        let b = makeBackfiller(store: store, box: box)
        await offload(b, [])
        XCTAssertTrue(store.rawBatches.isEmpty)
        XCTAssertEqual(store.events, ["setCursor", "ack:\(Fx.endTrim)"], "an empty END is still acked")
        XCTAssertEqual(Backfiller.sessionCensusLine(census: b.sessionCensus, chunks: b.sessionChunks, diagnosticFrames: 0),
                       "Backfill: record census — no data records in 1 chunk(s) (the strap handed over only bookkeeping, or nothing).")
    }

    func testDiagnosticStoreFailureNeverHoldsTheAck() async {
        let store = SpyStore(), box = LogBox()
        store.failRaw = true
        let b = makeBackfiller(store: store, box: box)
        await offload(b, Fx.v18(3) + [Fx.bulk(total: 88, version: 26, index: 9)])
        XCTAssertEqual(store.events, ["insert", "setCursor", "ack:\(Fx.endTrim)"])
        XCTAssertEqual(box.lines.filter { $0.contains("couldn't store the raw diagnostic sample") }.count, 1)
        XCTAssertEqual(b.sessionDiagnosticFrames, 0)
    }

    func testResearchRawCaptureTogglePreventsDuplicateDiagnosticBatch() async {
        let store = SpyStore(), box = LogBox()
        let b = makeBackfiller(store: store, rawCapture: true, box: box)
        await offload(b, Fx.v18(3) + [Fx.bulk(total: 88, version: 26, index: 9)])
        XCTAssertEqual(store.rawBatches.count, 1, "only the full-chunk research batch")
        XCTAssertTrue(store.rawBatches[0].meta.batchId.hasPrefix("hist-"))
        XCTAssertEqual(b.sessionDiagnosticFrames, 0)
    }

    func testFailedInsertDoesNotCountOrAckAndSessionBudgetIsEnforced() async {
        let store = SpyStore(), box = LogBox()
        store.failInsert = true
        let b = makeBackfiller(store: store, box: box)
        await offload(b, Fx.v18(3))
        XCTAssertTrue(b.sessionCensus.isEmpty, "a chunk whose rows weren't persisted is re-sent — don't count it twice")
        XCTAssertFalse(store.events.contains { $0.hasPrefix("ack") })

        // Session byte budget: once spent, further samples are skipped (sync unaffected).
        let store2 = SpyStore()
        let b2 = makeBackfiller(store: store2, box: LogBox())
        b2.begin(family: .whoop5)
        let big = [UInt8](repeating: 0xAB, count: 700_000)
        let first = await b2.archiveDiagnostic(frames: [big], tag: "a")
        let second = await b2.archiveDiagnostic(frames: [big], tag: "b")
        let third = await b2.archiveDiagnostic(frames: [big], tag: "c")
        XCTAssertTrue(first); XCTAssertTrue(second); XCTAssertFalse(third)
        XCTAssertEqual(store2.rawBatches.count, 2)
    }
}

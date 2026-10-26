import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

/// Fixtures (real WHOOP 5 captures, see Whoop5HistoricalTests). A plain enum so the constants are
/// nonisolated and usable from the @MainActor test class and from `@Sendable` closures alike.
private enum Fx {
    static let historyEndHex =
        "aa011c00010023d1316a0284a3266a0a373d00000041b601001000000000000044d21e3d"   // trim=112193, unix=1780917124
    static let historyStartHex =
        "aa012c0001002cd1312c0184a3266ad7230d0000005200000000000000320000002600000001000000000000000b010034497926"
    static let historicalV18Hex =
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

    /// CRC-valid v18 records with consecutive timestamps starting at `startUnix`.
    static func dataFrames(_ count: Int, startUnix: Int = baseUnix) -> [[UInt8]] {
        let template = bytes(historicalV18Hex)
        let payloadEnd = (Int(template[2]) | (Int(template[3]) << 8)) + 8 - 4
        return (0..<count).map { i in
            var f = template
            let ts = UInt32(startUnix + i)
            for k in 0..<4 { f[15 + k] = UInt8((ts >> (8 * UInt32(k))) & 0xFF) }
            let c = crc32(Array(f[8..<payloadEnd]))
            for k in 0..<4 { f[payloadEnd + k] = UInt8((c >> (8 * UInt32(k))) & 0xFF) }
            return f
        }
    }

    static var startFrame: [UInt8] { bytes(historyStartHex) }
    static var endFrame: [UInt8] { bytes(historyEndHex) }
}

/// Pins the history-sync performance work in `Backfiller`: the per-frame META pre-filter in `ingest` and
/// the off-main-actor chunk decode in `finishChunk`. Behaviour must be identical to the old synchronous
/// path — same persisted rows, same store-write → setCursor → ack order, and the CRC integrity gate on
/// START/END/COMPLETE still applies.
@MainActor
final class BackfillerOffMainDecodeTests: XCTestCase {

    // MARK: - Spies

    private final class SpyStore: BackfillStoreWriting {
        var events: [String]
        var inserted: [Streams] = []
        var failInsert = false
        init(events: [String] = []) { self.events = events }
        struct Boom: Error {}

        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            if failInsert { throw Boom() }
            events.append("insert")
            inserted.append(streams)
            return (streams.hr.count, streams.rr.count, streams.events.count, streams.battery.count,
                    streams.spo2.count, streams.skinTemp.count, streams.resp.count, streams.gravity.count)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws { events.append("raw") }
        func setCursor(_ name: String, _ value: Int) async throws { events.append("setCursor:\(name)=\(value)") }
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    private final class ThreadProbe: @unchecked Sendable {   // test-only box guarded by a lock
        private let lock = NSLock()
        private var flags: [Bool] = []
        func record() { lock.lock(); flags.append(Thread.isMainThread); lock.unlock() }
        var onMainFlags: [Bool] { lock.lock(); defer { lock.unlock() }; return flags }
    }

    private struct Harness {
        let backfiller: Backfiller
        let store: SpyStore
        var log: LogBox
    }
    private final class LogBox { var lines: [String] = []; var rejected: [(frames: [[UInt8]], trim: UInt32)] = [] }

    private func makeHarness(extract: Backfiller.Extractor? = nil,
                             rejectedSinkResult: Bool = true) -> Harness {
        let store = SpyStore()
        let box = LogBox()
        let ack: (UInt32, [UInt8]) -> Void = { trim, _ in store.events.append("ack:\(trim)") }
        let sink: (_ frames: [[UInt8]], _ trim: UInt32, _ family: DeviceFamily) -> Bool = { frames, trim, _ in
            box.rejected.append((frames, trim))
            store.events.append("rejectedSink")
            return rejectedSinkResult
        }
        let b: Backfiller
        if let extract {
            b = Backfiller(store: store, deviceId: "t", ackTrim: ack, log: { box.lines.append($0) },
                           rejectedSink: sink, extract: extract)
        } else {
            b = Backfiller(store: store, deviceId: "t", ackTrim: ack, log: { box.lines.append($0) },
                           rejectedSink: sink)
        }
        b.clockRef = ClockRef(device: Fx.baseUnix, wall: Fx.baseUnix)
        return Harness(backfiller: b, store: store, log: box)
    }

    // MARK: - classify (ingest pre-filter) parity

    func testClassifyMatchesFullParseForRealFramesBothFamilies() {
        let frames = [Fx.startFrame, Fx.endFrame] + Fx.dataFrames(5)
            + [frameFromPayload([], type: 49, seq: 0, cmd: 1),
               frameFromPayload([], type: 49, seq: 0, cmd: 3),
               frameFromPayload([1, 2, 3], type: 40, seq: 0, cmd: 0),
               [], [0xAA], [UInt8](repeating: 0xAA, count: 30)]
        for family in [DeviceFamily.whoop4, .whoop5] {
            for f in frames {
                XCTAssertEqual(Backfiller.classify(f, family: family),
                               classifyHistoricalMeta(parseFrame(f, family: family)),
                               "family \(family) frame \(f.prefix(12))")
            }
        }
        XCTAssertEqual(Backfiller.classify(Fx.startFrame, family: .whoop5), .start)
        XCTAssertEqual(Backfiller.classify(Fx.endFrame, family: .whoop5), .end(unix: 1780917124, trim: Fx.endTrim))
        XCTAssertEqual(Backfiller.classify(Fx.dataFrames(1)[0], family: .whoop5), .other)
    }

    // MARK: - end-to-end ordering + parity

    func testChunkPersistsThenCursorThenAckInOrderAndMatchesSynchronousDecode() async {
        let h = makeHarness()
        let frames = Fx.dataFrames(30)
        h.backfiller.begin(family: .whoop5)
        await h.backfiller.ingest(Fx.startFrame)
        for f in frames { await h.backfiller.ingest(f) }
        XCTAssertTrue(h.store.events.isEmpty, "nothing is persisted or acked before the HISTORY_END")
        await h.backfiller.ingest(Fx.endFrame)

        XCTAssertEqual(h.store.events, ["insert", "setCursor:strap_trim=\(Fx.endTrim)", "ack:\(Fx.endTrim)"])
        XCTAssertEqual(h.backfiller.lastAckedTrim, Fx.endTrim)

        // The persisted rows are exactly what the old synchronous decode produced.
        let expected = extractHistoricalStreams(frames.map { parseFrame($0, family: .whoop5) },
                                                deviceClockRef: Fx.baseUnix, wallClockRef: Fx.baseUnix,
                                                sessionOldestUnix: nil, sessionNewestUnix: nil)
        XCTAssertEqual(h.store.inserted.count, 1)
        XCTAssertEqual(h.store.inserted[0], expected)
        XCTAssertEqual(h.store.inserted[0].hr.count, 30)
        XCTAssertTrue(h.log.lines.contains("Backfill: historical records use layout v18"))
        let s0 = h.store.inserted[0]
        XCTAssertEqual(h.backfiller.sessionRowsPersisted,
                       s0.hr.count + s0.rr.count + s0.spo2.count + s0.skinTemp.count + s0.resp.count + s0.gravity.count)
        XCTAssertGreaterThan(h.backfiller.sessionRowsPersisted, 0)
    }

    func testTwoChunksStayOrderedAndDoNotLeakFramesIntoEachOther() async {
        let h = makeHarness()
        let a = Fx.dataFrames(10, startUnix: Fx.baseUnix)
        let b = Fx.dataFrames(7, startUnix: Fx.baseUnix + 100)
        h.backfiller.begin(family: .whoop5)
        await h.backfiller.ingest(Fx.startFrame)
        for f in a { await h.backfiller.ingest(f) }
        await h.backfiller.ingest(Fx.endFrame)
        for f in b { await h.backfiller.ingest(f) }
        await h.backfiller.ingest(Fx.endFrame)

        let cursor = "setCursor:strap_trim=\(Fx.endTrim)", ack = "ack:\(Fx.endTrim)"
        XCTAssertEqual(h.store.events, ["insert", cursor, ack, "insert", cursor, ack])
        XCTAssertEqual(h.store.inserted.map(\.hr.count), [10, 7])
        XCTAssertEqual(h.store.inserted[1].hr.first?.ts, Fx.baseUnix + 100)
    }

    func testEmptyEndIsStillAckedWithoutInsert() async {
        let h = makeHarness()
        h.backfiller.begin(family: .whoop5)
        await h.backfiller.ingest(Fx.endFrame)
        XCTAssertEqual(h.store.events, ["setCursor:strap_trim=\(Fx.endTrim)", "ack:\(Fx.endTrim)"])
    }

    func testFailedInsertHoldsCursorAndAck() async {
        let h = makeHarness()
        h.store.failInsert = true
        h.backfiller.begin(family: .whoop5)
        await h.backfiller.ingest(Fx.startFrame)
        for f in Fx.dataFrames(5) { await h.backfiller.ingest(f) }
        await h.backfiller.ingest(Fx.endFrame)
        XCTAssertTrue(h.store.events.isEmpty, "no cursor write and NO ack when the durable write fails")
        XCTAssertNil(h.backfiller.lastAckedTrim)
    }

    func testRejectedRecordsAreArchivedBeforeCursorAndAck() async {
        let h = makeHarness()
        var bad = Fx.dataFrames(1, startUnix: Fx.baseUnix + 500)[0]
        bad[bad.count - 1] ^= 0xFF                       // CRC32 mismatch → genuine reject
        h.backfiller.begin(family: .whoop5)
        await h.backfiller.ingest(Fx.startFrame)
        for f in Fx.dataFrames(3) { await h.backfiller.ingest(f) }
        await h.backfiller.ingest(bad)
        await h.backfiller.ingest(Fx.endFrame)
        // "raw" = the bounded histdiag forensics sample of the CRC-failed record (observation only).
        XCTAssertEqual(h.store.events, ["insert", "rejectedSink", "raw", "setCursor:strap_trim=\(Fx.endTrim)", "ack:\(Fx.endTrim)"])
        XCTAssertEqual(h.log.rejected.count, 1)
        XCTAssertEqual(h.log.rejected[0].frames, [bad])
        XCTAssertEqual(h.store.inserted[0].hr.count, 3)

        // A failed archive still holds the ack.
        let h2 = makeHarness(rejectedSinkResult: false)
        h2.backfiller.begin(family: .whoop5)
        await h2.backfiller.ingest(Fx.startFrame)
        await h2.backfiller.ingest(bad)
        await h2.backfiller.ingest(Fx.endFrame)
        XCTAssertEqual(h2.store.events, ["insert", "rejectedSink"], "archive failure: no cursor write, no ack")
        XCTAssertNil(h2.backfiller.lastAckedTrim)
    }

    // MARK: - integrity gate is unchanged

    func testForgedEndWithBadCRCIsNotActedOn() async {
        let h = makeHarness()
        var forged = Fx.endFrame
        forged[forged.count - 1] ^= 0xFF
        h.backfiller.begin(family: .whoop5)
        await h.backfiller.ingest(Fx.startFrame)
        for f in Fx.dataFrames(3) { await h.backfiller.ingest(f) }
        await h.backfiller.ingest(forged)
        XCTAssertTrue(h.store.events.isEmpty, "a CRC-failed HISTORY_END must not persist, set the cursor or ack")
        XCTAssertTrue(h.backfiller.isBackfilling)
        // The genuine END afterwards still sees the 3 buffered records (the forged one was just a data frame).
        await h.backfiller.ingest(Fx.endFrame)
        XCTAssertEqual(h.store.events.first, "insert")
        XCTAssertEqual(h.store.events.last, "ack:\(Fx.endTrim)")
    }

    // MARK: - off-main

    func testChunkDecodeRunsOffTheMainThread() async {
        let probe = ThreadProbe()
        let h = makeHarness(extract: { parsed, dev, wall, oldest, newest in
            probe.record()
            return extractHistoricalStreams(parsed, deviceClockRef: dev, wallClockRef: wall,
                                            sessionOldestUnix: oldest, sessionNewestUnix: newest)
        })
        h.backfiller.begin(family: .whoop5)
        await h.backfiller.ingest(Fx.startFrame)
        for f in Fx.dataFrames(12) { await h.backfiller.ingest(f) }
        await h.backfiller.ingest(Fx.endFrame)
        XCTAssertEqual(probe.onMainFlags, [false], "extract must run exactly once and off the main thread")
        XCTAssertEqual(h.store.inserted.first?.hr.count, 12)
    }

    func testDecodeChunkIsPureAndReportsUnmappedLayoutOnce() {
        // A type-47 frame whose layout version has no field map: valid CRC, no HR / gravity / PPG.
        var odd = Fx.dataFrames(1)[0]
        odd[9] = 99                                       // hist_version → unmapped
        let payloadEnd = (Int(odd[2]) | (Int(odd[3]) << 8)) + 8 - 4
        let c = crc32(Array(odd[8..<payloadEnd]))
        for k in 0..<4 { odd[payloadEnd + k] = UInt8((c >> (8 * UInt32(k))) & 0xFF) }
        let good = Fx.dataFrames(2)
        let out = Backfiller.decodeChunk(frames: [good[0], odd, odd, good[1]], family: .whoop5,
                                         deviceClock: Fx.baseUnix, wallClock: Fx.baseUnix,
                                         sessionOldestUnix: nil, sessionNewestUnix: nil,
                                         extract: { extractHistoricalStreams($0, deviceClockRef: $1, wallClockRef: $2,
                                                                             sessionOldestUnix: $3, sessionNewestUnix: $4) })
        XCTAssertEqual(out.firstLayoutVersion, 18)
        XCTAssertEqual(out.unmappedVersions, [99], "distinct, first-seen order")
        XCTAssertEqual(out.streams.hr.count, 2)
        XCTAssertEqual(out.rejected, [odd, odd])
    }
}

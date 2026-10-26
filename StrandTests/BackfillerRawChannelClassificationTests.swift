import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

/// WHOOP 5.0 firmware 50.42.x hands over every second as a v18 + v20 + v21 triple. The Backfiller used to
/// classify the CRC-valid v20/v21 raw-channel records as "undecodable": it archived them into the reject
/// archive, counted them as lost, and logged "layout v20/v21 … NOOP doesn't decode yet — no motion data, so
/// sleep can't be computed" although the v18 record of the same second supplied HR, gravity and the rest.
/// All frames below are CONSTRUCTED (no captured health data); only the two control frames are the
/// already-checked-in START/END metadata fixtures.
@MainActor
final class BackfillerRawChannelClassificationTests: XCTestCase {

    private enum Fx {
        static let historyEndHex =
            "aa011c00010023d1316a0284a3266a0a373d00000041b601001000000000000044d21e3d"   // trim=112193
        static let historyStartHex =
            "aa012c0001002cd1312c0184a3266ad7230d0000005200000000000000320000002600000001000000000000000b010034497926"
        static let endTrim: UInt32 = 112193

        static func bytes(_ s: String) -> [UInt8] {
            var out = [UInt8](); var i = s.startIndex
            while i < s.endIndex {
                let j = s.index(i, offsetBy: 2)
                out.append(UInt8(s[i..<j], radix: 16)!); i = j
            }
            return out
        }

        static func put32(_ f: inout [UInt8], _ off: Int, _ v: UInt32) {
            for k in 0..<4 { f[off + k] = UInt8((v >> (8 * UInt32(k))) & 0xff) }
        }

        static func frame(total: Int, version: UInt8, unix: Int, _ body: (inout [UInt8]) -> Void) -> [UInt8] {
            var f = [UInt8](repeating: 0, count: total)
            f[0] = 0xAA; f[1] = 0x01
            let declared = total - 8
            f[2] = UInt8(declared & 0xff); f[3] = UInt8((declared >> 8) & 0xff)
            f[4] = 0x01; f[5] = 0x00
            f[8] = 47; f[9] = version
            put32(&f, 15, UInt32(unix))
            body(&f)
            let h = crc16Modbus(Array(f[0..<6]))
            f[6] = UInt8(h & 0xff); f[7] = UInt8((h >> 8) & 0xff)
            let end = total - 4
            put32(&f, end, crc32(Array(f[8..<end])))
            return f
        }

        /// Synthetic v18: HR 64, gravity (0.10, -0.20, 0.97), skin raw 3214, step counter, state byte 0x21.
        static func v18(unix: Int, steps: Int) -> [UInt8] {
            frame(total: 124, version: 18, unix: unix) { f in
                f[22] = 64
                f[45...48] = ArraySlice(Float(0.10).bitPattern.leBytes)
                f[49...52] = ArraySlice(Float(-0.20).bitPattern.leBytes)
                f[53...56] = ArraySlice(Float(0.97).bitPattern.leBytes)
                f[57] = UInt8(steps & 0xff); f[58] = UInt8((steps >> 8) & 0xff)
                f[73] = UInt8(3214 & 0xff); f[74] = UInt8(3214 >> 8)
                f[81] = 0x21
            }
        }

        static func v21(unix: Int) -> [UInt8] {
            frame(total: 1244, version: 21, unix: unix) { f in
                f[10] = 0x80
                for i in 0..<100 { f[28 + i * 2] = UInt8(truncatingIfNeeded: 20 + i % 9) }
            }
        }

        static func v20(unix: Int) -> [UInt8] {
            frame(total: 2140, version: 20, unix: unix) { f in
                f[10] = 0x81
                f[0x1a] = 0x19
                for i in 0..<50 { f[0x2f + i * 4] = UInt8(truncatingIfNeeded: 10 + i % 5) }
                for i in 0..<50 { f[0xf7 + i * 4] = UInt8(truncatingIfNeeded: 30 + i % 5) }
            }
        }

        static func triples(_ n: Int, start: Int) -> [[UInt8]] {
            (0..<n).flatMap { [v18(unix: start + $0, steps: 100 + $0), v20(unix: start + $0), v21(unix: start + $0)] }
        }
    }

    private final class SpyStore: BackfillStoreWriting {
        var events: [String] = []
        var inserted: [Streams] = []
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            events.append("insert"); inserted.append(streams)
            return (streams.hr.count, streams.rr.count, streams.events.count, streams.battery.count,
                    streams.spo2.count, streams.skinTemp.count, streams.resp.count, streams.gravity.count)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws { events.append("raw") }
        func setCursor(_ name: String, _ value: Int) async throws { events.append("setCursor") }
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    private final class Box { var lines: [String] = []; var rejectedArchived = 0; var acked: [UInt32] = [] }

    private let extractor: Backfiller.Extractor = {
        extractHistoricalStreams($0, deviceClockRef: $1, wallClockRef: $2, sessionOldestUnix: $3, sessionNewestUnix: $4)
    }

    private var start: Int { Int(Date().timeIntervalSince1970) - 7200 }

    // MARK: - decodeChunk

    func testTripleChunkHasNoUnmappedVersionAndNoRejects() {
        let t = start
        let frames = Fx.triples(17, start: t)
        let out = Backfiller.decodeChunk(frames: frames, family: .whoop5, deviceClock: t, wallClock: t,
                                         sessionOldestUnix: nil, sessionNewestUnix: nil, extract: extractor)
        XCTAssertEqual(out.firstLayoutVersion, 18)
        XCTAssertEqual(out.unmappedVersions, [], "v20/v21 raw-channel records are a known layout")
        XCTAssertTrue(out.rejected.isEmpty)
        XCTAssertEqual(out.census.count("47/v18"), 17)
        XCTAssertEqual(out.census.count("47/v20"), 17)
        XCTAssertEqual(out.census.count("47/v21"), 17)
        XCTAssertEqual(out.streams.hr.count, 17)
        XCTAssertEqual(out.streams.gravity.count, 17)
        XCTAssertEqual(out.streams.skinTemp.count, 17)
        XCTAssertEqual(out.streams.steps.count, 17)
        XCTAssertEqual(out.streams.strapState.count, 17)
        // Only a bounded sample of the raw-channel records is kept for research (2 per label).
        XCTAssertEqual(out.diagnostic.count, 4)
    }

    func testEmptyV20WithoutChannelsIsStillReportedUnmapped() {
        let t = start
        let empty = Fx.frame(total: 2140, version: 20, unix: t) { $0[10] = 0x81 }   // all presence bytes 0
        let out = Backfiller.decodeChunk(frames: [Fx.v18(unix: t, steps: 1), empty], family: .whoop5,
                                         deviceClock: t, wallClock: t, sessionOldestUnix: nil,
                                         sessionNewestUnix: nil, extract: extractor)
        XCTAssertEqual(out.unmappedVersions, [20])
        XCTAssertEqual(out.rejected, [empty])
    }

    // MARK: - log wording

    func testUnmappedLogLineOnlyClaimsNoSleepWhenNothingSuppliedMotion() {
        let none = Backfiller.unmappedLayoutLogLine(version: 99, chunkHasMotion: false)
        XCTAssertTrue(none.contains("v99") && none.contains("doesn't decode yet") && none.contains("sleep can't be computed"))
        let some = Backfiller.unmappedLayoutLogLine(version: 99, chunkHasMotion: true)
        XCTAssertTrue(some.contains("v99"))
        XCTAssertFalse(some.contains("sleep can't be computed"))
        XCTAssertFalse(some.contains("doesn't decode yet"))
        XCTAssertTrue(some.contains("sleep is unaffected"))
    }

    // MARK: - whole offload

    func testOffloadOfTriplesPersistsMotionAndLogsNothingUndecodable() async {
        let t = start
        let store = SpyStore(), box = Box()
        let b = Backfiller(store: store, deviceId: "t", ackTrim: { trim, _ in box.acked.append(trim) },
                           enableRawCapture: false, log: { box.lines.append($0) },
                           rejectedSink: { _, _, _ in box.rejectedArchived += 1; return true })
        b.clockRef = ClockRef(device: t, wall: t)
        b.begin(family: .whoop5)
        await b.ingest(Fx.bytes(Fx.historyStartHex))
        for f in Fx.triples(17, start: t) { await b.ingest(f) }
        await b.ingest(Fx.bytes(Fx.historyEndHex))

        XCTAssertEqual(store.inserted.count, 1)
        XCTAssertEqual(store.inserted[0].gravity.count, 17, "motion persists from the v18 records")
        XCTAssertEqual(store.inserted[0].hr.count, 17)
        XCTAssertEqual(box.rejectedArchived, 0, "v20/v21 are not archived as undecodable")
        XCTAssertFalse(box.lines.contains { $0.contains("undecodable") })
        XCTAssertFalse(box.lines.contains { $0.contains("doesn't decode yet") })
        XCTAssertFalse(box.lines.contains { $0.contains("sleep can't be computed") })
        XCTAssertEqual(box.acked, [Fx.endTrim])
        XCTAssertEqual(b.sessionCensus.count("47/v18"), 17)
        XCTAssertEqual(b.sessionCensus.count("47/v20"), 17)
        XCTAssertEqual(b.sessionCensus.count("47/v21"), 17)
    }
}

private extension UInt32 {
    var leBytes: [UInt8] { (0..<4).map { UInt8((self >> (8 * UInt32($0))) & 0xff) } }
}

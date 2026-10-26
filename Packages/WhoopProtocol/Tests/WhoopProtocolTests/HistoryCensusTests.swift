import XCTest
@testable import WhoopProtocol

/// Census / diagnostic sampling / unmapped-frame tap / per-channel reassembly (forensics for offloads
/// that complete without any sensor rows). All frames are synthetic with valid envelopes except the one
/// real v18 capture used as the "decodes to sensor rows" control.
final class HistoryCensusTests: XCTestCase {

    /// Real WHOOP 5.0 v18 record (same capture the Whoop5HistoricalTests use): decodes HR + gravity.
    private let v18Hex =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    /// Valid WHOOP 5 envelope of `total` bytes with packet `type` and version byte @9.
    private func frame5(total: Int, type: UInt8, version: UInt8, unix: UInt32 = 1_790_000_000) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: total)
        f[0] = 0xAA; f[1] = 0x01
        let declared = total - 8
        f[2] = UInt8(declared & 0xff); f[3] = UInt8((declared >> 8) & 0xff)
        f[4] = 0x01; f[5] = 0x00
        f[8] = type; f[9] = version
        for k in 0..<4 where total > 18 { f[15 + k] = UInt8((unix >> (8 * UInt32(k))) & 0xff) }
        let h = crc16Modbus(Array(f[0..<6]))
        f[6] = UInt8(h & 0xff); f[7] = UInt8((h >> 8) & 0xff)
        let end = total - 4
        let c = crc32(Array(f[8..<end]))
        for k in 0..<4 { f[end + k] = UInt8((c >> (8 * UInt32(k))) & 0xff) }
        return f
    }

    private func corrupt(_ f: [UInt8]) -> [UInt8] {
        var g = f; g[30] ^= 0xFF; return g   // payload bit-flip; header CRC16 still valid, CRC32 not
    }

    private func parsedAll(_ frames: [[UInt8]]) -> [ParsedFrame] {
        frames.map { parseFrame($0, family: .whoop5) }
    }

    // MARK: labels + census

    func testLabelsPerFamily() {
        XCTAssertEqual(HistoryFrameLabel.label(for: bytes(v18Hex), family: .whoop5), "47/v18")
        XCTAssertEqual(HistoryFrameLabel.label(for: frame5(total: 88, type: 47, version: 26), family: .whoop5), "47/v26")
        XCTAssertEqual(HistoryFrameLabel.label(for: frame5(total: 40, type: 52, version: 0), family: .whoop5), "52")
        XCTAssertEqual(HistoryFrameLabel.label(for: [0xAA, 0x01], family: .whoop5), "short")
        // WHOOP 4: type @4, version @5 (= the inner seq byte).
        let w4 = frameFromPayload([1, 2, 3], type: 47, seq: 24, cmd: 0)
        XCTAssertEqual(HistoryFrameLabel.label(for: w4, family: .whoop4), "47/v24")
    }

    func testCensusCountsMergesAndRendersDeterministically() {
        var a = HistoryCensus()
        XCTAssertEqual(a.summary, "none")
        a.note(bytes(v18Hex), family: .whoop5, crcOK: true)
        a.note(bytes(v18Hex), family: .whoop5, crcOK: true)
        a.note(frame5(total: 88, type: 47, version: 26), family: .whoop5, crcOK: true)
        a.note(frame5(total: 40, type: 48, version: 0), family: .whoop5, crcOK: true)
        var b = HistoryCensus()
        b.note(corrupt(frame5(total: 88, type: 47, version: 26)), family: .whoop5, crcOK: false)
        b.note(frame5(total: 40, type: 48, version: 0), family: .whoop5, crcOK: nil)
        a.merge(b)
        XCTAssertEqual(a.count("47/v18"), 2)
        XCTAssertEqual(a.count("47/v26"), 1)
        XCTAssertEqual(a.count("47/v26!crc"), 1)
        XCTAssertEqual(a.count("48"), 2)
        XCTAssertEqual(a.type47Total, 4)
        XCTAssertEqual(a.total, 6)
        XCTAssertEqual(a.summary, "47/v18×2, 47/v26×1, 47/v26!crc×1, 48×2")
    }

    // MARK: diagnostic sampling

    func testDiagnosticFramesKeepOnlyWhatDidNotBecomeSensorRows() {
        let v18 = bytes(v18Hex)
        let v26 = (0..<5).map { frame5(total: 88, type: 47, version: 26, unix: 1_790_000_000 + UInt32($0)) }
        let v20 = frame5(total: 2140, type: 47, version: 20)
        let v99 = frame5(total: 124, type: 47, version: 99)
        let badV18 = corrupt(frame5(total: 124, type: 47, version: 18))
        let event = frame5(total: 40, type: 48, version: 0)
        let unknownType = frame5(total: 60, type: 52, version: 0)
        let frames = [v18, v26[0], event, v26[1], v20, v99, v26[2], badV18, unknownType, v18]
        let parsed = parsedAll(frames)
        // Control: the real capture decodes sensor rows, the synthetic bulk layouts do not.
        XCTAssertNotNil(parsed[0].parsed["heart_rate"]?.intValue)

        let kept = diagnosticHistoryFrames(frames: frames, parsed: parsed, family: .whoop5)
        XCTAssertEqual(kept, [v26[0], v26[1], v20, v99, badV18, unknownType],
                       "v18 (stored) and the event are skipped; v26 is capped at 2 per label; order preserved")
    }

    func testDiagnosticFramesRespectFrameAndByteBudgets() {
        let frames = (0..<10).map { frame5(total: 124, type: 47, version: UInt8(60 + $0)) }  // 10 distinct unmapped versions
        let parsed = parsedAll(frames)
        XCTAssertEqual(diagnosticHistoryFrames(frames: frames, parsed: parsed, family: .whoop5, maxFrames: 3).count, 3)
        XCTAssertEqual(diagnosticHistoryFrames(frames: frames, parsed: parsed, family: .whoop5, maxBytes: 124 * 4).count, 4)
        XCTAssertTrue(diagnosticHistoryFrames(frames: [], parsed: [], family: .whoop5).isEmpty)
    }

    // MARK: unmapped-frame tap

    func testTapCountsOnlyUnhandledTypesAndBoundsSamples() {
        var tap = UnmappedFrameTap()
        XCTAssertFalse(tap.note(frame5(total: 40, type: 40, version: 0), family: .whoop5))   // live data
        XCTAssertFalse(tap.note(frame5(total: 40, type: 47, version: 18), family: .whoop5))  // Backfiller's
        XCTAssertFalse(tap.note(frame5(total: 40, type: 56, version: 0), family: .whoop5))   // puffin metadata
        XCTAssertTrue(tap.isEmpty)
        for _ in 0..<5 { XCTAssertTrue(tap.note(frame5(total: 60, type: 52, version: 0), family: .whoop5)) }
        XCTAssertTrue(tap.note(frame5(total: 60, type: 51, version: 0), family: .whoop5))
        XCTAssertFalse(tap.note([0xAA], family: .whoop5), "too short to carry a type")
        XCTAssertEqual(tap.counts, [52: 5, 51: 1])
        XCTAssertEqual(tap.summary, "51×1, 52×5")
        XCTAssertEqual(tap.samples.count, 3, "2 samples of type 52 + 1 of type 51")
        let drained = tap.drain()
        XCTAssertEqual(drained.counts, [52: 5, 51: 1])
        XCTAssertEqual(drained.samples.count, 3)
        XCTAssertTrue(tap.isEmpty)
        XCTAssertTrue(tap.samples.isEmpty)
    }

    // MARK: per-channel reassembly

    func testBankKeepsInterleavedChannelsApart() {
        let big = frameFromPayload((0..<600).map { UInt8($0 & 0xff) }, type: 47, seq: 18, cmd: 0)
        let small = frameFromPayload([9, 9, 9], type: 48, seq: 0, cmd: 0)
        let third = big.count / 3
        let parts = [Array(big[0..<third]), Array(big[third..<2 * third]), Array(big[(2 * third)...])]

        // Shared reassembler (the old behaviour): the foreign small frame is spliced into the big one.
        let shared = Reassembler(family: .whoop4)
        var sharedOut: [[UInt8]] = []
        sharedOut += shared.feed(parts[0])
        sharedOut += shared.feed(small)
        sharedOut += shared.feed(parts[1]); sharedOut += shared.feed(parts[2])
        XCTAssertNotEqual(sharedOut.first, big, "documents the cross-channel corruption of a shared buffer")

        // Per-channel bank: both frames come out intact.
        let bank = ReassemblerBank(family: .whoop4)
        var out: [[UInt8]] = []
        out += bank.feed(parts[0], channel: "data")
        out += bank.feed(small, channel: "event")
        out += bank.feed(parts[1], channel: "data")
        out += bank.feed(parts[2], channel: "data")
        XCTAssertEqual(out, [small, big])
    }

    func testBankResetDropsHalfFrameAndSwitchesFamily() {
        let big = frameFromPayload((0..<600).map { UInt8($0 & 0xff) }, type: 47, seq: 18, cmd: 0)
        let small = frameFromPayload([1, 2, 3], type: 48, seq: 0, cmd: 0)
        let bank = ReassemblerBank(family: .whoop4)
        XCTAssertTrue(bank.feed(Array(big[0..<200]), channel: "data").isEmpty)   // link drops mid-frame
        bank.reset()
        XCTAssertEqual(bank.feed(small, channel: "data"), [small],
                       "the stale half frame must not swallow the head of the next connection")

        // Family switch: a 5/MG frame is only recognised after reset(family: .whoop5).
        let f5 = frame5(total: 40, type: 48, version: 0)
        bank.reset(family: .whoop5)
        XCTAssertEqual(bank.feed(f5, channel: "x"), [f5])
    }
}

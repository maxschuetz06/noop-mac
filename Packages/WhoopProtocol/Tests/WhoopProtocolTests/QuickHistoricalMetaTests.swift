import XCTest
@testable import WhoopProtocol

/// `quickHistoricalMetaCandidate` is a pure pre-filter for the Backfiller's per-frame META
/// classification. The contract: whenever it returns `false`, `classifyHistoricalMeta(parseFrame(f))`
/// MUST be `.other` (so skipping the full parse is behaviour-preserving). `true` is only "maybe".
final class QuickHistoricalMetaTests: XCTestCase {

    private func hexToBytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    private func fixtureFrames(_ name: String) throws -> [[UInt8]] {
        struct Entry: Decodable { let hex: String }
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url)).map { hexToBytes($0.hex) }
    }

    /// Mutations that exercise the envelope guards: truncations, bad SOF, corrupted CRC trailer.
    private func variants(of f: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = [f]
        for n in [0, 1, 3, 4, 7, 8, 9, 11, 12, 13] where n < f.count { out.append(Array(f.prefix(n))) }
        if !f.isEmpty { var b = f; b[0] = 0x55; out.append(b) }
        if f.count > 2 { var c = f; c[c.count - 1] ^= 0xFF; out.append(c) }
        return out
    }

    /// A broad corpus: golden fixtures, synthetic frames for EVERY packet-type byte in both
    /// envelopes, METADATA frames with and without valid CRC, real WHOOP 5 captures, random bytes.
    private func corpus() throws -> [[UInt8]] {
        var frames: [[UInt8]] = []
        frames += try fixtureFrames("frames")
        frames += try fixtureFrames("historical_frames")
        // WHOOP 4 envelope, every type byte.
        for t in 0...255 {
            for cmd in [UInt8(0), 1, 2, 3, 9] {
                let payload: [UInt8] = cmd == 2 ? le32(1_700_000_000) + [0, 0] + le32(7) + le32(99) : [1, 2, 3]
                frames.append(frameFromPayload(payload, type: UInt8(t), seq: 0, cmd: cmd))
            }
        }
        // WHOOP 5 puffin envelope, every type byte.
        for t in 0...255 {
            for cmd in [UInt8(1), 2, 3] {
                frames.append(puffinCommandFrame(cmd: cmd, seq: 0, payload: le32(1_700_000_000) + [0, 0] + le32(7) + le32(99),
                                                 type: UInt8(t)))
            }
        }
        // Real WHOOP 5 type-47 capture + benchmark-style records.
        frames += HistoricalDecodeBenchmarkTests.makeFrames(count: 16, baseUnix: 1_780_916_150)
        // Deterministic pseudo-random garbage, some with a valid-looking SOF.
        var x: UInt64 = 0x1234_5678_9ABC_DEF0
        func next() -> UInt8 { x = x &* 6364136223846793005 &+ 1442695040888963407; return UInt8(truncatingIfNeeded: x >> 33) }
        for i in 0..<400 {
            var f = (0..<Int(next() % 64)).map { _ in next() }
            if i % 2 == 0, !f.isEmpty { f[0] = 0xAA }
            frames.append(f)
        }
        return frames.flatMap(variants(of:))
    }

    func testFalseImpliesOtherForBothFamilies() throws {
        let frames = try corpus()
        XCTAssertGreaterThan(frames.count, 2_000)
        var rejectedByQuick = 0, candidates = 0, nonOtherSeen = 0
        for family in [DeviceFamily.whoop4, .whoop5] {
            for f in frames {
                let quick = quickHistoricalMetaCandidate(f, family: family)
                let full = classifyHistoricalMeta(parseFrame(f, family: family))
                if quick {
                    candidates += 1
                } else {
                    rejectedByQuick += 1
                    XCTAssertEqual(full, .other, "quick=false but full classify=\(full) for \(family) frame \(f.map { String($0, radix: 16) })")
                }
                if full != .other {
                    nonOtherSeen += 1
                    XCTAssertTrue(quick, "quick check must pass every frame the full classifier acts on (\(family))")
                }
            }
        }
        // Non-vacuous: the corpus has plenty of both outcomes, including real START/END/COMPLETE.
        XCTAssertGreaterThan(rejectedByQuick, 1_000)
        XCTAssertGreaterThan(candidates, 10)
        XCTAssertGreaterThan(nonOtherSeen, 0)
    }

    func testMetadataTypeBytesPerFamily() {
        // WHOOP 4: only METADATA (49). Puffin metadata (56) is a WHOOP 5 alias only.
        let m4 = frameFromPayload([], type: 49, seq: 0, cmd: 1)
        XCTAssertTrue(quickHistoricalMetaCandidate(m4, family: .whoop4))
        XCTAssertFalse(quickHistoricalMetaCandidate(frameFromPayload([], type: 56, seq: 0, cmd: 1), family: .whoop4))
        XCTAssertFalse(quickHistoricalMetaCandidate(frameFromPayload([], type: 47, seq: 0, cmd: 1), family: .whoop4))

        // WHOOP 5: inner record at offset 8; 49 and its puffin alias 56 are candidates.
        let payload = le32(1_700_000_000) + [0, 0] + le32(7) + le32(99)
        let m5 = puffinCommandFrame(cmd: 2, seq: 0, payload: payload, type: 49)
        let p5 = puffinCommandFrame(cmd: 2, seq: 0, payload: payload, type: 56)
        XCTAssertTrue(quickHistoricalMetaCandidate(m5, family: .whoop5))
        XCTAssertTrue(quickHistoricalMetaCandidate(p5, family: .whoop5))
        XCTAssertEqual(parseFrame(p5, family: .whoop5).typeName, "METADATA")
        XCTAssertFalse(quickHistoricalMetaCandidate(puffinCommandFrame(cmd: 2, seq: 0, payload: payload, type: 47), family: .whoop5))
        XCTAssertFalse(quickHistoricalMetaCandidate(puffinCommandFrame(cmd: 2, seq: 0, payload: payload, type: 50), family: .whoop5))
        // A WHOOP 5 data record is rejected without a parse.
        let hist = HistoricalDecodeBenchmarkTests.makeFrames(count: 1, baseUnix: 1_780_916_150)[0]
        XCTAssertFalse(quickHistoricalMetaCandidate(hist, family: .whoop5))
    }

    func testCandidateStillGoesThroughCRCGate() {
        // quick=true is only "maybe": a METADATA frame with a corrupted CRC32 is a candidate, and the full
        // classifier (unchanged) must still refuse it — the integrity gate was NOT moved into the filter.
        var bad = frameFromPayload([], type: 49, seq: 0, cmd: 3)
        bad[bad.count - 1] ^= 0xFF
        XCTAssertTrue(quickHistoricalMetaCandidate(bad, family: .whoop4))
        XCTAssertEqual(classifyHistoricalMeta(parseFrame(bad, family: .whoop4)), .other)
    }

    func testDegenerateFramesNeverCandidates() {
        for family in [DeviceFamily.whoop4, .whoop5] {
            XCTAssertFalse(quickHistoricalMetaCandidate([], family: family))
            XCTAssertFalse(quickHistoricalMetaCandidate([0xAA], family: family))
            XCTAssertFalse(quickHistoricalMetaCandidate([UInt8](repeating: 49, count: 20), family: family), "no SOF")
        }
    }
}

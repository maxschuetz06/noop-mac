import XCTest
@testable import WhoopProtocol

/// The hot-path hex encoder must stay byte-identical to the `String(format: "%02x")` algorithm it
/// replaced — `ParsedFrame.rawHex` / `DecodedField.raw` are persisted in strap logs and golden fixtures.
final class HexEncodeParityTests: XCTestCase {

    /// The original (slow) algorithm, kept here as the oracle.
    private func oldHex<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    func testEdgeCases() {
        XCTAssertEqual(hexEncode([UInt8]()), "")
        XCTAssertEqual(hexEncode([UInt8]()), oldHex([UInt8]()))
        XCTAssertEqual(hexEncode([0x00] as [UInt8]), "00")
        XCTAssertEqual(hexEncode([0xFF] as [UInt8]), "ff")
        XCTAssertEqual(hexEncode([0x0A] as [UInt8]), "0a")
        XCTAssertEqual(hexEncode([0xA0] as [UInt8]), "a0")
        XCTAssertEqual(hexEncode([0x00, 0xFF, 0x00, 0xFF] as [UInt8]), "00ff00ff")
        for b in 0...255 {
            XCTAssertEqual(hexEncode([UInt8(b)]), oldHex([UInt8(b)]), "byte \(b)")
        }
        // Every byte value in one buffer, and a long (> small-string) buffer.
        let all = (0...255).map { UInt8($0) }
        XCTAssertEqual(hexEncode(all), oldHex(all))
        XCTAssertEqual(hexEncode(all).count, 512)
    }

    func testRandomInputsMatchOldAlgorithm() {
        var rng = SplitMix64(state: 0xC0FFEE)
        for _ in 0..<2_000 {
            let n = Int(rng.next() % 300)
            let bytes = (0..<n).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            XCTAssertEqual(hexEncode(bytes), oldHex(bytes), "len \(n)")
        }
    }

    func testArraySliceWithNonZeroStartIndex() {
        var rng = SplitMix64(state: 42)
        let bytes = (0..<64).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        for start in [0, 1, 7, 30, 63] {
            for end in [start, start + 1, min(64, start + 17), 64] where end >= start && end <= 64 {
                let slice = bytes[start..<end]
                XCTAssertEqual(hexEncode(slice), oldHex(slice), "slice \(start)..<\(end)")
            }
        }
    }

    func testParsedFrameRawHexAndFieldRawMatchOldAlgorithm() {
        let whoop5 = HistoricalDecodeBenchmarkTests.makeFrames(count: 8, baseUnix: 1_780_916_150)
        for f in whoop5 {
            let p = parseFrame(f, family: .whoop5)
            XCTAssertEqual(p.rawHex, oldHex(f))
            for fld in p.fields where fld.off <= f.count {
                let end = min(fld.off + fld.len, f.count)
                XCTAssertEqual(fld.raw, oldHex(f[max(0, fld.off)..<max(fld.off, end)]), fld.name)
            }
        }
        // WHOOP 4 path + invalid/fragment path.
        let w4 = frameFromPayload([0x01, 0x02, 0xFF, 0x00], type: 49, seq: 0, cmd: 1)
        let p4 = parseFrame(w4, family: .whoop4)
        XCTAssertEqual(p4.rawHex, oldHex(w4))
        let frag: [UInt8] = [0x00, 0x01, 0xFE]
        XCTAssertEqual(parseFrame(frag, family: .whoop4).rawHex, oldHex(frag))
        XCTAssertEqual(parseFrame(frag, family: .whoop5).rawHex, oldHex(frag))
    }
}

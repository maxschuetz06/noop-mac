import XCTest
@testable import WhoopProtocol

/// v18 `@81` status byte → `Streams.strapState` (raw decoder values, no invented semantics).
final class StrapStateStreamTests: XCTestCase {
    /// Real captured WHOOP 5 v18 frame (unix 1780916150); same fixture as `Whoop5HistoricalTests`.
    private let historicalHex =
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

    /// CRC-valid v18 record with a given unix and status byte @81.
    private func frame(unixOffset: Int, status: UInt8) -> [UInt8] {
        var f = bytes(historicalHex)
        let payloadEnd = (Int(f[2]) | (Int(f[3]) << 8)) + 8 - 4
        let ts = UInt32(baseUnix + unixOffset)
        for k in 0..<4 { f[15 + k] = UInt8((ts >> (8 * UInt32(k))) & 0xFF) }
        f[81] = status
        let c = crc32(Array(f[8..<payloadEnd]))
        for k in 0..<4 { f[payloadEnd + k] = UInt8((c >> (8 * UInt32(k))) & 0xFF) }
        return f
    }

    private func extract(_ frames: [[UInt8]]) -> Streams {
        let parsed = frames.map { parseFrame($0, family: .whoop5) }
        return extractHistoricalStreams(parsed, deviceClockRef: baseUnix, wallClockRef: baseUnix)
    }

    func testStatusByteDecodesToRawOnWristAndSleepState() {
        // 0x00 → (onwrist 0, state 0) · 0x2D = 0b00_10_11_01 → onwrist 1, state 2 · 0x33 → onwrist 3, state 3.
        let s = extract([frame(unixOffset: 0, status: 0x00),
                         frame(unixOffset: 1, status: 0x2D),
                         frame(unixOffset: 2, status: 0x33)])
        XCTAssertEqual(s.strapState, [
            StrapStateSample(ts: baseUnix, onWrist: 0, sleepState: 0),
            StrapStateSample(ts: baseUnix + 1, onWrist: 1, sleepState: 2),
            StrapStateSample(ts: baseUnix + 2, onWrist: 3, sleepState: 3),
        ])
        // Matches the decoder fields one-to-one.
        let p = parseFrame(frame(unixOffset: 1, status: 0x2D), family: .whoop5).parsed
        XCTAssertEqual(p["onwrist"]?.intValue, 1)
        XCTAssertEqual(p["sleep_state"]?.intValue, 2)
    }

    func testCrcBrokenRecordProducesNoState() {
        // A CRC-broken record is skipped entirely, so it yields no state.
        var broken = frame(unixOffset: 0, status: 0x2D)
        broken[30] ^= 0xFF   // payload corruption → CRC failure → record skipped
        XCTAssertTrue(extract([broken]).strapState.isEmpty)
        XCTAssertTrue(Streams().strapState.isEmpty)
    }

    func testStrapStateDoesNotChangeIsEmptyAndRoundTrips() throws {
        var s = Streams()
        s.strapState = [StrapStateSample(ts: 5, onWrist: 1, sleepState: 2)]
        XCTAssertTrue(s.isEmpty, "isEmpty stays the 'no biometrics decoded' diagnostic")
        let round = try JSONDecoder().decode(Streams.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(round.strapState, s.strapState)
        // Older fixtures without the key still decode.
        let old = try JSONDecoder().decode(Streams.self, from: Data(#"{"hr":[]}"#.utf8))
        XCTAssertTrue(old.strapState.isEmpty)
    }
}

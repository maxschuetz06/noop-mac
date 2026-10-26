import CryptoKit
import Foundation
import XCTest
@testable import WhoopProtocol

/// Tripwire for `DecoderVersion`: a fingerprint of what a fixed corpus of real historical frames decodes
/// to on the archive-replay path. If this fails because decoding intentionally changed, bump
/// `DecoderVersion.current` and record the new fingerprint here in the same change, so installs replay
/// their archive of undecodable frames through the new decoder.
final class DecoderVersionTests: XCTestCase {
    private static let expected = (version: 1, fingerprint: "a417dbac11ab070a42d5adb51c557142336b2c63b86b07863cf36c993c577266")

    /// Real WHOOP 4.0 v25 records (84 B, 1 Hz).
    private static let whoop4V25 = [
        "aa50000c2f190013390000140d2b6a4075010068a2010032fdbcfd98fdd3fdccfd47ffb00366064f073e06c103d3016cffa2fc87fa2ffae5fdbe03140675060c0510012dff1bfec0018f3c500500010068dc8f44",
        "aa50000c2f190014390000150d2b6a487001003ab301008dfd6afdaffda9fdaffd68fddbfb0dfc09fd77fe89fe62febffec9fe91ff0bff81ff5fff3e00d600790078ff3dff4bff801d553c5005010000d7c016b3",
        "aa50000c2f190015390000160d2b6a586b01006d8f0100a3ff94ffc4ffbcffbeff22004a009400cb0048005d006b004400d700130115013301f20088001d0031ffd9fe5eff75ff0048933c50050001008bdf2c2c",
    ]
    /// A real WHOOP 5 type-47 v18 record.
    private static let whoop5V18 = [
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817",
    ]

    private struct FrameEntry: Decodable { let hex: String }

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    /// Decode like the app's archive replay does: identity clock reference, no session bounds.
    private func replayDecode(_ hex: [String], family: DeviceFamily) -> Streams {
        extractHistoricalStreams(hex.map { parseFrame(bytes($0), family: family) }, deviceClockRef: 0, wallClockRef: 0)
    }

    func testDecodedCorpusMatchesTheFingerprintRecordedForThisDecoderVersion() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "historical_frames", withExtension: "json"))
        let whoop4Legacy = try JSONDecoder().decode([FrameEntry].self, from: Data(contentsOf: url)).map(\.hex)
        let decoded = [
            replayDecode(whoop4Legacy, family: .whoop4),
            replayDecode(Self.whoop4V25, family: .whoop4),
            replayDecode(Self.whoop5V18, family: .whoop5),
        ]
        XCTAssertFalse(decoded.contains { $0.isEmpty }, "every fixture should decode to rows")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(decoded)).map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(DecoderVersion.current, Self.expected.version,
                       "record the fingerprint for the new DecoderVersion below")
        XCTAssertEqual(digest, Self.expected.fingerprint,
                       "historical decoding changed: bump DecoderVersion.current and record this fingerprint")
    }
}

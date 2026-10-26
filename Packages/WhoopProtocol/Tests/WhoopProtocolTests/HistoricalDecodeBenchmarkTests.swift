import XCTest
@testable import WhoopProtocol

/// Micro-benchmark for the WHOOP 5 historical decode hot path (strap history sync).
///
/// Prints wall-clock per 1000 valid-CRC v18 HISTORICAL_DATA frames for the three stages the Backfiller
/// runs on every frame: the per-frame META classification in `ingest`, and the per-chunk
/// parse + extract + rejection pass in `finishChunk`. Informational (no timing assertions — CI hosts
/// vary), but it also asserts the decode result so the benchmark can't silently measure a no-op.
final class HistoricalDecodeBenchmarkTests: XCTestCase {

    private static let baseHex =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    static func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    /// `count` distinct, CRC-valid WHOOP 5 v18 records with consecutive unix timestamps.
    static func makeFrames(count: Int, baseUnix: Int) -> [[UInt8]] {
        let template = bytes(baseHex)
        let declared = Int(template[2]) | (Int(template[3]) << 8)
        let payloadEnd = declared + 8 - 4
        return (0..<count).map { i in
            var f = template
            let ts = UInt32(baseUnix + i)
            f[15] = UInt8(ts & 0xFF); f[16] = UInt8((ts >> 8) & 0xFF)
            f[17] = UInt8((ts >> 16) & 0xFF); f[18] = UInt8((ts >> 24) & 0xFF)
            let c = crc32(Array(f[8..<payloadEnd]))
            f[payloadEnd] = UInt8(c & 0xFF); f[payloadEnd + 1] = UInt8((c >> 8) & 0xFF)
            f[payloadEnd + 2] = UInt8((c >> 16) & 0xFF); f[payloadEnd + 3] = UInt8((c >> 24) & 0xFF)
            return f
        }
    }

    private func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

    private func time(rounds: Int = 5, _ body: () -> Void) -> Double {
        var samples: [Double] = []
        for _ in 0..<rounds {
            let t0 = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        return median(samples)
    }

    func testBenchmarkWhoop5HistoricalDecodePer1000Frames() {
        let baseUnix = 1_780_916_150
        let frames = Self.makeFrames(count: 1000, baseUnix: baseUnix)
        var sink = 0

        // 1) Legacy ingest path: full parse of every frame just to classify META.
        let classifyMs = time {
            for f in frames {
                if classifyHistoricalMeta(parseFrame(f, family: .whoop5)) != .other { sink += 1 }
            }
        }
        // 1b) New ingest path: cheap packet-type pre-filter, full parse only for META candidates.
        let quickMs = time {
            for f in frames where quickHistoricalMetaCandidate(f, family: .whoop5) {
                if classifyHistoricalMeta(parseFrame(f, family: .whoop5)) != .other { sink += 1 }
            }
        }
        // 2) Chunk decode: parse all + extract + reject-classify (what finishChunk does).
        var decodedHR = 0
        let chunkMs = time {
            let parsed = frames.map { parseFrame($0, family: .whoop5) }
            let streams = extractHistoricalStreams(parsed, deviceClockRef: baseUnix, wallClockRef: baseUnix + 2000,
                                                   sessionOldestUnix: nil, sessionNewestUnix: nil)
            let rejected = rejectedHistoricalRecords(frames, family: .whoop5)
            decodedHR = streams.hr.count
            sink += rejected.count
        }
        XCTAssertEqual(sink, 0, "valid v18 records are neither META nor rejected")
        XCTAssertEqual(decodedHR, 1000, "every benchmark frame must decode one HR sample")

        print("BENCH[1000 WHOOP5 v18 frames] ingestClassifyFullParse=\(String(format: "%.1f", classifyMs)) ms  ingestQuickFilter=\(String(format: "%.2f", quickMs)) ms  chunkDecode(parse+extract+reject)=\(String(format: "%.1f", chunkMs)) ms")
    }
}

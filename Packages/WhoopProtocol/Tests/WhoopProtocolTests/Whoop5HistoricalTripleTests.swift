import XCTest
@testable import WhoopProtocol

/// WHOOP 5.0 firmware 50.42.x offers every recorded second as a **v18 + v20 + v21 triple**. The v18 record
/// still carries HR, R-R, gravity, skin temperature, the step counter and the wear/sleep state at the
/// absolute offsets documented on `decodeWhoop5Historical`; v20/v21 are raw bulk-sensor records (sample
/// channels, no HR/gravity). These tests use frames CONSTRUCTED from that layout (no captured data): they pin
/// (a) that the v18 record of a triple decodes into every persisted stream and (b) that CRC-valid v20/v21
/// records are NOT classified as undecodable (they used to be, which flooded the reject archive and logged
/// "doesn't decode yet — sleep can't be computed" although v18 supplied all the motion data).
final class Whoop5HistoricalTripleTests: XCTestCase {

    // MARK: - synthetic frame builders

    /// Valid WHOOP 5.0 type-47 envelope (CRC16 header + CRC32 trailer) of `total` bytes; `build` fills the body.
    private func makeFrame(total: Int, version: UInt8, _ build: (inout [UInt8]) -> Void) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: total)
        f[0] = 0xAA; f[1] = 0x01
        let declared = total - 8
        f[2] = UInt8(declared & 0xff); f[3] = UInt8((declared >> 8) & 0xff)
        f[4] = 0x01; f[5] = 0x00
        f[8] = 0x2f; f[9] = version
        build(&f)
        let h = crc16Modbus(Array(f[0..<6]))
        f[6] = UInt8(h & 0xff); f[7] = UInt8((h >> 8) & 0xff)
        let end = total - 4
        let c = crc32(Array(f[8..<end]))
        for k in 0..<4 { f[end + k] = UInt8((c >> (8 * UInt32(k))) & 0xff) }
        return f
    }

    private func putU16(_ f: inout [UInt8], _ off: Int, _ v: UInt16) {
        f[off] = UInt8(v & 0xff); f[off + 1] = UInt8(v >> 8)
    }
    private func putU32(_ f: inout [UInt8], _ off: Int, _ v: UInt32) {
        for k in 0..<4 { f[off + k] = UInt8((v >> (8 * UInt32(k))) & 0xff) }
    }
    private func putF32(_ f: inout [UInt8], _ off: Int, _ v: Float) { putU32(&f, off, v.bitPattern) }

    /// Synthetic v18 (124 B) record at second `unix`: HR 64, two R-R (940 / 950 ms → 63.5 bpm, consistent with
    /// HR), gravity (0.10, -0.20, 0.97) → |g| ≈ 1, step counter `steps`, skin 32.14 °C (raw 3214), state
    /// byte 0x21 → sleep_state 2 / onwrist 1.
    private func v18(unix: Int, index: Int, steps: Int) -> [UInt8] {
        makeFrame(total: 124, version: 18) { f in
            putU32(&f, 11, UInt32(index))
            putU32(&f, 15, UInt32(unix))
            f[22] = 64
            f[23] = 2
            putU16(&f, 24, 940); putU16(&f, 26, 950)
            putU16(&f, 36, 64 * 256)
            putF32(&f, 45, 0.10); putF32(&f, 49, -0.20); putF32(&f, 53, 0.97)
            putU16(&f, 57, UInt16(steps & 0xffff))
            f[59] = 40
            f[63] = 0
            putU16(&f, 69, 321); putU16(&f, 71, 322)
            putU16(&f, 73, 3214)
            f[81] = 0x21
        }
    }

    /// v21 (1244 B): three 100-sample i16 channels at @28/@228/@428.
    private func v21(unix: Int, index: Int) -> [UInt8] {
        makeFrame(total: 1244, version: 21) { f in
            f[10] = 0x80
            putU32(&f, 11, UInt32(index)); putU32(&f, 15, UInt32(unix))
            for ch in 0..<3 {
                for i in 0..<100 { putU16(&f, 28 + ch * 200 + i * 2, UInt16(1800 + ch * 100 + i % 7)) }
            }
        }
    }

    /// v20 (2140 B): block 0 active (presence byte + two 50-sample i32 channels), the rest empty.
    private func v20(unix: Int, index: Int, activeBlock: Bool = true) -> [UInt8] {
        makeFrame(total: 2140, version: 20) { f in
            f[10] = 0x81
            putU32(&f, 11, UInt32(index)); putU32(&f, 15, UInt32(unix))
            guard activeBlock else { return }
            f[0x1a] = 0x19
            for i in 0..<50 { putU32(&f, 0x2f + i * 4, UInt32(100_000 + i)) }
            for i in 0..<50 { putU32(&f, 0xf7 + i * 4, UInt32(200_000 + i)) }
        }
    }

    private var base: Int { Int(Date().timeIntervalSince1970) - 7200 }

    // MARK: - v18 inside a triple still decodes every stream

    func testV18OfATripleDecodesIntoEveryPersistedStream() {
        let t = base
        let triple = [v18(unix: t, index: 1000, steps: 18_157), v20(unix: t, index: 1000), v21(unix: t, index: 1000)]
        let parsed = triple.map { parseFrame($0, family: .whoop5) }
        XCTAssertEqual(parsed.map { $0.parsed["hist_version"]?.intValue }, [18, 20, 21])
        XCTAssertTrue(parsed.allSatisfy { $0.ok && $0.crcOK == true })

        let s = extractHistoricalStreams(parsed, deviceClockRef: t, wallClockRef: t)
        XCTAssertEqual(s.droppedImplausible, 0)
        XCTAssertEqual(s.hr, [HRSample(ts: t, bpm: 64)])
        XCTAssertEqual(s.rr.map(\.rrMs), [940, 950])
        XCTAssertEqual(s.rr.map(\.ts), [t, t])
        XCTAssertEqual(s.gravity.count, 1)
        let g = s.gravity[0]
        XCTAssertEqual((g.x * g.x + g.y * g.y + g.z * g.z).squareRoot(), 1.0, accuracy: 0.01)
        XCTAssertEqual(s.skinTemp, [SkinTempSample(ts: t, raw: 3214)])
        XCTAssertEqual(s.steps, [StepSample(ts: t, counter: 18_157, activityClass: 0)])
        XCTAssertEqual(s.strapState, [StrapStateSample(ts: t, onWrist: 1, sleepState: 2)])
        // v20/v21 add no HR/R-R/gravity rows of their own: exactly one row per stream from the one v18.
        XCTAssertEqual(s.hr.count, 1); XCTAssertEqual(s.gravity.count, 1)
    }

    func testSeventeenSecondChunkPersistsSeventeenSecondsOfEveryStream() {
        // Mirrors the field chunk census (47/v18 ×17, 47/v20 ×17, 47/v21 ×17).
        let t = base
        var frames: [[UInt8]] = []
        for i in 0..<17 {
            frames += [v18(unix: t + i, index: 5000 + i, steps: 100 + i),
                       v20(unix: t + i, index: 5000 + i), v21(unix: t + i, index: 5000 + i)]
        }
        let s = extractHistoricalStreams(frames.map { parseFrame($0, family: .whoop5) },
                                         deviceClockRef: t, wallClockRef: t)
        XCTAssertEqual(s.hr.map(\.ts), (0..<17).map { t + $0 }, "unix +1 s per record, none dropped")
        XCTAssertEqual(s.gravity.count, 17)
        XCTAssertEqual(s.skinTemp.count, 17)
        XCTAssertEqual(s.steps.map(\.counter), (0..<17).map { 100 + $0 })
        XCTAssertEqual(s.strapState.count, 17)
        XCTAssertEqual(s.rr.count, 34)
        XCTAssertTrue(rejectedHistoricalRecords(frames, family: .whoop5).isEmpty,
                      "a healthy triple chunk has no undecodable records")
    }

    // MARK: - v20/v21 classification

    func testCrcValidV20V21WithChannelsAreNotRejected() {
        let t = base
        let a = v21(unix: t, index: 1), b = v20(unix: t, index: 1)
        XCTAssertTrue(isRawSensorChannelRecord(parseFrame(a, family: .whoop5)))
        XCTAssertTrue(isRawSensorChannelRecord(parseFrame(b, family: .whoop5)))
        XCTAssertTrue(rejectedHistoricalRecords([a, b], family: .whoop5).isEmpty)
    }

    func testV20WithoutAnyActiveChannelBlockIsStillRejected() {
        let empty = v20(unix: base, index: 1, activeBlock: false)
        XCTAssertFalse(isRawSensorChannelRecord(parseFrame(empty, family: .whoop5)))
        XCTAssertEqual(rejectedHistoricalRecords([empty], family: .whoop5), [empty])
    }

    func testCorruptedV21IsStillRejected() {
        var bad = v21(unix: base, index: 1)
        bad[300] ^= 0xFF   // payload bit-flip: header CRC16 still valid, CRC32 not
        XCTAssertFalse(isRawSensorChannelRecord(parseFrame(bad, family: .whoop5)))
        XCTAssertEqual(rejectedHistoricalRecords([bad], family: .whoop5), [bad])
    }

    /// A frame shorter than its declared length never gets its CRC32 checked (`crcOK == nil`, not `false`).
    /// It is not decoded data, so it must NOT count as a raw-channel record and stays in the reject archive.
    func testTruncatedV20V21IsNotARawChannelRecordAndStaysRejected() {
        for full in [v21(unix: base, index: 1), v20(unix: base, index: 1)] {
            let cut = Array(full.dropLast(12))
            let p = parseFrame(cut, family: .whoop5)
            XCTAssertNil(p.crcOK, "truncated frame: CRC unknown, not 'ok'")
            XCTAssertFalse(isRawSensorChannelRecord(p))
            XCTAssertEqual(rejectedHistoricalRecords([cut], family: .whoop5), [cut])
        }
    }

    func testRawChannelPredicateIgnoresOtherLayouts() {
        // v18 (decoded via HR/gravity), v26 and an unknown version are not "raw sensor channel" records.
        for f in [v18(unix: base, index: 1, steps: 1),
                  makeFrame(total: 88, version: 26) { putU32(&$0, 15, UInt32(self.base)) },
                  makeFrame(total: 100, version: 99) { putU32(&$0, 15, UInt32(self.base)) }] {
            XCTAssertFalse(isRawSensorChannelRecord(parseFrame(f, family: .whoop5)))
        }
    }

    func testV99UnknownLayoutStaysRejected() {
        let odd = makeFrame(total: 100, version: 99) { putU32(&$0, 15, UInt32(self.base)) }
        XCTAssertEqual(rejectedHistoricalRecords([odd], family: .whoop5), [odd])
    }
}

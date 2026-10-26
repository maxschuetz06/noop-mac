import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Unit tests for V1's per-epoch HRV hygiene and the no-raw-resp deep recipe. SYNTHETIC data only.
final class SleepStagerV1HRVCleaningTests: XCTestCase {

    /// 1000 ms ± 30 ms zig-zag → every successive difference is exactly 60 ms → RMSSD = 60.
    private func zigzag(_ n: Int) -> [Double] { (0..<n).map { 1000 + ($0 % 2 == 0 ? 30.0 : -30.0) } }

    // MARK: - cleanWindowHRV

    func testCleanWindowHRVIgnoresInRangeArtifacts() {
        var rr = zigzag(300)
        // Missed / extra beats that are INSIDE [300, 2000] ms, so the range filter alone keeps them.
        for i in stride(from: 10, to: 300, by: 11) { rr[i] = (i / 11) % 2 == 0 ? 1550 : 560 }
        let rangeOnly = HRVAnalyzer.rmssdRaw(HRVAnalyzer.rangeFilter(rr))!
        XCTAssertGreaterThan(rangeOnly, 150, "sanity: range-only RMSSD is badly inflated by these artifacts")

        let (rmssd, sdnn) = SleepStager.cleanWindowHRV(rr)
        XCTAssertEqual(rmssd, 60, accuracy: 3.0, "cleaned RMSSD must recover the underlying 60 ms")
        XCTAssertEqual(sdnn, 30, accuracy: 3.0)
    }

    func testCleanWindowHRVMatchesPlainRMSSDOnCleanData() {
        let rr = zigzag(200)
        let (rmssd, _) = SleepStager.cleanWindowHRV(rr)
        XCTAssertEqual(rmssd, HRVAnalyzer.rmssdRaw(rr)!, accuracy: 1e-9)
    }

    func testCleanWindowHRVIsNaNWithTooFewCleanPairs() {
        XCTAssertTrue(SleepStager.cleanWindowHRV(zigzag(20)).rmssd.isNaN, "too few beats")
        // Plenty of beats, but nearly all are artifacts → no trustworthy pairs survive.
        let junk: [Double] = (0..<200).map { $0 % 3 == 0 ? 1000 : ($0 % 3 == 1 ? 520 : 1700) }
        XCTAssertTrue(SleepStager.cleanWindowHRV(junk).rmssd.isNaN, "an unusable window must read as missing, not high")
    }

    func testRemovedBeatNeverCreatesADoubleLengthDifference() {
        // Smooth drift of exactly +10 ms/beat with one corrupted beat. Dropping-and-concatenating would
        // pair beat 29 with beat 31 (Δ = 20); pairing only intact neighbours keeps every Δ at 10.
        var rr: [Double] = (0..<60).map { 1000 + 10.0 * Double($0) }
        rr[30] = 1900
        XCTAssertEqual(SleepStager.cleanWindowHRV(rr).rmssd, 10.0, accuracy: 1e-9)
    }

    func testBeatValidityFlagsOutOfRangeAndEctopic() {
        var rr = zigzag(40)
        rr[5] = 250      // below range
        rr[15] = 2400    // above range
        rr[25] = 1500    // in range but ectopic
        let v = SleepStager.beatValidity(rr).valid
        XCTAssertFalse(v[5]); XCTAssertFalse(v[15]); XCTAssertFalse(v[25])
        XCTAssertEqual(v.filter { $0 }.count, 37)
    }

    func testRepairedRRReplacesArtifactsByLocalMedianAndKeepsTheRest() {
        var rr = zigzag(40)
        rr[20] = 1700
        let fixed = SleepStager.repairedRR(rr)
        XCTAssertEqual(fixed.count, rr.count, "repair keeps the beat clock — nothing is dropped")
        XCTAssertLessThan(abs(fixed[20] - 1000), 40, "artifact replaced by ≈ the local median")
        for i in rr.indices where i != 20 { XCTAssertEqual(fixed[i], rr[i]) }
    }

    // MARK: - HR relative to the local baseline

    private func feat(_ i: Int, hr: Double, clock: Double = 0.5) -> SleepStager.EpochFeatures {
        SleepStager.EpochFeatures(index: i, midTs: Double(i) * 30, count: 0, moveFrac: 0, ckSleep: true,
                                  hr: hr, hrVar: 0, rmssd: 60, sdnn: 0, respRate: 14, rrv: 0.2, clock: clock)
    }

    func testHRRelativeToLocalBaselineRemovesDriftButKeepsADip() {
        // HR slides 70 → 50 over the night; epochs 100…129 sit a further 4 bpm below the trend.
        let n = 600
        let f = (0..<n).map { i -> SleepStager.EpochFeatures in
            let trend = 70.0 - 20.0 * Double(i) / Double(n)
            return feat(i, hr: trend - ((100..<130).contains(i) ? 4.0 : 0.0))
        }
        let rel = SleepStager.relativeToLocalBaseline(f)
        XCTAssertEqual(rel[400].hr, 0, accuracy: 1.0, "plain drift must cancel out")
        XCTAssertLessThan(rel[115].hr, -2.5, "a genuine local dip must stay clearly negative")
    }

    func testRMSSDIsRankedAsRatioToLocalBaseline() {
        // RMSSD climbs 40 → 80 ms toward morning; epochs 100…129 are 30 % above their surroundings.
        let n = 600
        let f = (0..<n).map { i -> SleepStager.EpochFeatures in
            let trend = 40.0 + 40.0 * Double(i) / Double(n)
            let r = trend * ((100..<130).contains(i) ? 1.3 : 1.0)
            return SleepStager.EpochFeatures(index: i, midTs: Double(i) * 30, count: 0, moveFrac: 0, ckSleep: true,
                                             hr: 55, hrVar: 0, rmssd: r, sdnn: 0, respRate: 14, rrv: 0.2, clock: 0.5)
        }
        let rel = SleepStager.relativeToLocalBaseline(f)
        XCTAssertEqual(rel[400].rmssd, 1.0, accuracy: 0.05, "a plain upward drift must cancel out")
        XCTAssertGreaterThan(rel[115].rmssd, 1.2, "a genuine local HRV rise must stay clearly above 1")
        XCTAssertLessThan(rel[550].rmssd, rel[115].rmssd, "late-night high HRV must not outrank the early block")
    }

    func testHRRelativeKeepsMissingHRMissing() {
        let f = [feat(0, hr: .nan), feat(1, hr: 55), feat(2, hr: 56)]
        let rel = SleepStager.relativeToLocalBaseline(f)
        XCTAssertTrue(rel[0].hr.isNaN)
        XCTAssertTrue(rel[1].hr.isFinite)
    }

    func testRelativeBaselineIsNaNWhenWindowHasTooFewFiniteValues() {
        // A lone epoch (and an epoch whose only finite neighbour is NaN) has no context: it must come back as
        // NaN, never as an absolute bpm / ms value inside a distribution of deviations and ratios.
        let lone = SleepStager.relativeToLocalBaseline([feat(0, hr: 55)])
        XCTAssertTrue(lone[0].hr.isNaN, "single-epoch HR window → NaN, not 55")
        XCTAssertTrue(lone[0].rmssd.isNaN, "single-epoch RMSSD window → NaN, not 60")
        let sparse = SleepStager.relativeToLocalBaseline([feat(0, hr: .nan), feat(1, hr: 55), feat(2, hr: .nan)])
        XCTAssertTrue(sparse[1].hr.isNaN)
    }

    // MARK: - Wake / REM rules never see the baseline-relative signals

    /// Slow HR drift (75 → 50 bpm) with periodic movement bursts, HR variability and irregular breathing:
    /// the night-wide raw HR percentiles and the local-relative ones disagree strongly here.
    private func driftingFeatures(_ n: Int = 700) -> [SleepStager.EpochFeatures] {
        (0..<n).map { i -> SleepStager.EpochFeatures in
            let hr = 75.0 - 25.0 * Double(i) / Double(n) + 4.0 * sin(Double(i) / 9.0)
            let moving = i % 17 < 2
            return SleepStager.EpochFeatures(index: i, midTs: Double(i) * 30, count: 0,
                                             moveFrac: moving ? 0.6 : 0.02, ckSleep: true, hr: hr,
                                             hrVar: 1 + Double((i * 7) % 13), rmssd: 40 + 40 * Double(i) / Double(n) + Double(i % 9),
                                             sdnn: 40, respRate: 14, rrv: 0.1 + Double((i * 5) % 17) * 0.05,
                                             clock: Double(i) / Double(n - 1))
        }
    }

    func testNoRawRespKeepsWakeAndREMOfTheLegacyRecipe() {
        let f = driftingFeatures()
        let legacy = SleepStager.classifyEpochs(f, recipe: .legacy)
        let rsa = SleepStager.classifyEpochs(f, recipe: .noRawResp)
        XCTAssertTrue(legacy.contains("wake") && legacy.contains("rem"), "sanity: both stages occur")
        XCTAssertEqual(legacy.map { $0 == "wake" }, rsa.map { $0 == "wake" },
                       "wake wins before deep and must not depend on the deep recipe")
        for i in f.indices where legacy[i] != "deep" && rsa[i] != "deep" {
            XCTAssertEqual(legacy[i], rsa[i], "epoch \(i): only deep may differ between the recipes")
        }
        XCTAssertNotEqual(legacy, rsa, "sanity: the recipes do differ (in deep)")
    }

    func testStageReferenceUsesRawFeaturesForNonDeepThresholds() {
        let f = driftingFeatures()
        let legacy = SleepStager.stageReference(f, recipe: .legacy)
        let rsa = SleepStager.stageReference(f, recipe: .noRawResp)
        XCTAssertEqual(rsa.hrHi, legacy.hrHi, "HR-high bar (wake/REM) is a RAW-HR percentile for every recipe")
        XCTAssertEqual(rsa.hrvarHi, legacy.hrvarHi)
        XCTAssertEqual(rsa.rrvHi, legacy.rrvHi)
        XCTAssertNotEqual(rsa.hrLo, legacy.hrLo, "only the deep HR bar lives in the relative frame")
    }

    func testClassifyOneDeepOverridesTouchOnlyTheDeepRule() {
        // Still, HR-high, activated, irregular breathing → REM; a deep override must not change that.
        let f = SleepStager.EpochFeatures(index: 0, midTs: 0, count: 0, moveFrac: 0, ckSleep: true, hr: 80,
                                          hrVar: 5, rmssd: 20, sdnn: 0, respRate: 14, rrv: 2.0, clock: 0.5)
        let plain = SleepStager.classifyOne(f, hrLo: 55, hrHi: 70, rmssdHi: 50, hrvarHi: 1, rrvHi: 1, rrvLo: 0.5)
        let overridden = SleepStager.classifyOne(f, hrLo: 55, hrHi: 70, rmssdHi: 50, hrvarHi: 1, rrvHi: 1, rrvLo: 0.5,
                                                 deepHRLow: false, deepParasympOK: false)
        XCTAssertEqual(plain, "rem")
        XCTAssertEqual(overridden, "rem")
        // And the override is what decides deep: still + low HR + regular + tone → deep only if both flags say so.
        let calm = SleepStager.EpochFeatures(index: 0, midTs: 0, count: 0, moveFrac: 0, ckSleep: true, hr: 60,
                                             hrVar: 0, rmssd: 20, sdnn: 0, respRate: 14, rrv: 0.1, clock: 0.5)
        XCTAssertEqual(SleepStager.classifyOne(calm, hrLo: 55, hrHi: 90, rmssdHi: 50, hrvarHi: 100, rrvHi: 1, rrvLo: 0.5,
                                               deepHRLow: true, deepParasympOK: true), "deep")
        XCTAssertEqual(SleepStager.classifyOne(calm, hrLo: 55, hrHi: 90, rmssdHi: 50, hrvarHi: 100, rrvHi: 1, rrvLo: 0.5,
                                               deepHRLow: true, deepParasympOK: false), "light")
    }

    func testNoRawRespRequiresAFiniteRMSSDForDeep() {
        var f = driftingFeatures(300)
        f = f.map { e in
            SleepStager.EpochFeatures(index: e.index, midTs: e.midTs, count: e.count, moveFrac: 0.0, ckSleep: true,
                                      hr: 55, hrVar: 0, rmssd: .nan, sdnn: .nan, respRate: 14, rrv: 0.1, clock: e.clock)
        }
        // Constant HR → relative HR is exactly 0 ≤ P50 everywhere: without a finite-RMSSD requirement every
        // epoch would read as deep.
        XCTAssertFalse(SleepStager.classifyEpochs(f, recipe: .noRawResp).contains("deep"))
        XCTAssertTrue(SleepStager.classifyEpochs(f, recipe: .legacy).contains("deep"),
                      "legacy keeps the missing-RMSSD-is-pro-deep rule (WHOOP 4.0 path unchanged)")
    }

    // MARK: - Recipe selection and the unchanged raw-resp path

    func testRecipeIsLegacyWithRawRespAndRSAWithout() {
        let grav = (0..<600).map { GravitySample(ts: 1000 + $0, x: 0, y: 0, z: 1) }
        let times = grav.map { $0.ts }
        let deltas = SleepStager.gravityDeltas(grav)
        let resp = (0..<600).map { RespSample(ts: 1000 + $0, raw: 100 + Int(30 * sin(Double($0) * 0.9))) }
        let withResp = SleepStager.buildEpochGrid(start: 1000, end: 1600, gravTimes: times, gravDeltas: deltas,
                                                  hr: [], rr: [], resp: resp)
        let without = SleepStager.buildEpochGrid(start: 1000, end: 1600, gravTimes: times, gravDeltas: deltas,
                                                 hr: [], rr: [], resp: [])
        XCTAssertEqual(SleepStager.StagingRecipe.forGrid(withResp), .legacy, "WHOOP 4.0 (raw resp) keeps the legacy construction")
        XCTAssertEqual(SleepStager.StagingRecipe.forGrid(without), .noRawResp)
        XCTAssertNotEqual(SleepStager.StagingRecipe.legacy, SleepStager.StagingRecipe.noRawResp)
    }

    func testLegacyRecipeCarriesTheOriginalConstants() {
        let r = SleepStager.StagingRecipe.legacy
        XCTAssertFalse(r.relativeToLocal)
        XCTAssertEqual(r.hrLowPct, SleepStager.stageHRLowPct)
        XCTAssertEqual(r.hrvHighPct, SleepStager.stageHRVHighPct)
        XCTAssertEqual(r.rrvRegularPct, SleepStager.stageRRVLowPct)
        XCTAssertEqual(r.deepFirstFraction, SleepStager.deepFirstFraction)
        XCTAssertFalse(r.requireFiniteRMSSDForDeep)
    }

    func testDefaultClassificationIsTheLegacyRecipe() {
        let f = (0..<400).map { i -> SleepStager.EpochFeatures in
            let hr = 55.0 + 6.0 * sin(Double(i) / 23.0)
            return SleepStager.EpochFeatures(index: i, midTs: Double(i) * 30, count: 0,
                                             moveFrac: i % 40 == 0 ? 0.5 : 0.02, ckSleep: true, hr: hr,
                                             hrVar: 1 + Double(i % 7), rmssd: 50 + Double(i % 31),
                                             sdnn: 40, respRate: 14, rrv: 0.1 + Double(i % 11) * 0.05,
                                             clock: Double(i) / 399)
        }
        XCTAssertEqual(SleepStager.classifyEpochs(f), SleepStager.classifyEpochs(f, recipe: .legacy))
        let labels = SleepStager.classifyEpochs(f)
        XCTAssertEqual(SleepStager.reimposePhysiology(labels, features: f, onsetIdx: 0, finalWakeIdx: 399),
                       SleepStager.reimposePhysiology(labels, features: f, onsetIdx: 0, finalWakeIdx: 399, recipe: .legacy))
    }

    func testFrontLoadedDeepPriorReachesFirstHalfForRSARecipeOnly() {
        let labels = ["deep", "deep", "deep", "deep"]
        let f = [feat(0, hr: 50, clock: 0.2), feat(1, hr: 50, clock: 0.42),
                 feat(2, hr: 50, clock: 0.6), feat(3, hr: 50, clock: 0.9)]
        let legacy = SleepStager.reimposePhysiology(labels, features: f, onsetIdx: 0, finalWakeIdx: 3, recipe: .legacy)
        XCTAssertEqual(legacy, ["deep", "light", "light", "light"])
        let rsa = SleepStager.reimposePhysiology(labels, features: f, onsetIdx: 0, finalWakeIdx: 3, recipe: .noRawResp)
        XCTAssertEqual(rsa, ["deep", "deep", "light", "light"])
    }

    func testHRVWindowIsAtLeastFiveMinutes() {
        let span = Double(2 * SleepStager.hrvHalfWindowEpochs + 1) * SleepStager.epochS
        XCTAssertGreaterThanOrEqual(span, 300)
    }
}

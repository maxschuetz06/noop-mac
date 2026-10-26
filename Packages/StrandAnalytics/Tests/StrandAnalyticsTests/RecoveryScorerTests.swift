import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class RecoveryScorerTests: XCTestCase {

    /// A usable (trusted) baseline with a given mean and σ (Gaussian).
    private func baseline(mean: Double, sigma: Double, nValid: Int = 14) -> BaselineState {
        // spread is internal abs-dev units; deviation() multiplies by 1.253 → σ.
        BaselineState(baseline: mean, spread: sigma / 1.253, nValid: nValid,
                      nightsSinceUpdate: 0, status: nValid >= 14 ? .trusted : .provisional)
    }

    func testRecoveryAtBaselineNearPopulationMean() {
        // HRV at baseline, RHR at baseline, no resp, sleepPerf at center → Z≈0 → ~58%.
        let r = RecoveryScorer.recovery(
            hrv: 50, rhr: 55, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6),
            rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: nil,
            sleepPerf: RecoveryScorer.sleepPerfCenter)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!, 57.93, accuracy: 0.5)
    }

    func testRecoveryHigherWhenHRVAboveAndRHRBelow() {
        let good = RecoveryScorer.recovery(
            hrv: 65, rhr: 50, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6.265),
            rhrBaseline: baseline(mean: 55, sigma: 2.506),
            respBaseline: nil,
            sleepPerf: 0.90)!
        let bad = RecoveryScorer.recovery(
            hrv: 40, rhr: 62, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6.265),
            rhrBaseline: baseline(mean: 55, sigma: 2.506),
            respBaseline: nil,
            sleepPerf: 0.70)!
        XCTAssertGreaterThan(good, bad)
        XCTAssertGreaterThan(good, 90)   // matches Python golden ~97
        XCTAssertLessThan(bad, 15)       // matches Python golden ~7
    }

    func testRecoveryClampedToRange() {
        let r = RecoveryScorer.recovery(
            hrv: 200, rhr: 30, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 5),
            rhrBaseline: baseline(mean: 55, sigma: 2),
            respBaseline: nil,
            sleepPerf: 1.0)!
        XCTAssertLessThanOrEqual(r, 100.0)
        XCTAssertGreaterThanOrEqual(r, 0.0)
    }

    func testColdStartReturnsNil() {
        let coldHRV = BaselineState(baseline: 50, spread: 5, nValid: 2,
                                    nightsSinceUpdate: 0, status: .calibrating)
        let r = RecoveryScorer.recovery(
            hrv: 60, rhr: 50, resp: nil,
            hrvBaseline: coldHRV, rhrBaseline: nil, respBaseline: nil, sleepPerf: 0.9)
        XCTAssertNil(r)
    }

    func testRespTermDropAndRenormalize() {
        // With resp present vs nil but everything else equal at baseline, the score
        // stays near population mean either way (no driver pushes Z off zero).
        let withResp = RecoveryScorer.recovery(
            hrv: 50, rhr: 55, resp: 100,
            hrvBaseline: baseline(mean: 50, sigma: 6),
            rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: baseline(mean: 100, sigma: 5),
            sleepPerf: RecoveryScorer.sleepPerfCenter)!
        let withoutResp = RecoveryScorer.recovery(
            hrv: 50, rhr: 55, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6),
            rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: baseline(mean: 100, sigma: 5),
            sleepPerf: RecoveryScorer.sleepPerfCenter)!
        XCTAssertEqual(withResp, withoutResp, accuracy: 1e-6)
    }

    func testRespAboveBaselineLowersAndBelowRaisesRecovery() {
        // Pins the resp-into-recovery wiring direction (mirrors the Android BaselineSeedingTest
        // addition): with HRV/RHR pinned at baseline, a nightly respiratory rate above the resp
        // baseline must LOWER recovery and one below it must RAISE it. A nil resp renormalizes
        // to the no-resp score (testRespTermDropAndRenormalize already pins that).
        func score(_ resp: Double?) -> Double {
            RecoveryScorer.recovery(
                hrv: 50, rhr: 55, resp: resp,
                hrvBaseline: baseline(mean: 50, sigma: 6),
                rhrBaseline: baseline(mean: 55, sigma: 3),
                respBaseline: baseline(mean: 14.5, sigma: 1),
                sleepPerf: 0.9)!
        }
        let neutral = score(nil)
        let elevated = score(17.5)
        let lowered = score(12.0)
        XCTAssertLessThan(elevated, neutral, "resp above baseline must lower recovery")
        XCTAssertGreaterThan(lowered, neutral, "resp below baseline must raise recovery")
    }

    func testSkinTempNilLeavesScoreIdenticalToBefore() {
        // The no-skin-temp path must be byte-identical to the pre-redesign score:
        // when skinTempDev is nil the term drops and the weights renormalize.
        func score(_ dev: Double?) -> Double {
            RecoveryScorer.recovery(
                hrv: 55, rhr: 52, resp: nil,
                hrvBaseline: baseline(mean: 50, sigma: 6),
                rhrBaseline: baseline(mean: 55, sigma: 3),
                respBaseline: nil,
                sleepPerf: 0.9,
                skinTempDev: dev)!
        }
        // Default argument (nil) and explicit nil agree, and both equal the no-skin-temp score.
        let implicitNil = RecoveryScorer.recovery(
            hrv: 55, rhr: 52, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6),
            rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: nil,
            sleepPerf: 0.9)!
        XCTAssertEqual(score(nil), implicitNil, accuracy: 1e-9)
    }

    func testSkinTempDeviationLowersChargeSymmetrically() {
        // A symmetric penalty: ANY drift from baseline (hot OR cold) lowers Charge, and a
        // larger |deviation| lowers it more. Baseline drivers are pinned ABOVE-center
        // (positive composite z) so the penalty has a visible direction to push against.
        func score(_ dev: Double?) -> Double {
            RecoveryScorer.recovery(
                hrv: 55, rhr: 52, resp: nil,
                hrvBaseline: baseline(mean: 50, sigma: 6),
                rhrBaseline: baseline(mean: 55, sigma: 3),
                respBaseline: nil,
                sleepPerf: 0.9,
                skinTempDev: dev)!
        }
        let neutral = score(nil)
        let zeroDev = score(0.0)
        let warm = score(1.0)
        let cold = score(-1.0)
        let bigWarm = score(2.0)
        // A present zero-deviation term adds no penalty itself, but participates in the
        // renormalization (extra weight at z=0), so an above-center composite is pulled
        // slightly toward the logistic center — strictly below the no-term score.
        XCTAssertLessThan(zeroDev, neutral)
        // A real deviation penalizes further, below the zero-deviation case…
        XCTAssertLessThan(warm, zeroDev, "warm deviation must lower Charge")
        XCTAssertLessThan(cold, zeroDev, "cold deviation must lower Charge")
        // …symmetrically (±1 °C cost the same)…
        XCTAssertEqual(warm, cold, accuracy: 1e-9)
        // …and a larger deviation lowers it more.
        XCTAssertLessThan(bigWarm, warm)
    }

    func testBandThresholds() {
        XCTAssertEqual(RecoveryScorer.band(20), "red")
        XCTAssertEqual(RecoveryScorer.band(33.9), "red")
        XCTAssertEqual(RecoveryScorer.band(34), "yellow")
        XCTAssertEqual(RecoveryScorer.band(50), "yellow")
        XCTAssertEqual(RecoveryScorer.band(66.9), "yellow")
        XCTAssertEqual(RecoveryScorer.band(67), "green")
        XCTAssertEqual(RecoveryScorer.band(90), "green")
    }

    func testRestingHRLowestRollingMean() {
        // Two 5-min blocks: first averages 60, second averages 50 → resting = 50.
        var hr: [HRSample] = []
        let start = 1000
        for i in 0..<300 { hr.append(HRSample(ts: start + i, bpm: 60)) }        // 0..299 s
        for i in 0..<300 { hr.append(HRSample(ts: start + 300 + i, bpm: 50)) }  // 300..599 s
        let r = RecoveryScorer.restingHR(hr, start: start, end: start + 600)
        XCTAssertEqual(r, 50)
    }

    func testRestingHRNilWhenNoSamples() {
        XCTAssertNil(RecoveryScorer.restingHR([], start: 0, end: 1000))
    }

    // MARK: - #686: artifact hardening of the resting-HR floor

    func testRestingHRRejectsSingleSampleArtifactBin() {
        // A dense, well-populated bin at 55 bpm, then a SECOND 5-min bin holding exactly ONE
        // artifact beat at 30 bpm. The old min-of-bin-means took the lone-sample bin (30) as the
        // floor; with #686 a single-sample bin can't WIN, so the floor is the real 55.
        var hr: [HRSample] = []
        let start = 1000
        for i in 0..<300 { hr.append(HRSample(ts: start + i, bpm: 55)) }   // bin 0: 300 samples @55
        hr.append(HRSample(ts: start + 300, bpm: 30))                       // bin 1: ONE sample @30
        let r = RecoveryScorer.restingHR(hr, start: start, end: start + 600)
        XCTAssertEqual(r, 55, "a single-sample artifact bin must not win the resting floor")
    }

    func testRestingHRRejectsSubPhysiologicalDropoutBin() {
        // Two FULLY-populated bins: a real 52 bpm bin and a dropout bin whose 300 samples all read
        // an implausible 10 bpm (decode-zero / dropout run). It clears the sample-count bar but is
        // sub-physiological, so #686 bars it from the floor → resting reads the real 52.
        var hr: [HRSample] = []
        let start = 2000
        for i in 0..<300 { hr.append(HRSample(ts: start + i, bpm: 52)) }         // real bin
        for i in 0..<300 { hr.append(HRSample(ts: start + 300 + i, bpm: 10)) }   // dropout bin
        let r = RecoveryScorer.restingHR(hr, start: start, end: start + 600)
        XCTAssertEqual(r, 52, "a sub-physiological dropout bin must not win the resting floor")
    }

    func testRestingHRKeepsGenuineLowFloor() {
        // A REAL sustained dip (a full 5-min bin at 45 bpm) is plausible AND well-populated, so it
        // still wins — the hardening must not flatten genuine athletic resting HRs.
        var hr: [HRSample] = []
        let start = 3000
        for i in 0..<300 { hr.append(HRSample(ts: start + i, bpm: 60)) }
        for i in 0..<300 { hr.append(HRSample(ts: start + 300 + i, bpm: 45)) }
        let r = RecoveryScorer.restingHR(hr, start: start, end: start + 600)
        XCTAssertEqual(r, 45, "a genuine sustained low bin must still win the floor")
    }

    func testRestingHRFallsBackWhenNoBinQualifies() {
        // A wholly sparse window: every bin holds a single sample (none clears the count bar).
        // Rather than return nil on data present, fall back to the legacy lowest-bin-mean (here 48).
        let start = 4000
        let hr = [HRSample(ts: start + 10, bpm: 58),
                  HRSample(ts: start + 320, bpm: 48)]   // two bins, one sample each
        let r = RecoveryScorer.restingHR(hr, start: start, end: start + 600)
        XCTAssertEqual(r, 48, "with no qualifying bin, fall back to the lowest bin mean (never nil on data)")
    }
}

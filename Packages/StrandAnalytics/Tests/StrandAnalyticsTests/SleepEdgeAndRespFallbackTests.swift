import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Synthetic-data tests for (1) trimming a trailing/leading movement burst that `mergePeriods` folds into
/// the sleep run, and (2) the R-R (RSA) respiration fallback used when no raw resp channel exists (WHOOP 5.0).
final class SleepEdgeAndRespFallbackTests: XCTestCase {

    // 2026-06-10 00:00:00 UTC; hour 01 start keeps the window overnight at tzOffset 0.
    private let midnight = 1_749_513_600

    private func still(_ start: Int, _ durS: Int) -> [GravitySample] {
        (0..<durS).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) }
    }
    private func moving(_ start: Int, _ durS: Int) -> [GravitySample] {
        (0..<durS).map { GravitySample(ts: start + $0, x: Double($0 % 2) * 0.5, y: 0, z: 1.0) }
    }
    private func hr(_ start: Int, _ durS: Int, _ bpm: Int) -> [HRSample] {
        (0..<durS).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    // MARK: - Edge bursts

    func testTrailingWakeBurstIsTrimmedFromSessionEnd() {
        let start = midnight + 3_600
        let sleepS = 4 * 3600
        let burstS = 10 * 60
        let grav = still(start, sleepS) + moving(start + sleepS, burstS)
        let h = hr(start, sleepS + burstS, 50)
        let sessions = SleepStager.detectSleep(hr: h, gravity: grav)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].start, start)
        // Ends where the final activity began, not 10 min later.
        XCTAssertEqual(sessions[0].end, start + sleepS, accuracy: 120)
        XCTAssertLessThan(sessions[0].end, start + sleepS + 120)
    }

    func testLeadingSettlingBurstIsTrimmedFromSessionStart() {
        let start = midnight + 3_600
        let burstS = 10 * 60
        let sleepS = 4 * 3600
        let grav = moving(start, burstS) + still(start + burstS, sleepS)
        let h = hr(start, burstS + sleepS, 50)
        let sessions = SleepStager.detectSleep(hr: h, gravity: grav)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].start, start + burstS, accuracy: 120)
        XCTAssertEqual(sessions[0].end, start + burstS + sleepS, accuracy: 5)
    }

    func testMidNightAwakeningStaysInsideSession() {
        let start = midnight + 3_600
        let aS = 2 * 3600, burstS = 8 * 60, bS = 2 * 3600
        let grav = still(start, aS) + moving(start + aS, burstS) + still(start + aS + burstS, bS)
        let total = aS + burstS + bS
        let sessions = SleepStager.detectSleep(hr: hr(start, total, 50), gravity: grav)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].start, start)
        XCTAssertEqual(sessions[0].end, start + total, accuracy: 5)
    }

    func testBandAsleepVetoesTrailingTrim() {
        let start = midnight + 3_600
        let sleepS = 4 * 3600, burstS = 10 * 60
        let grav = still(start, sleepS) + moving(start + sleepS, burstS)
        let band = (0..<(sleepS + burstS)).map { (ts: start + $0, state: 2) }
        let sessions = SleepStager.detectSleep(hr: hr(start, sleepS + burstS, 50), gravity: grav,
                                               bandSleepState: band)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].end, start + sleepS + burstS, accuracy: 5,
                       "strap says asleep through the burst → restlessness, not a wake-up; keep it")
    }

    // MARK: - R-R respiration fallback

    /// Tachogram with a strong 0.11 Hz (6.6 rpm, LF) component plus a weaker 0.27 Hz (16 rpm) breath.
    private func rrWindow(seconds: Double, lfAmp: Double, breathAmp: Double, breathHz: Double,
                          start: Int = 1_700_000_000) -> [RRInterval] {
        var rows: [RRInterval] = []
        var t = 0.0
        while t < seconds {
            let rr = 1000.0 + lfAmp * sin(2 * Double.pi * 0.11 * t) + breathAmp * sin(2 * Double.pi * breathHz * t)
            t += rr / 1000.0
            rows.append(RRInterval(ts: start + Int(t), rrMs: Int(rr)))
        }
        return rows
    }

    func testRespWindowPicksBreathBandNotLFPeak() {
        let rr = rrWindow(seconds: 300, lfAmp: 60, breathAmp: 25, breathHz: 0.27)
        let est = SleepStager.respFromRRWindow(rr.map { Double($0.rrMs) })
        XCTAssertTrue(est.rateBpm.isFinite)
        XCTAssertEqual(est.rateBpm, 16.2, accuracy: 1.5, "must lock onto ~16 rpm, not the 6–7 rpm LF peak")
        XCTAssertGreaterThan(est.rateBpm, 9.0)
    }

    func testRespWindowTooFewBeatsIsNaN() {
        let est = SleepStager.respFromRRWindow([1000, 1010, 990])
        XCTAssertTrue(est.rateBpm.isNaN && est.irregularity.isNaN)
    }

    func testEpochFeaturesGetRespFromRRWhenNoRawRespChannel() {
        let start = 1_700_000_000
        let durS = 1200
        let rr = rrWindow(seconds: Double(durS), lfAmp: 60, breathAmp: 30, breathHz: 0.27, start: start)
        let grav = still(start, durS)
        let grid = SleepStager.buildEpochGrid(start: Double(start), end: Double(start + durS),
                                              gravTimes: grav.map { $0.ts },
                                              gravDeltas: SleepStager.gravityDeltas(grav),
                                              hr: [], rr: rr, resp: [])
        let ck = SleepStager.coleKripke(SleepStager.rescaleCounts(grid.counts))
        let feats = SleepStager.extractFeatures(grid: grid, ckFlags: ck,
                                                dogHR: SleepStager.dogHRVariability(grid.hr),
                                                onsetIdx: 0, finalWakeIdx: grid.nEpochs - 1)
        let mid = feats[feats.count / 2]
        XCTAssertTrue(mid.respRate.isFinite, "per-epoch resp must come from R-R on a no-resp-ADC strap")
        XCTAssertEqual(mid.respRate, 16.2, accuracy: 2.0)
    }

    func testNoRRAndNoRespStaysNaNAndStagingMatchesNoRespBehaviour() {
        let start = 1_700_000_000
        let durS = 3 * 3600
        let grav = still(start, durS)
        let h = hr(start, durS, 52)
        let segs = SleepStager.stageSession(start: start, end: start + durS, grav: grav, hr: h, rr: [], resp: [])
        XCTAssertFalse(segs.isEmpty)
        // Genuinely unavailable respiration is not penalised: still, low-HR night stays restorative-capable
        // (the classifier treats NaN RRV as "regular"), so Rest keeps its restorative term.
        let asleep = segs.filter { $0.stage != "wake" }.reduce(0) { $0 + ($1.end - $1.start) }
        let restorative = segs.filter { $0.stage == "deep" || $0.stage == "rem" }.reduce(0) { $0 + ($1.end - $1.start) }
        let withNaN = AnalyticsEngine.Rest.composite(tstSeconds: Double(asleep), inBedSeconds: Double(durS),
                                                     efficiency: 0.95, restorativeSeconds: Double(restorative),
                                                     needHours: 8, consistency: nil,
                                                     deepSeconds: Double(restorative))
        XCTAssertGreaterThan(restorative, 0)
        XCTAssertGreaterThan(withNaN, 0)
    }
}

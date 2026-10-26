import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// V1 staging: per-epoch HRV hygiene + a plausible deep share on a typical NREM-like night.
///
/// ALL data here is SYNTHETIC (seeded generator below) — no health data is committed.
final class SleepStagerV1EpochHRVTests: XCTestCase {

    // MARK: - Deterministic synthetic night

    /// Tiny deterministic PRNG (SplitMix64) so the tests never flake.
    struct Rng {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func normal() -> Double {
            let u1 = max(uniform(), 1e-12), u2 = uniform()
            return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
        }
    }

    enum Truth { case wake, light, deep, rem }

    /// Per-stage physiology of the synthetic sleeper (HR, RSA amplitude, breathing regularity, jitter).
    struct Phys { let hr: Double; let rsaAmp: Double; let breathHz: Double; let breathWander: Double
                  let jitter: Double; let hrDrift: Double }
    static func phys(_ t: Truth, hard: Bool) -> Phys {
        // `hard` = realistic stage overlap (deep only ~3 bpm / ~25 % RSA above light) instead of a textbook split.
        switch t {
        case .deep:  return hard ? Phys(hr: 54, rsaAmp: 64, breathHz: 0.24, breathWander: 0.012, jitter: 10, hrDrift: 1.0)
                                 : Phys(hr: 51, rsaAmp: 75, breathHz: 0.24, breathWander: 0.003, jitter: 8,  hrDrift: 0.5)
        case .light: return Phys(hr: 57, rsaAmp: 50, breathHz: 0.26, breathWander: 0.02,  jitter: 12, hrDrift: 1.5)
        case .rem:   return Phys(hr: 60, rsaAmp: 32, breathHz: 0.27, breathWander: 0.06,  jitter: 16, hrDrift: 4.0)
        case .wake:  return Phys(hr: 66, rsaAmp: 20, breathHz: 0.28, breathWander: 0.05,  jitter: 20, hrDrift: 3.0)
        }
    }

    struct Night {
        let start: Int
        let end: Int
        let truth: [Truth]        // per 30 s epoch
        let grav: [GravitySample]
        let hr: [HRSample]
        let rr: [RRInterval]
    }

    /// ~6 h night: 4 × 90-min cycles (deep heavy in cycles 1–2, REM growing), a settling wake at the start
    /// and a couple of short mid-night wake bouts. `artifactEpochFrac` = share of epochs hit by an R-R
    /// artifact burst (missed / extra beats that survive the [300, 2000] ms range filter); `isolatedArtifact`
    /// = per-beat probability of a stray corrupted beat everywhere.
    static func makeNight(seed: UInt64 = 7, artifactEpochFrac: Double = 0.0, isolatedArtifact: Double = 0.0,
                          burstBeatFrac: Double = 0.25, includeDeep: Bool = true,
                          artifactOnlyInLightRange: Range<Int>? = nil, hard: Bool = false) -> Night {
        var rng = Rng(s: seed)
        var artRng = Rng(s: seed ^ 0x5DEE_CE66_D1CE_4E5B)   // artifacts never disturb the physiology stream
        let start = 1_700_000_000
        let nEp = 720
        var truth = [Truth](repeating: .light, count: nEp)
        // Cycle layout (epochs): [light, deep, light, rem, light]
        let deepLen = includeDeep ? [64, 44, 20, 4] : [0, 0, 0, 0]
        let remLen = [14, 24, 34, 44]
        for c in 0..<4 {
            let base = 12 + c * 176
            var p = base + 20
            for _ in 0..<deepLen[c] where p < nEp { truth[p] = .deep; p += 1 }
            p += 36
            for _ in 0..<remLen[c] where p < nEp { truth[p] = .rem; p += 1 }
        }
        for i in 0..<12 { truth[i] = .wake }
        for b in [260, 430, 590] { for i in b..<min(nEp, b + 6) { truth[i] = .wake } }
        for i in (nEp - 4)..<nEp { truth[i] = .wake }

        // Artifact epochs.
        var artEp = [Bool](repeating: false, count: nEp)
        for i in 0..<nEp {
            if let r = artifactOnlyInLightRange { artEp[i] = r.contains(i) }
            else { artEp[i] = artRng.uniform() < artifactEpochFrac }
        }

        var grav: [GravitySample] = []
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        var tBeat = 0.0                  // seconds since start (beat clock)
        var phase = 0.0                  // breathing phase
        var hrSlow = 0.0                 // slow HR wander (AR(1))

        for e in 0..<nEp {
            let ph = phys(truth[e], hard: hard)
            // Circadian HR nadir late in the night (hard mode): lowest HR sits at ~65 % of the night.
            let trend = hard ? -6.0 * exp(-pow((Double(e) / Double(nEp) - 0.65) / 0.25, 2)) : 0.0
            // gravity 1 Hz
            for s in 0..<30 {
                let ts = start + e * 30 + s
                var moving = false
                switch truth[e] {
                case .wake: moving = s % 2 == 0
                case .light: moving = (e % 29 == 0) && s < 6   // occasional micro-movement
                default: moving = false
                }
                grav.append(GravitySample(ts: ts, x: moving ? 0.3 : 0, y: 0, z: 1.0))
            }
            // beats inside this epoch
            hrSlow = 0.92 * hrSlow + ph.hrDrift * 0.4 * rng.normal()
            let epochEnd = Double((e + 1) * 30)
            while tBeat < epochEnd {
                let meanRR = 60_000.0 / (ph.hr + trend + hrSlow)
                let f = ph.breathHz + ph.breathWander * rng.normal()
                phase += 2 * Double.pi * f * (meanRR / 1000.0)
                var v = meanRR + ph.rsaAmp * sin(phase) + ph.jitter * rng.normal()
                if artEp[e] && artRng.uniform() < burstBeatFrac {
                    v *= artRng.uniform() < 0.5 ? (0.55 + 0.1 * artRng.uniform()) : (1.45 + 0.2 * artRng.uniform())
                } else if isolatedArtifact > 0 && artRng.uniform() < isolatedArtifact {
                    v *= artRng.uniform() < 0.5 ? 0.6 : 1.5
                }
                v = min(1900, max(320, v))
                tBeat += v / 1000.0
                if tBeat < epochEnd { rr.append(RRInterval(ts: start + Int(tBeat), rrMs: Int(v))) }
            }
            // HR 1 Hz (device-style integer bpm of the underlying rate, not the corrupted beats)
            for s in 0..<30 {
                let b = ph.hr + trend + hrSlow + 0.8 * rng.normal()
                hr.append(HRSample(ts: start + e * 30 + s, bpm: Int(b.rounded())))
            }
        }
        return Night(start: start, end: start + nEp * 30, truth: truth, grav: grav, hr: hr, rr: rr)
    }

    struct Shares { let deep: Double; let rem: Double; let light: Double; let wake: Double
                    let deepMin: Double }
    static func shares(_ segs: [StageSegment]) -> Shares {
        func dur(_ s: String) -> Double { segs.filter { $0.stage == s }.reduce(0) { $0 + Double($1.end - $1.start) } }
        let d = dur("deep"), r = dur("rem"), l = dur("light"), w = dur("wake")
        let tst = max(1, d + r + l)
        return Shares(deep: d / tst, rem: r / tst, light: l / tst, wake: w / max(1, d + r + l + w), deepMin: d / 60)
    }

    func stage(_ n: Night) -> [StageSegment] {
        SleepStager.stageSession(start: n.start, end: n.end, grav: n.grav, hr: n.hr, rr: n.rr, resp: [])
    }

    // MARK: - Diagnostics (kept as a smoke test; prints are informational)

    /// Per-epoch features exactly as `stageSession` builds them (no raw respiration channel).
    func features(_ n: Night) -> [SleepStager.EpochFeatures] {
        let gDeltas = SleepStager.gravityDeltas(n.grav)
        let grid = SleepStager.buildEpochGrid(start: Double(n.start), end: Double(n.end),
                                              gravTimes: n.grav.map { $0.ts }, gravDeltas: gDeltas,
                                              hr: n.hr, rr: n.rr, resp: [])
        let ck = SleepStager.coleKripke(SleepStager.rescaleCounts(grid.counts))
        let (o, f) = SleepStager.onsetAndFinalWake(ck)
        return SleepStager.extractFeatures(grid: grid, ckFlags: ck, dogHR: SleepStager.dogHRVariability(grid.hr),
                                           onsetIdx: o, finalWakeIdx: f)
    }

    /// Stage label of the epoch containing `epoch`'s midpoint.
    func label(_ segs: [StageSegment], _ n: Night, _ epoch: Int) -> String {
        let mid = n.start + epoch * 30 + 15
        return segs.first { $0.start <= mid && mid < $0.end }?.stage ?? "?"
    }

    // MARK: - HRV hygiene: artifacts must not inflate the night's HRV distribution

    func testArtifactsDoNotInflatePerEpochRMSSDDistribution() {
        let clean = features(Self.makeNight(hard: true))
        let dirty = features(Self.makeNight(artifactEpochFrac: 0.35, isolatedArtifact: 0.01, hard: true))
        for pct in [50.0, 70.0] {
            let c = SleepStager.percentile(clean.map { $0.rmssd }, pct)!
            let d = SleepStager.percentile(dirty.map { $0.rmssd }, pct)!
            XCTAssertEqual(d, c, accuracy: c * 0.12,
                           "P\(Int(pct)) per-epoch RMSSD with R-R artifacts (\(d)) must stay within 12 % of the clean night (\(c))")
        }
    }

    // MARK: - Deep share is plausible on a night with clear NREM-like epochs

    private func deepStats(_ night: Night) -> (share: Double, recall: Double, precision: Double) {
        let segs = stage(night)
        let sh = Self.shares(segs)
        var tp = 0, fn = 0, fp = 0
        for e in 0..<night.truth.count {
            let isDeep = label(segs, night, e) == "deep"
            if night.truth[e] == .deep { if isDeep { tp += 1 } else { fn += 1 } } else if isDeep { fp += 1 }
        }
        return (sh.deep, Double(tp) / Double(max(1, tp + fn)), Double(tp) / Double(max(1, tp + fp)))
    }

    func testTypicalNightGivesPlausibleDeepShare() {
        for (name, night) in [("textbook", Self.makeNight()),
                              ("realistic overlap + late HR nadir", Self.makeNight(hard: true))] {
            let st = deepStats(night)
            XCTAssertGreaterThanOrEqual(st.share, 0.10, "\(name): deep share \(st.share)")
            XCTAssertLessThanOrEqual(st.share, 0.30, "\(name): deep share \(st.share)")
            XCTAssertGreaterThan(st.recall, 0.5, "\(name): most true deep epochs must be found")
            // Block edges smear by the 2.5–5.5 min feature windows, so a perfect score is neither expected nor wanted.
            XCTAssertGreaterThan(st.precision, 0.65, "\(name): labelled deep must be mostly true deep")
        }
    }

    func testPlausibleDeepShareSurvivesRRArtifacts() {
        let night = Self.makeNight(artifactEpochFrac: 0.35, isolatedArtifact: 0.01, hard: true)
        let st = deepStats(night)
        XCTAssertGreaterThanOrEqual(st.share, 0.10, "deep share \(st.share)")
        XCTAssertLessThanOrEqual(st.share, 0.30, "deep share \(st.share)")
        XCTAssertGreaterThan(st.precision, 0.65)
    }

    // MARK: - Deep is not fabricated, and never handed to artifact spikes

    func testNightWithoutDeepDoesNotFabricateLargeDeepShare() {
        let sh = Self.shares(stage(Self.makeNight(includeDeep: false, hard: true)))
        XCTAssertLessThan(sh.deep, 0.12, "a night with no deep epochs must not be force-fed ~20 % deep (got \(sh.deep))")
    }

    func testArtifactBurstInLightSleepIsNotLabelledDeep() {
        let range = 300..<360
        let night = Self.makeNight(burstBeatFrac: 0.3, includeDeep: false, artifactOnlyInLightRange: range, hard: true)
        let segs = stage(night)
        let deepInBurst = range.filter { label(segs, night, $0) == "deep" }.count
        XCTAssertLessThanOrEqual(Double(deepInBurst) / Double(range.count), 0.10,
                                 "an artifact-laden R-R stretch must not read as high-HRV deep sleep")
        XCTAssertLessThan(Self.shares(segs).deep, 0.12)
    }

    // MARK: - noRawResp: wake / REM unchanged vs legacy; sparse R-R cannot fabricate deep

    func testWakeAndREMLabelsMatchLegacyRecipeOnSyntheticNight() {
        for hard in [false, true] {
            let f = features(Self.makeNight(hard: hard))
            let legacy = SleepStager.classifyEpochs(f, recipe: .legacy)
            let rsa = SleepStager.classifyEpochs(f, recipe: .noRawResp)
            XCTAssertEqual(legacy.map { $0 == "wake" }, rsa.map { $0 == "wake" }, "hard=\(hard): wake must not move")
            for i in f.indices where legacy[i] != "deep" && rsa[i] != "deep" {
                XCTAssertEqual(legacy[i], rsa[i], "hard=\(hard) epoch \(i): only deep may differ")
            }
        }
    }

    /// The same night with the R-R stream thinned to every `keepEvery`-th beat (0 → none at all).
    private func thinned(_ n: Night, keepEvery: Int) -> Night {
        let rr = keepEvery == 0 ? [] : n.rr.enumerated().filter { $0.offset % keepEvery == 0 }.map { $0.element }
        return Night(start: n.start, end: n.end, truth: n.truth, grav: n.grav, hr: n.hr, rr: rr)
    }

    func testSparseRRDoesNotCollapseToStillPlusLowHRDeep() {
        let base = Self.makeNight(hard: true)
        // No R-R at all: RMSSD is missing everywhere → there is no evidence of parasympathetic tone → no deep.
        XCTAssertEqual(Self.shares(stage(thinned(base, keepEvery: 0))).deep, 0, accuracy: 1e-9)
        // One beat in fifteen (~2 beats per epoch): far fewer than `minCleanHRVPairs` clean pairs per 5.5-min
        // window → RMSSD missing → no deep (HR alone, even "below the local median", must not be enough).
        let sparse = Self.shares(stage(thinned(base, keepEvery: 15)))
        XCTAssertLessThanOrEqual(sparse.deep, 0.05, "sparse R-R deep share \(sparse.deep)")
    }

    func testRRDropoutBlockGetsNoDeep() {
        // BLE-offload-style hole: no R-R for epochs 150…330 (covers the second deep block of the night, which
        // is truly deep). HR/motion are intact, but with no RMSSD there is no basis for deep in the hole.
        let base = Self.makeNight(hard: true)
        let lo = base.start + 150 * 30, hi = base.start + 330 * 30
        let holed = Night(start: base.start, end: base.end, truth: base.truth, grav: base.grav, hr: base.hr,
                          rr: base.rr.filter { $0.ts < lo || $0.ts >= hi })
        let segs = stage(holed)
        let deepInHole = (160..<320).filter { label(segs, holed, $0) == "deep" }.count
        XCTAssertEqual(deepInHole, 0, "no deep without a measurable RMSSD")
        XCTAssertGreaterThan(Self.shares(stage(base)).deep, 0.10, "sanity: the intact night does have deep")
    }
}

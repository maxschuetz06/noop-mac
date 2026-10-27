import Foundation
import StrandAnalytics

/// Stress evaluation on the live R-R stream, two independent layers (each opt-in, each off by default):
///   • the legacy experimental `behavior.stressNudge` buzz (a fresh HRV dip → one confirming buzz);
///   • the v5 L3 closed-loop check-in — the unit-tested `StressOnsetDetector` decides, at the moment
///     it matters, whether to offer a 60-s guided breath. On a fresh, non-metabolic HRV dip while the
///     user is still it fires a single confirming buzz AND posts a passive nudge to `nudgeCenter`
///     (the dismissible Stress check-in card surfaces it). The detector carries its own replay-safe
///     state (de-dup + slow baseline + rate limit), persisted via `BiofeedbackPrefs` so a relaunch
///     can't re-fire. Honest / non-clinical: "stress" is an autonomic proxy vs the user's own
///     baseline, never a diagnosis.
@MainActor
final class StressMonitor {
    private let live: LiveState
    private let behavior: BehaviorStore
    private let nudgeCenter: StressNudgeCenter
    private let buzz: (UInt8) -> Void

    // L3 stress-onset detector state: a rolling R-R buffer + the replay-safe detector state (persisted
    // via BiofeedbackPrefs so a relaunch can't re-fire), carried verbatim between evaluations.
    private var rrBuf: [Int] = []
    private var stressState = BiofeedbackPrefs.loadStressState()
    // Legacy experimental stress-nudge state (the older `behavior.stressNudge` buzz path) — a slow HRV
    // baseline + a rate limiter, kept so that toggle still works independently of the L3 check-in.
    private var hrvBaseline: Double = 0
    private var lastStressBuzzAt: Date = .distantPast

    init(live: LiveState, behavior: BehaviorStore, nudgeCenter: StressNudgeCenter,
         buzz: @escaping (UInt8) -> Void) {
        self.live = live
        self.behavior = behavior
        self.nudgeCenter = nudgeCenter
        self.buzz = buzz
    }

    /// Evaluate the latest live R-R window against both layers; `bpm` is the smoothed live heart rate.
    func evaluate(bpm: Int?) {
        let fresh = live.rr.filter { $0 > 300 && $0 < 2000 }   // plausible R-R (30–200 bpm)
        guard !fresh.isEmpty else { return }
        rrBuf.append(contentsOf: fresh)
        if rrBuf.count > 120 { rrBuf.removeFirst(rrBuf.count - 120) }
        evaluateLegacyNudge(bpm: bpm)
        evaluateCheckIn(bpm: bpm)
    }

    /// Legacy experimental nudge (behavior.stressNudge) — unchanged behaviour, kept separate.
    private func evaluateLegacyNudge(bpm: Int?) {
        guard behavior.stressNudge, live.bonded, live.worn, rrBuf.count >= 20 else { return }
        let rmssd = Self.rmssd(Array(rrBuf.suffix(60)))
        guard rmssd > 0 else { return }
        hrvBaseline = hrvBaseline == 0 ? rmssd : hrvBaseline * 0.98 + rmssd * 0.02   // slow EMA
        guard let hr = bpm, hr >= 55, hr <= 100 else { return }            // resting band — not a workout
        let now = Date()
        if rmssd < hrvBaseline * 0.6, now.timeIntervalSince(lastStressBuzzAt) > 900 {
            lastStressBuzzAt = now
            buzz(1)
            live.append(log: "Stress nudge — take a paced breath")
        }
    }

    /// v5 L3 closed-loop check-in (StressOnsetDetector). Inert unless the master toggle is on; the
    /// engine itself owns every gate (auto-nudge, exercise gate, quiet hours, rate limit, edge).
    private func evaluateCheckIn(bpm: Int?) {
        let cfg = BiofeedbackPrefs.stressConfig()
        guard cfg.enabled, live.bonded, live.worn else { return }
        let decision = StressOnsetDetector.evaluate(
            rrBuffer: rrBuf,
            currentHR: bpm.map(Double.init),
            recentMotionG: nil,   // wrist gravity is offloaded + lags live; the resting-HR band is the gate
            sessionActive: nudgeCenter.pending != nil,   // never stack a fresh nudge over a live one
            state: stressState,
            config: cfg,
            nowSec: Int(Date().timeIntervalSince1970),
            tzOffsetSec: TimeZone.current.secondsFromGMT())
        stressState = decision.nextState
        BiofeedbackPrefs.saveStressState(decision.nextState)
        guard decision.shouldNudge else { return }
        // Only an encrypted bond can buzz (the command characteristic is gated on bond; an un-encrypted
        // live-HR-only link can't).
        if live.bonded && live.encryptedBond { buzz(UInt8(clamping: decision.buzzLoops)) }
        nudgeCenter.present(fastRMSSD: decision.fastRMSSD, baselineRMSSD: decision.baselineRMSSD)
        live.append(log: "Stress check-in — HRV dipped while still")
    }

    private static func rmssd(_ rr: [Int]) -> Double {
        guard rr.count >= 2 else { return 0 }
        var sum = 0.0, n = 0
        for i in 1..<rr.count { let d = Double(rr[i] - rr[i - 1]); sum += d * d; n += 1 }
        return n > 0 ? (sum / Double(n)).squareRoot() : 0
    }
}

import Foundation
import WhoopStore
import StrandAnalytics

/// The v5 health-signal engines the Health hub and the illness banner read: illness / strain early
/// warning (`IllnessSignalEngine`), cycle-phase awareness (`CyclePhaseEngine`) and body-clock phase
/// (`CircadianEngine`). All on-device, opt-in where sensitive, honest-nil when there isn't enough data.
@MainActor
final class HealthSignalEngines: ObservableObject {
    /// Illness/strain early-warning (recent RHR up + HRV down + skin-temp up vs baseline). nil = clear.
    @Published var healthAlert: String?

    // The Insights / skin-temp Health-hub cards take pure engine RESULTS by value. The analytics pass
    // (IntelligenceEngine.analyzeRecent → refreshV5Signals) computes them once from the stores and
    // publishes them here so HealthView / InsightsHubView read a snapshot rather than re-deriving.
    // All opt-in / honest-nil — a nil result means "not enough data / not enabled".
    @Published var illnessSignal: IllnessSignalEngine.Result?
    /// Cycle-phase awareness (only computed when the user has opted in; else nil). Awareness only.
    @Published var cyclePhase: CyclePhaseEngine.Result?
    /// The nightly fused-index curve (oldest→newest) feeding the cycle card's sparkline.
    @Published var cycleCurve: [Double] = []
    /// Body-clock phase estimate (circadian). nil until a usable activity profile exists.
    @Published var circadianPhase: CircadianEngine.PhaseEstimate?

    private let repo: Repository
    private let behavior: BehaviorStore

    init(repo: Repository, behavior: BehaviorStore) {
        self.repo = repo
        self.behavior = behavior
    }

    /// Illness/strain early-warning (v5): the confounder-suppressed `IllnessSignalEngine`. For the last
    /// ~2 days vs a ~28-day personal baseline it z-scores resting HR, skin-temp deviation, HRV (negated)
    /// and respiration ORIENTED illness-ward, then the engine applies its minimum-corroboration gate,
    /// composite score, and — the differentiating part — same-day journal confounder suppression
    /// (alcohol / a hard-or-late workout / etc.) so a night out doesn't cry wolf. The journal context is
    /// read asynchronously, so this kicks a Task; the published `illnessSignal` + the `healthAlert`
    /// banner both come from the engine's single decision. On-device only, APPROXIMATE — not a diagnosis.
    func evaluateIllness(_ days: [DailyMetric]) {
        guard behavior.illnessWatch, days.count >= 14 else {
            healthAlert = nil; illnessSignal = nil; return
        }
        Task { [weak self] in
            guard let self else { return }
            // Confounder tags from the recent journal (within the last ~2 days). Read once, off the
            // engine's hot path — the engine only needs presence flags, not the rows.
            let recentDays = Set(days.suffix(2).map(\.day))
            let journal = await self.repo.journalEntries(days: 7)
            var ctxAlcohol = false, ctxHardWorkout = false, ctxAlreadyUnwell = false
            for e in journal where e.answeredYes && recentDays.contains(e.day) {
                let q = e.question.lowercased()
                if q.contains("alcohol") || q.contains("drink") { ctxAlcohol = true }
                if q.contains("workout") || q.contains("train") || q.contains("exercise") { ctxHardWorkout = true }
                if q.contains("sick") || q.contains("ill") || q.contains("unwell") { ctxAlreadyUnwell = true }
            }
            self.applyIllnessSignal(days, alcohol: ctxAlcohol, hardOrLateWorkout: ctxHardWorkout,
                                    alreadyUnwell: ctxAlreadyUnwell)
        }
    }

    /// Run the `IllnessSignalEngine` from the day history + the journal-derived confounder context, then
    /// publish the result + the legacy `healthAlert` banner string (kept for the existing banner surface).
    private func applyIllnessSignal(_ days: [DailyMetric], alcohol: Bool,
                                    hardOrLateWorkout: Bool, alreadyUnwell: Bool) {
        let previous = healthAlert
        let recent = Array(days.suffix(2))
        let base = Array(days.suffix(31).dropLast(3))    // ~28 days ending 3 days ago
        func mean(_ vals: [Double]) -> Double? { vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count) }
        func rm(_ kp: (DailyMetric) -> Double?) -> Double? { mean(recent.compactMap(kp)) }

        // Build each signal's illness-ward z against the personal baseline (Baselines.deviation). The
        // baseline is folded over the full pre-recent history; a trusted baseline (≥14 nights) is the
        // engine's gate for actually raising. Skin-temp is already a stored DEVIATION (°C), so it's
        // z-scored against a zero-centred personal spread; the others z-score the raw column.
        func signal(_ kp: (DailyMetric) -> Double?, cfgKey: String, illnessUp: Bool) -> (IllnessSignalEngine.SignalReading, Bool)? {
            guard let cfg = Baselines.metricCfg[cfgKey], let recentMean = rm(kp) else { return nil }
            let state = Baselines.foldHistory(base.map(kp), cfg: cfg)
            guard state.usable else { return (IllnessSignalEngine.SignalReading(zIllnessward: 0, present: false), false) }
            let dev = Baselines.deviation(recentMean, state: state)
            let z = illnessUp ? dev.z : -dev.z   // HRV drop is illness-ward → negate
            return (IllnessSignalEngine.SignalReading(zIllnessward: z), state.trusted)
        }

        let rhr = signal({ $0.restingHr.map(Double.init) }, cfgKey: "resting_hr", illnessUp: true)
        let hrv = signal({ $0.avgHrv }, cfgKey: "hrv", illnessUp: false)
        let resp = signal({ $0.respRateBpm }, cfgKey: "resp", illnessUp: true)
        // Skin-temp deviation: a stored °C delta. Build a small zero-centred state from its own recent
        // spread so a +0.6 °C reads as a meaningful z without needing a separate baseline column.
        var skin: (IllnessSignalEngine.SignalReading, Bool)? = nil
        if let recentSkin = rm({ $0.skinTempDevC }) {
            let z = recentSkin / 0.3     // ~0.3 °C ≈ one personal spread (matches skin_temp floorSpread)
            skin = (IllnessSignalEngine.SignalReading(zIllnessward: z), true)
        }

        let inputs = IllnessSignalEngine.Inputs(
            restingHR: rhr?.0, skinTemp: skin?.0, hrv: hrv?.0, respiration: resp?.0)
        // baselineTrusted: require the HRV/RHR baselines to be trusted before the engine may raise.
        let trusted = (rhr?.1 ?? false) || (hrv?.1 ?? false)
        let context = IllnessSignalEngine.Context(
            alcohol: alcohol, hardOrLateWorkout: hardOrLateWorkout,
            alreadyUnwell: alreadyUnwell, baselineTrusted: trusted)

        // Caller-rendered phrases for the signals that fire (the engine surfaces only the firing ones).
        var labels: [String: String] = [:]
        if let r = rm({ $0.restingHr.map(Double.init) }), let b = mean(base.compactMap { $0.restingHr.map(Double.init) }), r > b {
            labels["restingHR"] = "RHR +\(Int((r - b).rounded()))"
        }
        if let r = rm({ $0.avgHrv }), let b = mean(base.compactMap { $0.avgHrv }), b > 0, r < b {
            labels["hrv"] = "HRV −\(Int(((1 - r / b) * 100).rounded()))%"
        }
        if let r = rm({ $0.skinTempDevC }), r > 0 {
            labels["skinTemp"] = "skin temp +\(String(format: "%.1f", r)) °C"
        }
        if let r = rm({ $0.respRateBpm }), let b = mean(base.compactMap { $0.respRateBpm }), r > b {
            labels["respiration"] = "respiration up"
        }

        let result = IllnessSignalEngine.evaluate(inputs, context: context, firedLabels: labels)
        illnessSignal = result
        // The amber banner string reflects the raised / already-unwell levels only (the calmer levels
        // surface in the Health hub's Heads-Up card, never as a scary banner).
        healthAlert = (result.level == .raised || result.level == .alreadyUnwell) ? result.copy : nil
        if let alert = healthAlert, previous == nil {
            IllnessNotifier.post(alert)
        }
    }

    /// Re-run the illness watch over the cached history. Called when the Automations toggle
    /// flips — the repo.$days sink only fires on data changes, so a flip would otherwise wait
    /// for the next refresh.
    func reevaluateIllness() {
        evaluateIllness(repo.days)
    }

    // MARK: - v5 skin-temp suite engines (cycle phase + body clock)
    //
    // Run in the analytics pass (IntelligenceEngine calls this after it persists the night's scores) so
    // the Health hub's skin-temp cards read a ready snapshot. Both are pure StrandAnalytics engines fed
    // from the merged daily history; cycle awareness is gated behind the opt-in flag (default OFF) and
    // never computes — let alone surfaces — until the user turns it on.

    /// UserDefaults key for the cycle-awareness opt-in (default OFF — the most sensitive health category,
    /// manual-first). The Settings toggle + the card's opt-in CTA both write this single key.
    static let cycleAwarenessKey = "noopCycleAwareness"
    var cycleAwarenessEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.cycleAwarenessKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.cycleAwarenessKey) }
    }

    /// Recompute the v5 skin-temp suite snapshots (cycle phase + body clock) from the current history.
    /// Called from the analytics pass and when the cycle opt-in flips. Honest-nil throughout: cycle is
    /// nil unless opted in; circadian is nil unless a usable activity profile exists.
    func refreshV5Signals() async {
        await computeCyclePhase()
        await computeCircadianPhase()
    }

    /// Cycle-phase awareness from the nightly skin-temperature shift (+ luteal RHR rise / HRV drop). Each
    /// night is z-scored against the personal baseline, then `CyclePhaseEngine.classify` reads the run.
    /// Gated behind the opt-in flag; clears the published result the moment it's turned off.
    private func computeCyclePhase() async {
        guard cycleAwarenessEnabled else { cyclePhase = nil; cycleCurve = []; return }
        let days = repo.days
        guard let tempCfg = Baselines.metricCfg["skin_temp"],
              let rhrCfg = Baselines.metricCfg["resting_hr"],
              let hrvCfg = Baselines.metricCfg["hrv"] else { return }

        // The nightly absolute skin-temp mean isn't in repo.days (only the °C DEVIATION is), so z-score
        // the deviation against its own folded spread — a zero-centred personal baseline. RHR + HRV
        // z-score their raw columns. Oldest→newest.
        let sorted = days.sorted { $0.day < $1.day }
        let skinState = Baselines.foldHistory(sorted.map { $0.skinTempDevC }, cfg: tempCfg)
        let rhrState = Baselines.foldHistory(sorted.map { $0.restingHr.map(Double.init) }, cfg: rhrCfg)
        let hrvState = Baselines.foldHistory(sorted.map { $0.avgHrv }, cfg: hrvCfg)

        var nights: [CyclePhaseEngine.Night] = []
        var curve: [Double] = []
        for d in sorted {
            let tempZ = d.skinTempDevC.map { skinState.usable ? Baselines.deviation($0, state: skinState).z : $0 / 0.3 }
            let rhrZ = (rhrState.usable ? d.restingHr.map { Baselines.deviation(Double($0), state: rhrState).z } : nil)
            let hrvZ = (hrvState.usable ? d.avgHrv.map { Baselines.deviation($0, state: hrvState).z } : nil)
            nights.append(CyclePhaseEngine.Night(day: d.day, tempZ: tempZ, rhrZ: rhrZ, hrvZ: hrvZ))
            if let fused = CyclePhaseEngine.fusedIndex(tempZ: tempZ, rhrZ: rhrZ, hrvZ: hrvZ) { curve.append(fused) }
        }
        cyclePhase = CyclePhaseEngine.classify(nights, baselineUsable: skinState.usable)
        cycleCurve = curve
    }

    /// Body-clock phase estimate. Builds a coarse per-hour activity profile from the last ~14 days of
    /// downsampled HR buckets (HR amplitude is a usable rest/activity rhythm proxy when raw motion isn't
    /// to hand), then fits the cosinor. nil when there isn't enough to read.
    private func computeCircadianPhase() async {
        let now = Int(Date().timeIntervalSince1970)
        let from = now - 14 * 86_400
        let buckets = await repo.hrBuckets(from: from, to: now, bucketSeconds: 3_600)
        guard buckets.count >= 24 else { circadianPhase = nil; return }
        let tz = TimeZone.current.secondsFromGMT()
        // Pool HR by LOCAL hour-of-day → mean bpm per hour as the activity proxy (higher HR ≈ more active).
        var sums = [Double](repeating: 0, count: 24)
        var counts = [Int](repeating: 0, count: 24)
        var daySet = Set<Int>()
        for b in buckets {
            let local = b.ts + tz
            let hour = (local % 86_400 + 86_400) % 86_400 / 3_600
            sums[hour] += b.bpm; counts[hour] += 1
            daySet.insert(local / 86_400)
        }
        let bins: [CircadianEngine.ActivityBin] = (0..<24).compactMap { h in
            counts[h] > 0 ? CircadianEngine.ActivityBin(hour: Double(h), activity: sums[h] / Double(counts[h])) : nil
        }
        guard bins.count >= 6 else { circadianPhase = nil; return }
        // Habitual wake from the most recent night's banked wake, falling back to a 07:00 default.
        let wakeHour = habitualWakeHour() ?? 7.0
        circadianPhase = CircadianEngine.estimatePhase(
            bins: bins, daysObserved: daySet.count, habitualWakeHour: wakeHour)
    }

    /// A coarse habitual wake hour (local) from the most recent banked sleep session's end time, for the
    /// circadian schedule-offset comparison. nil when no sleep is banked.
    private func habitualWakeHour() -> Double? {
        guard let last = repo.sleeps.last else { return nil }
        let tz = TimeZone.current.secondsFromGMT()
        let local = (last.endTs + tz) % 86_400
        return Double((local + 86_400) % 86_400) / 3_600.0
    }
}

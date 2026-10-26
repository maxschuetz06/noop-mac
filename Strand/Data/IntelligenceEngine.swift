import Foundation
import Combine
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// On-device "intelligence": the app adapter around `RecomputePipeline` (StrandAnalytics), which computes
/// recovery / day-strain / sleep from the raw strap streams using the same model shape WHOOP uses (HRV vs
/// personal baseline ~60%, resting HR ~20%, sleep ~15%, respiration ~5%; strain 0–21 from cardiovascular
/// load). This is what makes NOOP independent of WHOOP's cloud — for any day the strap collected raw data
/// with NOOP connected, NOOP scores it itself rather than relying on the values WHOOP computed in the
/// imported CSV. The adapter owns scheduling (the `computing` lock, one-shot passes), the profile and
/// settings snapshot, and publishing the results.
@MainActor
final class IntelligenceEngine: ObservableObject {
    private let repo: Repository
    private let profile: ProfileStore
    private let deviceId: String

    @Published var results: [Computed] = []      // newest first
    @Published var computing = false
    @Published var note: String?

    typealias Computed = RecomputedDay

    /// Optional sink for the per-day scoring diagnostic, fed line-by-line into the SAME shareable strap
    /// log the user already exports (PII-scrubbed by `LiveState.append(log:)`). Defaults to nil so the
    /// engine stays testable with no UI; `AppModel` wires it to `live.append(log:)`. Each line is a
    /// concise, counts-only summary ("sleep day=… totalSleepMin=… matched=… source=…") so the next bug
    /// report ships proof of what was computed per day — addressing the project's log-failures-not-
    /// successes blind spot and the data needed to settle "Rest repeats across days". (Sleep overhaul §2.5.)
    var diagnosticSink: ((String) -> Void)?

    init(repo: Repository, profile: ProfileStore, deviceId: String) {
        self.repo = repo; self.profile = profile; self.deviceId = deviceId
    }

    /// Median of a list (0 when empty) — used to denoise the 7-day resting-HR for Fitness Age.
    static func medianOf(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// UserDefaults flag guarding the one-shot #313 full-history Effort rescore (below). Set once the
    /// pass completes so it never re-runs.
    static let effortRescoreFlagKey = "intelligence.effortRescore.v313.done"

    /// One-shot, on-upgrade FULL-history Effort rescore (#313 PART B). The Effort hero gauge + numbers
    /// moved from the old 0–21 axis to NOOP's own 0–100 axis. On-device computed rows since v2.6.1
    /// already store 0–100, but rows the engine computed on an OLDER build (capped at `maxDays` per run,
    /// so deep history was never revisited) may still hold 0–21 strain.
    ///
    /// The SAFE fix is to recompute strain FROM SOURCE for every day with raw HR — those regenerate at
    /// 0–100 with NO double-rescale risk — rather than a blind `strain*21→100` multiply that would
    /// double-rescale the large population already on 0–100 (→ ~0–476). We do that by running the normal
    /// `analyzeRecent` once with the `maxDays` cap lifted to the full history, then persist a flag so it
    /// runs exactly once. IMPORTED rows are never rewritten here (the engine only ever writes under the
    /// "-noop" computed source) — those are handled by re-import. A day already on 0–100 is recomputed
    /// from the same raw HR and lands on 0–100 again: UNCHANGED axis (verified by test).
    func runEffortRescoreIfNeeded(historyDays: Int = 4000) async {
        guard !UserDefaults.standard.bool(forKey: Self.effortRescoreFlagKey) else { return }
        await analyzeRecent(maxDays: historyDays)
        // Only mark done if the pass actually completed (wasn't skipped because another tick held the
        // `computing` lock). `computing` is false here once analyzeRecent's `defer` has run; a skipped
        // call returns with `note` unset by it. Use the lock state: if a concurrent run was in progress
        // the flag stays unset so the next launch retries — cheap, and correctness over a one-time cost.
        if !computing { UserDefaults.standard.set(true, forKey: Self.effortRescoreFlagKey) }
    }

    /// UserDefaults flag guarding the one-shot #547 implausible-timestamp DB heal (below). Set once the
    /// heal completes so it never re-runs.
    static let timestampHealFlagKey = "intelligence.timestampHeal.v547.done"

    /// #547 RE-POLLUTION re-arm: a one-shot heal isn't enough when a strap with a WANDERING clock keeps
    /// re-sending bad-dated records across syncs. Whenever a sync's ingest gate drops implausible records
    /// (the strap demonstrably has a bad clock THIS session), `BLEManager` sets this pending flag so the
    /// next analyze tick re-runs the purge — clearing any pollution that slipped in on an OLDER build whose
    /// gate was weaker, rather than permanently gating behind the one-shot `done` flag. Cleared once the
    /// re-heal runs. Pure UserDefaults so the BLE layer can set it without an engine reference.
    static let timestampHealPendingKey = "intelligence.timestampHeal.v547.pending"

    /// Mark the #547 heal as needing a re-run because a sync just dropped implausible (bad-clock) records.
    /// Called from `BLEManager.exitBackfilling` (no engine handle there); the next `runTimestampHealIfNeeded`
    /// honours it even after the one-shot `done` flag is set.
    static func requestTimestampReheal() {
        UserDefaults.standard.set(true, forKey: timestampHealPendingKey)
    }

    /// One-shot, on-upgrade heal of a database polluted by a bad-clock strap (#547, pikapik). The ingest
    /// gate now keeps garbage-timestamped records out, but a user who synced on an older build already has
    /// rows dated to scattered garbage (far-past, a bogus 2027, FUTURE dates) — which made one ~12h block
    /// re-attribute to every day (the repeated totalSleepMin=721 across many days) and a future row surface
    /// as the Today "last night" carry-over. This purges those rows ONCE, then rescores from the surviving
    /// real raw data so the genuine days recompute cleanly. Idempotent (a clean DB deletes nothing) and
    /// re-running is harmless, but a persisted flag skips it on every later launch. Runs BEFORE the normal
    /// `analyzeRecent` loop so the rescore it triggers operates on an already-cleaned DB.
    func runTimestampHealIfNeeded(historyDays: Int = 4000) async {
        // Run when the one-shot heal hasn't run yet OR a sync just flagged a re-heal (#547 re-pollution): a
        // wandering-clock strap re-sends bad-dated records across syncs, so a single on-upgrade pass can't
        // be the only line of defence. The pending flag is cleared below once the re-heal completes.
        let pending = UserDefaults.standard.bool(forKey: Self.timestampHealPendingKey)
        guard pending || !UserDefaults.standard.bool(forKey: Self.timestampHealFlagKey) else { return }
        guard let store = await repo.storeHandle() else { return }   // no store yet → retry next launch
        let result: WhoopStore.TimestampHealResult
        do {
            result = try await store.healImplausibleTimestamps()
        } catch {
            NSLog("IntelligenceEngine: timestamp heal (#547) FAILED — \(error); will retry next launch")
            return   // leave the flag unset so a transient failure retries
        }
        if result.didChange {
            diagnosticSink?("Heal(#547): purged \(result.rawRowsDeleted) raw + \(result.computedRowsDeleted) computed row(s) with implausible (bad-clock) timestamps; rescoring the real days.")
            // Recompute the affected real days from the surviving raw rows so the polluted (e.g. 721)
            // blocks regenerate cleanly. The dashboard refresh happens inside analyzeRecent on persist.
            await analyzeRecent(maxDays: historyDays)
            // Only mark done once the rescore actually ran (wasn't skipped by a concurrent tick holding
            // the `computing` lock), so a skipped pass retries next launch — correctness over a one-time cost.
            guard !computing else { return }
        }
        UserDefaults.standard.set(true, forKey: Self.timestampHealFlagKey)
        // Clear the re-pollution request now that this re-heal has run — a future bad-clock sync re-arms it.
        UserDefaults.standard.set(false, forKey: Self.timestampHealPendingKey)
    }

    /// Compute on-device scores for each of the last `maxDays` that actually has raw HR data, persist them
    /// under the computed ("-noop") source and refresh the dashboard. Skipped while a run is in progress.
    func analyzeRecent(maxDays: Int = 21) async {
        guard !computing else { return }
        guard let store = await repo.storeHandle() else { note = "No on-device store yet."; return }
        computing = true
        defer { computing = false }

        let host = PipelineHost(repo: repo, diagnosticSink: diagnosticSink)
        let outcome = await RecomputePipeline.run(recomputeRequest(maxDays: maxDays), store: store, host: host)
        if let steps = outcome.stepsCalibration {
            // Mirror the fit (or the #589 "need N more days" progress) so the Settings/Steps UI can show it.
            profile.stepsCalibrationCoefficient = steps.coefficient
            profile.stepsCalibrationSampleDays = steps.sampleDays
            profile.stepsCalibrationConfidence = steps.confidence
            profile.stepsCalibrationManual = steps.manual
        }
        results = outcome.days
        note = outcome.days.isEmpty
            ? "No scored nights yet. Wear the strap with NOOP connected overnight and the engine will score your charge, effort and rest itself, no WHOOP cloud required."
            : nil

        // Reload the dashboard caches so the freshly computed scores show up immediately.
        if !outcome.days.isEmpty { await repo.refresh() }
    }

    /// Snapshot of the profile and settings the run depends on.
    private func recomputeRequest(maxDays: Int) -> RecomputeRequest {
        let user = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                               age: Double(profile.age), sex: profile.sex,
                               stepTicksPerStep: profile.stepTicksPerStep)
        var request = RecomputeRequest(
            deviceId: deviceId, now: Int(Date().timeIntervalSince1970), timeZone: .current, maxDays: maxDays,
            profile: RecomputeProfile(user: user, waistCm: profile.waistCm, hrMaxOverride: profile.hrMaxOverride,
                                      hrMax: profile.hrMax, stepsManualOverride: profile.stepsManualOverride))
        request.hrvBaselineEpoch = Baselines.hrvBaselineEpoch()
        request.recoveryBaselineEpoch = Baselines.recoveryBaselineEpoch()
        request.useSleepStagerV2 = PuffinExperiment.experimentalSleepV2Enabled
        return request
    }
}

/// The app state the pipeline reaches back into mid-run, kept on the main actor where `Repository` and
/// the strap-log sink live.
@MainActor
private struct PipelineHost: RecomputeHost {
    let repo: Repository
    let diagnosticSink: ((String) -> Void)?

    func selfHealEditedStages(from: Int, to: Int) async -> [CachedSleepSession] {
        await repo.selfHealEditedStages(from: from, to: to)
    }

    func dismissedSleepWindows() async -> [(start: Int, end: Int)] { repo.dismissedSleepWindows() }

    func log(_ line: String) async { diagnosticSink?(line) }
}

extension DayProvenance {
    /// The badge shown on the By-Day card. Brand wording matches the rest of the app
    /// (SleepView "On-device"/"Whoop", Today "Apple Health"). NO em-dashes.
    var badge: String {
        switch self {
        case .computed:    return "On-device"
        case .whoopImport: return "Whoop"
        case .appleHealth: return "Apple Health"
        }
    }
}

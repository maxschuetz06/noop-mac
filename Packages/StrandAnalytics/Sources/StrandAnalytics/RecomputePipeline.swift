import Foundation
import WhoopProtocol
import WhoopStore

/// The on-device daily recompute: scores recovery / day-strain / sleep from the raw strap streams for each
/// of the last `maxDays` that has raw HR, and persists them under the computed ("-noop") source so the
/// whole dashboard reads them. Personal baselines are folded from the imported history PLUS the nights
/// scored here, so even a BLE-only user crosses the baseline seed and recovery lights up.
///
/// Stages, in order: pass 1 scores every night against the imported-only baseline; the baselines are
/// re-seeded from imports + pass-1 nightly values; the host self-heals edited nights; pass 2 re-scores
/// only the baseline-dependent recovery; then dailies, weekly headlines, the steps estimate, sleep and
/// detected workouts are persisted and under-scored manual workouts re-scored.
public enum RecomputePipeline {
    public static func run(_ request: RecomputeRequest, store: WhoopStore,
                           host: any RecomputeHost) async -> RecomputeOutcome {
        let ctx = RecomputeContext(request: request, store: store, host: host)
        let hist = await ctx.importedHistory()
        let habitual = await habitualMidsleep(
            store: store, sources: HabitualMidsleepSources(importedId: request.deviceId, computedId: request.computedId),
            window: (ctx.nowLocalMidnight - request.maxDays * 86_400 - 30 * 3_600)...request.now,
            offsetSec: ctx.tzOffset)
        let nights = await ctx.scoreNights(baselines: RecomputeBaselines.importedOnly(hist, request: request),
                                           habitualMidsleepSec: habitual)
        let baselines = RecomputeBaselines.seeded(history: hist, nights: nights, request: request)
        let realWorkouts = await ctx.realWorkouts()
        let editedRows = await host.selfHealEditedStages(from: ctx.windowStart, to: request.now)
        let overlay = SleepEditOverlay(
            editsByStart: Dictionary(editedRows.map { ($0.startTs, $0) }, uniquingKeysWith: { a, _ in a }),
            habitualMidsleepSec: habitual, offsetSec: ctx.tzOffset)
        let provenance = await ctx.provenance(history: hist)
        let rescored = await ctx.rescore(nights, baselines: baselines, overlay: overlay,
                                         provenance: provenance, realWorkouts: realWorkouts)
        await ctx.persistDailies(rescored)
        await ctx.persistWeeklyHeadlines(rescored.dailies)
        let steps = await ctx.estimateSteps(scoredDailies: rescored.dailies)
        await ctx.persistSleepAndWorkouts(rescored, editedRows: editedRows, nights: nights)
        await ctx.rescoreManualWorkouts()
        return RecomputeOutcome(days: rescored.days, stepsCalibration: steps)
    }
}

/// Run-scoped values every stage shares.
struct RecomputeContext {
    let request: RecomputeRequest
    let store: WhoopStore
    let host: any RecomputeHost
    let tzOffset: Int
    /// `now` floored to LOCAL midnight (#277), so each day start lands on a local-day boundary and the day
    /// keys are LOCAL calendar days, consistent with the dashboard's local "today" lookup.
    let nowLocalMidnight: Int
    let owners: DayOwnerLookup

    init(request: RecomputeRequest, store: WhoopStore, host: any RecomputeHost) {
        self.request = request
        self.store = store
        self.host = host
        tzOffset = request.tzOffset
        nowLocalMidnight = RecomputePipeline.midnightLocal(request.now, offsetSec: tzOffset)
        owners = DayOwnerLookup(store: store, fallbackId: request.deviceId)
    }

    /// Start of the scored window for the workout de-dup, the edited-sleep self-heal and the re-detection
    /// cleanup: `maxDays` back from `now` plus the 30 h night read lead.
    var windowStart: Int { request.now - request.maxDays * 86_400 - 30 * 3_600 }

    /// The IMPORTED rows only (computed rows live under the sibling "-noop" id), over the full history,
    /// chronologically — NOT the merged dashboard cache, which back-fills imported fields from computed
    /// values and would contaminate this "imported-only" baseline. Mirrors Android `days(importedDeviceId)`.
    func importedHistory() async -> [DailyMetric] {
        ((try? await store.dailyMetrics(deviceId: request.deviceId, from: "0000-01-01", to: "9999-12-31")) ?? [])
            .sorted { $0.day < $1.day }
    }

    /// Real (non-detected) workouts in the scored window, used to skip detected bouts that duplicate them
    /// (#107): imported WHOOP + manual/re-labelled rows under the strap id, and Apple Health imports.
    func realWorkouts() async -> [WorkoutRow] {
        var rows = (try? await store.workouts(deviceId: request.deviceId, from: windowStart,
                                              to: request.now, limit: 100_000)) ?? []
        rows += (try? await store.workouts(deviceId: FusionSource.appleHealth.rawValue, from: windowStart,
                                           to: request.now, limit: 100_000)) ?? []
        return rows
    }

    /// Key-presence sets for the honest By-Day badge: a WHOOP export row (`history`) or an Apple Health
    /// daily row for a day means that import wins the dashboard merge over the computed row.
    func provenance(history: [DailyMetric]) async -> DayProvenanceSets {
        let apple = (try? await store.dailyMetrics(deviceId: FusionSource.appleHealth.rawValue,
                                                   from: "0000-01-01", to: "9999-12-31")) ?? []
        return DayProvenanceSets(importedWhoopDays: Set(history.map { $0.day }),
                                 appleHealthDays: Set(apple.map { $0.day }))
    }
}

struct DayProvenanceSets {
    let importedWhoopDays: Set<String>
    let appleHealthDays: Set<String>

    func classify(_ day: String) -> DayProvenance {
        DayProvenance.classify(day: day, importedWhoopDays: importedWhoopDays, appleHealthDays: appleHealthDays)
    }
}

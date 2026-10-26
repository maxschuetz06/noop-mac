import Foundation
import WhoopStore

/// Writes of a recompute run. Everything goes under the computed ("-noop") source, which the dashboard
/// merges UNDER imported rows, so a real WHOOP import always wins; imported rows are never touched.
extension RecomputeContext {
    /// UPSERT the freshly local-keyed dailies FIRST, then delete only the STALE computed rows in the
    /// window a prior (UTC-keyed, #277) run left behind. Upsert-before-delete keeps the row count
    /// monotonic during a recompute, so churn never masquerades as new history (#521). No-op in steady
    /// state. Rows older than the window keep their old keys (cosmetic, accepted).
    func persistDailies(_ r: RescoredNights) async {
        let computedId = request.computedId
        if !r.dailies.isEmpty { _ = try? await store.upsertDailyMetrics(r.dailies, deviceId: computedId) }
        let freshKeys = Set(r.dailies.map { $0.day })
        let existingWindow = (try? await store.dailyMetrics(deviceId: computedId, from: oldestDay, to: newestDay)) ?? []
        for stale in existingWindow where !freshKeys.contains(stale.day) {
            _ = try? await store.deleteDailyMetrics(deviceId: computedId, from: stale.day, to: stale.day)
        }
        if !r.restPoints.isEmpty { _ = try? await store.upsertMetricSeries(r.restPoints, deviceId: computedId) }
        if !r.skinAbsPoints.isEmpty { _ = try? await store.upsertMetricSeries(r.skinAbsPoints, deviceId: computedId) }
    }

    /// Oldest / newest LOCAL day key the run enumerates; "yyyy-MM-dd" sorts chronologically, so the
    /// string range IS a date range.
    var oldestDay: String {
        AnalyticsEngine.dayString(nowLocalMidnight - (request.maxDays - 1) * 86_400, offsetSec: tzOffset)
    }
    var newestDay: String { AnalyticsEngine.dayString(nowLocalMidnight, offsetSec: tzOffset) }

    /// Re-detected sleep that overlaps a hand-corrected night (#318) or a night the user DELETED (#68) is
    /// not re-inserted: a detected onset drifts as raw data arrives, so the twin would upsert as a second
    /// row and double-count. Then per-epoch motion (H8) for the KEPT sessions only (an absent series stays
    /// absent), and the detected workouts are replaced in the scored window so a drifting bout start
    /// can't orphan stale rows.
    func persistSleepAndWorkouts(_ r: RescoredNights, editedRows: [CachedSleepSession],
                                 nights: [ScoredNight]) async {
        let computedId = request.computedId
        let editedWindows = editedRows.map { (start: $0.effectiveStartTs, end: $0.endTs) }
        let skipWindows = editedWindows + (await host.dismissedSleepWindows())
        let kept = r.cachedSleep.filter { s in
            !skipWindows.contains { s.startTs < $0.end && $0.start < s.endTs }
        }
        if !kept.isEmpty { _ = try? await store.upsertSleepSessions(kept, deviceId: computedId) }
        let keptStarts = Set(kept.map { $0.startTs })
        var motionByStart: [Int: [Double]] = [:]
        for night in nights {
            for (start, motion) in night.sessionMotion where keptStarts.contains(start) {
                motionByStart[start] = motion
            }
        }
        for (start, motion) in motionByStart {
            _ = try? await store.persistSessionMotion(deviceId: computedId, sessionStart: start, motionEpochs: motion)
        }
        _ = try? await store.deleteWorkouts(deviceId: computedId, sport: "detected", from: windowStart, to: request.now)
        if !r.workoutRows.isEmpty { _ = try? await store.upsertWorkouts(r.workoutRows, deviceId: computedId) }
    }

    /// #137: a manual workout is scored from sparse live HR at save time (near-zero on a 5/MG). Once
    /// offloaded HR covers the window, re-score the under-scored ones — only when that is a genuine
    /// improvement, so a well-scored workout or a still-sparse window is a no-op.
    func rescoreManualWorkouts() async {
        let deviceId = request.deviceId
        let since = request.now - 14 * 86_400
        guard let rows = try? await store.workouts(deviceId: deviceId, from: since, to: request.now, limit: 200)
        else { return }
        let hrMax = Double(request.profile.hrMax)
        var updated: [WorkoutRow] = []
        for row in rows where row.source == "manual"
            && ManualWorkoutRescore.looksUnderScored(currentKcal: row.energyKcal) {
            guard let samples = try? await store.hrSamples(deviceId: deviceId, from: row.startTs,
                                                           to: row.endTs, limit: 20_000),
                  let s = ManualWorkoutRescore.scored(windowSamples: samples, profile: request.profile.user,
                                                      hrMax: hrMax),
                  ManualWorkoutRescore.improves(s, over: row.energyKcal)
            else { continue }
            updated.append(WorkoutRow(
                startTs: row.startTs, endTs: row.endTs, sport: row.sport, source: row.source,
                durationS: row.durationS, energyKcal: s.kcal, avgHr: s.avgHr, maxHr: s.maxHr,
                strain: s.strain, distanceM: row.distanceM, zonesJSON: row.zonesJSON, notes: row.notes))
        }
        if !updated.isEmpty { _ = try? await store.upsertWorkouts(updated, deviceId: deviceId) }
    }
}

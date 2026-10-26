import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

extension TodayView {
    // MARK: - Loading

    func loadAll() async {
        // 14-day sparklines — Whoop.
        sparks["recovery"]        = await sparkValues("recovery", source: "my-whoop", window: 14)
        sparks["strain"]          = await sparkValues("strain", source: "my-whoop", window: 14)
        sparks["sleep_total_min"] = await sparkValues("sleep_total_min", source: "my-whoop", window: 14)
        sparks["hrv"]             = await sparkValues("hrv", source: "my-whoop", window: 14)
        sparks["rhr"]             = await sparkValues("rhr", source: "my-whoop", window: 14)
        sparks["spo2"]            = await sparkValues("spo2", source: "my-whoop", window: 14)

        // 14-day sparklines — Apple Health.
        sparks["resp_rate"]   = await sparkValues("resp_rate", source: "apple-health", window: 14)
        sparks["steps"]       = await sparkValues("steps", source: "apple-health", window: 14)
        // Steps prefer the strap's own @57 daily total (no metricSeries — it lives on the daily row),
        // so a strap-only WHOOP 5/MG user gets a steps trend without Apple Health. Falls back to the
        // Apple Health series above when the strap supplied no steps (#276).
        let strapSteps = repo.days.suffix(14).compactMap { $0.steps.map(Double.init) }
        if !strapSteps.isEmpty { sparks["steps"] = strapSteps }
        sparks["weight"]      = await sparkValues("weight", source: "apple-health", window: 90)
        sparks["active_kcal"] = await sparkValues("active_kcal", source: "apple-health", window: 14)
        sparks["energy_kcal"] = await sparkValues("energy_kcal", source: "my-whoop", window: 14)

        // Imported-WHOOP per-day energy / max HR / avg HR (series-only fields), keyed by day.
        var imported: [String: [String: Double]] = [:]
        // STRICT imported read: `series` reads only the imported `my-whoop` metricSeries. `exploreSeries` would
        // also fold in the on-device computed series and the `activeKcalEst` daily column, so a strap-only
        // day would show the HR-based estimate captioned "WHOOP total".
        for key in ["energy_kcal", "max_hr", "avg_hr"] {
            let pts = await repo.series(key: key, source: Repository.whoopSource)
            imported[key] = Dictionary(pts.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        }
        importedDayValues = imported

        // Rest SCORE for the logical day. `exploreSeries` already merges imported + computed
        // `sleep_performance` (imported-wins), so a Bluetooth-only user sees the on-device Rest
        // composite and an importer sees the export's figure — exactly like the Rest detail screen.
        let restSeries = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })

        // Steps ESTIMATE per day (WHOOP 4.0 motion → calibrated steps). exploreSeries reads the computed
        // "-noop" metricSeries the IntelligenceEngine writes, exactly like the Explore "steps_est" metric.
        // Only consulted when a day has no REAL step count (see the .steps tile), so it never overrides a
        // measured value — it just fills the gap a 4.0 user would otherwise see as "—".
        let stepsEstSeries = await repo.exploreSeries(key: "steps_est", source: "my-whoop")
        stepsEstByDay = Dictionary(stepsEstSeries.map { ($0.day, Int($0.value.rounded())) },
                                   uniquingKeysWith: { _, last in last })
        // The selected day's Rest, falling back to the series tail only when today itself is selected —
        // a navigated past day with no Rest row shows "—" rather than borrowing the newest value.
        restScore = restByDay[selectedDayKey] ?? (selectedDayOffset == 0 ? restSeries.last?.value : nil)

        // Component 4 — resolve the REAL per-day merge winner for the selected day's derived scores. The
        // cross-source resolver applies the SAME imported-WHOOP > NOOP-computed > Apple-Health precedence
        // the dashboard merge uses, returning the source that actually supplied each day's value — so the
        // provenance badge reflects the truth (computed vs imported), never a blanket "on-device". Keyed by
        // metric so the Charge ring and Rest tile each badge their own winner.
        var provenance: [String: String] = [:]
        let recoveryResolved = await repo.resolvedSeries(key: "recovery", source: Repository.whoopSource)
        if let win = recoveryResolved.points.last(where: { $0.day == selectedDayKey })?.source {
            provenance["recovery"] = win
        }
        let restResolved = await repo.resolvedSeries(key: "sleep_performance", source: Repository.whoopSource)
        if let win = restResolved.points.last(where: { $0.day == selectedDayKey })?.source {
            provenance["sleep_performance"] = win
        }
        provenanceByMetric = provenance

        workouts = await repo.workoutRows()
        appleDays = await repo.appleDailyRows()
        // Mi Band (Mi Fitness import) — distinct days across its representative metric keys.
        let xSteps = await repo.series(key: "steps", source: "xiaomi-band")
        let xSleep = await repo.series(key: "sleep_total_min", source: "xiaomi-band")
        xiaomiDays = Set(xSteps.map(\.day) + xSleep.map(\.day)).count
        // Your cards (#582 / Design Reset): latest Stress / Fitness age / Vitality for the pinned home
        // cards. Same merged exploreSeries reads their detail screens use; nil simply hides that card.
        stressToday = (await repo.exploreSeries(key: "stress", source: "my-whoop")).last?.value
        fitnessAgeToday = (await repo.exploreSeries(key: "fitness_age", source: "my-whoop")).last?.value
        vitalityToday = (await repo.exploreSeries(key: "vitality", source: "my-whoop")).last?.value
        // Hydration card (opt-in): today's stored total + the sex/Effort goal. Only loaded when the
        // feature is on, so a disabled feature does zero work and the card stays hidden.
        if hydrationEnabled {
            hydrationTotalML = await repo.hydrationTotal(day: Repository.localDayKey(Date()))
            hydrationGoalML = repo.hydrationGoalML(profileSex: profile.sex)
        } else {
            hydrationTotalML = nil
            hydrationGoalML = nil
        }
        if let store = await repo.storeHandle() {
            let farFuture = Int(Date.distantFuture.timeIntervalSince1970)
            xiaomiSleeps = ((try? await store.sleepSessions(deviceId: "xiaomi-band", from: 0, to: farFuture, limit: 4000))?.count) ?? 0
        }

        // HR trend for the SELECTED day — 5-minute bucket means from that logical day's local midnight.
        // For today the window runs to now (an in-progress curve); for a navigated past day it runs the
        // full 24h to the next midnight. The logical day rolls at 04:00 (Repository.logicalDayStart), so
        // in the small hours after midnight today still starts at yesterday's midnight rather than
        // blanking to an empty new-calendar-day axis (#144).
        let dayStart = Calendar.current.startOfDay(for: selectedLogicalDay)
        let windowStart = Int(dayStart.timeIntervalSince1970)
        let windowEnd: Int = selectedDayOffset == 0
            ? Int(Date().timeIntervalSince1970)
            : Int((Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart).timeIntervalSince1970)
        hrPoints = await repo.hrBuckets(from: windowStart, to: windowEnd, bucketSeconds: 300)
            .map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm) }

        // #605: if today itself has no HR yet, land the dashboard on the most recent day that DOES have
        // data rather than presenting an empty graph (the top fresh-strap complaint). One-shot — changing
        // selectedDayOffset re-runs this load for the landed day via .task(id:); the guard stops it
        // re-evaluating, so the user can chevron back to today freely. Mirrors the Deep Timeline (#597).
        if !didAutoLandLatest, selectedDayOffset == 0, hrPoints.isEmpty,
           let latest = await repo.latestDataDayStart() {
            didAutoLandLatest = true
            let cal = Calendar.current
            let todayStart = cal.startOfDay(for: Repository.logicalDay(Date()))
            let latestStart = cal.startOfDay(for: latest)
            let back = cal.dateComponents([.day], from: latestStart, to: todayStart).day ?? 0
            if back > 0 { selectedDayOffset = back; return }
        }

        // In-progress Effort for TODAY (#402): score today's strain over the SAME window the HR curve
        // above shows (logical-day midnight → now) so the gauge tracks the day live instead of lagging
        // on the last persisted daily row. Uses the identical params the daily pass uses — Tanaka HRmax
        // from age, today's resting HR (else the default), sex — so the live number matches what the
        // engine will eventually persist. Below StrainScorer.minReadings the scorer returns nil and the
        // gauge falls back to the stored row (never a fabricated value); a navigated past day clears it.
        if selectedDayOffset == 0 {
            let todayHr = await repo.hrSamples(from: windowStart, to: windowEnd)
            let maxHR = profile.age > 0 ? StrainScorer.tanakaHRmax(age: Double(profile.age)) : nil
            let restHR = displayDay?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
            liveTodayStrain = StrainScorer.strain(todayHr, maxHR: maxHR, restingHR: restHR, sex: profile.sex)
        } else {
            liveTodayStrain = nil
        }
        // Pin the chart axis to the loaded window — today midnight→now, a past day the full 24h — so
        // a gap (e.g. a morning the strap wasn't banking) shows as empty space, not a late start.
        hrAxis = Date(timeIntervalSince1970: TimeInterval(windowStart))
            ... Date(timeIntervalSince1970: TimeInterval(windowEnd))

        // Sleep session overlapping the window. Uses `allSleepSessions` (BOTH the imported and the
        // on-device COMPUTED source) — a Bluetooth-only user's sleep lives under the computed source,
        // so the imported-only `sleepSessions` returns nothing. Keep blocks that actually overlap the
        // displayed window, then pick the LONGEST — the main night, not an afternoon nap. Drives the
        // HR sleep band + the recovery marker's wake anchor.
        sleepToday = await repo.allSleepSessions(days: selectedDayOffset + 2)
            .filter { $0.endTs > windowStart && $0.startTs < windowEnd }
            .max(by: { ($0.endTs - $0.startTs) < ($1.endTs - $1.startTs) })

        announceNewDaysIfNeeded()
    }

    /// Post a single honest `.reading` update to the inbox when a refresh brought in genuinely NEWER
    /// history (a WHOOP import or an overnight backfill that pushed the newest day forward). We compare
    /// the MAX day-key in `repo.days`, not the count (#521): a background recompute rebuilds the window
    /// via delete-then-reinsert, so the count momentarily dips and recovers, but the newest key is
    /// unchanged — so churn never fires this. The very first load (empty baseline) records the key
    /// silently; a navigated past day is ignored; the persisted key means a relaunch over the same
    /// history never re-announces. The count of newly-forward days is real (keys strictly above the
    /// previous max), never fabricated. Links to Trends.
    func announceNewDaysIfNeeded() {
        guard selectedDayOffset == 0 else { return }
        guard let newestKey = repo.days.map(\.day).max() else { return }   // no history yet
        let previousKey = lastAnnouncedDayKey
        defer { lastAnnouncedDayKey = newestKey }
        // No baseline yet → record silently, never announce historical data on first sight.
        guard !previousKey.isEmpty else { return }
        // Only a STRICTLY newer day-key counts as new history (yyyy-MM-dd sorts chronologically).
        guard newestKey > previousKey else { return }
        // Honest count of how many distinct days arrived ABOVE the old watermark.
        let added = Set(repo.days.map(\.day)).filter { $0 > previousKey }.count
        guard added > 0 else { return }
        updateStore.post(UpdateItem(
            kind: .reading,
            title: "New data added",
            message: added == 1 ? "1 new day of history landed. Open Trends to see it."
                                : "\(added) new days of history landed. Open Trends to see them.",
            deepLink: NavRouter.Destination.trends.rawValue
        ))
    }

    /// Trailing-window values for a metric — NO fall back to all history. The section is labelled a
    /// current trend ("14-day trend"), so a stale import must not render months-old points as if they
    /// were recent (same spirit as the #23 trailing-window fix). The window is generous enough that a
    /// genuinely sparse-but-recent series still renders — weight uses 90 days — and the Sparkline view
    /// already handles 0/1 points (empty / a single head dot), so no fallback is needed for layout.
    /// `latestString` reads `.last` of this windowed series, so a value older than the window shows
    /// "—" rather than a stale number under a Today tile (#49).
    func sparkValues(_ key: String, source: String, window: Int) async -> [Double] {
        let all = await repo.series(key: key, source: source)   // full history, asc
        guard !all.isEmpty else { return [] }
        return trailingWindow(all, days: window).map { $0.value }
    }

    /// Keep only points within the trailing `days` CALENDAR days ending TODAY (the phone's local date).
    /// Was anchored to the most-recent point, which on a stale import pinned the window to months-old
    /// data shown as a current trend (issue #23). ISO yyyy-MM-dd compares chronologically.
    func trailingWindow(_ points: [(day: String, value: Double)], days: Int) -> [(day: String, value: Double)] {
        let cutoffKey = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date())
        return points.filter { $0.day >= cutoffKey }
    }

    /// Latest value of a loaded sparkline series, formatted — for tiles whose hero
    /// can't be read off `appleDailyRows` (e.g. respiratory from apple-health).
    func latestString(_ key: String, decimals: Int, unit: String = "") -> String {
        guard let last = sparks[key]?.last else { return "—" }
        let n = decimals == 0 ? intString(last) : String(format: "%.\(decimals)f", last)
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    /// The Weight tile's display string + an honest caption ("from profile" only on the fallback).
    /// Prefers a real Apple-Health reading (today's daily, else the "weight" series' newest point so a
    /// sparse-but-recent value still renders); when neither carries a weight, falls back to the user's
    /// self-reported profile weight instead of "—" (#204). Always formatted through the shared
    /// `UnitFormatter` so the Imperial/Metric toggle reaches this tile. Mirrors Android's `weightTile`.
    func weightTile(_ appleWeightKg: Double?) -> (value: String, caption: String) {
        if let kg = appleWeightKg ?? sparks["weight"]?.last {
            return (UnitFormatter.massFromKilograms(kg, system: unitSystem), "latest")
        }
        return (UnitFormatter.massFromKilograms(profile.weightKg, system: unitSystem), "from profile")
    }
}

/// `.task(id:)` key combining the data refresh sequence with the selected day so a reload runs on
/// either a data change or a day-navigation change (the HR trend + Rest score are day-scoped).
struct TodayLoadKey: Equatable {
    let seq: Int
    let offset: Int
}

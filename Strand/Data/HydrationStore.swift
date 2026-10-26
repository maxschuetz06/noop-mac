import Foundation
import WhoopStore
import StrandAnalytics

// MARK: - Hydration tracker (MVP) — opt-in, local-only water logging
//
// The user logs water with three quick taps (Sip 30 ml / Cup 237 ml / Bottle 500 ml). The day TOTAL is
// banked in the generic metric-series tall table under a dedicated source/key — the SAME `metricSeries`
// table + `upsertMetricSeries` path every other generic daily series uses (no schema change). Because the
// table holds one row per (deviceId, day, key), a tap reads the day's running total and re-upserts
// total + amount, so the stored value IS "the sum of today's hydration logged for this local day".
//
// This is the BYTE-PARITY twin of the Android `com.noop.analytics.HydrationStore`: identical source id
// ("hydration"), identical key ("hydration"), identical additive-accumulation logic, identical 7-day
// history projection (one row per local calendar day, 0 for empty days, oldest first). Per-tap timestamps
// are intentionally NOT persisted on either platform — the day total is the source of truth and the MVP
// detail shows the honest day figure. Everything stays on-device; nothing is synced.

enum HydrationStore {
    /// Source/device id the hydration total is written under — its own local-only source so it is never
    /// confused with strap-imported or computed metrics. MUST match the Android `SOURCE_ID`.
    static let sourceId = "hydration"

    /// metricSeries key for the daily total (ml). MUST match the Android `KEY`.
    static let key = "hydration"

    /// Settings opt-in key (default OFF). The dashboard card + detail are hidden while this is false.
    /// MUST match the Android `NoopPrefs.KEY_HYDRATION_TRACKING` so the toggle reads the same on both.
    static let enabledKey = "noop.hydrationTracking"
}

// MARK: - Logging + read seam (Repository extension)

extension Repository {

    /// The total fluid (ml) logged for a local day (yyyy-MM-dd), or 0 when nothing has been logged that
    /// day. The single row's value IS the day total (additive upsert). Mirrors Android `HydrationStore.total`.
    func hydrationTotal(day: String) async -> Double {
        guard let store = await storeHandle() else { return 0 }
        let pts = (try? await store.metricSeries(deviceId: HydrationStore.sourceId,
                                                 key: HydrationStore.key,
                                                 from: day, to: day)) ?? []
        return pts.first?.value ?? 0
    }

    /// Log `amountMl` of fluid for `day` (defaults to today's local day). Reads the day's current total
    /// and upserts total + amount, so repeated taps accumulate. A non-positive amount is a no-op. Returns
    /// the new day total (ml). Additive by design — each tap is a quick-add, like the WHOOP buttons.
    /// Mirrors Android `HydrationStore.log`.
    @discardableResult
    func logHydration(amountMl: Int, day: String? = nil) async -> Double {
        let dayKey = day ?? Repository.localDayKey(Date())
        guard amountMl > 0, let store = await storeHandle() else { return await hydrationTotal(day: dayKey) }
        let current = await hydrationTotal(day: dayKey)
        let next = current + Double(amountMl)
        _ = try? await store.upsertMetricSeries(
            [MetricPoint(day: dayKey, key: HydrationStore.key, value: next)],
            deviceId: HydrationStore.sourceId)
        return next
    }

    /// The last `days` local-day totals up to and including today, OLDEST first, as (day, ml) pairs — one
    /// entry per calendar day with 0 for days that have no log. Backs the 7-day mini bar history. `days`
    /// is clamped ≥ 1. Mirrors Android `HydrationStore.history` (a single ranged read projected onto the
    /// full day grid so empty days read as 0 rather than vanishing).
    func hydrationHistory(days: Int = 7, now: Date = Date()) async -> [(day: String, value: Double)] {
        let n = max(1, days)
        let from = now.addingTimeInterval(-Double(n - 1) * 86_400)
        let fromKey = Repository.localDayKey(from)
        let toKey = Repository.localDayKey(now)
        let byDay: [String: Double]
        if let store = await storeHandle() {
            let pts = (try? await store.metricSeries(deviceId: HydrationStore.sourceId,
                                                     key: HydrationStore.key,
                                                     from: fromKey, to: toKey)) ?? []
            byDay = Dictionary(pts.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        } else {
            byDay = [:]
        }
        return (0..<n).map { i in
            let key = Repository.localDayKey(now.addingTimeInterval(-Double(n - 1 - i) * 86_400))
            return (key, byDay[key] ?? 0)
        }
    }

    /// Today's hydration goal (ml) from the profile sex + today's Effort score. Pure math in
    /// `HydrationGoal`; this just feeds it the live inputs (today's `strain` is NOOP's 0–100 Effort).
    func hydrationGoalML(profileSex: String) -> Int {
        HydrationGoal.dailyGoalML(sex: profileSex, effort: today?.strain)
    }
}

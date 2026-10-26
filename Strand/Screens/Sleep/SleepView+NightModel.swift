import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

extension SleepView {
    // MARK: - Memoization plumbing

    /// A cheap fingerprint of the repo inputs this screen derives from. Recomputed every
    /// render but only contains counts + the identity of the newest/oldest rows, so equality
    /// is fast. When it changes we know `repo.days`/`repo.sleeps` actually changed and the
    /// memoized `model` must be rebuilt; otherwise hover/animation/1Hz HR re-renders are free.
    var dataKey: SleepInputKey {
        SleepInputKey(
            loaded: repo.loaded,
            daysCount: repo.days.count,
            sleepsCount: repo.sleeps.count,
            firstDay: repo.days.first?.day,
            lastDay: repo.days.last?.day,
            lastDayUpdated: repo.days.last,
            lastSleep: repo.sleeps.last,
            refreshSeq: repo.refreshSeq)
    }

    /// Build every expensive derivation exactly once. Called only when `dataKey` changes,
    /// so each full pass over repo.days / repo.sleeps runs once per data change rather than
    /// once per render. Returns nil when there is no usable latest night (renders empty state).
    func buildModel() -> SleepModel? {
        guard let night = latestNight else { return nil }
        return SleepModel(
            night: night,
            intervals: night.intervals,
            isPersistedHypnogram: (night.realSegments?.count ?? 0) >= 2,
            performance: performanceSeries,
            performanceSource: SleepPerformanceResolver.source(of: performancePoints),
            efficiency: efficiencySeries,
            consistency: consistencySeries,
            hoursVsNeeded: hoursVsNeededSeries,
            restorative: restorativeSeries,
            respiratory: respiratorySeries,
            sleepDebt: sleepDebtSeries,
            typicalTotalMin: typicalTotalMin,
            typicalDeepMin: typicalStageMin(\.deepMin),
            typicalRemMin: typicalStageMin(\.remMin),
            typicalLightMin: typicalStageMin(\.lightMin),
            trendPoints: durationTrendPoints,
            sleepDebtLedger: debtLedger)
    }

    /// The rolling 14-night sleep-debt ledger from the cached daily metrics. Uses the
    /// SAME personal sleep need the tiles use (`sleepNeedMin`, ≥ 7.5 h, the per-user
    /// override over the 8 h default), measured against each night's `totalSleepMin`.
    /// Skips nights with no sleep (the analytics function does the skip). (#242)
    var debtLedger: SleepDebtLedger {
        SleepDebt.ledger(
            series: repo.days.map { (day: $0.day, totalSleepMin: $0.totalSleepMin) },
            needHours: sleepNeedMin / 60.0)
    }

    // MARK: - Derived model

    /// The most recent sleep, decoded into stage durations. TWO stagesJSON formats exist:
    /// imported nights store a dict of MINUTES {"light","deep","rem","awake"}; on-device computed
    /// nights store a SEGMENT ARRAY [{start,end,stage}] (AnalyticsEngine.encodeStages). Only the
    /// dict was decoded before, so a Bluetooth-only user's night vanished from this tab entirely
    /// while Intelligence showed it (#77). Computed nights also carry their REAL timeline now —
    /// the hypnogram draws genuine segments instead of the synthetic reconstruction.
    var latestNight: Night? { decodedNight(at: 0) }

    /// The browsable block list: every sleep session un-deduplicated (incl. same-day naps / split
    /// sleep). Falls back to `repo.sleeps` (one-per-night) until the fuller list loads, so the hero
    /// is never empty during the first frame. (#170)
    var navSessions: [CachedSleepSession] {
        allSessions.isEmpty ? repo.sleeps : allSessions
    }

    /// The browsable DAY list: every block grouped by the calendar day it ENDS on (matching the
    /// dashboard's per-night merge), newest day first, blocks within a day oldest→newest. Each day
    /// is ONE ◀/▶ stop, so a split-sleep day reads as a single night and the "N nights ago" label
    /// stays truthful — two blocks of the same day are never "1 night ago" AND "2 nights ago". (#170)
    var navDays: [[CachedSleepSession]] {
        navDaysCache.days(for: navSessions)
    }

    /// The day's MAIN sleep block — the night people mean by "last night" — and the rest (naps). (#518)
    /// A day can hold an overnight AND an afternoon nap (both end on the same calendar day, so both
    /// bucket here). The pick is the SINGLE shared selector (`SleepStageTotals.mainNightIndex`) the
    /// analytics rollup uses — the LEARNED-TIMING score (asleep span + alignment bonus), NOT a re-derived
    /// overnight gate — so the hero, the edit affordance, the analytics total, and the Sleep tab ALL
    /// resolve to the identical block (the whole point of #525/#547). Delegates to `mainNightSession`,
    /// passing the LEARNED habitual midsleep (the same value the engine threaded into the daily total) so
    /// a shift/late sleeper's hero and analytics total agree — not just at cold-start. (#547)
    func mainBlock(_ sessions: [CachedSleepSession]) -> CachedSleepSession? {
        SleepView.mainNightSession(sessions, habitualMidsleepSec: habitualMidsleepSec)
    }

    /// The device's current UTC offset (seconds east), evaluated once per pick. Feeds the selector's
    /// `offsetSec` so the timing test reads the user's clock via the SAME `offsetSec` math the engine
    /// uses (`SleepStageTotals.localSecOfDay`), instead of `Calendar.current.component(.hour:)` which was
    /// the duplicated, DST-fragile gate the audit flagged. (#547)
    static var tzOffsetSec: Int { TimeZone.current.secondsFromGMT() }

    /// The day's single WINNING main block — the durable-edit anchor (`editTarget`) and the one block whose
    /// learned-timing score won. Scores by learned timing on each block's EFFECTIVE onset (what the user
    /// sees) and returns the owning session. This is the BARE single-block pick (no gap-bridge), because the
    /// edit affordance writes against ONE real row so it must resolve to one block. The HERO display and the
    /// nap split do NOT use this alone: they use `mainNightGroup`, which bridges the winner's adjacent
    /// fragments (a wake gap shorter than `gapBridgeMaxMin`) into ONE night the way `AnalyticsEngine`
    /// does (#561), so a biphasic / briefly-interrupted night is shown as one continuous sleep instead of
    /// phantom naps (#555). `habitualMidsleepSec` is the SAME learned value the engine threads into the
    /// persisted totals (loaded via `repo.habitualMidsleepSec()`), so a shift/late sleeper's pick matches
    /// the analytics rollup; nil keeps the cold-start overnight-band bonus. (#525 / #547 / #561)
    static func mainNightSession(_ sessions: [CachedSleepSession],
                                 habitualMidsleepSec: Int? = nil) -> CachedSleepSession? {
        SleepStageTotals.mainNightIndex(
            sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec).map { sessions[$0] }
    }

    /// The day's MAIN-night GROUP — the winning block PLUS any adjacent fragments bridged into it (a wake
    /// gap shorter than `gapBridgeMaxMin`), so a briefly-interrupted / biphasic night reads as ONE
    /// continuous sleep exactly the way `AnalyticsEngine.analyzeDay` rolls it up for the daily total (#561).
    /// The hero aggregates this whole group and ONLY blocks outside it are naps. Without it the tab used the
    /// un-bridged single-block pick and rendered the bridged siblings as phantom naps (#555). A night with
    /// no bridgeable gap collapses to the single block `mainNightSession` picks, so the common case is byte-
    /// identical. Returns ascending by effective onset. (#561 / #555)
    static func mainNightGroup(_ sessions: [CachedSleepSession],
                               habitualMidsleepSec: Int? = nil) -> [CachedSleepSession] {
        guard let idx = SleepStageTotals.mainNightGroupIndices(
            sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec) else { return [] }
        return idx.map { sessions[$0] }.sorted { $0.effectiveStartTs < $1.effectiveStartTs }
    }

    /// Soft nap-duration hint retained for callers/tests; the nap CLASSIFICATION is now purely "not the
    /// chosen main block" (see `isNap`), never an independent duration/onset test. (#518/#547)
    static let napMaxHours: Double = 3.0
    /// Classify a block as a nap: it's a nap exactly when it is NOT the day's chosen main block. Derived
    /// from the pick (never an independent onset/duration gate), so the label can't contradict the
    /// selection — the contradiction the audit flagged. The main block is never a nap. (#518/#547)
    static func isNap(_ s: CachedSleepSession, main: CachedSleepSession?) -> Bool {
        guard let main else { return false }
        return s.startTs != main.startTs
    }

    // MARK: - Why-this-is-your-main-sleep explainer (COMPONENT 1, spec 2026-06-20)

    /// The verbatim reason copy for the displayed night, with {DUR} filled as "Xh Ym" from the chosen
    /// block's asleep duration — driven entirely by the foundation `MainNightReason`, so the explainer
    /// states exactly what the selector decided (never a re-derived guess). Resolved over the day's blocks
    /// via the same `mainNightSelection` API the analytics pick uses, with the SAME learned habitual the
    /// hero used, so the words match the block the hero shows. nil only when the day has no blocks. (C1)
    func mainSleepReasonText(_ night: Night) -> String? {
        guard let sel = SleepStageTotals.mainNightSelection(
            night.sourceBlocks.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: SleepView.tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec) else { return nil }
        let dur = durationText(sel.asleepMinutes)
        switch sel.reason {
        case .onlyBlock:
            return "This is your only sleep block today."
        case .longest:
            return "Picked as your main sleep because it was your longest block (\(dur))."
        case .longestNearUsual:
            return "Picked as your main sleep because it was your longest block (\(dur)), near your usual bedtime."
        case .alignedToUsual:
            return "Picked as your main sleep because it started near your usual sleep time."
        }
    }

    /// Build the hero `Night` for a day around its MAIN-night GROUP — the winning block PLUS any fragments
    /// a brief wake split it into, bridged the way `AnalyticsEngine.analyzeDay` bridges them (#561), so a
    /// biphasic / interrupted night shows as ONE continuous sleep whose total matches the day's headline.
    /// It does NOT merge the whole day: an afternoon nap sits OUTSIDE the bridged group (its gap exceeds
    /// `gapBridgeMaxMin`), so it never folds in and stays a nap (the impossible 1 AM→5 PM merge #518 guarded
    /// against). Stage minutes are SUMMED over the group (the inter-fragment wake gap belongs to no
    /// fragment, so it is excluded from the minutes exactly as the engine excludes it), the hypnogram lays
    /// each fragment's real timeline end-to-end, and `sourceBlocks` keeps every block so the naps card and
    /// the daily Main/Nap/Total summary can read them. A single-block day is byte-identical to the prior
    /// behaviour. Returns nil if the group decodes to no usable stages. (#170, #318, #518, #555, #561)
    func mergeDay(_ sessions: [CachedSleepSession]) -> Night? {
        let group = SleepView.mainNightGroup(sessions, habitualMidsleepSec: habitualMidsleepSec)
        // Earliest fragment's EFFECTIVE onset (corrected bedtime when present) to the latest wake. (#318)
        guard let first = group.first, let last = group.last else { return nil }
        let onset = first.effectiveStartTs, wake = last.endTs
        var stages = Stages(awake: 0, light: 0, deep: 0, rem: 0)
        var segs: [SleepInterval] = []
        // #407: lay the GROUP's per-epoch motion fragment-by-fragment in the SAME order the stage timeline
        // is laid, reading the already-chosen group's stored series (NOT a re-resolution). The detected key
        // (`startTs`, not `effectiveStartTs`) is the motion store's key. A fragment with no persisted series
        // contributes nothing; if NO fragment has one, `motionEpochs` stays empty → honest empty state.
        var motion: [Double] = []
        for frag in group {
            if let seg = decodeSegments(frag.stagesJSON, sessionStart: frag.effectiveStartTs), seg.stages.total > 0 {
                stages.awake += seg.stages.awake; stages.light += seg.stages.light
                stages.deep  += seg.stages.deep;  stages.rem   += seg.stages.rem
                for iv in seg.intervals {
                    segs.append(SleepInterval(stage: iv.stage, start: iv.start, end: iv.end))
                }
            } else if let st = decodeStages(frag.stagesJSON), st.total > 0 {
                stages.awake += st.awake; stages.light += st.light
                stages.deep  += st.deep;  stages.rem   += st.rem
            }
            if let m = motionByStart[frag.startTs] { motion.append(contentsOf: m) }
        }
        guard stages.asleep > 0 else { return nil }
        let eff = stages.total > 0 ? stages.asleep / stages.total : nil
        let synth = CachedSleepSession(startTs: onset, endTs: wake, efficiency: eff,
                                       restingHr: nil, avgHrv: nil, stagesJSON: nil)
        let realSegs = segs.count >= 2 ? segs.sorted { $0.start < $1.start } : nil
        return Night(session: synth, stages: stages, realSegments: realSegs, sourceBlocks: sessions,
                     motionEpochs: motion, habitualMidsleepSec: habitualMidsleepSec)
    }

    /// The real stored blocks composing the day at `offset` (for the stage-less stub Night, so its edit
    /// affordance still targets a real row). Empty when out of range.
    func dayBlocks(at offset: Int) -> [CachedSleepSession] {
        let days = navDays
        return offset >= 0 && offset < days.count ? days[offset] : []
    }

    /// The merged Night for the DAY `offset` stops back from the most recent (0 = last night).
    /// Backs the hero's ◀/▶ navigation via the `navNight` cache — JSON-decodes, so it only runs
    /// from `buildModel()` and the onChange handlers, never per render. (#160, #170)
    func decodedNight(at offset: Int) -> Night? {
        let days = navDays
        guard offset >= 0, offset < days.count else { return nil }
        return mergeDay(days[offset])
    }

    /// A synthetic session for the DAY `offset` stops back, spanning the MAIN block's window (not the
    /// whole day), for the honest no-stage-data header when the day's blocks don't decode to usable
    /// stages. Using the main block (#518) keeps the stub header on the real night rather than a
    /// 1 AM→5 PM overnight+nap span. (#160, #170)
    func sessionRow(at offset: Int) -> CachedSleepSession? {
        let days = navDays
        guard offset >= 0, offset < days.count, let main = mainBlock(days[offset]) else { return nil }
        return CachedSleepSession(startTs: main.effectiveStartTs, endTs: main.endTs,
                                  efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
    }
}

import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Local value types

/// Cheap, Equatable fingerprint of the repo inputs SleepView derives from. Two snapshots are
/// equal iff the data the screen reads is unchanged, so the heavy `SleepModel` rebuild is
/// skipped on the many `body` re-evaluations that don't touch sleep data.
struct SleepInputKey: Equatable {
    let loaded: Bool
    let daysCount: Int
    let sleepsCount: Int
    let firstDay: String?
    let lastDay: String?
    /// Newest day row (Equatable) — catches in-place edits to the latest day's values.
    let lastDayUpdated: DailyMetric?
    /// Newest sleep session (Equatable) — catches a re-import of the latest night.
    let lastSleep: CachedSleepSession?
    /// Bumped on every Repository.refresh — catches a re-import that changes only the
    /// imported metricSeries figures (importedSleep) without touching days/sleeps.
    let refreshSeq: Int
}

/// Memoized result of every expensive SleepView derivation. Built once per data change in
/// `buildModel()` and read by the subviews, so full passes over repo.days / repo.sleeps and
/// the Night.intervals reconstruction no longer run on every render.
struct SleepModel {
    /// (latest, typical mean, full history) per metric — mirrors SleepView.Metric.
    typealias Metric = (latest: Double?, typical: Double?, series: [Double])

    let night: Night
    /// Stage intervals for the hypnogram — computed once (Night.intervals is a computed
    /// property; it was previously re-derived on each access during render).
    let intervals: [SleepInterval]
    /// True when `intervals` are the stager's persisted per-epoch segments (on-device
    /// APPROXIMATE staging), not the synthesized architecture.
    let isPersistedHypnogram: Bool

    let performance: Metric
    /// Provenance of `performance.latest` — the day that figure was actually taken from.
    let performanceSource: SleepPerformanceSource
    let efficiency: Metric
    let consistency: Metric
    let hoursVsNeeded: Metric
    let restorative: Metric
    let respiratory: Metric
    let sleepDebt: Metric

    let typicalTotalMin: Double?
    let typicalDeepMin: Double?
    let typicalRemMin: Double?
    let typicalLightMin: Double?

    let trendPoints: [TrendPoint]

    /// Rolling 14-night sleep-debt ledger: Σ(slept − personal need) across the recent
    /// fortnight, with the per-night deltas behind it. Computed once per data change.
    let sleepDebtLedger: SleepDebtLedger
}

struct Stages {
    var awake: Double
    var light: Double
    var deep: Double
    var rem: Double
    /// All stages (includes awake) — total time-in-bed minutes.
    var total: Double { awake + light + deep + rem }
    /// Asleep time = total minus awake.
    var asleep: Double { light + deep + rem }
}

struct Night {
    let session: CachedSleepSession
    let stages: Stages
    /// The REAL per-segment timeline for on-device computed nights (nil for imported nights,
    /// whose export carries totals only — those keep the synthetic reconstruction below). (#77)
    var realSegments: [SleepInterval]? = nil
    /// The actual stored block(s) this merged Night was built from. `session` above is a SYNTHETIC
    /// merge for display; an edit must target a real row, so it resolves it from here by identity
    /// rather than re-scanning by wake time. (#318)
    var sourceBlocks: [CachedSleepSession] = []

    /// Per-epoch MOTION for the MAIN-night GROUP, laid fragment-by-fragment in the SAME order `intervals`
    /// lays the group's stage timeline (#407). Empty when no group fragment has a persisted `motionJSON`
    /// (older rows) — the Sleep tab then shows an honest empty state instead of a fabricated zero trace.
    /// This is read off the already-resolved group, NOT a re-resolution of the night.
    var motionEpochs: [Double] = []

    /// The LEARNED habitual midsleep (local time-of-day seconds) the owning view loaded for the user — the
    /// SAME value the engine threaded into the daily total — so `editTarget` resolves the SAME main block
    /// the hero and the analytics rollup did, for a shift/late sleeper too. nil = cold-start band. (#547)
    var habitualMidsleepSec: Int? = nil

    /// The real stored block a sleep-time edit writes against — the day's MAIN block, resolved by the
    /// SAME shared selector (`SleepView.mainNightSession` → `SleepStageTotals.mainNightIndex`) the hero,
    /// the naps card, and `AnalyticsEngine.analyzeDay` use, so all of them and the edit affordance agree
    /// (no re-derived overnight gate). Passes the same learned habitual the hero used, so the edit target
    /// matches the hero block even for a shift/late sleeper. Its `startTs` is a genuine detected key, so
    /// `applySleepEdit` matches. nil when there's no underlying block (a synthetic stub) — the edit
    /// affordance is then hidden. (#318, #518, #547)
    var editTarget: CachedSleepSession? {
        SleepView.mainNightSession(sourceBlocks, habitualMidsleepSec: habitualMidsleepSec)
    }

    /// The `startTs` of every block in the day's bridged MAIN-night GROUP (the winning block plus the
    /// fragments bridged into it, #561), so the naps card excludes ALL of them — only blocks OUTSIDE the
    /// group are naps. Without this the tab treated every block except the single winner as a nap and a
    /// biphasic night rendered as phantom naps. (#555)
    var mainGroupStarts: Set<Int> {
        Set(SleepView.mainNightGroup(sourceBlocks, habitualMidsleepSec: habitualMidsleepSec).map { $0.startTs })
    }

    /// Total time in bed in minutes (from reconstructed stages).
    var timeInBed: Double { stages.total }

    /// The wall-clock start of the night (for the Hypnogram's clock labels).
    var onsetDate: Date { Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs)) }

    /// Stage intervals laid end-to-end across the night, in seconds from start.
    /// On-device computed nights use their REAL timeline; imported nights are reconstructed
    /// from durations only (the export has no per-epoch timeline).
    var intervals: [SleepInterval] {
        if let real = realSegments, real.count >= 2 { return real }
        var t: TimeInterval = 0
        var out: [SleepInterval] = []
        func add(_ stage: SleepStage, _ minutes: Double) {
            guard minutes > 0 else { return }
            let secs = minutes * 60
            out.append(SleepInterval(stage: stage, start: t, end: t + secs))
            t += secs
        }
        // A plausible architecture: deep early, REM later, awake last.
        add(.light, stages.light * 0.4)
        add(.deep, stages.deep)
        add(.light, stages.light * 0.3)
        add(.rem, stages.rem)
        add(.light, stages.light * 0.3)
        add(.awake, stages.awake)
        return out
    }

    var onsetText: String { Night.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs))) }
    var wakeText: String { Night.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.endTs))) }
    var dateLabel: String { Night.dateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs))) }

    /// Date label that becomes a span when the night crosses midnight (onset on a different
    /// calendar day from wake) — e.g. "Fri 13 → Sat 14 Jun" — otherwise a single date. Lets an
    /// aggregated day that started the previous evening read honestly. (#170)
    var spanLabel: String {
        let onsetDay = Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs))
        let wakeDay  = Date(timeIntervalSince1970: TimeInterval(session.endTs))
        let cal = Calendar.current
        if cal.isDate(onsetDay, inSameDayAs: wakeDay) { return Night.dateFmt.string(from: onsetDay) }
        return "\(Night.spanFmt.string(from: onsetDay)) → \(Night.dateFmt.string(from: wakeDay))"
    }

    /// A unix-second timestamp as a device-locale clock string ("11:42 PM" / "23:42"). Shared so the nap
    /// rows format their windows identically to the Asleep/Woke row. (#508)
    static func clockString(_ ts: Int) -> String {
        timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    // Clock for the Asleep/Woke row — the times people read at a glance. The "jmm" skeleton
    // follows the device's 12-/24-hour setting ("11:42 PM" or "23:42") instead of forcing one
    // on everyone, matching the HR-tooltip / workout times (#337).
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()
    /// Onset side of a cross-midnight span — no month (the wake side carries it): "Fri 13".
    private static let spanFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d"; return f
    }()
}

// MARK: - navDays memo

/// Caches the "sessions grouped by the calendar day they end on" list. The input is compared by VALUE
/// (array equality, which short-circuits on an identical buffer) and the grouping depends on the current
/// time zone, so the cached list is returned only when the very same sessions are asked for in the same
/// zone — otherwise it is rebuilt with the original grouping, newest day first, blocks oldest→newest.
final class NavDaysCache {
    private var input: [CachedSleepSession]?
    private var zone = ""
    private var output: [[CachedSleepSession]] = []

    func days(for sessions: [CachedSleepSession]) -> [[CachedSleepSession]] {
        let cal = Calendar.current
        let zoneID = cal.timeZone.identifier
        if let input, zone == zoneID, input == sessions { return output }
        func endDay(_ s: CachedSleepSession) -> Date {
            cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
        }
        let groups = Dictionary(grouping: sessions, by: endDay)
        let built = groups.keys.sorted(by: >).map { key in
            (groups[key] ?? []).sorted { $0.effectiveStartTs < $1.effectiveStartTs }
        }
        input = sessions; zone = zoneID; output = built
        return built
    }
}

import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

extension TodayView {
    /// The logical day the selector resolves to: offset 0 is today's logical day (rolls at 04:00 like
    /// `repo.today`), past offsets count back from it. Presentation-only — used to pick which stored row
    /// is on screen and to anchor the HR-trend window. Mirrors Android TodayScreen.selectedDay.
    var selectedLogicalDay: Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: base) ?? base
    }
    /// The day key the day-scoped read-outs (Rest score, HR window, sleep band) key on. At offset 0 it
    /// follows `repo.today?.day` so it tracks the row the resolver actually surfaces — including the
    /// non-UTC pre-04:00 case (#304) where Today is the LOCAL-calendar-day row, not the logical-day one.
    /// Falls back to the logical key when no row is banked yet. Past offsets use the logical key directly.
    var selectedDayKey: String {
        if selectedDayOffset == 0, let todayKey = repo.today?.day { return todayKey }
        return Repository.localDayKey(selectedLogicalDay)
    }

    /// The DailyMetric shown for the selected day. Offset 0 prefers the live `repo.today` (so the small
    /// hours after midnight still show the logical day's banked row), past offsets look the stored row up
    /// by key. nil when no row exists for that day — every read-out then renders its honest empty state.
    var displayDay: DailyMetric? {
        if selectedDayOffset == 0 {
            return repo.today ?? repo.days.last(where: { $0.day == selectedDayKey })
        }
        return repo.days.last(where: { $0.day == selectedDayKey })
    }

    /// Recovery cold-start: recovery is nil until the HRV baseline crosses the seed gate
    /// (Baselines.minNightsSeed valid nights). While calibrating, this is the count of nights
    /// banked so far — it drives an honest "Calibrating, N of 4 nights" on the recovery ring,
    /// the synthesis card and the Key Metrics tile instead of a bare empty state. It self-clears
    /// the moment recovery populates, and never claims "calibrating" at/above the seed gate.
    /// Mirrors Android TodayScreen.recoveryCalibrationNights (7b5f212). Only meaningful for today —
    /// a past day with no recovery is missing data, not mid-calibration, so navigated days return nil.
    var recoveryCalibration: Int? {
        guard selectedDayOffset == 0 else { return nil }
        if derivedKey == todayInputKey, let d = derived { return d.calibration }
        return computeCalibration()
    }

    /// The most recent fully-SCORED recovery day to carry over on TODAY while tonight's recovery hasn't
    /// been computed yet (#543). Right after the logical-day rollover the new day has no recovery (the new
    /// night isn't scored until you wear it tonight), so a baseline-established user — past calibration,
    /// so `recoveryCalibration` is nil — saw the whole recovery side blank ("No Data" Charge AND blank
    /// HRV / resting-HR / respiratory / SpO₂ tiles + Synthesis) while live HR kept ticking, which reads
    /// as broken. This is the ONE prior row every recovery-derived read-out carries over from, the way
    /// WHOOP keeps showing last recovery until the new one lands. It NEVER fabricates a number for the new
    /// day — each carried tile shows the REAL prior value, labelled as prior, and any metric the prior row
    /// genuinely lacks still falls through to "—". Non-nil only when: it's today, today itself has no
    /// recovery, and we're not mid-calibration (calibration owns its own copy). Past offsets / scored
    /// today / mid-calibration all return nil so live behaviour is unchanged.
    var lastScoredRecoveryDay: DailyMetric? {
        TodayDisplayRules.lastScoredRecoveryDay(
            days: repo.days,
            selectedDayKey: selectedDayKey,
            isToday: selectedDayOffset == 0,
            todayScored: displayDay?.recovery != nil,
            isCalibrating: recoveryCalibration != nil)
    }

    /// "Last night · <date>" stamp for the carried-over recovery row, keyed on that scored day's own
    /// date. Shared by every carried recovery read-out so the prior-day provenance reads identically.
    func carriedCaption(_ prior: DailyMetric) -> String {
        "Last night · \(Self.lastChargeDateFmt(prior.day))"
    }

    /// The most recent SCORED Charge to carry over on TODAY (#543) — the prior row's recovery value plus
    /// its "Last night · <date>" caption. Derived from `lastScoredRecoveryDay` so Charge and every other
    /// recovery tile carry the SAME prior day; recovery is always present on that row by construction.
    var lastScoredCharge: (value: Double, caption: String)? {
        guard let prior = lastScoredRecoveryDay, let rec = prior.recovery else { return nil }
        return (rec, carriedCaption(prior))
    }

    // MARK: Component 2 — explained score states (calibrating / carriedLastNight / needsStrap)

    /// The Charge (recovery) score's explained state for the selected day. Built ENTIRELY from the
    /// bindings the rings/tiles already drive — today's recovery, the running calibration count, the
    /// #543 carry-over — re-expressed through the honest `MetricTileState` precedence so the hero/tile show
    /// a clear state, detail and next step rather than a bare blank when there's no number. `calibrating`
    /// reports the nights REMAINING (seed gate minus banked), never a fabricated value.
    var chargeScoreState: MetricTileState {
        MetricTileState.resolve(
            hasTodayValue: displayDay?.recovery != nil,
            calibratingNightsRemaining: recoveryCalibration.map { max(1, Baselines.minNightsSeed - $0) },
            carriedDate: lastScoredRecoveryDay.map { Self.lastChargeDateFmt($0.day) })
    }

    // MARK: Component 3 — recording status

    /// The strap's live recording state, mapped from the connection, the live heart-rate sample, and the
    /// last-sync timestamp. Only TODAY carries a recording chip (a navigated past day isn't "recording
    /// now"), so this returns the honest state at offset 0 and `nil` otherwise (the chip then isn't
    /// rendered). "Recording" requires BOTH a live connection AND a current live HR sample, so a connected
    /// strap that isn't yet streaming HR reads as a last-sync / not-recording state, not a false "Recording".
    var recordingState: RecordingState? {
        guard selectedDayOffset == 0 else { return nil }
        // #580 — a connected WHOOP 5/MG streaming live HR but offloading no history reads "Connected —
        // history sync is experimental on 5.0" rather than a WHOOP-4-style "not recording"/sync-error.
        // BLEManager only flips this true while connected + streaming, so it overrides the honest mapper.
        if live.connected && live.historySyncExperimental { return .historyExperimental }
        return RecordingState.resolve(connected: live.connected,
                                      heartRate: live.heartRate,
                                      lastSyncedAt: live.lastSyncedAt)
    }

    // MARK: Component 4 — provenance badge (the real per-day merge winner)

    /// The display name for a derived score's per-day merge winner ("On-device" / "Whoop" / "Apple
    /// Health"), or nil when no source supplied that metric for the selected day (the badge is then
    /// hidden rather than guessing). Delegates to the PURE `provenanceDisplayLabel` mapper so the
    /// raw-source-id → spec-label mapping unit-tests without the live view.
    func provenanceLabel(_ metricKey: String) -> String? {
        guard let raw = provenanceByMetric[metricKey] else { return nil }
        return Self.provenanceDisplayLabel(rawSource: raw, deviceId: repo.deviceId)
    }

    /// PURE mapper (unit-testable) — a raw resolver source id onto the spec's provenance labels, given
    /// the strap's real `deviceId`. The NOOP-computed strap sibling (`deviceId + "-noop"`) reads
    /// "On-device" (scored on THIS device from the raw strap stream); the imported strap source
    /// (`deviceId`, normally "my-whoop") reads "Whoop"; the Apple-Health source reads "Apple Health".
    /// Any other real source (Mi Band, Health Connect, nutrition) keeps its `FusionSource.displayName`
    /// — still the genuine merge winner, never a blanket claim.
    static func provenanceDisplayLabel(rawSource: String, deviceId: String) -> String {
        if rawSource == deviceId + "-noop" { return "On-device" }
        if rawSource == deviceId || rawSource == Repository.whoopSource { return "Whoop" }
        if rawSource == Repository.appleHealthSource { return "Apple Health" }
        // Fall back to the FusionSource display name for any other known source; else the raw id.
        return FusionSource(rawValue: rawSource)?.displayName ?? rawSource
    }

    /// The tint for a provenance badge — gold for Whoop, cyan for Apple Health, the positive status hue
    /// for on-device, matching the Data Sources footer so the same source reads the same colour on Today.
    func provenanceTint(_ metricKey: String) -> Color {
        switch provenanceLabel(metricKey) {
        case "Whoop":       return StrandPalette.accent
        case "Apple Health": return StrandPalette.metricCyan
        default:            return StrandPalette.statusPositive
        }
    }

    /// Parses a stored `yyyy-MM-dd` day key in the device-local zone (matching how DailyMetric.day
    /// is written) — local so a key never shifts a day under timezone conversion.
    static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    /// "d MMM" for a stored `yyyy-MM-dd` day key, used by the carried-over Charge caption (#543). Falls
    /// back to the raw key if it can't be parsed so the caption is never empty.
    ///
    /// Called from `chargeScoreState` / the carry-over captions on every body pass. Building a localized
    /// `DateFormatter` per call is by far the most expensive step there, so the formatted string is memoized
    /// per (locale, day key). The caption only depends on those two inputs, so the output is identical.
    static var lastChargeCaptions: [String: String] = [:]
    static func lastChargeDateFmt(_ dayKey: String) -> String {
        let locale = Locale.current
        let cacheKey = locale.identifier + "|" + dayKey
        if let hit = lastChargeCaptions[cacheKey] { return hit }
        guard let date = dayKeyParser.date(from: dayKey) else { return dayKey }
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("dMMM")
        let text = f.string(from: date)
        if lastChargeCaptions.count >= 512 { lastChargeCaptions.removeAll(keepingCapacity: true) }
        lastChargeCaptions[cacheKey] = text
        return text
    }

    /// On-device training-readiness synthesis (HRV / resting-HR / load). Read through the
    /// memoized cache so the full-history sort inside `evaluate` runs once per data change,
    /// not once per ~1 Hz `body` pass while HR streams.
    var readiness: ReadinessEngine.Readiness {
        if derivedKey == todayInputKey, let d = derived { return d.readiness }
        return computeReadiness()
    }

    // MARK: Memoization plumbing (absorbs the 1 Hz live-HR body flood)

    /// Cached expensive derivations and the inputs they were built from.
    struct TodayDerived { let readiness: ReadinessEngine.Readiness; let calibration: Int? }

    /// A cheap, O(1) fingerprint of the inputs `derived` depends on. Recomputed every render
    /// (and per accessor call), but it only holds counts + the identity of the first/last and
    /// today rows + the selected offset, so equality is fast and never walks the history.
    struct TodayInputKey: Equatable {
        let loaded: Bool
        let daysCount: Int
        let firstDay: String?
        let lastDay: DailyMetric?
        let today: DailyMetric?   // covers repo.today?.recovery (calibration) and day rollover
        let offset: Int
        let refreshSeq: Int
    }

    var todayInputKey: TodayInputKey {
        TodayInputKey(
            loaded: repo.loaded,
            daysCount: repo.days.count,
            firstDay: repo.days.first?.day,
            lastDay: repo.days.last,
            today: repo.today,
            offset: selectedDayOffset,
            refreshSeq: repo.refreshSeq)
    }

    func computeReadiness() -> ReadinessEngine.Readiness {
        // Carry-over (#543): Readiness anchors on the day whose row carries today's vitals. Normally that's
        // today's logical day; right after the rollover today has no scored row, so `evaluate` would read
        // `.insufficient` and the whole Readiness card would VANISH while live HR ticks — the same blank
        // the carried Charge/Synthesis avoid. So when carrying, anchor Readiness on the last scored day's
        // key instead (the section header then stamps "Last night · <date>"). Honest: it's the real prior
        // read, not a fabricated today's, and today's own readiness wins the instant tonight is scored.
        let anchor = lastScoredRecoveryDay?.day ?? Repository.logicalDayKey(Date())
        return ReadinessEngine.evaluate(days: repo.days, today: anchor)
    }

    func computeCalibration() -> Int? {
        guard selectedDayOffset == 0 else { return nil }
        return RecoveryScorer.calibrationNights(nightlyHrv: repo.days.map(\.avgHrv),
                                                hasRecovery: repo.today?.recovery != nil)
    }

    func buildDerived() -> TodayDerived {
        TodayDerived(readiness: computeReadiness(), calibration: computeCalibration())
    }

    /// Synthesis-card copy while the recovery baseline calibrates; nil otherwise. Built as
    /// LocalizedStringKey literals so the String Catalog picks up the %lld patterns.
    var calibrationStatus: LocalizedStringKey? {
        recoveryCalibration == nil ? nil : "Calibrating"
    }
    var calibrationDetail: LocalizedStringKey? {
        guard let n = recoveryCalibration else { return nil }
        return "Learning your baseline, \(n) of \(Baselines.minNightsSeed) nights."
    }
}

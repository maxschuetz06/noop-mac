import Foundation
import WhoopStore

/// Pure visibility / value-selection rules for the Today screen. Kept separate from `TodayView` so the
/// "show the user's values, nothing else" decisions are unit-testable without a Repository or a view.
enum TodayDisplayRules {

    // MARK: Coaching prose

    /// Coach-style prose cards on Today (the "Synthesis" read-out and the "Readiness" advice card). The
    /// app is a plain values display, so they are off. The engines behind them stay.
    static var coachingCardsVisible: Bool {
        false
    }

    // MARK: "Live now. Your scores are building." note

    /// Nights of merged history after which the "scores are building" note no longer applies.
    static let historyDaysEndingOnboarding = 14

    /// The first-run "Live now. Your scores are building… import your WHOOP export" note is only for a
    /// brand-new install on today with no score yet. It disappears once a WHOOP export is imported
    /// (`importedDays > 0`) or enough history exists, and stays gone once the user dismissed it.
    static func showScoresBuildingNote(isToday: Bool, todayHasRecovery: Bool, dismissed: Bool,
                                       importedDays: Int, historyDays: Int) -> Bool {
        guard isToday, !todayHasRecovery, !dismissed else { return false }
        if importedDays > 0 { return false }
        return historyDays < historyDaysEndingOnboarding
    }

    // MARK: Recovery state pill

    enum StatePill: Equatable {
        case solid
        case calibrating(nights: Int)
        case hidden
    }

    /// "Solid" with a score, "Calibrating, N of 4" only while the baseline really is forming
    /// (`calibrationNights` non-nil). A baselined user whose tonight simply isn't scored yet gets no pill
    /// (the old fallback claimed "Calibrating" next to 290 days of history).
    static func statePill(score: Double?, calibrationNights: Int?) -> StatePill {
        if score != nil { return .solid }
        if let n = calibrationNights { return .calibrating(nights: n) }
        return .hidden
    }

    // MARK: Latest value with its date

    struct DatedValue<Value: Equatable>: Equatable {
        let value: Value
        let day: String
    }

    /// The newest non-nil value at or before `dayKey` (`days` is oldest→newest), with the day it came
    /// from. nil when no such value exists.
    static func latest<Value: Equatable>(in days: [DailyMetric], upTo dayKey: String,
                                         _ pick: (DailyMetric) -> Value?) -> DatedValue<Value>? {
        for d in days.reversed() where d.day <= dayKey {
            if let v = pick(d) { return DatedValue(value: v, day: d.day) }
        }
        return nil
    }

    /// The date caption for a value ("23 Jul", the Health "Vital Signs" convention) — nil when the value
    /// belongs to the shown day itself.
    static func dateCaption(valueDay: String, shownDay: String) -> String? {
        valueDay == shownDay ? nil : BodyVitalReading.dayLabel(valueDay)
    }

    // MARK: "Your cards"

    /// A card without any value is hidden while the user is on the default selection; once they customised
    /// the list themselves, their cards stay put (showing "—") so the layout never shifts under them.
    static func showsDashboardCard(hasValue: Bool, userCustomised: Bool) -> Bool {
        hasValue || userCustomised
    }

    // MARK: Carry-over of the last scored recovery day (#543)

    /// Pure carry-over selector behind `TodayView.lastScoredRecoveryDay` and Home's carried vitals — the
    /// gate + selection are unit-testable without a live view (mirrors `buildingHintCopy` / the Android `lastScoredRecoveryDay`).
    /// Returns the freshest scored prior row to carry over, or nil. `days` is oldest→newest; the chosen
    /// row is the last with a non-nil recovery that ISN'T today's (still-nil) key. nil unless: it's today,
    /// today itself isn't scored, and we're not mid-calibration (calibration owns its own copy) — so past
    /// days / a scored today / a calibrating today all carry nothing and live behaviour is unchanged.
    static func lastScoredRecoveryDay(days: [DailyMetric], selectedDayKey: String,
                                      isToday: Bool, todayScored: Bool, isCalibrating: Bool) -> DailyMetric? {
        guard isToday, !todayScored, !isCalibrating else { return nil }
        // Defensive future-day guard (#547): the carry-over must NEVER select a day after today's key, or a
        // stray future-dated row (a bad-clock strap that slipped past the ingest gate / pre-heal DB) would
        // surface as "last night · 12 Jul". `selectedDayKey` is today's logical-day key here (isToday), and
        // yyyy-MM-dd compares lexicographically, so `$0.day < selectedDayKey` keeps only genuine prior days.
        // Belt-and-suspenders on top of the gate + one-time heal — cheap and never wrong.
        return days.last(where: { $0.recovery != nil && $0.day < selectedDayKey })
    }
}

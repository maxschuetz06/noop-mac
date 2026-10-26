import Foundation
import WhoopStore

/// Pure visibility / value-selection rules for the Today screen. Kept separate from `TodayView` so the
/// "show the user's values, nothing else" decisions are unit-testable without a Repository or a view.
enum TodayDisplayRules {

    // MARK: Coaching prose

    /// Coach-style prose cards on Today (the "Synthesis" read-out and the "Readiness" advice card). The
    /// macOS app is a plain values display, so they are off there. iOS keeps them. The engines behind them stay.
    static var coachingCardsVisible: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
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
}

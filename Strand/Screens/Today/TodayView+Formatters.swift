import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

extension TodayView {
    // MARK: - Date parsing (yyyy-MM-dd, en_US_POSIX, LOCAL zone)
    //
    // Parses a `DailyMetric.day` key, which is written in the device's LOCAL zone (the post-#277
    // local-day bucketing). It MUST parse in that same local zone: parsing a local-day key like
    // "2026-06-14" as UTC yields 00:00Z, which is still June 13 in any negative-UTC zone, so the
    // header subtitle then printed the previous day for everyone west of UTC (#319/#320).

    static let dayParser = DayKey.makeFormatter()

    /// Local wall-clock time for the HR trend's x-axis / tooltip — the chart spans one day, so it must
    /// show times, not the day-granularity default ("EEE d MMM"). Also formats the workout-tile caption's
    /// time range (#157). The "jmm" skeleton respects the device's 12-/24-hour setting (#337): "7:10 AM"
    /// where 12-hour is preferred, "19:10" where 24-hour is — instead of forcing one on everyone.
    /// "d MMM" for the workout tiles' caption. Shared: building a `DateFormatter` per tile per body pass
    /// was a measurable share of Today's main-thread stall. Follows the system zone like a fresh formatter.
    static let workoutDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.autoupdatingCurrent
        f.dateFormat = "d MMM"
        return f
    }()

    /// "EEEE, d MMMM" for the header date line (shared for the same reason as `workoutDateFmt`).
    static let dateLineFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.autoupdatingCurrent
        f.dateFormat = "EEEE, d MMMM"
        return f
    }()

    static let hrTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
}

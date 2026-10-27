import Foundation

/// The `yyyy-MM-dd` day keys rows are stored under (`DailyMetric.day`, metric series, journal, …).
/// The POSIX locale fixes the Gregorian calendar and ASCII digits, so a key never depends on the user's
/// settings. Parsing is strict: an impossible day such as "2026-02-30" is nil, not rolled into March.
public enum DayKey {
    public static let utc = TimeZone(identifier: "UTC")!

    /// A new day-key formatter. `timeZone: nil` keeps the formatter's default zone (the system zone),
    /// which is how local day keys are written; pass `DayKey.utc` for keys used as zone-free dates.
    public static func makeFormatter(timeZone: TimeZone? = nil) -> DateFormatter {
        let f = DateFormatter()
        // Setting `calendar` explicitly would make parsing lenient, so the locale alone provides it.
        f.locale = Locale(identifier: "en_US_POSIX")
        if let timeZone { f.timeZone = timeZone }
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// The key of the day containing `date` in `timeZone` (nil: the system zone).
    public static func string(from date: Date, timeZone: TimeZone? = nil) -> String {
        withFormatter(timeZone) { $0.string(from: date) }
    }

    /// Midnight starting the day `key` names in `timeZone` (nil: the system zone); nil for a non-key.
    public static func date(from key: String, timeZone: TimeZone? = nil) -> Date? {
        withFormatter(timeZone) { $0.date(from: key) }
    }

    private static let lock = NSLock()
    private static let local = makeFormatter()
    private static let utcFormatter = makeFormatter(timeZone: utc)

    private static func withFormatter<T>(_ timeZone: TimeZone?, _ body: (DateFormatter) -> T) -> T {
        guard let timeZone else { return lock.withLock { body(local) } }
        if timeZone.identifier == "UTC" || timeZone.identifier == "GMT" {
            return lock.withLock { body(utcFormatter) }
        }
        return body(makeFormatter(timeZone: timeZone))
    }
}

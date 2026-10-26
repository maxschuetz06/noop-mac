import Foundation

/// Memoized `yyyy-MM-dd` → `Date` parse (UTC midnight, en_US_POSIX) shared by the screens that turn the
/// stored day keys of a whole history into chart points on every body pass.
///
/// A `DateFormatter` parse is microseconds and those screens re-parse every row of every series several
/// times per pass (Trends, Compare, Explore), which added up to tens of milliseconds on the main thread.
/// The day keys are a small closed set (one per history day), the parse is a pure function of the string,
/// so caching returns exactly what the formatter would. The lock also serialises the shared (non
/// thread-safe) formatter, so the helper may be used off the main actor too.
final class DayKeyDateCache: @unchecked Sendable {
    /// UTC / en_US_POSIX parser — the convention every history screen uses for day keys.
    static let utc = DayKeyDateCache(timeZone: TimeZone(identifier: "UTC"))

    private let lock = NSLock()
    private let formatter: DateFormatter
    private var parsed: [String: Date?] = [:]

    init(timeZone: TimeZone?) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if let timeZone { f.timeZone = timeZone }
        f.dateFormat = "yyyy-MM-dd"
        formatter = f
    }

    func date(_ day: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        if let hit = parsed[day] { return hit }
        let d = formatter.date(from: day)
        if parsed.count >= 8_192 { parsed.removeAll(keepingCapacity: true) }
        parsed[day] = .some(d)
        return d
    }
}

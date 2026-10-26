import Foundation

/// Markers the user taps on the strap: "moments" (double-tap markers) and "sleep marks" (#461). Both
/// lists persist in `UserDefaults` (newest 500 each), confirm with a single buzz and write a line into
/// the strap log.
@MainActor
final class MomentsStore: ObservableObject {
    static let momentsKey = "moments"
    static let sleepMarksKey = "sleepMarks"
    private static let capacity = 500

    /// Timestamps of moments marked via a double-tap (persisted).
    @Published var moments: [Date]
    /// Timestamps of "sleep marks" tapped on the strap (#461) — bedtime / wake / mid-night marks the
    /// user double-taps without screenshots or remembering the time. Persisted; each also writes a
    /// greppable "Sleep mark @ HH:mm" line into the strap log. Phase-1 foundation for tap-driven sleep
    /// bounds + personal sleep-stage calibration.
    @Published var sleepMarks: [Date]

    private let defaults: UserDefaults
    private let buzz: () -> Void
    private let log: (String) -> Void
    /// Upserts the typed `sleep_mark` metric-series row the Sleep screen reads back.
    private let recordSleepMark: (SleepMark) -> Void

    init(defaults: UserDefaults = .standard,
         buzz: @escaping () -> Void,
         log: @escaping (String) -> Void,
         recordSleepMark: @escaping (SleepMark) -> Void) {
        self.defaults = defaults
        self.buzz = buzz
        self.log = log
        self.recordSleepMark = recordSleepMark
        moments = Self.load(Self.momentsKey, from: defaults)
        sleepMarks = Self.load(Self.sleepMarksKey, from: defaults)
    }

    /// Record a "moment" at a specific time (the Siri/Shortcuts path captures the invocation time even
    /// though the app only drains the queue later when it becomes active).
    func markMoment(at date: Date) {
        moments = Self.appending(date, to: moments)
        defaults.set(moments.map(\.timeIntervalSince1970), forKey: Self.momentsKey)
        buzz()
        log("Moment marked")
    }

    /// #461: record a "sleep mark" — a bedtime / wake / mid-night tap. Stored like moments (survives
    /// relaunch) and written as a distinct, greppable "Sleep mark @ HH:mm" line into the strap log so it
    /// rides along in the shared log / raw export. A single buzz confirms it registered. No start/end
    /// smarts yet (Phase 1): marks are logged in sequence; pairing into sleep bounds comes later.
    func markSleep(at date: Date) {
        sleepMarks = Self.appending(date, to: sleepMarks)
        defaults.set(sleepMarks.map(\.timeIntervalSince1970), forKey: Self.sleepMarksKey)
        buzz()
        let hhmm = DateFormatter()
        hhmm.locale = Locale(identifier: "en_US_POSIX")
        hhmm.dateFormat = "HH:mm"
        log("Sleep mark @ \(hhmm.string(from: date))")
        // Persistence parity with Android's `AppViewModel.markSleep` (#461): also upsert the TYPED
        // `sleep_mark` metric-series row that the Sleep screen reads back (SleepView.logMark writes the
        // same row when the user taps a button). A physical double-tap can't choose bedtime vs wake, so
        // it defaults to `.bedtime` — the boundary the gesture most naturally marks.
        recordSleepMark(SleepMark(type: .bedtime, at: date))
    }

    private static func load(_ key: String, from defaults: UserDefaults) -> [Date] {
        (defaults.array(forKey: key) as? [Double] ?? []).map { Date(timeIntervalSince1970: $0) }
    }

    private static func appending(_ date: Date, to list: [Date]) -> [Date] {
        var list = list
        list.append(date)
        if list.count > capacity { list.removeFirst(list.count - capacity) }
        return list
    }
}

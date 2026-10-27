import Foundation
import WhoopStore

// MARK: - Home dashboard model
//
// Pure, view-independent derivations behind the "Overview" home screen: the short metric
// histories the cards draw, honest week-over-baseline insights, and today's timeline segments.
// Everything here is computed from rows the app already stores (no fabricated values): an insight
// is only produced when both its recent window and its baseline window hold enough real data.

/// One generated "Findings" row on the home screen.
struct HomeInsight: Identifiable, Equatable {
    enum Tone: Equatable { case positive, neutral, caution }
    enum Topic: String, Equatable { case hrv, sleep, restingHr, bedtime }

    let topic: Topic
    let tone: Tone
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    var id: String { topic.rawValue }
}

/// A block on today's 24 h timeline.
struct HomeTimelineItem: Identifiable, Equatable {
    enum Kind: Equatable { case sleep, nap, workout }
    enum Status: Equatable { case completed, running }

    let kind: Kind
    let title: LocalizedStringResource
    let start: Date
    let end: Date
    let status: Status

    var id: String { "\(kind)-\(Int(start.timeIntervalSince1970))" }
}

enum HomeModel {

    // MARK: Windows

    /// Values of `value` for the last `count` days that carry one, oldest → newest, never after `dayKey`.
    static func recentValues(_ days: [DailyMetric], upTo dayKey: String, count: Int,
                             _ value: (DailyMetric) -> Double?) -> [Double] {
        Array(days.filter { $0.day <= dayKey }.compactMap(value).suffix(count))
    }

    /// Mean of `value` over the calendar days in `(dayKey - from, dayKey - to]`, or nil below `minCount`.
    static func windowMean(_ days: [DailyMetric], dayKey: String, fromDaysBack: Int, toDaysBack: Int,
                           minCount: Int, _ value: (DailyMetric) -> Double?) -> Double? {
        guard let anchor = dayParser.date(from: dayKey),
              let lower = Calendar.current.date(byAdding: .day, value: -fromDaysBack, to: anchor),
              let upper = Calendar.current.date(byAdding: .day, value: -toDaysBack, to: anchor) else { return nil }
        let lowKey = dayParser.string(from: lower), highKey = dayParser.string(from: upper)
        let vals = days.filter { $0.day > lowKey && $0.day <= highKey }.compactMap(value)
        guard vals.count >= minCount else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    /// Recent mean (last 7 calendar days, ≥ 3 values) and baseline mean (the up to 28 most recent values
    /// before that week within 120 days, ≥ 7 values). Value-count based rather than calendar based so a
    /// gap in wear (strap not synced for weeks) doesn't silently disable every comparison.
    static func recentAndBaseline(_ days: [DailyMetric], dayKey: String,
                                  _ value: (DailyMetric) -> Double?) -> (recent: Double, base: Double)? {
        guard let recent = windowMean(days, dayKey: dayKey, fromDaysBack: 7, toDaysBack: 0, minCount: 3, value),
              let anchor = dayParser.date(from: dayKey),
              let weekStart = Calendar.current.date(byAdding: .day, value: -7, to: anchor),
              let floor = Calendar.current.date(byAdding: .day, value: -120, to: anchor) else { return nil }
        let hi = dayParser.string(from: weekStart), lo = dayParser.string(from: floor)
        let prior = Array(days.filter { $0.day > lo && $0.day <= hi }.compactMap(value).suffix(28))
        guard prior.count >= 7 else { return nil }
        return (recent, prior.reduce(0, +) / Double(prior.count))
    }

    /// Relative change of the last 7 days against the baseline before them, in percent (nil without data).
    static func weekChangePercent(_ days: [DailyMetric], dayKey: String,
                                  _ value: (DailyMetric) -> Double?) -> Double? {
        guard let rb = recentAndBaseline(days, dayKey: dayKey, value), rb.base > 0 else { return nil }
        return (rb.recent - rb.base) / rb.base * 100
    }

    // MARK: Insights

    static func insights(days: [DailyMetric], sleeps: [CachedSleepSession], dayKey: String) -> [HomeInsight] {
        var out: [HomeInsight] = []

        if let pct = weekChangePercent(days, dayKey: dayKey, { $0.avgHrv }) {
            let rounded = Int(pct.rounded())
            if rounded >= 5 {
                out.append(HomeInsight(topic: .hrv, tone: .positive,
                                       title: "Your HRV is \(rounded) % above your average",
                                       detail: "Last 7 days compared with your average before"))
            } else if rounded <= -5 {
                out.append(HomeInsight(topic: .hrv, tone: .caution,
                                       title: "Your HRV is \(-rounded) % below your average",
                                       detail: "More recovery can help"))
            } else {
                out.append(HomeInsight(topic: .hrv, tone: .neutral,
                                       title: "Your HRV is stable",
                                       detail: "Last 7 days within your usual range"))
            }
        }

        if let (recent, base) = recentAndBaseline(days, dayKey: dayKey, { $0.totalSleepMin }) {
            let diff = Int((recent - base).rounded())
            if diff >= 10 {
                out.append(HomeInsight(topic: .sleep, tone: .positive,
                                       title: "You're sleeping \(diff) min longer this week",
                                       detail: "Average \(hoursMinutes(recent)) per night"))
            } else if diff <= -10 {
                out.append(HomeInsight(topic: .sleep, tone: .caution,
                                       title: "You're sleeping \(-diff) min less this week",
                                       detail: "Average \(hoursMinutes(recent)) per night"))
            } else {
                out.append(HomeInsight(topic: .sleep, tone: .neutral,
                                       title: "Your sleep duration is steady",
                                       detail: "Average \(hoursMinutes(recent)) per night"))
            }
        }

        let rhr: (DailyMetric) -> Double? = { $0.restingHr.map(Double.init) }
        if let (recent, base) = recentAndBaseline(days, dayKey: dayKey, rhr) {
            let diff = recent - base
            let now = Int(recent.rounded())
            if diff >= 3 {
                out.append(HomeInsight(topic: .restingHr, tone: .caution,
                                       title: "Your resting pulse is up \(Int(diff.rounded())) bpm",
                                       detail: "Currently \(now) bpm · a sign of strain"))
            } else if diff <= -2 {
                out.append(HomeInsight(topic: .restingHr, tone: .positive,
                                       title: "Your resting pulse is down \(Int((-diff).rounded())) bpm",
                                       detail: "Currently \(now) bpm"))
            } else {
                out.append(HomeInsight(topic: .restingHr, tone: .neutral,
                                       title: "Your resting pulse is steady at \(now) bpm",
                                       detail: "No sign of overload"))
            }
        }

        if let spread = bedtimeSpreadMinutes(sleeps: sleeps, dayKey: dayKey) {
            if spread > 45 {
                out.append(HomeInsight(topic: .bedtime, tone: .caution,
                                       title: "Your bedtime varies by ±\(spread) min",
                                       detail: "Regular times steady your recovery"))
            } else {
                out.append(HomeInsight(topic: .bedtime, tone: .positive,
                                       title: "You go to bed at regular times (±\(spread) min)",
                                       detail: "Last 7 nights"))
            }
        }
        return out
    }

    /// Standard deviation (minutes) of sleep onset over the main nights of the last 7 days, or nil
    /// below four nights. Onsets are measured from 18:00 so a midnight crossing doesn't wrap.
    static func bedtimeSpreadMinutes(sleeps: [CachedSleepSession], dayKey: String) -> Int? {
        guard let anchor = dayParser.date(from: dayKey),
              let end = Calendar.current.date(byAdding: .day, value: 1, to: anchor),
              let start = Calendar.current.date(byAdding: .day, value: -7, to: anchor) else { return nil }
        let lo = Int(start.timeIntervalSince1970), hi = Int(end.timeIntervalSince1970)
        let nights = sleeps.filter { !$0.isNap && $0.endTs > lo && $0.endTs <= hi && $0.endTs - $0.startTs >= 3 * 3600 }
        guard nights.count >= 4 else { return nil }
        let cal = Calendar.current
        let mins: [Double] = nights.map { s in
            let d = Date(timeIntervalSince1970: TimeInterval(s.startTsAdjusted ?? s.startTs))
            let c = cal.dateComponents([.hour, .minute], from: d)
            let m = Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
            return (m - 18 * 60 + 1440).truncatingRemainder(dividingBy: 1440)
        }
        let mean = mins.reduce(0, +) / Double(mins.count)
        let variance = mins.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(mins.count)
        return Int(variance.squareRoot().rounded())
    }

    // MARK: Timeline

    /// The next local midnight after `dayStart`: 23 or 25 hours later on a DST change, not a fixed 24.
    static func dayEnd(_ dayStart: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .day, for: dayStart)?.end ?? dayStart.addingTimeInterval(86_400)
    }

    /// Where `date` falls on the bar of the local day starting at `dayStart`, clamped to 0…1.
    static func dayFraction(_ date: Date, dayStart: Date, calendar: Calendar = .current) -> Double {
        let length = dayEnd(dayStart, calendar: calendar).timeIntervalSince(dayStart)
        return min(max(date.timeIntervalSince(dayStart) / length, 0), 1)
    }

    /// Bar positions of the clock labels 00:00, 03:00 … 24:00 for the local day starting at `dayStart`:
    /// each label sits at its real wall-clock instant, so a DST day's extra or missing hour stays in place.
    static func hourTicks(dayStart: Date, calendar: Calendar = .current) -> [(hour: Int, fraction: Double)] {
        stride(from: 0, through: 24, by: 3).map { hour in
            let instant = hour == 24 ? dayEnd(dayStart, calendar: calendar)
                : calendar.date(bySettingHour: hour, minute: 0, second: 0, of: dayStart) ?? dayStart
            return (hour, dayFraction(instant, dayStart: dayStart, calendar: calendar))
        }
    }

    /// Unix-second span of the HR chart for the local day starting at `dayStart`: today runs up to
    /// `now`, a past day up to its next local midnight.
    static func hrWindow(dayStart: Date, isToday: Bool, now: Date,
                         calendar: Calendar = .current) -> (from: Int, to: Int) {
        let end = isToday ? now : dayEnd(dayStart, calendar: calendar)
        return (Int(dayStart.timeIntervalSince1970), Int(end.timeIntervalSince1970))
    }

    /// Sleep, naps and workouts overlapping the local day `[dayStart, dayEnd)`, sorted by start.
    static func timeline(dayStart: Date, sleeps: [CachedSleepSession], workouts: [WorkoutRow],
                         now: Date, calendar: Calendar = .current) -> [HomeTimelineItem] {
        let lo = Int(dayStart.timeIntervalSince1970)
        let hi = Int(dayEnd(dayStart, calendar: calendar).timeIntervalSince1970)
        let nowTs = Int(now.timeIntervalSince1970)
        var items: [HomeTimelineItem] = []
        for s in sleeps where s.endTs > lo && (s.startTsAdjusted ?? s.startTs) < hi {
            let start = s.startTsAdjusted ?? s.startTs
            items.append(HomeTimelineItem(kind: s.isNap ? .nap : .sleep,
                                          title: s.isNap ? "Nap" : "Sleep",
                                          start: Date(timeIntervalSince1970: TimeInterval(start)),
                                          end: Date(timeIntervalSince1970: TimeInterval(s.endTs)),
                                          status: s.endTs > nowTs ? .running : .completed))
        }
        for w in workouts where w.endTs > lo && w.startTs < hi {
            items.append(HomeTimelineItem(kind: .workout, title: sportName(w.sport),
                                          start: Date(timeIntervalSince1970: TimeInterval(w.startTs)),
                                          end: Date(timeIntervalSince1970: TimeInterval(w.endTs)),
                                          status: w.endTs > nowTs ? .running : .completed))
        }
        return items.sorted { $0.start < $1.start }
    }

    /// Localized display name for a stored sport label (falls back to the stored label, untranslated).
    static func sportName(_ sport: String) -> LocalizedStringResource {
        let map: [String: LocalizedStringResource] = [
            "running": "Run", "run": "Run", "cycling": "Cycling", "walking": "Walking",
            "hiking": "Hiking", "swimming": "Swimming", "weightlifting": "Strength Training",
            "strength trainer": "Strength Training", "functional fitness": "Functional Fitness",
            "yoga": "Yoga", "activity": "Activity", "other": "Training",
        ]
        return map[sport.lowercased()] ?? "\(sport.capitalized)"
    }

    // MARK: Formatting

    static func hoursMinutes(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return "\(m / 60) h \(String(format: "%02d", m % 60)) min"
    }

    static let dayParser = DayKey.makeFormatter()
}

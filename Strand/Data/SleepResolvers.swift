import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - Sleep-performance provenance (pure, unit-tested)

/// Where a displayed sleep-performance score comes from. Badge wording matches Today / Intelligence.
enum SleepPerformanceSource: Equatable {
    case whoop, onDevice
    var badge: String { self == .whoop ? "Whoop" : "On-device" }
}

/// Resolves the sleep-performance series together with the provenance of each point, so the hero badge
/// describes the day the number was taken from. `latest` is the newest day that HAS a score, which is not
/// necessarily `days.last` (e.g. today's row exists but carries no sleep yet): looking the source up by
/// `days.last` mislabelled an imported night as "On-device".
enum SleepPerformanceResolver {
    struct Point: Equatable {
        let day: String
        let value: Double
        let source: SleepPerformanceSource
    }

    /// Imported WHOOP figure when the export carried one for the day; else the APPROXIMATE
    /// asleep / need fallback (capped 100). Days with neither are skipped.
    static func points(days: [DailyMetric], imported: [String: ImportedSleepFigures],
                       needMin: Double) -> [Point] {
        days.compactMap { d -> Point? in
            if let p = imported[d.day]?.performancePct, p.isFinite {
                return Point(day: d.day, value: p, source: .whoop)
            }
            guard let asleep = d.totalSleepMin, asleep > 0, needMin > 0 else { return nil }
            let v = min(100, asleep / needMin * 100)
            return v.isFinite ? Point(day: d.day, value: v, source: .onDevice) : nil
        }
    }

    /// Provenance of the latest point (the displayed score); on-device when there is none.
    static func source(of points: [Point]) -> SleepPerformanceSource {
        points.last?.source ?? .onDevice
    }

    /// Provenance of a night's figures, keyed by its LOCAL wake-day (sleep is filed under the day you woke).
    static func nightSource(wakeDay: String, imported: [String: ImportedSleepFigures]) -> SleepPerformanceSource {
        imported[wakeDay] != nil ? .whoop : .onDevice
    }
}

/// Resolves the sleep-consistency series per day with the SAME precedence as `SleepPerformanceResolver`:
/// the imported WHOOP figure (sleep_consistency, 0–100) when the export carried one for that day, else
/// the APPROXIMATE rolling bedtime-spread score of the session that ended that day. `latest` is therefore
/// the newest day that HAS a value, not necessarily `days.last` (a trailing day without sleep data).
enum SleepConsistencyResolver {
    struct Point: Equatable {
        let day: String
        let value: Double
        let source: SleepPerformanceSource
    }

    /// Rolling (14-session) bedtime-spread score per local wake-day (lower spread → higher score).
    /// Needs ≥ 3 sessions overall and ≥ 3 in the window; the last session of a day wins.
    /// `dayKey` maps a session to its local wake-day key (the caller passes `Repository.localDayKey`).
    static func approximateByDay(sessions: [CachedSleepSession], calendar: Calendar = .current,
                                 dayKey: (CachedSleepSession) -> String) -> [String: Double] {
        func bedMinutes(_ s: CachedSleepSession) -> Double {
            let d = Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs))
            let comps = calendar.dateComponents([.hour, .minute], from: d)
            var m = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
            if m < 12 * 60 { m += 24 * 60 }   // wrap evening onsets into one continuous scale
            return m
        }
        let mins = sessions.map(bedMinutes)
        guard mins.count >= 3 else { return [:] }
        var out: [String: Double] = [:]
        for i in mins.indices {
            let window = Array(mins[Swift.max(0, i - 13)...i])
            guard window.count >= 3 else { continue }
            let m = window.reduce(0, +) / Double(window.count)
            let variance = window.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(window.count)
            let score = Swift.max(0, Swift.min(100, 100 * (1 - variance.squareRoot() / 120)))
            if score.isFinite { out[dayKey(sessions[i])] = score }
        }
        return out
    }

    /// Per day of `days`: imported consistency wins, else the approximation; days with neither are skipped.
    static func points(days: [DailyMetric], imported: [String: ImportedSleepFigures],
                       sessions: [CachedSleepSession], calendar: Calendar = .current,
                       dayKey: (CachedSleepSession) -> String) -> [Point] {
        let approx = approximateByDay(sessions: sessions, calendar: calendar, dayKey: dayKey)
        return days.compactMap { d -> Point? in
            if let p = imported[d.day]?.consistencyPct, p.isFinite {
                return Point(day: d.day, value: p, source: .whoop)
            }
            if let v = approx[d.day] { return Point(day: d.day, value: v, source: .onDevice) }
            return nil
        }
    }
}

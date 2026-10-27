import Foundation
import WhoopStore

/// The latest point of a catalog metric that actually has data for this user.
struct MetricAvailability: Equatable {
    let latestDay: String      // YYYY-MM-DD
    let latestValue: Double
}

/// Pure "which catalog metrics have data" logic behind Explore and the Compare picker. Kept free of UI and
/// the Repository so it is unit-testable with synthetic data and can run off the main thread.
enum MetricAvailabilityIndex {

    /// metric.id → latest point, for every catalog metric with at least one data point. Metrics without
    /// data are simply absent. Mirrors `Repository.exploreSeries` semantics: a strap ("my-whoop") metric
    /// resolves from the imported series (wins), then the on-device computed series, then the merged
    /// daily column; every other source reads only its own series.
    static func build(catalog: [MetricDescriptor],
                      summaries: [MetricSeriesSummary],
                      deviceId: String,
                      days: [DailyMetric]) -> [String: MetricAvailability] {
        let computedId = deviceId + SourceID.computedSuffix
        var latestBySeries: [String: MetricSeriesSummary] = [:]
        for s in summaries where s.count > 0 { latestBySeries[s.deviceId + "\u{1F}" + s.key] = s }

        var out: [String: MetricAvailability] = [:]
        for m in catalog {
            // (day, value, priority) — later day wins; on a tie the higher-priority layer wins.
            var best: (day: String, value: Double, priority: Int)?
            func offer(_ day: String, _ value: Double, _ priority: Int) {
                if let b = best, (b.day, b.priority) >= (day, priority) { return }
                best = (day, value, priority)
            }
            if m.source == SourceID.whoop {
                if let s = latestBySeries[deviceId + "\u{1F}" + m.key] { offer(s.latestDay, s.latestValue, 2) }
                if let s = latestBySeries[computedId + "\u{1F}" + m.key] { offer(s.latestDay, s.latestValue, 1) }
                for d in days {
                    if let v = Repository.dailyColumn(key: m.key, day: d) { offer(d.day, v, 0) }
                }
            } else if let s = latestBySeries[m.source + "\u{1F}" + m.key] {
                offer(s.latestDay, s.latestValue, 2)
            }
            if let b = best { out[m.id] = MetricAvailability(latestDay: b.day, latestValue: b.value) }
        }
        return out
    }

    /// Splits `metrics` (order preserved) into those with data and those without. A nil availability map
    /// (store unavailable / not probed) keeps everything visible so nothing is ever hidden by a failure.
    static func split(_ metrics: [MetricDescriptor],
                      availability: [String: MetricAvailability]?) -> (withData: [MetricDescriptor],
                                                                       withoutData: [MetricDescriptor]) {
        guard let availability else { return (metrics, []) }
        var with: [MetricDescriptor] = [], without: [MetricDescriptor] = []
        for m in metrics { if availability[m.id] != nil { with.append(m) } else { without.append(m) } }
        return (with, without)
    }

    /// Metrics to list: those with data, plus the rest when `showAll` — and always `keeping` (e.g. already
    /// selected Compare metrics) so a selection never vanishes from its own picker.
    static func visible(_ metrics: [MetricDescriptor],
                        availability: [String: MetricAvailability]?,
                        showAll: Bool,
                        keeping: Set<String> = []) -> [MetricDescriptor] {
        guard !showAll, let availability else { return metrics }
        return metrics.filter { availability[$0.id] != nil || keeping.contains($0.id) }
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "23 Jul" for a `yyyy-MM-dd` day; "23 Jul 2025" when it is not in `currentYear`. nil if malformed.
    static func shortDate(_ day: String, currentYear: Int) -> String? {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let mo = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(mo), (1...31).contains(d) else { return nil }
        let base = "\(d) \(months[mo - 1])"
        return y == currentYear ? base : "\(base) \(y)"
    }
}

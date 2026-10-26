#if os(macOS)
import SwiftUI
import StrandDesign

/// Locale-aware number, date and summary formatting shared by the Home and Sleep dashboards.
/// Views build it from `@Environment(\.locale)` so the output follows Settings → Language.
struct HomeFormat {
    let locale: Locale

    func decimal(_ v: Double, digits: Int) -> String {
        v.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(locale))
    }

    func grouped(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0)).locale(locale))
    }

    func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(locale))
    }

    /// "Mo., 26. Okt. 2026" / "Mon, Oct 26, 2026": the weekday in its format form, then the localized date.
    func headerDate(_ date: Date) -> String {
        let weekday = DateFormatter()
        weekday.locale = locale
        weekday.dateFormat = "EEE"
        return "\(weekday.string(from: date)), \(date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale)))"
    }

    /// Five evenly spaced clock labels across the given points (their real first…last times).
    func axisLabels(_ points: [TrendPoint]) -> [String] {
        guard let first = points.first?.date, let last = points.last?.date, last > first else { return [] }
        let span = last.timeIntervalSince(first)
        return (0...4).map { clock(first.addingTimeInterval(span * Double($0) / 4)) }
    }

    /// VoiceOver text for a mini chart: range and latest value, so the chart never relies on shape alone.
    /// Numbers are formatted by `Text` with the environment locale.
    static func seriesSummary(_ title: Text, _ values: [Double], unit: Text) -> Text {
        guard let lo = values.min(), let hi = values.max(), let last = values.last else {
            return Text("\(title): no data")
        }
        func style(_ v: Double) -> FloatingPointFormatStyle<Double> {
            v >= 100 ? .number.precision(.fractionLength(0))
                : .number.precision(.fractionLength(v < 10 ? 1 : 0)).grouping(.never)
        }
        return Text("\(title): from \(lo, format: style(lo)) to \(hi, format: style(hi)) \(unit), latest \(last, format: style(last)) \(unit)")
    }
}
#endif

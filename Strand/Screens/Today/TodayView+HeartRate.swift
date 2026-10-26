import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

extension TodayView {
    // MARK: HEART RATE — today's continuous HR, off the strap's own ~1Hz history.

    /// A full-width 24-hour heart-rate trend, plotted from 5-minute bucket means of the strap's
    /// `hrSample` history (offloaded even while the app was closed, so the day reads continuously).
    /// Hidden until there are at least two buckets — a strap-only user with no wear today sees nothing
    /// rather than an empty axis. Mirrored on Android (TodayScreen.kt HeartRateTrendCard).
    @ViewBuilder
    var heartRateTrendSection: some View {
        if hrPoints.count > 1 {
            let v = hrPoints.map(\.value)
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Heart Rate", overline: "\(selectedDayOverline)")
                ChartCard(
                    title: "Beats per minute",
                    subtitle: selectedDayOffset == 0 ? "5-minute average · since midnight" : "5-minute average · selected day",
                    trailing: v.last.map { "\(Int($0.rounded())) bpm" },
                    tint: StrandPalette.metricRose
                ) {
                    OverviewHRChart(
                        points: hrPoints,
                        sleep: sleepSpan,
                        workouts: workoutSpans,
                        recovery: recoveryMarker,
                        effort: effortMarker,
                        gradient: Gradient(colors: [StrandPalette.metricRose.opacity(0.55), StrandPalette.metricRose]),
                        valueRange: hrRange(v),
                        xRange: hrAxis,
                        height: NoopMetrics.chartHeight,
                        valueFormat: { "\(Int($0.rounded())) bpm" },
                        dateFormat: { Self.hrTimeFmt.string(from: $0) }
                    )
                } footer: {
                    ChartFooter([
                        ("Min", "\(Int((v.min() ?? 0).rounded()))"),
                        ("Avg", "\(Int((v.reduce(0, +) / Double(v.count)).rounded()))"),
                        ("Max", "\(Int((v.max() ?? 0).rounded()))"),
                    ])
                }
            }
        }
    }

    /// Padded HR axis range so the line never sits flush against an edge (mirrors MetricExplorer.valueRange).
    func hrRange(_ v: [Double]) -> ClosedRange<Double> {
        guard let lo = v.min(), let hi = v.max() else { return 40...120 }
        if hi <= lo { return (lo - 5)...(hi + 5) }
        let span = hi - lo
        return (lo - span * 0.12)...(hi + span * 0.12)
    }

    // MARK: Overview HR markers (sleep band · workout glyphs · Charge / Effort)

    /// The HR chart's x-window, derived from the loaded points (used to scope workout glyphs).
    var hrWindow: ClosedRange<Date>? {
        guard let lo = hrPoints.first?.date, let hi = hrPoints.last?.date, lo < hi else { return nil }
        return lo...hi
    }

    /// "H:MM" for a duration in seconds (e.g. a 6h06m night → "6:06").
    func hoursMinutes(_ seconds: Int) -> String {
        let h = max(0, seconds) / 3600, m = (max(0, seconds) % 3600) / 60
        return "\(h):\(String(format: "%02d", m))"
    }

    /// Last night's sleep as a shaded band, labelled with its duration.
    var sleepSpan: OverviewHRChart.SleepSpan? {
        guard let s = sleepToday else { return nil }
        // Use the EFFECTIVE onset so a hand-corrected bedtime shows the same band/duration here as on
        // the Sleep tab (not the detected onset). (#318)
        return .init(
            start: Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs)),
            end: Date(timeIntervalSince1970: TimeInterval(s.endTs)),
            label: hoursMinutes(s.endTs - s.effectiveStartTs)
        )
    }

    /// Each workout overlapping the HR window, as a sport glyph anchored at its HR peak.
    var workoutSpans: [OverviewHRChart.WorkoutSpan] {
        guard let win = hrWindow else { return [] }
        return workouts.compactMap { w in
            let start = Date(timeIntervalSince1970: TimeInterval(w.startTs))
            let end = Date(timeIntervalSince1970: TimeInterval(w.endTs))
            guard end >= win.lowerBound, start <= win.upperBound else { return nil }
            return .init(start: start, end: end, symbol: sportSymbol(w.sport))
        }
    }

    /// "Charge" marker (NOOP's name for recovery) at wake time (sleep end), else at the window start.
    /// Hidden while calibrating.
    var recoveryMarker: OverviewHRChart.EdgeMarker? {
        guard let rec = displayDay?.recovery else { return nil }
        let at = sleepToday.map { Date(timeIntervalSince1970: TimeInterval($0.endTs)) }
            ?? hrPoints.first?.date
        guard let date = at else { return nil }
        return .init(date: date, label: "\(Int(rec.rounded()))% Charge",
                     color: StrandPalette.recoveryColor(rec), alignment: .leading)
    }

    /// "Effort" marker pinned to the right edge (latest HR sample). Routed through the SAME formatter
    /// as the Effort tile (`UnitFormatter.effortDisplay`) so it honours the 0–100 / WHOOP-0–21 scale
    /// preference (#268) and reads identically — the stored strain is on the 0–100 axis, so a morning
    /// "21.2" is 21.2-of-100, not WHOOP's near-max 21-of-21.
    var effortMarker: OverviewHRChart.EdgeMarker? {
        guard let strain = displayDay?.strain, let date = hrPoints.last?.date else { return nil }
        return .init(date: date,
                     label: "\(UnitFormatter.effortDisplay(strain, scale: effortScale)) Effort",
                     color: StrandPalette.effortTint(fraction: Repository.effortFraction(strain)), alignment: .trailing)
    }
}

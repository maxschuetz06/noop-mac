import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

extension TodayView {
    // MARK: (b) METRICS — one uniform grid of 104pt StatTiles, every cell filled.

    @ViewBuilder
    var metricsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // The section header keeps its "14-day trend" trailing label; an Edit control sits beside it
            // to open the local layout editor (#251). No new nav destination — a sheet over Today.
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("Key Metrics", overline: "\(selectedDayOverline)", trailing: "14-day trend")
                Button {
                    showingMetricsEditor = true
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                        .font(StrandFont.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityLabel("Edit Key Metrics")
                .help("Choose which Key Metrics show and reorder them")
            }
            // Render the enabled tiles in the saved order; an empty layout still shows the default set.
            LazyVGrid(columns: grid, alignment: .leading, spacing: NoopMetrics.gap) {
                ForEach(enabledKeyMetrics) { metric in
                    keyMetricTile(metric)
                }
            }
        }
        .sheet(isPresented: $showingMetricsEditor) {
            KeyMetricsEditorSheet(layoutRaw: $keyMetricsRaw)
        }
    }

    /// A carried recovery-vital tile's (value, caption): today's own value wins (with the metric's
    /// static unit caption); otherwise, when we're carrying the last scored day (#543), the PRIOR row's
    /// value with a "Last night · <date>" caption so the whole recovery side stays consistent rather than
    /// blanking to "—" at the rollover. A metric the carried row genuinely lacks (e.g. SpO₂ on a BLE-only
    /// night) still falls through to "—" with its unit caption — we never fabricate the new day's value.
    /// `format` renders the stored Double; `today`/`prior` pull the metric off a row (Int metrics map up).
    func carriedVital(
        unit: String,
        today: Double?,
        prior: (DailyMetric) -> Double?,
        format: (Double) -> String
    ) -> (value: String, caption: String?) {
        if let v = today { return (format(v), unit) }
        if let p = lastScoredRecoveryDay, let v = prior(p) {
            return (format(v), carriedCaption(p))
        }
        // H10 — an empty vital on TODAY reads honestly ("After tonight's sleep") instead of a lone unit
        // beside a bare "—", which looked like a fault; a navigated PAST day keeps the plain unit (it's
        // genuinely missing data the user can't act on now). Pure copy via `emptyVitalCaption`.
        if let honest = Self.emptyVitalCaption(unit: unit, isToday: selectedDayOffset == 0) {
            return ("—", honest)
        }
        return ("—", unit)
    }

    /// One Key-Metric tile, keyed so the grid can be filtered + reordered per the saved layout (#251).
    /// Each case is byte-for-byte the tile that used to be hard-coded in the grid — the refactor only
    /// changes WHICH tiles render and in WHAT order, never how an individual tile looks.
    @ViewBuilder
    func keyMetricTile(_ metric: KeyMetric) -> some View {
        let d = displayDay
        let aLatest = appleDays.last
        switch metric {
        case .charge:
            chargeMetricTile(d)
        case .effort:
            effortMetricTile(d)
        case .rest:
            restMetricTile(d)
        case .hrv:
            hrvMetricTile(d)
        case .restingHr:
            restingHrMetricTile(d)
        case .bloodOxygen:
            bloodOxygenMetricTile(d)
        case .respiratory:
            respiratoryMetricTile(d)
        case .steps:
            stepsMetricTile(d, latestApple: aLatest)
        case .weight:
            weightMetricTile(latestApple: aLatest)
        case .calories:
            caloriesMetricTile(latestApple: aLatest)
        }
    }
}

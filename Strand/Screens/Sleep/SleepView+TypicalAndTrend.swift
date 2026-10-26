import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

extension SleepView {
    // MARK: - 3. Stages vs typical

    @ViewBuilder
    func stagesVsTypical(_ model: SleepModel) -> some View {
        let s = model.night.stages
        // Per-stage typical means are computed ONCE in the model build (each a full pass
        // over repo.days) and read here.
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Stages vs typical", overline: "Last night",
                          trailing: "hatch = typical")
            NoopCard(tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    stageRow(stage: "Deep",  last: s.deep,  typical: model.typicalDeepMin,  nightTotal: s.total, color: StrandPalette.sleepDeep)
                    Divider().overlay(StrandPalette.hairline)
                    stageRow(stage: "REM",   last: s.rem,   typical: model.typicalRemMin,   nightTotal: s.total, color: StrandPalette.sleepREM)
                    Divider().overlay(StrandPalette.hairline)
                    stageRow(stage: "Light", last: s.light, typical: model.typicalLightMin, nightTotal: s.total, color: StrandPalette.sleepLight)
                }
            }
        }
    }

    /// One stage row, WHOOP sleep-detail style: a colour swatch + UPPERCASE stage + the share-of-night %
    /// (in the stage colour), then a bar that reads "solid = you, hatch = the context" — a diagonal-hatch
    /// track spanning the TYPICAL (the personal mean for this stage) with the user's last-night value as a
    /// solid coloured fill on top, plus a thin marker at the typical mean and the right-aligned duration.
    /// Same data as before (`last` minutes, `typical` personal mean) — the hatch just renders the typical
    /// context the prior vertical-only marker implied.
    @ViewBuilder
    func stageRow(stage label: String, last: Double, typical: Double?, nightTotal: Double, color: Color) -> some View {
        // Scale both values against a shared per-row max so the typical hatch + marker are meaningful.
        let scaleMax = max(last, typical ?? 0) * 1.18
        let max = scaleMax > 0 ? scaleMax : 1
        // Share of the night this stage took (drives the WHOOP coloured %); over time-in-bed, matching the
        // stage-breakdown rows above.
        let sharePct = nightTotal > 0 ? Int((last / nightTotal * 100).rounded()) : 0
        let deltaText: String = {
            guard let typical, typical > 0 else { return "" }
            let diff = last - typical
            let sign = diff >= 0 ? "+" : "−"
            return "\(sign)\(durationText(abs(diff))) vs typ"
        }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text(label.uppercased())
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("\(sharePct)%")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(color)
                Spacer()
                Text(durationText(last)).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                if !deltaText.isEmpty {
                    Text(deltaText)
                        .font(StrandFont.footnote)
                        .foregroundStyle(last >= (typical ?? last) ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                }
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    // Track.
                    Capsule(style: .continuous)
                        .fill(StrandPalette.surfaceInset)
                    // Typical-range CONTEXT: a diagonal-hatch track spanning the personal mean for this
                    // stage. "Hatch = the context" — the user's solid value sits over it.
                    if let typical, typical > 0 {
                        DiagonalHatch(spacing: 5, lineWidth: 1)
                            .stroke(color.opacity(0.5), lineWidth: 1)
                            .frame(width: w * CGFloat(min(1, typical / max)))
                            .clipShape(Capsule(style: .continuous))
                    }
                    // Last-night SOLID value fill — "solid = you".
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: w * CGFloat(min(1, last / max)))
                    // Crisp typical-mean marker so the exact mean still reads at a glance.
                    if let typical, typical > 0 {
                        Rectangle()
                            .fill(StrandPalette.textPrimary)
                            .frame(width: 2, height: 16)
                            .position(x: w * CGFloat(min(1, typical / max)), y: 5)
                    }
                }
            }
            .frame(height: 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label): \(durationText(last)) last night, \(sharePct) percent of the night\(typical.map { ", typical \(durationText($0))" } ?? "")")
        }
    }

    // MARK: - 4. 30-day asleep-hours trend

    @ViewBuilder
    func durationTrend(_ model: SleepModel) -> some View {
        // Trailing-30 trend points and the typical total are precomputed in the model build
        // (full passes over repo.days) — read here, not recomputed per render.
        let pts = model.trendPoints
        let avg = model.typicalTotalMin.map { $0 / 60.0 }
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Asleep duration", overline: "Trend", trailing: "Last 30 days")
            ChartCard(
                title: "Hours asleep",
                subtitle: "Per night, trailing 30 days",
                trailing: avg.map { String(format: "%.1f h avg", $0) },
                height: NoopMetrics.chartHeight,
                tint: StrandPalette.restColor,
                chart: {
                    if pts.count >= 2 {
                        TrendChart(points: pts,
                                   gradient: StrandPalette.restGradient,
                                   valueRange: trendRange(pts),
                                   showsArea: true,
                                   height: NoopMetrics.chartHeight,
                                   valueFormat: { String(format: "%.1f h", $0) },
                                   accessibilityLabel: "Hours asleep trend")
                    } else {
                        sparsePlaceholder
                    }
                },
                footer: {
                    ChartFooter([
                        ("Avg",    avg.map { String(format: "%.1f h", $0) } ?? "—"),
                        ("Min",    pts.map(\.value).min().map { String(format: "%.1f h", $0) } ?? "—"),
                        ("Max",    pts.map(\.value).max().map { String(format: "%.1f h", $0) } ?? "—"),
                        ("Nights", "\(pts.count)"),
                    ])
                }
            )
        }
    }
}

extension SleepView {
    /// Mean total sleep duration (minutes) across nights with data — the "typical".
    var typicalTotalMin: Double? {
        mean(repo.days.compactMap { $0.totalSleepMin }.filter { $0 > 0 })
    }

    /// Mean of a per-stage minutes column across days with data.
    func typicalStageMin(_ key: KeyPath<DailyMetric, Double?>) -> Double? {
        mean(repo.days.compactMap { $0[keyPath: key] }.filter { $0 > 0 })
    }
}

extension SleepView {
    // MARK: - Trend points

    /// Trailing 30 days of total sleep, plotted in HOURS. Falls back to all nights with
    /// data if the trailing window is too sparse.
    var durationTrendPoints: [TrendPoint] {
        let fmt = SleepView.dayParser
        func build(_ slice: ArraySlice<DailyMetric>) -> [TrendPoint] {
            slice.compactMap { d -> TrendPoint? in
                guard let mins = d.totalSleepMin, mins > 0,
                      let date = fmt.date(from: d.day) else { return nil }
                return TrendPoint(date: date, value: mins / 60.0)
            }
        }
        let recent = build(repo.days.suffix(30))
        if recent.count >= 2 { return recent }
        return build(repo.days[...])
    }

    func trendRange(_ pts: [TrendPoint]) -> ClosedRange<Double> {
        let vals = pts.map(\.value)
        let lo = Swift.max(0, (vals.min() ?? 0) - 1)
        let hi = (vals.max() ?? 9) + 1
        return lo...Swift.max(hi, lo + 1)
    }
}

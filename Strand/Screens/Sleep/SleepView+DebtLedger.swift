import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

extension SleepView {
    // MARK: - 2b. Sleep-debt ledger (rolling 14-night running balance)

    /// A running balance of (slept − personal need) across the recent fortnight, surfaced
    /// as one card: the net debt/surplus headline, a plain-English read, and a diverging
    /// bar of each night's delta (surplus above the line, deficit below). Honest: a simple
    /// accumulator — a surplus night offsets a deficit one — capped at 14 nights, no-data
    /// nights skipped. (#242)
    @ViewBuilder
    func sleepDebtLedger(_ model: SleepModel) -> some View {
        let ledger = model.sleepDebtLedger
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep-debt ledger", overline: "Last 14 nights",
                          trailing: "running balance")
            NoopCard(tint: StrandPalette.restColor) {
                if ledger.nightCount == 0 {
                    Text("No nights with sleep data yet — your ledger fills in as you wear the strap to bed.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                        // Headline: net balance (count-up on appear) + the short tag (DEBT / SURPLUS / ON
                        // TARGET). The number ticks from the accumulated magnitude via the same formatter.
                        HStack(alignment: .firstTextBaseline) {
                            CountUpText(
                                value: ledger.magnitudeMin,
                                format: { debtHeadline(forMagnitudeMin: $0, ledger: ledger) },
                                font: StrandFont.number(26),
                                color: debtBalanceColor(ledger)
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            Spacer(minLength: NoopMetrics.space2)
                            Text(debtTag(ledger))
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(debtBalanceColor(ledger))
                        }
                        // Plain-English read.
                        Text(debtRead(ledger))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // Per-night diverging delta bars (surplus up, deficit down).
                        debtDeltaBars(ledger)
                        Divider().overlay(StrandPalette.hairline)
                        ChartFooter([
                            ("Balance", debtSigned(ledger.balanceMin)),
                            ("Per-night need", durationText(ledger.needMin)),
                            ("Nights", "\(ledger.nightCount)"),
                        ])
                    }
                }
            }
        }
    }

    /// The diverging per-night delta strip: each night a bar from the centre line — up
    /// (accent) for a surplus, down (rose) for a deficit — scaled to the largest |delta|.
    @ViewBuilder
    func debtDeltaBars(_ ledger: SleepDebtLedger) -> some View {
        let deltas = ledger.nights.map { $0.deltaMin }
        let scale = max(deltas.map { abs($0) }.max() ?? 1, 1)
        GeometryReader { geo in
            let n = max(deltas.count, 1)
            let slot = geo.size.width / CGFloat(n)
            let barW = max(2, slot * 0.6)
            let midY = geo.size.height / 2
            ZStack(alignment: .topLeading) {
                // Centre (zero) line.
                Rectangle()
                    .fill(StrandPalette.hairline)
                    .frame(height: 1)
                    .position(x: geo.size.width / 2, y: midY)
                ForEach(Array(deltas.enumerated()), id: \.offset) { i, d in
                    let frac = CGFloat(abs(d) / scale)
                    let h = max(2, frac * (midY - 2))
                    let x = slot * CGFloat(i) + slot / 2
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(d >= 0 ? StrandPalette.accent : StrandPalette.metricRose)
                        .frame(width: barW, height: h)
                        // Surplus grows upward from the centre, deficit downward.
                        .position(x: x, y: d >= 0 ? midY - h / 2 : midY + h / 2)
                }
            }
        }
        .frame(height: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Per-night sleep balance: \(ledger.nightCount) nights, net \(debtSigned(ledger.balanceMin))")
    }
}

extension SleepView {
    // MARK: - Sleep-debt ledger formatting

    /// "≈2h 10m" magnitude headline — leading "≈" because it's an accumulated estimate.
    /// Reads "On target" inside the deadband so a few stray minutes don't show as debt.
    func debtHeadline(_ ledger: SleepDebtLedger) -> String {
        debtHeadline(forMagnitudeMin: ledger.magnitudeMin, ledger: ledger)
    }

    /// The same headline formatter, but for an arbitrary (interpolated) magnitude so `CountUpText` can
    /// render a coherent string on every frame as the number ticks up. The on-target deadband check
    /// uses the LIVE magnitude `m` so the headline crosses from "On target" to "≈…" mid-count exactly
    /// once, matching the final reading. Final-value identical to `debtHeadline(_:)`.
    func debtHeadline(forMagnitudeMin m: Double, ledger: SleepDebtLedger) -> String {
        if m < SleepDebt.onTargetBandMin { return "On target" }
        return "≈\(durationText(m))"
    }

    /// Short tag under/beside the headline: DEBT / SURPLUS / ON TARGET.
    func debtTag(_ ledger: SleepDebtLedger) -> String {
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin { return "balanced" }
        return ledger.isDebt ? "sleep debt" : "surplus"
    }

    /// Plain-English read of the running balance over the window.
    func debtRead(_ ledger: SleepDebtLedger) -> String {
        let nights = ledger.nightCount
        let span = "the last \(nights) night\(nights == 1 ? "" : "s")"
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin {
            return "You're roughly on top of your sleep across \(span) — slept minutes balance out against your need."
        }
        let mag = durationText(ledger.magnitudeMin)
        if ledger.isDebt {
            return "You've banked about \(mag) of sleep debt over \(span). Surplus nights count back against it — an earlier night or two would clear it."
        }
        return "You're carrying about \(mag) of surplus over \(span) — you've slept past your need on balance. Nicely ahead."
    }

    /// Color the balance by sign + size: surplus/within-band → positive green, modest
    /// debt → warning, heavier debt → critical.
    func debtBalanceColor(_ ledger: SleepDebtLedger) -> Color {
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin || !ledger.isDebt {
            return StrandPalette.statusPositive
        }
        // A debt: amber up to ~3 h accumulated, red beyond.
        return ledger.magnitudeMin < 180 ? StrandPalette.statusWarning : StrandPalette.statusCritical
    }

    /// Signed "+1h 20m" / "−2h 10m" / "0m" balance string.
    func debtSigned(_ minutes: Double) -> String {
        if abs(minutes) < 1 { return "0m" }
        let sign = minutes >= 0 ? "+" : "−"
        return "\(sign)\(durationText(abs(minutes)))"
    }
}

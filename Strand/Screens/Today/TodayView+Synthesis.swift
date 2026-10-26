import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

extension TodayView {
    /// Design Reset: the greeting + gold Synthesis read-out + vitals, lifted OUT of the hero so Today
    /// reads rings -> Heart rate -> Your cards (the flat mockup order). Same content + behaviour, it just
    /// sits below the HR card and the pinned cards now instead of crowding directly under the rings.
    @ViewBuilder
    var synthesisSection: some View {
        let d = displayDay
        let score = d?.recovery
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(greetingWord)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                recoveryStatePill(score: score)
                    .layoutPriority(1)
            }
            .accessibilityElement(children: .combine)

            if TodayDisplayRules.coachingCardsVisible {
                InsightCard(
                    category: "Synthesis",
                    status: calibrationStatus ?? "\(synthesisCardStatus(d, score: score))",
                    detail: calibrationDetail ?? "\(synthesisCardDetail(d, score: score))",
                    statusColor: StrandPalette.textPrimary,
                    tint: StrandPalette.chargeColor
                )
            }

            if let note = effortZeroNote {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.effortColor)
                    Text(note)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 2)
                .accessibilityElement(children: .combine)
            }

            // HRV / Resting HR / Respiratory — the vitals that drive recovery.
            recoveryVitalsCard(d)
        }
    }
}

extension TodayView {
    // MARK: Synthesis card — today's read, or the carried last-scored read (#543)

    /// The Synthesis status word, carrying the LAST scored day's read when today isn't scored yet (the
    /// post-rollover state) — so the card mirrors the carried Charge ring instead of reading "No Data".
    /// When today IS scored (or there's nothing to carry) it's today's own `hrvInsightStatus`.
    func synthesisCardStatus(_ d: DailyMetric?, score: Double?) -> String {
        if let prior = lastScoredRecoveryDay {
            return hrvInsightStatus(prior, score: prior.recovery)
        }
        return hrvInsightStatus(d, score: score)
    }

    /// The Synthesis detail line. When carrying a prior scored day it summarises THAT day and appends a
    /// "Last night · <date>" provenance, so the prior read is never silently passed off as today's.
    func synthesisCardDetail(_ d: DailyMetric?, score: Double?) -> String {
        if let prior = lastScoredRecoveryDay {
            return hrvInsightDetail(prior, score: prior.recovery) + " " + carriedCaption(prior) + "."
        }
        return hrvInsightDetail(d, score: score)
    }

    /// The Synthesis status colour — keyed on the carried prior recovery when carrying, else today's.
    func synthesisCardColor(score: Double?) -> Color {
        if let rec = lastScoredRecoveryDay?.recovery {
            return StrandPalette.recoveryColor(rec)
        }
        return score.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textTertiary
    }

    /// Screen-4 insight headline — when the HRV baseline is established, the gold "primed" read
    /// keyed on how far today's HRV sits above/below the learned baseline ("HRV 12% over baseline");
    /// otherwise the recovery-state word. Purely a re-presentation of the existing recovery + HRV
    /// bindings (no new computation beyond the baseline mean already available on `repo.days`).
    func hrvInsightStatus(_ d: DailyMetric?, score: Double?) -> String {
        guard let pct = hrvBaselineDeltaPct(d) else { return synthesisWord(score) }
        let sign = pct >= 0 ? "over" : "under"
        return "HRV \(abs(pct))% \(sign) baseline"
    }

    /// The supporting line for the screen-4 insight: the primed/steady read tied to the HRV delta,
    /// folding in the recovery-state synthesis so the card still reads as a coaching summary.
    func hrvInsightDetail(_ d: DailyMetric?, score: Double?) -> String {
        guard let pct = hrvBaselineDeltaPct(d) else { return synthesisDetail(d) }
        let lead: String
        if pct >= 8 { lead = "Your nervous system is well-recovered — you're primed to push" }
        else if pct >= -8 { lead = "You're in balance with your baseline — moderate strain is well-judged" }
        else { lead = "HRV is below your baseline — ease into the day" }
        return lead + ". " + synthesisDetail(d)
    }

    /// Today's HRV as a percentage above/below the learned baseline (mean of prior nights' avgHrv),
    /// rounded to a whole percent. nil until there are enough banked HRV nights to form a stable
    /// baseline (mirrors the recovery seed gate) — the insight then falls back to the state word.
    func hrvBaselineDeltaPct(_ d: DailyMetric?) -> Int? {
        guard let today = d?.avgHrv, today > 0 else { return nil }
        // Baseline = mean of the prior nights' HRV, excluding the row being read so "vs baseline"
        // compares it against the rest of history. Excludes the row's OWN day (not always the selected
        // day) so a carried prior-day synthesis (#543) isn't compared against a baseline that includes
        // itself. Needs the same seed depth recovery uses to be honest.
        let excludeDay = d?.day ?? selectedDayKey
        let prior = repo.days
            .filter { $0.day != excludeDay }
            .compactMap(\.avgHrv)
            .filter { $0 > 0 }
        return Self.hrvBaselineDeltaPct(today: today, priorHrvs: prior)
    }

    /// Pure core of the HRV-vs-baseline delta: today's HRV against the mean of the prior nights' HRV,
    /// rounded to a whole percent. nil until there are enough banked HRV nights to form a stable
    /// baseline (mirrors the recovery seed gate) — the insight then falls back to the state word.
    ///
    /// STOPGAP (#696): NOOP mixes HRV measurement methods on the shared `avgHrv` field —
    /// strap/WHOOP-CSV HRV is RMSSD (~20-100 ms) while Apple-Health-imported HRV is SDNN
    /// (~100-200 ms). With no method awareness, an SDNN reading (e.g. an Oura ring's 176 ms)
    /// compared against an RMSSD baseline (~57 ms) yields a physiologically-impossible delta
    /// (+209%) and renders the alarming "210% over baseline" headline. Genuine night-to-night
    /// HRV variation essentially never exceeds ~±80-100%, so a magnitude beyond that is almost
    /// always a units/method artifact rather than a real swing. We suppress the misleading
    /// percentage comparison (return nil → callers fall back to the qualitative recovery-state
    /// word) when the delta is implausibly large. The raw HRV tile value stays honest; only the
    /// "X% over baseline" comparison is hidden. Proper fix = tag HRV provenance/method per row
    /// and isolate baselines (separate follow-up).
    static func hrvBaselineDeltaPct(today: Double, priorHrvs prior: [Double]) -> Int? {
        guard today > 0 else { return nil }
        guard prior.count >= Baselines.minNightsSeed else { return nil }
        let baseline = prior.reduce(0, +) / Double(prior.count)
        guard baseline > 0 else { return nil }
        let pct = ((today - baseline) / baseline * 100).rounded()
        // Stopgap method-mismatch guard (#696): a real night-to-night HRV move never doubles or halves
        // the value, so a reading outside [0.5x, 2x] of the baseline is almost always a units/method
        // artifact (SDNN reads ~2-3x RMSSD) rather than a genuine swing. Drop the comparison in that case
        // so the alarming "X% over/under baseline" headline never renders (the insight falls back to the
        // qualitative recovery word). Gated on the RATIO, not abs(pct): the percentage is bounded at -100%
        // on the low side but unbounded high, so a symmetric abs() threshold can't catch a near-zero
        // reading. Proper fix tags HRV provenance/method per row and isolates baselines (follow-up).
        guard today <= 2.0 * baseline, today >= 0.5 * baseline else { return nil }
        return Int(pct)
    }
}

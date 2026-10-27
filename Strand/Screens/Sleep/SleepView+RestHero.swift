import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

extension SleepView {
    // MARK: - 0. REST HERO — scenic backdrop + sleep-performance gauge (Bevel)

    /// The fill fraction (0…1) the Rest hero gauge animates to — the night's sleep-performance
    /// score over 100. 0 when no score exists (the headline-hours hero shows instead). Cheap, so
    /// it's read every render to drive the draw-in animation.
    func heroScoreFraction(_ model: SleepModel?) -> Double {
        guard let p = model?.performance.latest else { return 0 }
        return min(max(p / 100.0, 0), 1)
    }

    /// The Rest world's opening: a scenic indigo backdrop with — when the night carries a 0–100
    /// sleep-performance score — a layered `BevelGauge` in the Rest gradient; otherwise a big
    /// SF-Rounded hours-slept headline over the same backdrop. A `SourceBadge` states whether the
    /// score is WHOOP's own imported figure or NOOP's on-device estimate. Presentation-only — the
    /// number comes straight from the existing `model.performance.latest` / hours computation. (Bevel)
    @ViewBuilder
    func restHero(_ model: SleepModel) -> some View {
        let score = model.performance.latest
        let frac = heroScoreFraction(model)
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep performance", overline: "Last night", trailing: "Rest")
            // A subtle night atmosphere sits behind the sleep hero ONLY (the Rest world's whisper:
            // faint indigo wash + crescent moon over the near-black canvas, no glow), clipped to the
            // card. Replaces the now-flat ScenicHeroBackground here.
            VStack(spacing: NoopMetrics.space4) {
                if let score {
                    BevelGauge(
                        fraction: frac,
                        stops: StrandPalette.restGradient.stops,
                        tipColor: StrandPalette.restColor,
                        numberText: "\(Int(score.rounded()))",
                        captionText: "of 100",
                        stateText: sleepScoreWord(score),
                        diameter: 184,
                        lineWidth: 15,
                        animatedFraction: heroFraction
                    )
                    .padding(.top, NoopMetrics.space1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Sleep performance \(Int(score.rounded())) of 100")
                } else {
                    // No 0–100 score for the night — lead with hours slept as a big rounded headline
                    // whose minutes tick up on appear (the same count-up the scored hero gets).
                    VStack(spacing: NoopMetrics.space1) {
                        CountUpText(
                            value: model.night.stages.asleep,
                            format: { durationText($0) },
                            font: StrandFont.number(46),
                            color: StrandPalette.restBright
                        )
                        Text("asleep last night")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .padding(.vertical, NoopMetrics.space5)
                    .accessibilityElement(children: .combine)
                }
                SourceBadge("\(score != nil ? model.performanceSource.badge : SleepPerformanceSource.onDevice.badge)",
                            tint: StrandPalette.restColor)
            }
            .padding(NoopMetrics.cardInnerPadding + NoopMetrics.space1)
            .frame(maxWidth: .infinity)
            .timeOfDayBackground(.night)
            .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        }
    }

    /// A short Rest state word for the hero gauge — same banding the synthesis hero uses.
    func sleepScoreWord(_ score: Double) -> String {
        switch score {
        case ..<50:  return "Poor"
        case ..<70:  return "Fair"
        case ..<85:  return "Good"
        default:     return "Optimal"
        }
    }

    // The hero badge reads `model.performanceSource`, resolved by `SleepPerformanceResolver` from the SAME
    // day the displayed score comes from (the newest day that HAS a score), not from `repo.days.last`.

    // MARK: - Provenance for the displayed night (COMPONENT 4, spec 2026-06-20)

    /// The REAL per-day merge winner for the DISPLAYED night's sleep numbers, as the same brand wording the
    /// By-Day badge / Today / Intelligence use ("On-device" / "Whoop"). A WHOOP export covering the night's
    /// wake-day wins the dashboard merge (imports win field-by-field, Repository.mergeDaily), so the badge
    /// says "Whoop"; otherwise the night was scored on-device by NOOP. Keyed by the night's LOCAL wake-day
    /// (the `mergeSleep` / importer convention, sleep is filed under the day you woke), so a navigated past
    /// night reads its OWN provenance, not last night's. Honest: never a blanket "on-device". Apple Health
    /// carries no sleep into `importedSleep`, so the sleep merge winner is only ever Whoop vs on-device. (C4)
    func nightSource(_ night: Night) -> String {
        let wakeDay = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(night.session.endTs)))
        return SleepPerformanceResolver.nightSource(wakeDay: wakeDay, imported: repo.importedSleep).badge
    }
}

import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

extension TodayView {
    // MARK: Readiness — on-device training-readiness synthesis (HRV / resting-HR / load).

    @ViewBuilder
    var readinessSection: some View {
        let r = readiness
        if r.level != .insufficient {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                // When Readiness is anchored on the carried last-scored day (#543), the overline stamps
                // its date so the prior read isn't passed off as today's; otherwise the usual prompt.
                SectionHeader("Readiness",
                              overline: lastScoredRecoveryDay.map { "\(carriedCaption($0))" } ?? "Should you push today?")
                NoopCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Circle().fill(readinessColor(r.level)).frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                            Text(r.headline).font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .accessibilityLabel("Readiness: \(levelWord(r.level)). \(r.headline)")
                            Spacer()
                            if let acwr = r.acwr {
                                Text("load \(String(format: "%.2f", acwr))")
                                    .font(StrandFont.captionNumber)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .help("Acute (7-day) vs chronic (28-day) training load. 0.8–1.3 is the sweet spot.")
                            }
                        }
                        Text(r.summary).font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !r.signals.isEmpty {
                            Divider().overlay(StrandPalette.hairline)
                            ForEach(r.signals, id: \.key) { s in
                                HStack(alignment: .top, spacing: 8) {
                                    // Glyph + colour (not colour alone) so the flag reads
                                    // for colour-blind users; hidden from VoiceOver since the
                                    // flag word is folded into the row's combined label below.
                                    Image(systemName: flagSymbol(s.flag))
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(flagColor(s.flag))
                                        .padding(.top, 4)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.label).font(StrandFont.caption)
                                            .foregroundStyle(StrandPalette.textSecondary)
                                        if let evidence = s.evidence {
                                            Text(evidence).font(StrandFont.captionNumber)
                                                .foregroundStyle(StrandPalette.textTertiary)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.8)
                                        }
                                    }
                                        .frame(width: 104, alignment: .leading)
                                    Text(s.detail).font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(s.label), \(flagWord(s.flag)): \(s.detail)")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // Word + glyph equivalents so the colour-coded severity isn't carried by hue
    // alone — read by VoiceOver and visible to colour-blind users.
    func levelWord(_ l: ReadinessEngine.Level) -> String {
        switch l {
        case .primed:       return "Primed"
        case .balanced:     return "Balanced"
        case .strained:     return "Strained"
        case .rundown:      return "Run down"
        case .insufficient: return "Not enough data"
        }
    }

    func flagWord(_ f: ReadinessEngine.Flag) -> String {
        switch f {
        case .good:    return "Good"
        case .neutral: return "Neutral"
        case .watch:   return "Watch"
        case .bad:     return "Alert"
        }
    }

    /// Colour-independent glyph so severity isn't conveyed by hue alone.
    func flagSymbol(_ f: ReadinessEngine.Flag) -> String {
        switch f {
        case .good:    return "checkmark.circle.fill"
        case .neutral: return "minus.circle.fill"
        case .watch:   return "exclamationmark.circle.fill"
        case .bad:     return "exclamationmark.triangle.fill"
        }
    }

    func readinessColor(_ l: ReadinessEngine.Level) -> Color {
        switch l {
        case .primed:       return StrandPalette.accent
        case .balanced:     return StrandPalette.statusPositive
        case .strained:     return StrandPalette.statusWarning
        case .rundown:      return StrandPalette.metricRose
        case .insufficient: return StrandPalette.textTertiary
        }
    }

    func flagColor(_ f: ReadinessEngine.Flag) -> Color {
        switch f {
        case .good:    return StrandPalette.accent
        case .neutral: return StrandPalette.textTertiary
        case .watch:   return StrandPalette.statusWarning
        case .bad:     return StrandPalette.metricRose
        }
    }
}

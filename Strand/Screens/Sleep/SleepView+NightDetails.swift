import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

extension SleepView {
    /// The night's clock window — when you fell asleep and when you woke — as its own clearly
    /// labelled row. These were previously only in the nav-header's trailing caption, which
    /// truncates between the two chevrons on a phone, so in practice the two times people look for
    /// first were effectively hidden. The header now carries just the date span.
    @ViewBuilder
    func sleepWindowRow(_ night: Night) -> some View {
        // A frosted Rest-tinted card (was a flat surfaceRaised block) so the window row sits in the
        // same colour world as the rest of the screen. Bevel treatment — content unchanged.
        NoopCard(padding: NoopMetrics.cardInnerPadding, tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                HStack(spacing: 0) {
                    sleepTime(icon: "moon.zzz.fill", label: "Asleep", value: night.onsetText)
                    Spacer(minLength: 12)
                    Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 30)
                    Spacer(minLength: 12)
                    sleepTime(icon: "sun.max.fill", label: "Woke", value: night.wakeText)
                    Spacer(minLength: 8)
                    wakeEditButton(night)
                }
                .frame(maxWidth: .infinity)
                // Provenance (C4) + the "why this is your main sleep" explainer (C1). The badge names the
                // REAL per-day merge winner; the info button reveals the foundation reason for the pick.
                Divider().overlay(StrandPalette.hairline)
                mainSleepFooter(night)
            }
        }
    }

    /// The hero's footer: the night's provenance badge (the real merge winner) next to a tappable "why
    /// this is your main sleep" affordance. Tapping reveals the foundation `MainNightReason` copy in a
    /// popover, so the pick is explainable on the spot without leaving the hero. (spec 2026-06-20 C1/C4)
    @ViewBuilder
    func mainSleepFooter(_ night: Night) -> some View {
        HStack(spacing: 10) {
            // C4 — provenance. Dynamic String into the badge slot, so wrap in "\()" (the
            // String vs LocalizedStringKey SwiftUI footgun) to show it verbatim, not as a lookup key.
            SourceBadge("\(nightSource(night))", tint: StrandPalette.restColor)
            Spacer(minLength: 8)
            if mainSleepReasonText(night) != nil {
                Button { showMainSleepWhy.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "info.circle")
                        Text("Why this sleep?")
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.restColor)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Why this is your main sleep")
                .accessibilityLabel("Why this is your main sleep")
                .popover(isPresented: $showMainSleepWhy, arrowEdge: .bottom) {
                    whyPopover(text: mainSleepReasonText(night) ?? "", napSuffix: false)
                }
            }
        }
    }

    /// A compact explainer popover: the verbatim foundation reason text, with the nap suffix appended for a
    /// nap row. Plain English, no jargon, no em-dashes (the words come straight from `mainSleepReasonText`
    /// and the spec's nap-row suffix). Sized for both macOS and iOS. (spec 2026-06-20 C1)
    @ViewBuilder
    func whyPopover(text: String, napSuffix: Bool) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(spacing: NoopMetrics.space2) {
                Image(systemName: "moon.stars.fill")
                    .foregroundStyle(StrandPalette.restColor)
                    .accessibilityHidden(true)
                Text(napSuffix ? "About this nap" : "About your main sleep")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            if !text.isEmpty {
                Text(text)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if napSuffix {
                Text("Logged as a nap. Wrong? Tap Edit to adjust your sleep and wake times.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(NoopMetrics.cardInnerPadding)
        .frame(width: 260)
        .background(StrandPalette.surfaceOverlay)
        .accessibilityElement(children: .combine)
    }

    func sleepTime(icon: String, label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.restColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).strandOverline()
                Text(value).font(StrandFont.number(22)).foregroundStyle(StrandPalette.textPrimary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Pencil affordance that opens the wake-time editor for `night`. Auto-detection misreads the wake
    /// time most often (a late lie-in, or a morning stir read as still-asleep), so a one-tap correction
    /// lives right next to the "Woke" value. A filled pencil marks a night already hand-corrected. (#318)
    ///
    /// The hero shows a MERGED/synthetic Night — its `session` carries no `stagesJSON` and a reset
    /// `userEdited` (mergeDay), with the real stage data in `night.stages`. So resolve the actual stored
    /// block we're editing — the one whose wake time IS the night's wake — and edit against its detected
    /// startTs key, current effective bed/wake (to seed the pickers), stagesJSON, and edited state.
    @ViewBuilder
    func wakeEditButton(_ night: Night) -> some View {
        // Resolve the real stored block by identity (the night's main block), never by re-scanning
        // `allSessions` for a wake-time match — that guess could pick the wrong source/night and, when
        // it missed, fall back to the synthetic effective onset (not a real key) so the edit no-oped.
        if let target = night.editTarget {
            let isEdited = target.userEdited
            Button {
                wakeEdit = WakeEdit(detectedStartTs: target.startTs,
                                    bedTs: target.effectiveStartTs,
                                    wakeTs: target.endTs,
                                    stagesJSON: target.stagesJSON)
            } label: {
                Image(systemName: isEdited ? "pencil.circle.fill" : "pencil.circle")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.restColor)
            }
            .buttonStyle(.plain)
            .help("Edit sleep times")
            .accessibilityLabel(isEdited ? "Edit sleep times (edited)" : "Edit sleep times")
        }
    }

    /// Full-width proportional stacked stage bar (fallback when no intervals).
    @ViewBuilder
    func stageBar(_ s: Stages) -> some View {
        let total = max(1, s.total)
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    segment(.deep, s.deep, total, geo.size.width)
                    segment(.light, s.light, total, geo.size.width)
                    segment(.rem, s.rem, total, geo.size.width)
                    segment(.awake, s.awake, total, geo.size.width)
                }
            }
            .frame(height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sleep stage breakdown: deep \(pct(s.deep, s.total)) percent, light \(pct(s.light, s.total)) percent, REM \(pct(s.rem, s.total)) percent, awake \(pct(s.awake, s.total)) percent")
            HStack(spacing: 16) {
                legend(.deep, "Deep")
                legend(.light, "Light")
                legend(.rem, "REM")
                legend(.awake, "Awake")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    func segment(_ stage: SleepStage, _ minutes: Double, _ total: Double, _ width: CGFloat) -> some View {
        let w = CGFloat(minutes / total) * width
        Rectangle()
            .fill(StrandPalette.sleepStageColor(stage))
            .frame(width: max(0, w))
    }

    @ViewBuilder
    func legend(_ stage: SleepStage, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(StrandPalette.sleepStageColor(stage))
                .frame(width: 9, height: 9)
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }
}

extension SleepView {
    /// Header above the hypnogram with ◀/▶ to browse past nights. ◀ goes older (increasing offset),
    /// ▶ goes newer; each is disabled at its bound. The canonical SectionHeader carries the
    /// hierarchy so the hero reads like every other section. (#160)
    @ViewBuilder
    func nightNavHeader(trailing: String) -> some View {
        let lastIndex = max(navDays.count - 1, 0)
        let title: LocalizedStringKey = nightOffset == 0 ? "Last night"
            : (nightOffset == 1 ? "1 night ago" : "\(nightOffset) nights ago")
        HStack(spacing: NoopMetrics.cardInnerSpacing) {
            Button { if nightOffset < lastIndex { nightOffset += 1 } } label: {
                Image(systemName: "chevron.left")
                    .font(StrandFont.headline)
                    .foregroundStyle(nightOffset >= lastIndex ? StrandPalette.textTertiary : StrandPalette.accent)
            }
            .buttonStyle(.plain)
            .disabled(nightOffset >= lastIndex)
            .accessibilityLabel("Previous night")

            SectionHeader(title, overline: "Sleep", trailing: trailing)

            Button { if nightOffset > 0 { nightOffset -= 1 } } label: {
                Image(systemName: "chevron.right")
                    .font(StrandFont.headline)
                    .foregroundStyle(nightOffset == 0 ? StrandPalette.textTertiary : StrandPalette.accent)
            }
            .buttonStyle(.plain)
            .disabled(nightOffset == 0)
            .accessibilityLabel("Next night")
        }
    }
}

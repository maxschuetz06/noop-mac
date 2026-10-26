import SwiftUI
import StrandDesign

// MARK: - How NOOP works (primer)
//
// COMPONENT 5 of the Sleep & Recovery Guidance / Explainability layer
// (docs/superpowers/specs/2026-06-20-sleep-guidance-explainability.md).
//
// A short, skimmable, plain-English primer that answers the four "how does this
// work?" questions people ask: how sleep is sorted, how scores + calibration work,
// what "recording" means, and where the provenance badges come from. It is the one
// place that ties the four guidance components together so nobody has to guess.
//
// Presented as a sheet, mirroring ScoringGuideView / WhatsNewView exactly: a fixed
// header with a close button over a scenic hero, a scrollable column of frosted
// cards, and a "Got it" footer. Reachable from Settings → About and a "?" affordance.
//
// All copy here is the single APPROVED source of truth (the spec's COMPONENT 5 text,
// verbatim), shared word-for-word across macOS / iOS / Android. No fabricated values,
// no jargon, no em-dashes. Kotlin's primer composable mirrors these four sections.

struct HowNoopWorksView: View {
    let onClose: () -> Void

    /// The four primer sections, in the order the spec lists them. The icon + tint give
    /// each card its own glance-able identity, echoing the colour worlds used elsewhere.
    private enum Section: CaseIterable, Identifiable {
        case sleepSorting
        case scores
        case recording
        case provenance

        var id: Self { self }

        var title: String {
            switch self {
            case .sleepSorting: return "How your sleep is sorted"
            case .scores:       return "How your scores work"
            case .recording:    return "What \"recording\" means"
            case .provenance:   return "Where your numbers come from"
            }
        }

        var body: String {
            switch self {
            case .sleepSorting:
                return "NOOP picks your main sleep as your longest real block, and (once it has learned your usual hours) the one nearest your normal sleep time. Everything else that day is a nap. You can always edit bed and wake times."
            case .scores:
                return "Charge, Effort and Rest are scored on your own device from your strap data. They get personal after about two weeks of your nights (that's \"Calibrating\"). Before that NOOP shows what it can without faking a number."
            case .recording:
                return "When your strap is connected NOOP is saving data live. \"Last synced\" tells you how fresh it is. If it says \"Not recording\", reconnect."
            case .provenance:
                return "A badge shows whether a number was scored on-device by NOOP, or imported from Whoop or Apple Health."
            }
        }

        /// SF Symbol for the section header — sleep / scores / recording / provenance.
        var icon: String {
            switch self {
            case .sleepSorting: return "moon.zzz.fill"
            case .scores:       return "gauge.with.dots.needle.67percent"
            case .recording:    return "dot.radiowaves.left.and.right"
            case .provenance:   return "checkmark.seal.fill"
            }
        }

        /// The colour world that tints the card, matched to the domain each section is about
        /// (sleep = Rest, scores = Charge, recording = Effort, provenance = neutral accent).
        var tint: Color {
            switch self {
            case .sleepSorting: return DomainTheme.rest.color
            case .scores:       return DomainTheme.charge.color
            case .recording:    return DomainTheme.effort.color
            case .provenance:   return StrandPalette.accent
            }
        }

        /// Short overline tag above the section title.
        var overline: String {
            switch self {
            case .sleepSorting: return "SLEEP"
            case .scores:       return "SCORES"
            case .recording:    return "RECORDING"
            case .provenance:   return "PROVENANCE"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .background {
                    ScenicHeroBackground(domain: .rest, starCount: 28, fadesToBase: true)
                }
            Divider().overlay(StrandPalette.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    introCard
                    ForEach(Section.allCases) { section in
                        primerCard(section)
                    }
                    footerNote
                }
                .padding(20)
            }
            Divider().overlay(StrandPalette.hairline)
            footerBar
        }
        // Same sizing split as ScoringGuideView / WhatsNewView: a fixed window on macOS,
        // fill the presented sheet on iOS so nothing runs off a narrow phone screen (#185).
        #if os(macOS)
        .frame(width: 560, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .noopSheetPresentation(largeFirst: true)
        #endif
        .background(StrandPalette.surfaceBase)
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("THE BASICS").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("How NOOP works").font(StrandFont.rounded(26, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Sleep · scores · recording · where your numbers come from")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(20)
    }

    private var footerBar: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Text("Got it").frame(minWidth: 120).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(StrandPalette.accent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Cards

    private var introCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("THE ONE RULE").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("NOOP never shows you a number it had to make up. If a score isn't ready, it tells you why and what to do next. Everything here runs on your device, from your strap.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One primer section: a frosted, tinted card carrying the tinted icon + overline +
    /// title, then the plain-English body. The icon is decorative (hidden from
    /// VoiceOver); the card reads its title and body together.
    private func primerCard(_ section: Section) -> some View {
        NoopCard(tint: section.tint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: section.icon)
                        .font(.system(size: 18))
                        .foregroundStyle(section.tint)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.overline)
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .textCase(.uppercase)
                            .foregroundStyle(section.tint)
                        Text(section.title)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                Text(section.body)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(section.title). \(section.body)")
    }

    private var footerNote: some View {
        Text("NOOP never makes up a number. When it can't compute one honestly it tells you what's missing and what to do, rather than showing a fake value.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

#if DEBUG
#Preview("How NOOP works") {
    HowNoopWorksView(onClose: {})
        .preferredColorScheme(.dark)
}
#endif

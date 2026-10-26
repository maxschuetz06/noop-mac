import SwiftUI
import StrandDesign

/// About — what this build is, where to report problems, and the projects it is built on.
struct AboutView: View {
    var body: some View {
        ScreenScaffold(title: "About",
                       subtitle: "This Mac app is an unofficial fork of NOOP by NoopApp. It is not maintained or endorsed by NoopApp.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    SectionHeader("Help & Contact", overline: "Get in touch")
                    linkCard(icon: "exclamationmark.bubble.fill", title: "Report an issue",
                             detail: "Questions, feedback and bugs go to this fork's GitHub issues.",
                             url: ProjectInfo.issuesURL)
                    linkCard(icon: "chevron.left.forwardslash.chevron.right", title: "Original NOOP",
                             detail: "The upstream project by NoopApp that this fork is based on.",
                             url: ProjectInfo.upstreamURL)
                    builtOnCard
                }
                .staggeredAppear(index: 0)
                disclaimerCard
                    .staggeredAppear(index: 1)
            }
        }
    }

    /// A frosted card that opens `url`: a tinted leading glyph, a title + detail stack and a trailing
    /// accent chevron.
    private func linkCard(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey,
                          url: URL) -> some View {
        NoopCard {
            Button {
                PlatformOpen.url(url)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .frame(width: 28, height: 28)
                        .background(StrandPalette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text(detail).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(url.absoluteString)
        }
    }

    private var builtOnCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "hands.clap.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .frame(width: 28, height: 28)
                        .background(StrandPalette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Built on").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                }
                Text("This stands on community reverse-engineering. Huge thanks:")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                ForEach(Array(ProjectInfo.attributions.enumerated()), id: \.element.repo) { index, a in
                    if index > 0 { Divider().overlay(StrandPalette.hairline) }
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
                        Text(a.repo).font(StrandFont.mono(12)).foregroundStyle(StrandPalette.textPrimary)
                        Text("· \(a.note)").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var disclaimerCard: some View {
        NoopCard(padding: 18) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundStyle(StrandPalette.textTertiary)
                    .font(.system(size: 13)).accessibilityHidden(true)
                Text("Not affiliated with, endorsed by, or connected to WHOOP. Interoperability software for hardware you own and your own data. Use it only with a device you own, and not in breach of any agreement that applies to you. Not a medical device.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

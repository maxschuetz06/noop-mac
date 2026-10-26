import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotosUI
import StrandDesign
import StrandAnalytics
import WhoopStore

extension SettingsView {
    // MARK: - About

    /// The real marketing version straight from the bundle (CFBundleShortVersionString, set from
    /// project.yml MARKETING_VERSION), so the About pill can never go stale the way a hand-edited
    /// Swift constant can. Mirrors how Android's pill reads BuildConfig.VERSION_NAME. Falls back to
    /// the hand-maintained changelog version only if the Info.plist key is somehow missing.
    var bundleVersionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? AppChangelog.currentVersion
    }

    var aboutCard: some View {
        SettingsSection(
            icon: "info.circle.fill",
            title: "About",
            blurb: "NOOP — all your data, none of the cloud."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("NOOP")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    StatePill("v\(bundleVersionString)", tone: .neutral, showsDot: false)
                    Spacer()
                    NoopButton("What's new", systemImage: "sparkles", kind: .secondary) {
                        showWhatsNew = true
                    }
                }

                // How NOOP works — the plain-English primer: how sleep is sorted, how scores +
                // calibration work, what recording means, and where the provenance badges come
                // from. The "?" entry point to the four-section explainability primer.
                Button {
                    showHowNoopWorks = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("How NOOP works")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("Sleep sorting, scores, recording, and where your numbers come from.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("How NOOP works")

                // How your scores work — the honest explainer for Charge / Effort / Rest and the
                // confidence labels. Always reachable here, mirroring the "What's new" affordance.
                Button {
                    showScoringGuide = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("How your scores work")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("Charge, Effort and Rest — and how they differ from WHOOP.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("How your scores work")

                // Storage (#590) — on-device space breakdown (database, leftover import Inbox, stranded
                // temp files) plus a one-tap clean-up. iOS is where "Documents & Data" can balloon after
                // an Apple Health import; it compiles + reads fine on macOS too, so the link is unconditional.
                NavigationLink {
                    StorageView()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Storage")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("Where NOOP's on-device space is going — and a one-tap clean-up.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Storage")

                // Check for updates — a single, user-initiated read of GitHub's public releases API.
                // No background polling, no auto-update; sends nothing about you, just reads the version.
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    HStack(spacing: NoopMetrics.space2 + 2) {
                        Button {
                            // Compare the ACTUAL installed bundle version against GitHub's latest, not the
                            // hand-maintained AppChangelog.currentVersion (which drifts stale and told v7
                            // users they were behind, #697-adjacent). Mirrors Android's BuildConfig check.
                            updateChecker.check(currentVersion: bundleVersionString)
                        } label: {
                            if updateChecker.state == .checking {
                                HStack(spacing: NoopMetrics.space1 + 2) {
                                    ProgressView().controlSize(.small)
                                    Text("Checking…")
                                }
                            } else {
                                Label("Check for updates", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .buttonStyle(NoopButtonStyle(.secondary))
                        .disabled(updateChecker.state == .checking)

                        if case .upToDate(let v) = updateChecker.state {
                            Text("You're on the latest (\(v)).")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        } else if case .failed = updateChecker.state {
                            Text("Couldn't check. Try again.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.statusWarning)
                        }
                        Spacer()
                    }

                    // Update available: show what's new, with a download straight to the release.
                    if case .available(let v, let url, let notes) = updateChecker.state {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Version \(v) is available")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                NoopButton("Download", systemImage: "arrow.down.circle.fill", kind: .primary) {
                                    openURL(url)
                                }
                            }
                            if !notes.isEmpty {
                                ScrollView {
                                    Text(notes)
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 150)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(StrandPalette.surfaceInset,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(StrandPalette.accent.opacity(0.3), lineWidth: 1)
                        )
                    }

                    Text("Checks the project's home (GitHub) for the latest version when you tap — nothing else is sent.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                // Project home — this fork's code, releases and issues live on GitHub.
                Link(destination: ProjectInfo.repositoryURL) {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Project home & source")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("GitHub — code, releases and issues.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Project home and source code at noop dot fans")

                Text("A standalone companion for your WHOOP. Everything stays on this device — your history, your live stream, your numbers. Nothing is uploaded. NOOP is an independent, experimental project, not the WHOOP app.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Medical disclaimer
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(StrandPalette.statusWarning)
                        .font(.system(size: 13))
                        .accessibilityHidden(true)
                    Text("NOOP is not a medical device. It is for informational and personal-insight purposes only and is not intended to diagnose, treat, cure or prevent any condition. Talk to a clinician for medical advice.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(StrandPalette.statusWarning.opacity(0.25), lineWidth: 1)
                )

                rowDivider

                VStack(alignment: .leading, spacing: 6) {
                    Text("Built on").strandOverline()
                    attribution(repo: "johnmiddleton12/my-whoop", note: "WHOOP 4.0 protocol")
                    attribution(repo: "b-nnett/goose", note: "WHOOP 5.0 protocol")
                }

                Text("Open-source BLE reverse-engineering work. Thank you.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    func attribution(repo: String, note: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .accessibilityHidden(true)
            Text(repo)
                .font(StrandFont.mono(12))
                .foregroundStyle(StrandPalette.textPrimary)
            Text("· \(note)")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

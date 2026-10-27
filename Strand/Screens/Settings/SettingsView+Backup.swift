import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotosUI
import StrandDesign
import StrandAnalytics
import WhoopStore

extension SettingsView {
    // MARK: - Backup & restore

    var backupCard: some View {
        SettingsSection(
            icon: "externaldrive.fill",
            title: "Backup & restore",
            blurb: "Move all your NOOP data to another machine. Export saves everything — history, sleeps, workouts, settings — to a single file you can copy across; import replaces \(Platform.deviceNounPhrase)'s data with a backup."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                // Three labelled buttons must share a narrow iPhone row without wrapping mid-word
                // (the labels otherwise broke to one character per line). Equal width + shrink-to-fit
                // keeps each on a single line. On iPhone the SF Symbol icons were the main space-thief
                // (~90pt/button) and there's no room for them in a 3-up row, so we drop to icon-less
                // text there; macOS is wide enough to keep the icons. No trailing Spacer/ProgressView
                // inside this HStack — either would steal a share of the equal-width row. (#188)
                HStack(spacing: NoopMetrics.space3) {
                    Button {
                        runExport()
                    } label: {
                        backupButtonLabel("Export…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                    .disabled(backupBusy)

                    Button {
                        runImport()
                    } label: {
                        backupButtonLabel("Import…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                    .disabled(backupBusy)

                    Button {
                        runCsvExport()
                    } label: {
                        backupButtonLabel("Export CSV…", systemImage: "tablecells")
                    }
                    .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                    .disabled(backupBusy)
                }

                if backupBusy {
                    HStack(spacing: NoopMetrics.space2) {
                        ProgressView().controlSize(.small)
                        Text("Working…")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(StrandPalette.textTertiary)
                        .font(.system(size: 13))
                        .accessibilityHidden(true)
                    Text("Importing overwrites everything currently on \(Platform.deviceNounPhrase). Your old data is kept in a side file just in case. NOOP needs a relaunch for an import to take effect. Export CSV writes a WHOOP-format zip of your days, sleeps, workouts and journal that re-imports into NOOP on Mac, iPhone, or Android — on-device computed rows are marked APPROXIMATE in its Source column; the full backup stays the lossless restore path.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // Equal-width, single-line label for the three Backup buttons. (#188)
    @ViewBuilder
    func backupButtonLabel(_ title: String, systemImage: String) -> some View {
        // The NoopButtonStyle (fullWidth) owns the width + padding; the label just supplies the
        // content and the single-line shrink-to-fit so the 3-up row never wraps mid-word (#188).
        Label(title, systemImage: systemImage)
            .lineLimit(1).minimumScaleFactor(0.7)
    }

    func runExport() {
        backupBusy = true
        Task {
            let result = await DataBackup.runExport(checkpoint: { await model.repo.checkpointForBackup() })
            handleBackup(result)
        }
    }

    func runImport() {
        backupBusy = true
        Task {
            let result = await DataBackup.runImport()
            handleBackup(result)
        }
    }

    func runCsvExport() {
        backupBusy = true
        Task {
            let result = await CsvExport.run(repo: model.repo)
            backupBusy = false
            switch result {
            case .cancelled:
                return
            case .exported(let url):
                backupAlertTitle = "CSV exported"
                backupAlertMessage = "Saved to \(url.lastPathComponent). The zip re-imports into NOOP (Data Sources → WHOOP Export) on any Mac, iPhone, or Android device."
                showBackupAlert = true
            case .failure(let message):
                backupAlertTitle = "Export problem"
                backupAlertMessage = message
                showBackupAlert = true
            }
        }
    }

    @MainActor
    func handleBackup(_ result: DataBackup.BackupResult) {
        backupBusy = false
        switch result {
        case .cancelled:
            return
        case .exported(let url):
            backupAlertTitle = "Backup exported"
            backupAlertMessage = "Saved to \(url.lastPathComponent). Copy this file to your other \(Platform.deviceNoun) and use Import there to restore everything."
            showBackupAlert = true
        case .imported:
            backupAlertTitle = "Backup imported"
            backupAlertMessage = "Your data has been restored. Quit and reopen NOOP for it to take effect."
            showBackupAlert = true
        case .failure(let message):
            backupAlertTitle = "Backup problem"
            backupAlertMessage = message
            showBackupAlert = true
        }
    }
}

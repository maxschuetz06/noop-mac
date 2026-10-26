import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotosUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - App card (macOS: launch at login + language)

/// "App" settings for the Mac build: start NOOP at login (`SMAppService.mainApp`) and pick the UI
/// language (`AppLanguage` → the app's own `AppleLanguages` default, effective after a relaunch).
struct AppSettingsCard: View {
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @State private var language = AppLanguage.current()
    @State private var relaunchError: String?

    /// On while registered — including "waiting for approval", so the switch matches the pending state.
    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled || launchAtLogin.requiresApproval },
            set: { on in try? launchAtLogin.setEnabled(on) }
        )
    }

    var body: some View {
        SettingsSection(
            icon: "gearshape",
            title: "App",
            blurb: "How NOOP starts and which language it uses on this Mac."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Toggle(isOn: launchBinding) {
                    Text("Launch at login")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("Starts NOOP automatically so your strap keeps syncing without an open window.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if launchAtLogin.requiresApproval {
                    Button("Approve in System Settings") { launchAtLogin.openLoginItemsSettings() }
                        .buttonStyle(NoopButtonStyle(.secondary))
                }
                if let error = launchAtLogin.lastError {
                    Text(error)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(StrandPalette.hairline)

                FormRow(label: "Language") {
                    Picker("Language", selection: languageBinding) {
                        Text("System").tag(AppLanguage.system)
                        Text(verbatim: "Deutsch").tag(AppLanguage.german)
                        Text(verbatim: "English").tag(AppLanguage.english)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityLabel("Language")
                }
                Text("The language changes after you restart the app.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Restart now") { relaunch() }
                    .buttonStyle(NoopButtonStyle(.secondary))
                if let relaunchError {
                    Text(relaunchError)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { launchAtLogin.refresh() }
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { language },
            set: { newValue in
                language = newValue
                newValue.apply()
            }
        )
    }

    /// Open a fresh instance of this app, then quit the current one so the new language is picked up.
    /// Terminates only after the new instance launched, so a failed relaunch never just closes the app.
    private func relaunch() {
        relaunchError = nil
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    relaunchError = error.localizedDescription
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

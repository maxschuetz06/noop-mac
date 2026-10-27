import Foundation
import ServiceManagement

/// Thin observable wrapper around `SMAppService.mainApp` (macOS 13+) for the Settings "Launch at login"
/// toggle. The real system status is the single source of truth — nothing is persisted separately, so the
/// toggle can never disagree with System Settings → General → Login Items.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    /// `true` while the app is registered as a login item (status `.enabled`).
    @Published private(set) var isEnabled = false
    /// `true` when registration succeeded but the user still has to approve it in System Settings.
    @Published private(set) var requiresApproval = false
    /// Localized description of the last register/unregister failure, if any.
    @Published private(set) var lastError: String?

    init() { refresh() }

    /// Re-read the live status from `SMAppService.mainApp`.
    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = (status == .enabled)
        requiresApproval = (status == .requiresApproval)
    }

    /// Register or unregister the app as a login item, then re-sync with the real status.
    func setEnabled(_ on: Bool) throws {
        lastError = nil
        defer { refresh() }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Open System Settings → General → Login Items so the user can approve the pending registration.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

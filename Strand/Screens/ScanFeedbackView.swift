import SwiftUI
import StrandDesign
#if canImport(UIKit)
import UIKit
#endif

/// Visible feedback for a strap scan (Settings → Re-scan, Live → Scan & connect, the menu bar): a
/// "Searching…" pill while scanning, a blocker explanation when Bluetooth is unavailable (with a button
/// to the Bluetooth privacy pane when permission is missing), and a pairing-mode hint on timeout.
/// Renders nothing while idle, so it can sit permanently under a scan button.
struct ScanFeedbackView: View {
    @EnvironmentObject private var live: LiveState
    @Environment(\.openURL) private var openURL
    /// Pill + one short line only (menu bar); the full variant also shows the action button.
    var compact: Bool = false

    /// System Settings → Privacy & Security → Bluetooth (macOS) / this app's settings page (iOS).
    static var bluetoothSettingsURL: URL? {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
        #elseif canImport(UIKit)
        URL(string: UIApplication.openSettingsURLString)
        #else
        nil
        #endif
    }

    private var content: (title: String, tone: StrandTone, detail: String?, spinner: Bool)? {
        switch live.scanPhase {
        case .idle:
            return nil
        case .scanning:
            return ("Searching for WHOOP…", .accent, nil, true)
        case .connecting:
            return ("Connecting to your WHOOP…", .accent, nil, true)
        case .timedOut:
            return ("No WHOOP found yet", .warning, ScanFeedback.timeoutMessage, false)
        case .blocked(let availability):
            return ("Can't scan", .critical, availability.blockerMessage, false)
        }
    }

    var body: some View {
        if let content {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if content.spinner {
                        ProgressView().controlSize(.small)
                    }
                    StatePill(LocalizedStringKey(content.title), tone: content.tone, showsDot: !content.spinner)
                    Spacer(minLength: 0)
                }
                if let detail = content.detail {
                    Text(detail)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !compact, case .blocked(let availability) = live.scanPhase, availability.needsPermission,
                   let url = Self.bluetoothSettingsURL {
                    NoopButton("Open Bluetooth settings", systemImage: "gearshape", kind: .secondary) {
                        openURL(url)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

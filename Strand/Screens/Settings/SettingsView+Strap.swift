import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotosUI
import StrandDesign
import StrandAnalytics
import WhoopStore

extension SettingsView {
    // MARK: - Strap

    var strapCard: some View {
        SettingsSection(
            icon: "antenna.radiowaves.left.and.right",
            title: "Strap",
            blurb: "NOOP pairs directly with your WHOOP over Bluetooth — no WHOOP app, no cloud."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    StatePill("\(strapStatusTitle)", tone: strapTone, pulsing: live.connected)
                    if let pct = live.batteryPct {
                        StatePill(live.charging == true
                                  ? "Battery \(Int(pct.rounded()))% · Charging"
                                  : "Battery \(Int(pct.rounded()))%",
                                  tone: batteryTone(pct), showsDot: false)
                    }
                    Spacer(minLength: 0)
                }
                Text(strapStatusDetail)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                HStack(spacing: NoopMetrics.space3) {
                    NoopButton("Re-scan", systemImage: "arrow.clockwise", kind: .primary) {
                        model.scan()
                    }

                    NoopButton("Disconnect", systemImage: "xmark.circle", kind: .secondary) {
                        model.disconnect()
                    }
                    .disabled(!live.connected && !live.bonded)
                }
                ScanFeedbackView()

                Divider().overlay(StrandPalette.hairline)
                // MARK: Strap log — a Settings shortcut so people don't have to hunt for it on the Live
                // screen (#507: couldn't find it on Mac; #509: same on iPhone). Same text as the Live card.
                HStack(spacing: 12) {
                    Text("STRAP LOG").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Button("Copy") { PlatformPasteboard.copy(live.exportableLogText()) }
                        .buttonStyle(.plain).font(StrandFont.mono).foregroundStyle(StrandPalette.accent)
                    Button("Save…") {
                        FileExport.exportText(live.exportableLogText(),
                                              suggestedName: FileExport.timestampedName("noop-strap-log", ext: "txt"))
                    }
                    .buttonStyle(.plain).font(StrandFont.mono).foregroundStyle(StrandPalette.accent)
                }
                Text("Grab this when you report a bug — it tells me what the app saw. (The full live log is also on the Live screen.)")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(StrandPalette.hairline)

                // MARK: Continuous HRV capture — keep the dense beat-to-beat (R-R) stream armed 24/7.
                Toggle(isOn: $continuousHrvEnabled) {
                    Text("Continuous HRV capture")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .onChangeCompat(of: continuousHrvEnabled) { on in model.ble.setKeepRealtimeForData(on) }
                Text("Keeps the detailed beat-to-beat heart-rate stream running all day and night, not just while a live screen is open, so NOOP captures much more for overnight HRV, recovery and sleep. Uses more battery — your strap streams heart rate continuously while connected.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                // MARK: Strap name — rename the WHOOP 4.0's BLE advertising name (Harvard command set).
                if live.connected && selectedWhoopModelRaw == WhoopModel.whoop4.rawValue {
                    Divider().overlay(StrandPalette.hairline)
                    strapNameControl
                }

            }
        }
    }

    /// Rename the WHOOP 4.0's BLE advertising name. Shows the current name (read back from firmware in
    /// the connect handshake → `LiveState.advertisingName`) and writes a new one via `renameStrap`. The
    /// strap reboots to apply, so the new name lands on the next connect. WHOOP 4.0 only (Harvard).
    @ViewBuilder var strapNameControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Strap name").strandOverline()
            Text("Current: \(live.advertisingName ?? "—")")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: NoopMetrics.space3) {
                TextField("New strap name", text: $strapNameDraft)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, NoopMetrics.space3)
                    .padding(.vertical, 9)
                    .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    .disableAutocorrection(true)
                    .accessibilityLabel("New strap name")
                NoopButton("Rename", systemImage: "pencil", kind: .primary) {
                    model.ble.renameStrap(strapNameDraft)
                }
                .disabled(strapNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let status = live.renameStatus {
                Text(status)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Text("Changes the Bluetooth name your WHOOP 4.0 advertises — what you see when pairing. The strap reboots to apply, so the new name appears the next time it connects. WHOOP 4.0 only.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Shares LiveState.connectionStatus* with the sidebar footer (RootView) so the two never drift (#266).
    var strapStatusTitle: String { live.connectionStatusLabel }

    var strapTone: StrandTone {
        if live.connectionStatusIsActive { return .positive }
        if live.connectionStatusIsIdle { return .warning }
        return .critical
    }

    var strapStatusDetail: String {
        if live.bonded && live.connected {
            return "Your strap is paired and sending data. Open Live for a real-time heart rate."
        }
        if live.connected, let hint = live.pairingHint { return hint }
        if live.connected { return "Connected. Finishing the secure pairing handshake…" }
        if live.bonded { return "Previously paired but not currently connected. Re-scan to reconnect." }
        return "No strap connected. Put your WHOOP nearby and tap Re-scan to pair."
    }

    func batteryTone(_ pct: Double) -> StrandTone {
        if pct <= 15 { return .critical }
        if pct <= 30 { return .warning }
        return .positive
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotosUI
import StrandDesign
import StrandAnalytics
import WhoopStore

extension SettingsView {
    // MARK: - Experimental (WHOOP 5 / MG)

    /// Entry point used by `body`. The 5/MG probe card only renders for a 5/MG (see `showFiveMGControls`,
    /// #22); the raw-sensor CSV diagnostic is split into its own card so it stays available on every
    /// model — a 4.0 owner still needs the export to share decoded streams.
    @ViewBuilder var experimentalCard: some View {
        if showFiveMGControls { fiveMGCard }
        sleepStagingCard
        rawSensorDiagnosticsCard
        RawPPGCaptureCard()
    }

    /// Opt-in experimental sleep staging (V2). Model-agnostic — the V2 recipe works on WHOOP 4 and 5 — so it
    /// renders on every strap, separate from the 5/MG probe card. Default OFF; flipping it on re-stages
    /// future (and re-derived) nights with `SleepStagerV2`. The default V1 stager is untouched.
    var sleepStagingCard: some View {
        SettingsSection(
            icon: "bed.double.fill",
            title: "Experimental · Sleep staging",
            blurb: "How NOOP splits a night into light / deep / REM. This is a separate, opt-in recipe — your default staging is unchanged unless you turn it on."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Toggle(isOn: $experimentalSleepV2Enabled) {
                    Text("Experimental sleep staging (V2)")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("A transparent cardiorespiratory recipe that recovers deep and REM better than the default staging. Opt-in and experimental — it only changes how already-detected nights are split into stages (detection and scores are unchanged), and the default staging stays in place if you leave this off. Takes effect on the next nights staged.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The R22 "send enable sequence" button gates on the REAL runtime link state on every platform —
    /// the full encrypted bond plus the strap on the wrist — via the pure `Whoop5WriteGate`. macOS
    /// CoreBluetooth completes the encrypted bond and the command-characteristic writes work there
    /// (verified on real hardware), so there is no OS term.
    var deepDataGate: Whoop5WriteGate.Status {
        Whoop5WriteGate.deepData(encryptedBond: live.encryptedBond, worn: live.worn)
    }

    var deepDataButtonDisabled: Bool { !deepDataGate.isReady }

    /// The reason line under the R22 button, explaining the unmet condition (or what to do when ready).
    var deepDataButtonReason: String { Whoop5WriteGate.deepDataCaption(deepDataGate) }

    /// Broadcast HR needs the encrypted bond (not the wrist). The toggle stays usable — it is a saved
    /// preference applied on the next connection and must always be switchable OFF — so this only
    /// feeds an explanatory caption.
    var broadcastHrCaption: String? {
        Whoop5WriteGate.broadcastHrCaption(Whoop5WriteGate.broadcastHr(encryptedBond: live.encryptedBond))
    }

    var fiveMGCard: some View {
        SettingsSection(
            icon: "flask.fill",
            title: "Experimental · WHOOP 5 / MG",
            blurb: "Live heart rate already works on a WHOOP 5/MG strap. These probes go further and try to coax more out of it. They are guesses, off by default, and only ever touch a 5/MG strap — WHOOP 4.0 is never affected."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Toggle(isOn: $puffinExperiments) {
                    Text("Try WHOOP 5/MG protocol probes")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("On a 5/MG connection NOOP will send a puffin realtime-stream request after the handshake, and log what comes back. If you have a 5/MG strap, turning this on and sharing your strap log helps map the protocol. No effect on WHOOP 4.0.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(StrandPalette.hairline)

                deepDataUnlockControls

                Divider().overlay(StrandPalette.hairline)

                broadcastHrControls

                puffinCaptureControls
            }
        }
    }

    /// R22 deep-data unlock — the one probe that writes to the strap.
    @ViewBuilder
    var deepDataUnlockControls: some View {
        Toggle(isOn: $deepDataEnabled) {
            Text("Unlock WHOOP 5/MG deep data (R22)")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .toggleStyle(.switch)
        .tint(StrandPalette.accent)
        Text("WHOOP 5/MG straps hand a fresh app only live heart rate. The official app switches on the deeper streams (high-rate HR + motion + history) by writing a set of feature flags — a sequence two independent projects have documented. With this on, the button below sends that exact sequence to your strap. Unlike everything else here it does write to the strap, but it's reversible (it only changes which data the strap chooses to emit) and is the same thing the official app does. The flags are stored on the strap until they're changed back. Experimental: it may do nothing on your firmware. Works on Mac and iPhone once the strap has the full encrypted bond and is on your wrist.")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

        if deepDataEnabled {
            NoopButton("Send enable sequence to strap", systemImage: "bolt.badge.automatic", kind: .primary) {
                model.ble.enableWhoop5DeepData()
            }
            .disabled(deepDataButtonDisabled)
            Text(deepDataButtonReason)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)

            // Live R22 telemetry (#174): proof of what the strap is doing right now.
            if live.r22FlagsAccepted > 0 {
                Label(live.r22FlagsAccepted >= 15
                      ? "Strap accepted all 15 R22 flags"
                      : "Strap accepted \(live.r22FlagsAccepted)/15 R22 flags…",
                      systemImage: live.r22FlagsAccepted >= 15 ? "checkmark.seal.fill" : "ellipsis")
                    .font(StrandFont.caption)
                    .foregroundStyle(live.r22FlagsAccepted >= 15 ? StrandPalette.statusPositive : StrandPalette.textSecondary)
            }
            if live.deepPacketsThisSession > 0 {
                Label("\(live.deepPacketsThisSession) type-0x2F historical-offload frame\(live.deepPacketsThisSession == 1 ? "" : "s") seen outside our sync — these are history (e.g. another app pulling the strap's backlog), not a live R22 stream (#494).",
                      systemImage: "clock.arrow.circlepath")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else if live.r22FlagsAccepted >= 15 {
                Text("Flags accepted, but the enable sequence doesn't start a separate live stream — the deep records arrive as part of the normal history sync (#494).")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    /// Broadcast HR — make the strap a standard BLE HR sensor (Garmin/Zwift/gym).
    @ViewBuilder
    var broadcastHrControls: some View {
        Toggle(isOn: $broadcastHrEnabled) {
            Text("Broadcast heart rate (Garmin/ANT)")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .toggleStyle(.switch)
        .tint(StrandPalette.accent)
        .onChangeCompat(of: broadcastHrEnabled) { on in model.ble.setBroadcastHr(on) }
        Text("Makes your WHOOP 5.0/MG advertise its heart rate as a standard Bluetooth HR sensor, so a Garmin (Edge/watch), Zwift or gym equipment can use it during a workout. Applied on the next connection (and immediately if connected); writes the strap's whoop_live_hr_in_adv_ind_pkt flag, which is stored on the strap until you switch it back. Reversible. Needs the full encrypted bond.")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

        if let caption = broadcastHrCaption {
            Text(caption)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
        }

        // #573: leaving broadcast on keeps the strap radio advertising continuously, which drains
        // the strap faster — make that visible and persistent so it isn't left on by accident.
        if broadcastHrEnabled {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(StrandPalette.statusWarning)
                    .accessibilityHidden(true)
                Text("Broadcast HR is ON. Your strap is advertising its heart rate continuously, which keeps its radio hot and drains the battery faster. Turn it off when you're not using it with another device.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    var puffinCaptureControls: some View {
        Toggle(isOn: $puffinCapture) {
            Text("Record puffin frames to a file")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .toggleStyle(.switch)
        .tint(StrandPalette.accent)
        Text("Saves every raw 5/MG frame (with a timestamp and the live heart rate) to a JSON file you can share to help map the biometric layout. This only records frames the strap already sent — it never writes to your strap — so it is safe to leave on. Export the file and attach it to a protocol-mapping issue.")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

        if live.puffinCaptureCount > 0 {
            Text("\(live.puffinCaptureCount) frame\(live.puffinCaptureCount == 1 ? "" : "s") captured this session.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: NoopMetrics.space3) {
                NoopButton("Export frames…", systemImage: "square.and.arrow.up", kind: .primary) {
                    exportPuffinCaptures()
                }

                NoopButton("Reveal in Finder", systemImage: "folder", kind: .secondary) {
                    revealPuffinCaptures()
                }
                Spacer(minLength: 0)
            }
            // One-tap "matched pair" export (#510): hands a reporter BOTH the raw capture file
            // and the strap log together (timestamped, same minute) so a protocol-mapping issue
            // arrives with the frames AND the context that produced them.
            NoopButton("Export raw + log", systemImage: "square.and.arrow.up.on.square", kind: .secondary) {
                exportRawAndLog()
            }
            Text("Saves the raw capture and the strap log together as a matched pair — attach both to a protocol-mapping issue.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

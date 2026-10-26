import Foundation
import WhoopProtocol

// WHOOP 5/MG strap configuration: R22 deep-data telemetry and unlock, broadcast HR, advertising name.
extension BLEManager {
    /// EXPERIMENTAL R22 telemetry (#174): give the user (and us) live proof of what the strap is doing.
    /// (1) Every `COMMAND_RESPONSE` (type 0x24) to a `SET_CONFIG` (0x78) is the strap ACKing one
    ///     `enable_r22_*` flag — hardware-confirmed in sebastianwoo's capture. 15 ACKs = full acceptance.
    /// (2) A type-0x2F record arriving OUTSIDE our own history offload is NOT a separate live stream.
    ///     #494 showed these are historical-offload data: they appear when a SECOND BLE client pulls
    ///     the strap's history (`SendHistoricalData`) — the burst scales with the disconnect/backlog
    ///     time, not wall-clock — and the SET_CONFIG `enable_r22_*` sequence (accepted 15/15) starts no
    ///     separate stream. type-0x2F is only ever the historical offload (confirmed across #344's v20/v21
    ///     captures too). We still surface these as a diagnostic, but as what they are — another client's
    ///     backlog reaching us over the shared notify channel — not a live R22 "unlock".
    /// Frame layout (5/MG puffin envelope): packet_type @ byte 8, the responded-to cmd @ byte 10.
    ///
    /// #174 cooldown: when our own offload ENDS, the strap can keep flushing a few trailing type-0x2F
    /// records AFTER `backfilling` has already flipped false. So we stamp `lastOffloadFrameAt` on every
    /// offload frame (and at HISTORY_COMPLETE) and skip a non-offload 0x2F within
    /// `deepPacketLiveCooldownSeconds` of it. The flag-ACK counting (1) is unchanged.
    func noteWhoop5R22Telemetry(_ frame: [UInt8], duringOffload: Bool) {
        // R22 deep-data is a WHOOP 5/MG concept only. On a WHOOP 4 a type-0x2F frame is something else
        // entirely, so counting it as a "deep packet" gave 4.0 owners a bogus deep-data counter (#346).
        guard selectedModel.deviceFamily == .whoop5 else { return }
        guard frame.count > 10 else { return }
        if frame[8] == 0x24, frame[10] == WhoopCommand.setConfig.rawValue {
            state.r22FlagsAccepted += 1
            let total = Whoop5Config.enableR22Sequence.count
            if state.r22FlagsAccepted == total {
                log("Deep-data: strap ACCEPTED all \(total)/\(total) R22 flags ✓ — keep it on; watching for deep packets.")
            }
        }
        if frame[8] == 0x2F {
            if duringOffload {
                // Trailing-history reference point: a 0x2F arriving during the offload is banked
                // history (handled by the Backfiller). Remember when it landed so the cooldown below
                // can discount the few that dribble in just after the session ends.
                lastOffloadFrameAt = Date()
                return
            }
            // Cooldown guard: a 0x2F within deepPacketLiveCooldownSeconds of our own last offload
            // frame/HISTORY_COMPLETE is a trailing historical record from that session.
            if let last = lastOffloadFrameAt,
               Date().timeIntervalSince(last) < BLEManager.deepPacketLiveCooldownSeconds {
                return
            }
            // A 0x2F outside our offload is historical-offload data, not a live R22 stream (#494) —
            // typically another BLE client pulling the strap's backlog over the shared notify channel.
            // Surface it as a diagnostic, but don't claim a live-stream "unlock".
            state.deepPacketsThisSession += 1
            if state.deepPacketsThisSession == 1 {
                log("Deep-data: type-0x2F received outside our offload — this is historical-offload data (another BLE client pulling the strap's history, or a trailing flush), not a live R22 stream (#494).")
            } else if state.deepPacketsThisSession.isMultiple(of: 50) {
                log("Deep-data: \(state.deepPacketsThisSession) type-0x2F historical-offload frames seen outside our session.")
            }
        }
    }

    /// EXPERIMENTAL (#174): write the official app's `enable_r22_*` SET_CONFIG sequence to a bonded
    /// WHOOP 5/MG, to switch on the deep biometric (type-0x2F "R22") streams the strap withholds from a
    /// fresh third-party connection. The exact 15-flag sequence + values are documented by judes.club
    /// and Asherlc/dofek and built byte-for-byte by `Whoop5Config` (golden-frame unit-tested).
    ///
    /// Safety: only ever runs when the deep-data experiment is explicitly opted in AND the strap is a
    /// bonded, worn 5/MG. The R22 stream is on-wrist gated, so an off-wrist strap is refused with a hint.
    /// Each flag is one `.setConfig` write WITH RESPONSE, spaced ~80 ms (the official app pauses between
    /// writes). Reversible — it only changes which data the strap emits. After it runs, the user should
    /// wear + sync and share their strap log so we can confirm the deeper records start flowing.
    public func enableWhoop5DeepData() {
        guard selectedModel.deviceFamily == .whoop5 else {
            log("Deep-data: needs a WHOOP 5.0/MG strap selected — ignored."); return
        }
        guard PuffinExperiment.deepDataEnabled else {
            log("Deep-data: the deep-data experiment is off — enable it in Settings → Experimental first."); return
        }
        guard state.connected, state.encryptedBond else {
            // The R22 SET_CONFIG writes go over the encrypted command channel, so the live-HR-only
            // shortcut (`bonded` true, `encryptedBond` false on a 5/MG still owned by the official app,
            // #69/#266) can't carry them. Require the genuine bond, or the writes silently fail (#269).
            log("Deep-data: needs the full encrypted bond, not the live-HR-only link. Close the official WHOOP app, put the strap in pairing mode, and bond it to NOOP first — ignored."); return
        }
        guard state.worn else {
            log("Deep-data: the R22 stream is on-wrist only — put the strap ON, then try again."); return
        }
        state.r22FlagsAccepted = 0   // fresh attempt — count this send's ACKs from zero
        let frames = Whoop5Config.enableR22Sequence
        log("Deep-data: sending the \(frames.count)-flag enable_r22 sequence (experimental, reversible)…")
        for (i, flag) in frames.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80 * i)) { [weak self] in
                guard let self else { return }
                self.send(.setConfig,
                          payload: [0x01] + Whoop5Config.payloadBody(name: flag.name, value: flag.value),
                          writeType: .withResponse)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80 * frames.count + 200)) { [weak self] in
            self?.log("Deep-data: sequence sent. Keep the strap on, let it sync, then share your strap log — we're looking for new deep records (type-0x2F) to start arriving. (#174)")
        }
    }

    /// EXPERIMENTAL (#181): make a bonded WHOOP 5/MG advertise its heart rate as a standard BLE HR
    /// sensor (0x180D + the live HR in its manufacturer data) by writing the device-config flag
    /// `whoop_live_hr_in_adv_ind_pkt` = "1" (on) / "0" (off) via SET_DEVICE_CONFIG (0x77). With it on, a
    /// Garmin (Edge/watch), Zwift or gym HR client can pair to the WHOOP directly during a workout.
    /// Validated on real hardware (paired on a Garmin Edge 840). Opt-in, reversible; unlike R22 it is NOT
    /// on-wrist gated. Re-applied on each 5/MG connection. Needs the full encrypted bond; macOS
    /// CoreBluetooth completes that bond and the command-characteristic writes work there (verified on
    /// real hardware), so there is no OS restriction.
    public func setBroadcastHr(_ on: Bool) {
        guard selectedModel.deviceFamily == .whoop5 else {
            log("Broadcast HR: needs a WHOOP 5.0/MG strap selected — ignored."); return
        }
        guard state.connected, state.bonded else {
            log("Broadcast HR: connect and bond a 5/MG strap first — ignored."); return
        }
        let value: UInt8 = on ? 0x31 : 0x30   // ASCII '1' / '0'
        send(.setDeviceConfig,
             payload: [0x01] + Whoop5Config.deviceConfigBody(name: "whoop_live_hr_in_adv_ind_pkt", value: value),
             writeType: .withResponse)
        log("Broadcast HR: wrote whoop_live_hr_in_adv_ind_pkt=\(on ? "1" : "0")")
    }

    /// Read the strap's current BLE advertising name (WHOOP 4.0 / Harvard). The reply lands as a
    /// GET_ADVERTISING_NAME COMMAND_RESPONSE and FrameRouter publishes it to `LiveState.advertisingName`.
    /// Also sent automatically in the connect handshake; this is the manual refresh the Settings card
    /// fires after a rename. No-op on a 5/MG (the Harvard name command isn't part of its framing).
    public func requestAdvertisingName() {
        guard selectedModel.deviceFamily == .whoop4 else {
            log("Strap name: WHOOP 4.0 only — ignored on a 5/MG."); return
        }
        guard state.connected else { log("Strap name: not connected — ignored."); return }
        send(.getAdvertisingNameHarvard, payload: [0x00])
    }

    /// Rename the strap's BLE advertising name (WHOOP 4.0 / Harvard) via SET_ADVERTISING_NAME (cmd 77).
    /// Writes `[0x00,0x00] + UTF-8 name + [0x00]` (see `WhoopCommand.advertisingNamePayload`) over the
    /// confirmed command channel; the strap reboots to apply, so the new name appears on the next connect
    /// (the connect handshake re-reads it). The result ack is surfaced via `LiveState.renameStatus`.
    /// WHOOP 4.0 only — a 5/MG uses puffin framing and a different device-config path. Reversible.
    public func renameStrap(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selectedModel.deviceFamily == .whoop4 else {
            state.renameStatus = "Renaming is WHOOP 4.0 only."
            log("Strap rename: WHOOP 4.0 only — ignored on a 5/MG."); return
        }
        guard state.connected, state.bonded else {
            state.renameStatus = "Connect and pair your strap first."
            log("Strap rename: connect + bond first — ignored."); return
        }
        guard !name.isEmpty else {
            state.renameStatus = "Enter a name first."; return
        }
        state.renameStatus = "Renaming…"
        send(.setAdvertisingNameHarvard,
             payload: WhoopCommand.advertisingNamePayload(name),
             writeType: .withResponse)
        log("Strap rename: wrote advertising name=\(name.debugDescription)")
        // Re-read shortly after so the card reflects the change if the strap applies it without dropping
        // the link; if it reboots instead, the connect handshake re-reads the name on reconnect anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            self?.requestAdvertisingName()
        }
        // Timeout so the card can't hang on "Renaming…" forever. Some WHOOP 4.0 firmware never returns the
        // SET_ADVERTISING_NAME COMMAND_RESPONSE that clears this status (it just reboots, or swallows the
        // command) — the reporter on #428 sat on a permanent "Renaming…". If nothing has updated the status
        // by now, surface an honest fallback instead of an endless spinner. A real ack or the reconnect
        // re-read overwrites this the moment it arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(8)) { [weak self] in
            guard let self, self.state.renameStatus == "Renaming…" else { return }
            self.state.renameStatus = "Rename sent — reconnect your strap to confirm the new name."
            self.log("Strap rename: no ack within 8s — firmware may apply it on reboot/reconnect.")
        }
    }
}

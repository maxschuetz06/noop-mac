import Foundation

/// Runtime gate for the two WHOOP 5/MG features that WRITE to the strap over the encrypted command
/// characteristic: the R22 "deep data" enable sequence and the Broadcast-HR device-config flag.
///
/// There is deliberately NO operating-system term here. macOS CoreBluetooth completes the encrypted
/// just-works bond, and the command-characteristic writes (SET_RTC, history ack/trim) are verified on
/// real hardware, so the only things that decide whether a write can land are the live link state:
///  - the full encrypted bond (a live-HR-only link — strap still owned by the official app — can't carry
///    the write, #269), and
///  - for the R22 stream only, the strap being on the wrist (the stream is on-wrist gated).
/// Mirrors the guards inside `BLEManager.enableWhoop5DeepData()` / `setBroadcastHr(_:)`. Pure so the
/// Settings gating is unit-testable without a view or a BLE stack.
enum Whoop5WriteGate {

    enum Status: Equatable {
        /// Every runtime condition is met; the write can land.
        case ready
        /// No full encrypted bond (not connected, or only the live-HR-only link).
        case needsEncryptedBond
        /// Bonded, but the strap is off-wrist (R22 only).
        case needsWear

        var isReady: Bool { self == .ready }
    }

    /// R22 deep-data enable sequence: needs the encrypted bond AND the strap worn.
    static func deepData(encryptedBond: Bool, worn: Bool) -> Status {
        if !encryptedBond { return .needsEncryptedBond }
        if !worn { return .needsWear }
        return .ready
    }

    /// Broadcast-HR flag: needs the encrypted bond only — it is NOT on-wrist gated (BLEManager).
    static func broadcastHr(encryptedBond: Bool) -> Status {
        encryptedBond ? .ready : .needsEncryptedBond
    }

    /// The caption under the "Send enable sequence" button.
    static func deepDataCaption(_ status: Status) -> String {
        switch status {
        case .needsEncryptedBond:
            return String(localized: "Needs the full encrypted bond — close the official WHOOP app and pair the strap to NOOP first (a live-HR-only link can't carry the unlock).")
        case .needsWear:
            return String(localized: "Put the strap on first — the deep stream is on-wrist only.")
        case .ready:
            return String(localized: "Wear the strap, tap once, then let it sync and share your strap log.")
        }
    }

    /// The caption under the Broadcast-HR toggle, or nil when nothing needs saying. The toggle itself
    /// stays usable (it's a saved preference applied on the next connection, and it must always be
    /// possible to switch it OFF), so an unmet bond is explained rather than disabled.
    static func broadcastHrCaption(_ status: Status) -> String? {
        switch status {
        case .ready, .needsWear:
            return nil
        case .needsEncryptedBond:
            return String(localized: "Needs the full encrypted bond to apply — close the official WHOOP app and pair the strap to NOOP first. Your choice is saved until then.")
        }
    }
}

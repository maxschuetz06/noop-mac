import CoreBluetooth
import Foundation

/// What the Bluetooth radio / permission currently allows, published so the UI can explain a scan that
/// cannot start instead of the reason only landing in the strap log. Mirrors `CBManagerState`.
public enum BluetoothAvailability: Equatable, Sendable {
    case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn

    public init(_ state: CBManagerState) {
        switch state {
        case .poweredOn:    self = .poweredOn
        case .poweredOff:   self = .poweredOff
        case .unauthorized: self = .unauthorized
        case .unsupported:  self = .unsupported
        case .resetting:    self = .resetting
        case .unknown:      self = .unknown
        @unknown default:   self = .unknown
        }
    }

    /// Short, user-facing explanation for a state that blocks scanning; nil when scanning can proceed.
    public var blockerMessage: String? {
        switch self {
        case .poweredOn:    return nil
        case .unauthorized: return "NOOP has no Bluetooth permission — System Settings → Privacy & Security → Bluetooth."
        case .poweredOff:   return "Bluetooth is turned off. Turn it on to find your WHOOP."
        case .unsupported:  return "This device doesn't support Bluetooth Low Energy."
        case .resetting:    return "Bluetooth is restarting — try again in a moment."
        case .unknown:      return "Bluetooth is still starting up — try again in a moment."
        }
    }

    /// True when the user can fix the blocker by granting permission in system settings.
    public var needsPermission: Bool { self == .unauthorized }
}

/// Where a strap scan / connect attempt currently stands. Published via `LiveState.scanPhase`.
public enum ScanPhase: Equatable, Sendable {
    case idle
    case scanning
    /// A strap was found and the connection is being established.
    case connecting
    /// Nothing was found within `ScanFeedback.timeoutSeconds` (the scan keeps running in the background).
    case timedOut
    /// The scan could not start because Bluetooth is unavailable.
    case blocked(BluetoothAvailability)
}

/// Pure decisions behind the scan feedback, kept free of CoreBluetooth side effects so they are testable.
public enum ScanFeedback {
    /// How long a scan may find nothing before the UI suggests what to check.
    public static let timeoutSeconds: TimeInterval = 20

    /// The phase a scan request starts in, given the current radio availability.
    public static func phaseOnStart(_ availability: BluetoothAvailability) -> ScanPhase {
        availability == .poweredOn ? .scanning : .blocked(availability)
    }

    /// The phase a targeted connect to the pinned strap (no scan involved) starts in. The strap is already
    /// known, so it reads "connecting" rather than "searching".
    public static func phaseOnTargetedConnect(_ availability: BluetoothAvailability) -> ScanPhase {
        availability == .poweredOn ? .connecting : .blocked(availability)
    }

    /// The phase to show once `timeoutSeconds` have elapsed: a scan that is still searching OR a targeted
    /// connect that has not completed (strap out of range / asleep) and has not connected turns into
    /// `.timedOut`; an idle/connected/blocked state is left alone.
    public static func phaseAfterTimeout(current: ScanPhase, connected: Bool) -> ScanPhase {
        guard current == .scanning || current == .connecting, !connected else { return current }
        return .timedOut
    }

    /// The phase after a scan was deliberately abandoned (disconnect, Add-a-WHOOP present-scan taking over
    /// or ending, a device being forgotten): nothing is pending any more, so the pill must not linger.
    public static func phaseAfterScanStopped() -> ScanPhase { .idle }

    /// The phase after the radio state changed. A blocker always wins; once Bluetooth is back on, a
    /// stale `.blocked` clears to `.idle` (the reconnect that follows moves it to `.scanning`).
    public static func phaseOnAvailabilityChange(_ availability: BluetoothAvailability,
                                                 current: ScanPhase) -> ScanPhase {
        if availability != .poweredOn { return .blocked(availability) }
        if case .blocked = current { return .idle }
        return current
    }

    /// Help text shown under a timed-out scan.
    public static let timeoutMessage =
        "No WHOOP found. Put the strap in pairing mode (tap it until the LEDs flash blue) and close the WHOOP phone app, then try again."
}

extension WhoopModel {
    static let selectedKey = "selectedWhoopModel"
    static let lastConnectedKey = "lastConnectedWhoopModel"

    /// Resolve which family to scan for. Order: an explicit choice, the model of the active registry row
    /// that is pinned to a specific strap (it has a `peripheralId`, so its model describes exactly the
    /// strap a targeted connect will reach), the user's stored pick, the family of the last strap that
    /// actually connected, any other registry model, then the WHOOP 4.0 default. Unparseable values are
    /// skipped so one stale string (or the neutral "WHOOP" placeholder) never wins.
    static func resolve(explicit: WhoopModel? = nil,
                        pinnedRegistryModel: String? = nil,
                        stored: String?,
                        lastConnected: String?,
                        registryModel: String? = nil) -> WhoopModel {
        if let explicit { return explicit }
        for raw in [pinnedRegistryModel, stored, lastConnected, registryModel] {
            if let model = raw.flatMap(WhoopModel.init(rawValue:)) { return model }
        }
        return .whoop4
    }

    /// `resolve` fed from UserDefaults (+ optional registry model strings).
    static func resolveFromDefaults(explicit: WhoopModel? = nil,
                                    pinnedRegistryModel: String? = nil,
                                    registryModel: String? = nil) -> WhoopModel {
        let d = UserDefaults.standard
        return resolve(explicit: explicit,
                       pinnedRegistryModel: pinnedRegistryModel,
                       stored: d.string(forKey: selectedKey),
                       lastConnected: d.string(forKey: lastConnectedKey),
                       registryModel: registryModel)
    }

    /// The WHOOP family PROVEN by a service that was actually found on the strap: a service-filtered scan
    /// or `discoverServices` for one family's service can only return that family's service, so seeing it
    /// is evidence of the family. nil for any other service (HR, battery, unknown) — those prove nothing.
    /// Merely being *connected* proves nothing: a targeted reconnect never checks the family.
    static func proven(byService service: CBUUID) -> WhoopModel? {
        allCases.first { $0.scanService == service }
    }

    /// Remember the family of a strap that is PROVEN (see `proven(byService:)`), so the next scan (and
    /// Settings/Live pickers) start on the right service even if the preference key was never written.
    static func recordConnected(_ model: WhoopModel) {
        let d = UserDefaults.standard
        d.set(model.rawValue, forKey: selectedKey)
        d.set(model.rawValue, forKey: lastConnectedKey)
    }
}

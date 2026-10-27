import Foundation
import Combine
import WhoopStore

// MARK: - DeviceRegistry
//
// Observable @MainActor cache over the synchronous `DeviceRegistryStore` (device-foundation
// Task 5). The UI observes this for the paired-device list + the currently active device; the
// app's `deviceId` is sourced from `activeDeviceId` so it's "the active device's id" rather than
// the hardcoded "my-whoop" literal. Behaviour is unchanged today — migration v15 seeds a single
// 'my-whoop' row as `.active`, so the active id is still "my-whoop".
//
// `DeviceRegistryStore` is synchronous (its own GRDB queue, internally serialized), so the reads
// here are plain synchronous calls; we keep failures non-fatal and fall back to the seeded defaults.
@MainActor
final class DeviceRegistry: ObservableObject {
    /// All paired devices (any status), oldest-added first — the store's `all()` ordering.
    @Published private(set) var devices: [PairedDevice] = []
    /// The active device's id. Defaults to "my-whoop" so callers have a safe value before the
    /// first `reload()` and if the registry can't be read.
    @Published private(set) var activeDeviceId: String = SourceID.whoop

    private let store: DeviceRegistryStore

    init(store: DeviceRegistryStore) {
        self.store = store
    }

    /// Load the device list and active id from the store. Best-effort: on any error the published
    /// values are left untouched (keeping the safe "my-whoop" fallback), never crashing.
    func reload() {
        guard let rows = try? store.all() else { return }
        devices = rows
        if let active = rows.first(where: { $0.status == .active })?.id {
            activeDeviceId = active
        }
    }

    // MARK: - UI mutations (Devices screen)
    //
    // Each op delegates to the synchronous store, then `reload()`s so the published `devices` /
    // `activeDeviceId` reflect the change and the UI updates. Best-effort: a store failure leaves the
    // published state untouched (we never crash the UI on a write error).

    /// Add or upsert a paired device (the Add wizard's chosen strap). Refreshes the published list.
    func add(_ device: PairedDevice) {
        try? store.add(device)
        reload()
    }

    /// Make `id` the single active device. The store demotes whatever was active in the same
    /// transaction (invariant I1); changing `activeDeviceId` drives the `SourceCoordinator` to run the
    /// right live source.
    func setActive(_ id: String) {
        try? store.setActive(id)
        reload()
    }

    /// Archive (remove) a device: NOOP stops connecting to it, but its recorded data is kept. If the
    /// archived device was the active one, `activeDeviceId` is left as-is here — the caller decides the
    /// next active device (or leaves none active) and calls `setActive` explicitly.
    func archive(_ id: String) {
        try? store.archive(id)
        reload()
    }

    /// Rename a device. `name` nil/empty clears the nickname so it falls back to brand+model.
    func rename(_ id: String, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try? store.rename(id, nickname: (trimmed?.isEmpty == false) ? trimmed : nil)
        reload()
    }

    /// Permanently delete every recorded sample/derived row for a device across all `deviceId`-keyed
    /// tables. Does NOT remove the registry row (that's `archive`); this only empties its recordings.
    func deleteDeviceData(_ id: String) {
        try? store.deleteAllData(deviceId: id)
        reload()
    }

    /// Adopt (or clear, when nil) the stable BLE identity for a device — the
    /// CBPeripheral.identifier.uuidString on iOS/Mac. Lets NOOP tell physical straps apart and map a
    /// connected peripheral back to its registry row. Refreshes the published list. Best-effort.
    func setPeripheralId(_ id: String, peripheralId: String?) {
        try? store.setPeripheralId(id, peripheralId: peripheralId)
        reload()
    }

    /// Find the paired device that has adopted a given BLE peripheral, if any. A plain read of the
    /// store (no reload) — returns nil on any error or when no row has adopted that peripheral yet.
    func device(forPeripheralId peripheralId: String) -> PairedDevice? {
        (try? store.device(forPeripheralId: peripheralId)) ?? nil
    }

    /// Refine the seeded neutral "WHOOP" model on the 'my-whoop' row to the strap the user actually
    /// picked (migration v15 seeds a placeholder the app can't fill at migration time, since the
    /// selected model lives in the app's UserDefaults). No-op when it already matches. Best-effort.
    func reconcileWhoopModel(_ model: String) {
        guard let rows = try? store.all(),
              let existing = rows.first(where: { $0.id == SourceID.whoop }),
              existing.model != model else { return }
        var updated = existing
        updated.model = model
        try? store.add(updated)
        reload()
    }

    // MARK: - Strap (re)connect reconciliation

    /// The registry row a just-connected WHOOP strap belongs to: the row that adopted its BLE
    /// `peripheralId`, else the active device's row when that row hasn't adopted a strap yet (the
    /// legacy "my-whoop" before first adoption). nil when the connected strap maps to no WHOOP row.
    nonisolated static func connectedWhoopDevice(in devices: [PairedDevice],
                                                 activeDeviceId: String,
                                                 connectedPeripheralId: String?) -> PairedDevice? {
        func isWhoop(_ d: PairedDevice) -> Bool {
            d.id == SourceID.whoop || d.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
        }
        if let pid = connectedPeripheralId,
           let match = devices.first(where: { $0.peripheralId == pid }) {
            return isWhoop(match) ? match : nil
        }
        guard let active = devices.first(where: { $0.id == activeDeviceId }),
              isWhoop(active), active.peripheralId == nil else { return nil }
        return active
    }

    /// Id of a removed (archived) WHOOP that just re-bonded and should return to `.active`. nil when the
    /// connected strap isn't an archived row, or when another device is active (never steal the slot).
    nonisolated static func archivedDeviceToRestore(in devices: [PairedDevice],
                                                    activeDeviceId: String,
                                                    connectedPeripheralId: String?) -> String? {
        guard let device = connectedWhoopDevice(in: devices, activeDeviceId: activeDeviceId,
                                                connectedPeripheralId: connectedPeripheralId),
              device.status == .archived,
              !devices.contains(where: { $0.status == .active && $0.id != device.id }) else { return nil }
        return device.id
    }

    /// True for a model string that carries no real information: empty, or the neutral "WHOOP" the v15
    /// migration seeds (and the Devices card calls "Exact model unknown"). Only such a placeholder may be
    /// refined automatically; a known 4.0 / 5.0 value is never rewritten behind the user's back.
    nonisolated static func isUnknownModelPlaceholder(_ model: String) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.caseInsensitiveCompare("WHOOP") == .orderedSame
    }

    /// The device row with `model` applied, or nil when there is nothing to write: the new model is empty,
    /// the row already carries it, or the row already carries a KNOWN model (only an unknown placeholder is
    /// replaced — a wrongly proven/stale model must not silently flip a 4.0 row to 5/MG or back).
    nonisolated static func device(_ device: PairedDevice, withModel model: String) -> PairedDevice? {
        guard !model.isEmpty, device.model != model,
              isUnknownModelPlaceholder(device.model) else { return nil }
        var updated = device
        updated.model = model
        return updated
    }

    /// The model string of the active row when that row is pinned to a specific strap (has a
    /// `peripheralId`). nil for an unpinned row (the legacy "my-whoop" before first adoption) — its model
    /// is only a seeded placeholder, not evidence about the strap a scan will find.
    nonisolated static func pinnedModel(in devices: [PairedDevice], activeDeviceId: String) -> String? {
        guard let active = devices.first(where: { $0.id == activeDeviceId }),
              active.peripheralId != nil else { return nil }
        return active.model
    }

    /// A WHOOP strap just connected: bring a removed device back to active and record the exact model
    /// (so the Devices card stops saying "Exact model unknown"). Returns human-readable log lines for the
    /// strap log. Best-effort like every other registry write.
    @discardableResult
    func reconcileConnectedWhoop(peripheralId: String?, model: String?) -> [String] {
        var lines: [String] = []
        if let id = Self.archivedDeviceToRestore(in: devices, activeDeviceId: activeDeviceId,
                                                 connectedPeripheralId: peripheralId) {
            setActive(id)
            lines.append("Devices: \(id) reconnected — restored from Removed to active")
        }
        if let model,
           let device = Self.connectedWhoopDevice(in: devices, activeDeviceId: activeDeviceId,
                                                  connectedPeripheralId: peripheralId),
           let updated = Self.device(device, withModel: model) {
            try? store.add(updated)
            reload()
            lines.append("Devices: recorded model \(model) for \(device.id)")
        }
        return lines
    }
}

import Foundation
import Combine
import WhoopProtocol
import WhoopStore

// MARK: - Paired devices and WHOOP strap control
//
// The device registry, the source coordinator that runs exactly one device's live BLE at a time, and
// the WHOOP scan / present-scan entry points every screen uses (Live, onboarding, menu bar, Settings,
// the Add-a-device wizard). All strap calls go through `engine`, which is nil in the XCTest host.
extension AppModel {
    /// Build the device registry + source coordinator once the store is open, then start observing.
    /// Tiny and guarded: with no generic strap paired the active id is "my-whoop", so the coordinator
    /// observes WHOOP-active and stays a NO-OP — the existing `scan()`/`disconnect()` WHOOP flow is
    /// untouched. The coordinator only acts if/when a non-WHOOP strap becomes the active device.
    /// `startWhoop`/`stopWhoop` are thin closures over BLEManager's EXISTING public methods (via the
    /// model's `scan()` / `disconnect()`), so the coordinator never references BLEManager directly.
    func makeDeviceSources(engine: BLEManager, store: WhoopStore) -> (DeviceRegistry, SourceCoordinator) {
        let registry = DeviceRegistry(store: DeviceRegistryStore(dbQueue: store.registryQueue))
        registry.reload()
        let coordinator = SourceCoordinator(
            registry: registry,
            live: live,
            storeHandle: { [weak self] in await self?.repo.storeHandle() },
            startWhoop: { [weak self] in self?.scan() },
            stopWhoop: { [weak self] in self?.disconnect() },
            // WHOOP targeting hooks — thin wrappers over BLEManager's existing additive setters, so the
            // coordinator never references BLEManager directly (mirrors the start/stop injection). On the
            // single-WHOOP path these are setPreferredPeripheral(nil) and (no setActiveDeviceId call),
            // i.e. the BLE engine's defaults — no behaviour change.
            setWhoopPreferredPeripheral: { [weak self] uuid in self?.engine?.setPreferredPeripheral(uuid) },
            setWhoopActiveDeviceId: { [weak self] id in self?.engine?.setActiveDeviceId(id) },
            // The engine's last-connected WHOOP uuid drives first-connect identity adoption.
            connectedPeripheralUUID: engine.$connectedPeripheralUUID.eraseToAnyPublisher(),
            // The family PROVEN for the connected strap (service filter / found service). The coordinator
            // reconciles the registry row (restore a removed device, record the model) from both signals.
            connectedWhoopModel: engine.$connectedModel.eraseToAnyPublisher(),
            // Generic-HR connect lifecycle → the SAME strap log BLEManager writes to (`live.append(log:)`),
            // so a "connected but no data" report (issue #421) is no longer blind to the Polar/Wahoo/etc
            // path. Timestamp matches BLEManager.log()'s "HH:mm:ss" so the lines read consistently.
            straplog: { [weak self] line in
                self?.live.append(log: "[\(AppModel.logTimeFormatter.string(from: Date()))] \(line)")
            })
        coordinator.start()
        seedStoredWhoopModel(from: registry)
        return (registry, coordinator)
    }

    /// First launch after an update / reinstall: `selectedWhoopModel` may be unset while the registry
    /// already knows the exact model of the paired strap — seed it so the pickers and scans match.
    /// Only seeds from real evidence (last connected family / registry model), never the 4.0 fallback.
    private func seedStoredWhoopModel(from registry: DeviceRegistry) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: WhoopModel.selectedKey) == nil else { return }
        let registryModel = registry.devices.first(where: { $0.id == registry.activeDeviceId })?.model
        let evidence = [defaults.string(forKey: WhoopModel.lastConnectedKey), registryModel]
            .compactMap { $0.flatMap(WhoopModel.init(rawValue:)) }
            .first
        if let evidence { defaults.set(evidence.rawValue, forKey: WhoopModel.selectedKey) }
    }

    /// Start scanning for the strap. When no model is given, use the one the user
    /// picked (persisted under "selectedWhoopModel"), so every scan entry point —
    /// Live, onboarding, the menu bar, Settings — honours the same choice.
    func scan(model: WhoopModel? = nil) {
        // Explicit pick → the pinned active strap's registry model → stored pick → last connected family →
        // the active row's registry model → 4.0. A paired strap's own row beats a possibly stale preference.
        let devices = deviceRegistry?.devices ?? []
        let activeId = deviceRegistry?.activeDeviceId ?? SourceID.whoop
        engine?.connect(model: WhoopModel.resolveFromDefaults(
            explicit: model,
            pinnedRegistryModel: DeviceRegistry.pinnedModel(in: devices, activeDeviceId: activeId),
            registryModel: devices.first(where: { $0.id == activeId })?.model))
    }
    func disconnect() { engine?.disconnect() }

    /// Drop the current strap and clear bond state so a newly-picked strap model connects fresh
    /// (lets a user with both a WHOOP 4 and a 5/MG switch between them).
    func prepareStrapSwitch() { engine?.prepareForModelSwitch() }

    // MARK: - Add-a-device wizard (WHOOP present-scan + register/activate)
    //
    // Thin pass-throughs over BLEManager's EXISTING public present-scan surface so the wizard never
    // references BLEManager directly (mirrors `scan()` / `disconnect()`). The wizard observes
    // `ble.discoveredWhoops` for the WHOOP families and runs its own `StandardHRSource` for generic
    // straps — see AddDeviceWizard.

    /// The straps surfaced by the WHOOP present-scan (`scanForWhoops`), for the wizard's live list.
    /// Empty until a present-scan has discovered something; refreshed in place as RSSI updates.
    var discoveredWhoops: [(uuid: String, name: String, rssi: Int)] { engine?.discoveredWhoops ?? [] }

    /// Point the WHOOP scan at a specific family, then present nearby straps WITHOUT auto-connecting.
    /// `prepareForModelSwitch()` first clears any sticky bond/connection so the engine is idle, then
    /// `connect(model:)` selects the family + installs its framing (it sets the engine's private
    /// `selectedModel`, which `scanForWhoops()` scans for), and the immediate `scanForWhoops()` takes
    /// over the central in present-mode (it `stopScan()`s the connect's scan and re-arms a duplicate-
    /// allowing present scan). The persisted `selectedWhoopModel` is updated too, so a later real
    /// connect to the chosen strap targets the right family. All via existing public methods.
    func presentWhoopScan(model: WhoopModel) {
        UserDefaults.standard.set(model.rawValue, forKey: "selectedWhoopModel")
        engine?.prepareForPresentScan(model: model) // idle for a family switch, but KEEP a live same-family bond (#74)
        engine?.connect(model: model)           // select the family (sets engine selectedModel + framing)
        engine?.scanForWhoops()                 // take over the central, present nearby straps only
    }

    /// End the WHOOP present-scan (idempotent). Call on leaving the wizard's pick step / on dismiss.
    func stopWhoopScan() { engine?.stopWhoopScan() }

    /// Register a paired device and (optionally) make it the active one. The Add-a-device wizard's
    /// single write path: `add` upserts the row, and when `makeActive` is true `setActive` promotes it
    /// (the SourceCoordinator reacts to the active-device change and connects). No-op if the registry
    /// hasn't been wired yet (pre store-open) — the wizard is only reachable once it has.
    func registerDevice(_ device: PairedDevice, makeActive: Bool) {
        guard let registry = deviceRegistry else { return }
        registry.add(device)
        if makeActive { registry.setActive(device.id) }
    }
}

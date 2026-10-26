import XCTest
import Combine
import CoreBluetooth
import WhoopStore
@testable import Strand

/// Pure decisions behind the scan feedback UI, the WHOOP model resolution order and the
/// archived → active restore when a removed strap reconnects.
final class ScanFeedbackTests: XCTestCase {

    // MARK: Scan phase / timeout

    func testBluetoothAvailabilityMapsEveryCentralState() {
        XCTAssertEqual(BluetoothAvailability(.poweredOn), .poweredOn)
        XCTAssertEqual(BluetoothAvailability(.poweredOff), .poweredOff)
        XCTAssertEqual(BluetoothAvailability(.unauthorized), .unauthorized)
        XCTAssertEqual(BluetoothAvailability(.unsupported), .unsupported)
        XCTAssertEqual(BluetoothAvailability(.resetting), .resetting)
        XCTAssertEqual(BluetoothAvailability(.unknown), .unknown)
    }

    func testOnlyPoweredOnHasNoBlockerMessage() {
        XCTAssertNil(BluetoothAvailability.poweredOn.blockerMessage)
        for blocked in [BluetoothAvailability.unknown, .resetting, .unsupported, .unauthorized, .poweredOff] {
            XCTAssertNotNil(blocked.blockerMessage, "\(blocked)")
        }
        XCTAssertTrue(BluetoothAvailability.unauthorized.blockerMessage?.contains("Privacy & Security") == true)
        XCTAssertTrue(BluetoothAvailability.unauthorized.needsPermission)
        XCTAssertFalse(BluetoothAvailability.poweredOff.needsPermission)
    }

    func testScanStartsSearchingOnlyWhenPoweredOn() {
        XCTAssertEqual(ScanFeedback.phaseOnStart(.poweredOn), .scanning)
        XCTAssertEqual(ScanFeedback.phaseOnStart(.unauthorized), .blocked(.unauthorized))
        XCTAssertEqual(ScanFeedback.phaseOnStart(.poweredOff), .blocked(.poweredOff))
    }

    func testTimeoutTurnsAnUnconnectedSearchOrConnectIntoTimedOut() {
        XCTAssertEqual(ScanFeedback.phaseAfterTimeout(current: .scanning, connected: false), .timedOut)
        XCTAssertEqual(ScanFeedback.phaseAfterTimeout(current: .scanning, connected: true), .scanning)
        // A targeted connect that never completes (strap out of range / asleep) must time out too.
        XCTAssertEqual(ScanFeedback.phaseAfterTimeout(current: .connecting, connected: false), .timedOut)
        XCTAssertEqual(ScanFeedback.phaseAfterTimeout(current: .connecting, connected: true), .connecting)
        XCTAssertEqual(ScanFeedback.phaseAfterTimeout(current: .timedOut, connected: false), .timedOut)
        XCTAssertEqual(ScanFeedback.phaseAfterTimeout(current: .idle, connected: false), .idle)
        XCTAssertEqual(ScanFeedback.phaseAfterTimeout(current: .blocked(.poweredOff), connected: false),
                       .blocked(.poweredOff))
        XCTAssertEqual(ScanFeedback.timeoutSeconds, 20)
    }

    func testAvailabilityChangeBlocksAndThenClearsStaleBlocker() {
        XCTAssertEqual(ScanFeedback.phaseOnAvailabilityChange(.unauthorized, current: .scanning),
                       .blocked(.unauthorized))
        XCTAssertEqual(ScanFeedback.phaseOnAvailabilityChange(.poweredOn, current: .blocked(.unauthorized)), .idle)
        XCTAssertEqual(ScanFeedback.phaseOnAvailabilityChange(.poweredOn, current: .scanning), .scanning)
        XCTAssertEqual(ScanFeedback.phaseOnAvailabilityChange(.poweredOn, current: .timedOut), .timedOut)
    }

    // MARK: Model resolution

    func testExplicitModelWinsOverEverything() {
        XCTAssertEqual(WhoopModel.resolve(explicit: .whoop4, stored: "WHOOP 5.0 / MG",
                                          lastConnected: "WHOOP 5.0 / MG", registryModel: "WHOOP 5.0 / MG"),
                       .whoop4)
    }

    func testStoredPickBeatsLastConnectedAndRegistry() {
        XCTAssertEqual(WhoopModel.resolve(stored: "WHOOP 4.0", lastConnected: "WHOOP 5.0 / MG",
                                          registryModel: "WHOOP 5.0 / MG"), .whoop4)
    }

    func testMissingStoredFallsBackToLastConnectedThenRegistryThenWhoop4() {
        XCTAssertEqual(WhoopModel.resolve(stored: nil, lastConnected: "WHOOP 5.0 / MG", registryModel: "WHOOP 4.0"),
                       .whoop5mg)
        XCTAssertEqual(WhoopModel.resolve(stored: nil, lastConnected: nil, registryModel: "WHOOP 5.0 / MG"),
                       .whoop5mg)
        XCTAssertEqual(WhoopModel.resolve(stored: nil, lastConnected: nil, registryModel: nil), .whoop4)
    }

    func testUnparseableValuesAreSkipped() {
        XCTAssertEqual(WhoopModel.resolve(stored: "garbage", lastConnected: "WHOOP", registryModel: "WHOOP 5.0 / MG"),
                       .whoop5mg)
        XCTAssertEqual(WhoopModel.resolve(stored: "", lastConnected: nil, registryModel: "WHOOP"), .whoop4)
    }

    func testTargetedConnectShowsConnectingOnlyWhenPoweredOn() {
        XCTAssertEqual(ScanFeedback.phaseOnTargetedConnect(.poweredOn), .connecting)
        XCTAssertEqual(ScanFeedback.phaseOnTargetedConnect(.poweredOff), .blocked(.poweredOff))
        XCTAssertEqual(ScanFeedback.phaseOnTargetedConnect(.unauthorized), .blocked(.unauthorized))
    }

    func testStoppingAScanAlwaysResetsToIdle() {
        // disconnect / forgetDevice / scanForWhoops / stopWhoopScan all reset through this decision.
        XCTAssertEqual(ScanFeedback.phaseAfterScanStopped(), .idle)
    }

    // MARK: Proven model

    func testOnlyAFamilyServiceProvesAFamily() {
        XCTAssertEqual(WhoopModel.proven(byService: WhoopModel.whoop4.scanService), .whoop4)
        XCTAssertEqual(WhoopModel.proven(byService: WhoopModel.whoop5mg.scanService), .whoop5mg)
        XCTAssertNil(WhoopModel.proven(byService: CBUUID(string: "180D")))   // heart rate
        XCTAssertNil(WhoopModel.proven(byService: CBUUID(string: "180F")))   // battery
    }

    // MARK: Resolve order with a registry-pinned model

    func testPinnedRegistryModelBeatsStoredAndLastConnected() {
        XCTAssertEqual(WhoopModel.resolve(pinnedRegistryModel: "WHOOP 4.0", stored: "WHOOP 5.0 / MG",
                                          lastConnected: "WHOOP 5.0 / MG"), .whoop4)
        XCTAssertEqual(WhoopModel.resolve(pinnedRegistryModel: "WHOOP 5.0 / MG", stored: "WHOOP 4.0",
                                          lastConnected: "WHOOP 4.0"), .whoop5mg)
    }

    func testExplicitPickStillBeatsPinnedRegistryModel() {
        XCTAssertEqual(WhoopModel.resolve(explicit: .whoop4, pinnedRegistryModel: "WHOOP 5.0 / MG",
                                          stored: nil, lastConnected: nil), .whoop4)
    }

    func testPlaceholderOrMissingPinnedModelFallsThroughToStored() {
        XCTAssertEqual(WhoopModel.resolve(pinnedRegistryModel: "WHOOP", stored: "WHOOP 5.0 / MG",
                                          lastConnected: nil), .whoop5mg)
        XCTAssertEqual(WhoopModel.resolve(pinnedRegistryModel: nil, stored: nil,
                                          lastConnected: "WHOOP 5.0 / MG"), .whoop5mg)
    }

    func testPinnedModelOnlyComesFromAnActiveRowWithAPeripheral() {
        let pinned = [device("my-whoop", model: "WHOOP 5.0 / MG", peripheralId: "AAA", status: .active)]
        XCTAssertEqual(DeviceRegistry.pinnedModel(in: pinned, activeDeviceId: "my-whoop"), "WHOOP 5.0 / MG")
        let unpinned = [device("my-whoop", model: "WHOOP 5.0 / MG", status: .active)]
        XCTAssertNil(DeviceRegistry.pinnedModel(in: unpinned, activeDeviceId: "my-whoop"))
        XCTAssertNil(DeviceRegistry.pinnedModel(in: pinned, activeDeviceId: "other"))
    }

    // MARK: Archived → active on reconnect

    private func device(_ id: String, brand: String = "WHOOP", model: String = "WHOOP",
                        peripheralId: String? = nil, status: DeviceStatus) -> PairedDevice {
        PairedDevice(id: id, brand: brand, model: model, peripheralId: peripheralId,
                     sourceKind: .liveBLE, capabilities: [.hr], status: status, addedAt: 0, lastSeenAt: 0)
    }

    func testArchivedWhoopMatchedByPeripheralIsRestored() {
        let devices = [device("my-whoop", peripheralId: "AAA", status: .archived)]
        XCTAssertEqual(DeviceRegistry.archivedDeviceToRestore(in: devices, activeDeviceId: "my-whoop",
                                                              connectedPeripheralId: "AAA"), "my-whoop")
    }

    func testArchivedActiveRowWithoutPeripheralIsRestoredOnFirstConnect() {
        let devices = [device("my-whoop", status: .archived)]
        XCTAssertEqual(DeviceRegistry.archivedDeviceToRestore(in: devices, activeDeviceId: "my-whoop",
                                                              connectedPeripheralId: "AAA"), "my-whoop")
    }

    func testNonArchivedOrForeignConnectionIsNotRestored() {
        let active = [device("my-whoop", peripheralId: "AAA", status: .active)]
        XCTAssertNil(DeviceRegistry.archivedDeviceToRestore(in: active, activeDeviceId: "my-whoop",
                                                            connectedPeripheralId: "AAA"))
        // A different strap connected than the one the archived row adopted.
        let other = [device("my-whoop", peripheralId: "AAA", status: .archived)]
        XCTAssertNil(DeviceRegistry.archivedDeviceToRestore(in: other, activeDeviceId: "my-whoop",
                                                            connectedPeripheralId: "BBB"))
    }

    func testRestoreNeverStealsTheActiveSlotFromAnotherDevice() {
        let devices = [device("my-whoop", peripheralId: "AAA", status: .archived),
                       device("polar", brand: "Polar", model: "H10", status: .active)]
        XCTAssertNil(DeviceRegistry.archivedDeviceToRestore(in: devices, activeDeviceId: "polar",
                                                            connectedPeripheralId: "AAA"))
    }

    func testNonWhoopRowIsNeverRestoredByAStrapConnect() {
        let devices = [device("polar", brand: "Polar", model: "H10", peripheralId: "AAA", status: .archived)]
        XCTAssertNil(DeviceRegistry.archivedDeviceToRestore(in: devices, activeDeviceId: "polar",
                                                            connectedPeripheralId: "AAA"))
    }

    func testModelIsRecordedOnlyWhenItChanges() {
        let unknown = device("my-whoop", status: .active)
        XCTAssertEqual(DeviceRegistry.device(unknown, withModel: "WHOOP 5.0 / MG")?.model, "WHOOP 5.0 / MG")
        let known = device("my-whoop", model: "WHOOP 5.0 / MG", status: .active)
        XCTAssertNil(DeviceRegistry.device(known, withModel: "WHOOP 5.0 / MG"))
        XCTAssertNil(DeviceRegistry.device(unknown, withModel: ""))
    }

    func testOnlyAnUnknownPlaceholderModelIsReplaced() {
        XCTAssertTrue(DeviceRegistry.isUnknownModelPlaceholder("WHOOP"))
        XCTAssertTrue(DeviceRegistry.isUnknownModelPlaceholder("whoop"))
        XCTAssertTrue(DeviceRegistry.isUnknownModelPlaceholder(""))
        XCTAssertFalse(DeviceRegistry.isUnknownModelPlaceholder("WHOOP 4.0"))
        XCTAssertFalse(DeviceRegistry.isUnknownModelPlaceholder("WHOOP 5.0 / MG"))
        // A known 4.0 row is never flipped to 5/MG (nor the reverse), whatever a later connect claims.
        let four = device("my-whoop", model: "WHOOP 4.0", status: .active)
        XCTAssertNil(DeviceRegistry.device(four, withModel: "WHOOP 5.0 / MG"))
        let five = device("my-whoop", model: "WHOOP 5.0 / MG", status: .active)
        XCTAssertNil(DeviceRegistry.device(five, withModel: "WHOOP 4.0"))
    }

    @MainActor
    func testReconcileNeverOverwritesAKnownModel() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistry(store: DeviceRegistryStore(dbQueue: store.registryQueue))
        registry.add(device("my-whoop", model: "WHOOP 4.0", peripheralId: "AAA", status: .active))
        let lines = registry.reconcileConnectedWhoop(peripheralId: "AAA", model: "WHOOP 5.0 / MG")
        XCTAssertEqual(registry.devices.first(where: { $0.id == "my-whoop" })?.model, "WHOOP 4.0")
        XCTAssertTrue(lines.isEmpty)
    }

    @MainActor
    func testReconcileRestoresArchivedDeviceAndRecordsModelEndToEnd() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistry(store: DeviceRegistryStore(dbQueue: store.registryQueue))
        registry.add(device("my-whoop", status: .archived))
        let lines = registry.reconcileConnectedWhoop(peripheralId: "AAA", model: "WHOOP 5.0 / MG")
        let row = try XCTUnwrap(registry.devices.first(where: { $0.id == "my-whoop" }))
        XCTAssertEqual(row.status, .active)
        XCTAssertEqual(row.model, "WHOOP 5.0 / MG")
        XCTAssertEqual(lines.count, 2)
    }

    // MARK: Coordinator reconcile (registry write driven by the connect signals)

    @MainActor
    private func makeCoordinator(registry: DeviceRegistry,
                                 uuid: PassthroughSubject<String?, Never>,
                                 model: PassthroughSubject<WhoopModel?, Never>,
                                 log: @escaping (String) -> Void = { _ in }) -> SourceCoordinator {
        SourceCoordinator(registry: registry,
                          live: LiveState(),
                          storeHandle: { nil },
                          startWhoop: {},
                          stopWhoop: {},
                          setWhoopPreferredPeripheral: { _ in },
                          setWhoopActiveDeviceId: { _ in },
                          connectedPeripheralUUID: uuid.eraseToAnyPublisher(),
                          connectedWhoopModel: model.eraseToAnyPublisher(),
                          straplog: log)
    }

    @MainActor
    func testCoordinatorRestoresArchivedDeviceAndRecordsProvenModelAfterConnect() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistry(store: DeviceRegistryStore(dbQueue: store.registryQueue))
        registry.add(device("my-whoop", status: .archived))
        let uuid = PassthroughSubject<String?, Never>()
        let model = PassthroughSubject<WhoopModel?, Never>()
        var lines: [String] = []
        let coordinator = makeCoordinator(registry: registry, uuid: uuid, model: model) { lines.append($0) }
        coordinator.start()

        // didConnect on a targeted reconnect: model cleared, strap published, family not proven yet.
        model.send(nil)
        uuid.send("AAA")
        var row = try XCTUnwrap(registry.devices.first(where: { $0.id == "my-whoop" }))
        XCTAssertEqual(row.status, .active)
        XCTAssertEqual(row.peripheralId, "AAA")
        XCTAssertEqual(row.model, "WHOOP", "an unproven connect must not record a model")

        // Service discovery then finds the 5/MG service → the model is recorded.
        model.send(.whoop5mg)
        row = try XCTUnwrap(registry.devices.first(where: { $0.id == "my-whoop" }))
        XCTAssertEqual(row.model, "WHOOP 5.0 / MG")
        XCTAssertEqual(lines.count, 2)
    }

    @MainActor
    func testCoordinatorNeverAttributesTheOldStrapsModelToANewStrap() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistry(store: DeviceRegistryStore(dbQueue: store.registryQueue))
        registry.add(device("my-whoop", model: "WHOOP 4.0", peripheralId: "AAA", status: .active))
        let uuid = PassthroughSubject<String?, Never>()
        let model = PassthroughSubject<WhoopModel?, Never>()
        let coordinator = makeCoordinator(registry: registry, uuid: uuid, model: model)
        coordinator.start()
        model.send(.whoop4)
        uuid.send("AAA")

        // A different strap connects and proves a different family: the 4.0 row is neither re-adopted
        // nor rewritten.
        model.send(nil)
        uuid.send("BBB")
        model.send(.whoop5mg)
        let row = try XCTUnwrap(registry.devices.first(where: { $0.id == "my-whoop" }))
        XCTAssertEqual(row.peripheralId, "AAA")
        XCTAssertEqual(row.model, "WHOOP 4.0")
    }
}

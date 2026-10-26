import Foundation
import CoreBluetooth
import WhoopProtocol

// Multi-WHOOP: pin one strap, re-adopt a working strap, Add-a-WHOOP scan (inert on the single-WHOOP path).
extension BLEManager {
    /// Pin connections to ONE specific strap by its CBPeripheral.identifier.uuidString. The app sets
    /// this to the active device's persisted `peripheralId` when it has one; pass nil to clear it
    /// (back to "connect to the first WHOOP discovered" — the single-WHOOP default). An unparseable
    /// string clears the pin rather than wedging the scan. Only `didDiscover` reads it; setting it
    /// does NOT start/stop/redirect an in-flight connection on its own.
    public func setPreferredPeripheral(_ uuidString: String?) {
        let resolved = uuidString.flatMap { UUID(uuidString: $0) }   // nil for unparseable → clears the pin
        // A genuinely NEW pin starts the #52 refusal streak clean — the old streak belonged to the strap we
        // were pinned to before, not this one. Re-applying the SAME pin (the common no-op when the active
        // device doesn't change) deliberately preserves an in-progress count. A pin change to anything other
        // than the in-flight handoff target also abandons that handoff (the user/registry re-targeted).
        if resolved != preferredPeripheralUUID {
            pinnedBondRefusals = 0
            if resolved != readoptingTo { readoptingTo = nil }
        }
        preferredPeripheralUUID = resolved
    }

    /// True when `p` is the strap we're pinned to — or when no pin is set (the single-WHOOP default, so
    /// any WHOOP is acceptable and the legacy first-found behaviour is preserved byte-for-byte). The
    /// attach/reconnect paths consult this so they can never adopt the WRONG already-connected strap on a
    /// multi-WHOOP setup (the registry said one strap, the radio stayed on another — multi-WHOOP switch bug).
    func isPreferredPeripheral(_ p: CBPeripheral) -> Bool {
        guard let preferred = preferredPeripheralUUID else { return true }
        return p.identifier == preferred
    }

    /// #52: a strap reached a GENUINE encrypted bond. Remember its identifier as the live working strap
    /// (the candidate the registry pin should follow if a stale pin keeps refusing), and clear the
    /// pin-refusal streak — any healthy bond proves the current path is fine, so a later transient
    /// "insufficient" starts counting from zero rather than inheriting old suspicion. If this bond is the
    /// strap we're mid-handoff onto (#52 re-adoption), CONFIRM it to SourceCoordinator now: republish its
    /// identity on `connectedPeripheralUUID` while `encryptedBond` is true, the one emission of that seam
    /// that proves a genuine bond — which is exactly how SourceCoordinator tells a vetted re-adoption from
    /// the ordinary pre-bond `didConnect` publish (where `encryptedBond` is still false).
    func noteGenuineBond(of p: CBPeripheral) {
        lastBondedPeripheralUUID = p.identifier
        pinnedBondRefusals = 0
        if readoptingTo == p.identifier {
            readoptingTo = nil
            log("Multi-WHOOP (#52): working strap bonded — confirming re-adoption to the registry.")
            // nil first so the publisher's removeDuplicates() can't swallow the value when this strap was
            // already the last-connected uuid (the nil emission is ignored downstream — the uuid guard).
            connectedPeripheralUUID = nil
            connectedPeripheralUUID = p.identifier.uuidString
        }
    }

    /// #52: the pinned strap (`stalePin`) has refused the encrypted bond `pinBondRefusalLimit` times in a
    /// row while a DIFFERENT strap (`working`) bonds fine — the registry pin is stale and is making
    /// connect() abandon the strap that actually works. Hand the pin off to the working strap: re-point our
    /// own pin so connect()/didDiscover stop dropping the working strap, then reconnect onto it. Once it
    /// re-bonds, `noteGenuineBond` republishes its identity to SourceCoordinator (with `encryptedBond` true)
    /// so the registry re-adopts it. The normal first-connect/identity path (encryptedBond false at
    /// didConnect) is untouched, so this never fires on the correct-pin or single-strap path.
    func readoptWorkingStrap(_ working: UUID, awayFrom stalePin: UUID) {
        log("Multi-WHOOP (#52): pinned strap refused the bond \(pinnedBondRefusals)× but another strap is bonded — handing the pin off to the working strap.")
        preferredPeripheralUUID = working
        pinnedBondRefusals = 0
        readoptingTo = working
        // The stale pin made us drop the working strap; reconnect so the now-correct pin lands on it. If
        // it's somehow still the held+bonded peripheral, confirm the re-adoption straight away instead.
        if let p = peripheral, p.identifier == working, p.state == .connected, state.encryptedBond {
            noteGenuineBond(of: p)
        } else if !intentionalDisconnect {
            connect(model: selectedModel)
        }
    }

    /// Re-point which device id live WHOOP samples store under, when the active WHOOP changes (a
    /// WHOOP↔WHOOP switch via the registry). Only the `SourceCoordinator` calls this, and only when a
    /// DIFFERENT registered WHOOP becomes active — the single-WHOOP path leaves the seeded "my-whoop" id
    /// in place (bootstrapStore set it; this is never called), so that path is byte-for-byte unchanged.
    /// Sets the manager's `deviceId` AND re-points the in-flight Collector/Backfiller so the very next
    /// flush / standard-HR persist / historical finishChunk attributes new samples to the new id —
    /// without waiting for a relaunch or a full strap-switch store rebuild. The Collector reads
    /// `deviceId` at persist time (live + 0x2A37 standard-HR paths) and the Backfiller at finishChunk,
    /// so updating their mutable `deviceId` here is sufficient. Additive: nothing on the single-WHOOP
    /// path invokes it, so with one WHOOP the id stays "my-whoop" throughout.
    public func setActiveDeviceId(_ id: String) {
        guard !id.isEmpty else { return }
        deviceId = id
        collector?.deviceId = id
        backfiller?.deviceId = id
    }

    /// Add-a-WHOOP wizard: scan the selected family's WHOOP service and surface every nearby strap in
    /// `discoveredWhoops` WITHOUT auto-connecting. Turns on the `isPresentingScan` flag that diverts
    /// `didDiscover` to collect-not-connect, and uses duplicate-allowing scanning so RSSI refreshes.
    /// The wizard MUST call `stopWhoopScan()` before any normal connect resumes — this mode owns the
    /// central while active. No-op-to-the-connect-path: it never touches `peripheral`/bond state.
    public func scanForWhoops() {
        guard central.state == .poweredOn else {
            log("Add-a-WHOOP scan: Bluetooth not powered on (state=\(central.state.rawValue))")
            return
        }
        cancelScanFallback()            // no family-rotation timer should fire during a present-scan
        resetScanFeedback()             // the wizard owns the central now; an old "searching"/timeout must not linger
        isPresentingScan = true
        discoveredWhoops = []           // fresh list each time the wizard opens the scan
        central.stopScan()
        // Allow duplicates so the wizard's RSSI/signal readout updates as straps move.
        central.scanForPeripherals(
            withServices: [selectedModel.scanService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        log("Add-a-WHOOP scan: presenting nearby \(selectedModel.displayName) straps")
    }

    /// End the Add-a-WHOOP present-scan: stop scanning and clear `isPresentingScan` so `didDiscover`
    /// returns to its normal auto-connect behaviour. Safe to call when not presenting (idempotent).
    public func stopWhoopScan() {
        guard isPresentingScan else { return }
        isPresentingScan = false
        central.stopScan()
        resetScanFeedback()
        log("Add-a-WHOOP scan: stopped")
    }
}

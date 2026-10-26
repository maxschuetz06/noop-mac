import Foundation
import CoreBluetooth
import WhoopProtocol

// Connect, disconnect, scan and service-discovery plumbing.
extension BLEManager {
    public func connect(model: WhoopModel = .persisted) {
        intentionalDisconnect = false
        selectedModel = model
        // Frame the inbound stream for the chosen family (WHOOP 4.0 CRC8 vs WHOOP 5.0 CRC16/puffin)
        // and tell the router which decoder to use. Fresh per connection so no stale bytes carry over.
        reassemblers.reset(family: model.deviceFamily)
        router.family = model.deviceFamily
        // Live 5/MG persistence: point the Collector's decode at the selected family and install the
        // identity clock ref for a 5/MG (its live timestamps are already real unix). WHOOP 4.0 keeps
        // the GET_CLOCK correlation flow untouched. Re-applied after bootstrapStore builds the
        // collector so whichever runs last wins.
        configureCollectorFamily()
        guard central.state == .poweredOn else {
            log("Bluetooth not powered on (state=\(central.state.rawValue)); cannot scan yet")
            let availability = BluetoothAvailability(central.state)
            state.bluetoothAvailability = availability
            state.scanPhase = ScanFeedback.phaseOnStart(availability)
            return
        }
        // Reuse the already-held peripheral ONLY if it's the strap we're pinned to. Without this guard a
        // multi-WHOOP switch attached straight back to the previously-held strap, ignoring the new active
        // device (registry said B, radio stayed on A). No pin (single-WHOOP) → always true, unchanged.
        if let p = peripheral, p.state == .connected, isPreferredPeripheral(p) {
            state.connected = true
            resetScanFeedback()   // no scan/connect is pending — don't leave an old pill or timeout behind
            p.delegate = self
            log("Already connected to \(model.displayName) — refreshing services and notifications")
            discoverPrimaryServices(on: p)
            enableLiveNotifications(reason: "manual refresh")
            return
        }
        // Existing OS-level connections for this WHOOP family. CoreBluetooth keeps a bonded strap connected
        // across app sessions, and `retrieveConnectedPeripherals(...).first` previously adopted WHICHEVER
        // WHOOP macOS already had open — bypassing the scan (the only place the preferred-strap pin was
        // read), so a switch could never move off the wrong strap. Now: with a pin set, drop every OTHER
        // open WHOOP (so it stops holding the link) and attach ONLY to the pinned one. No pin → first-wins,
        // exactly as before. #52: this drop is what abandoned a strap that bonds fine when the pin was
        // STALE — `readoptWorkingStrap()` repoints the pin to the live-bonding strap first, so after a
        // handoff this loop drops the dead strap and attaches to the working one instead of vice-versa.
        let existing = central.retrieveConnectedPeripherals(withServices: [model.scanService])
        if preferredPeripheralUUID != nil {
            for other in existing where !isPreferredPeripheral(other) {
                log("Dropping non-active WHOOP connection \(other.identifier) — not the selected strap")
                central.cancelPeripheralConnection(other)
            }
        }
        if let p = existing.first(where: { isPreferredPeripheral($0) }) {
            log("Found existing \(model.displayName) connection \(p.identifier) — attaching")
            preparePeripheral(p)
            // The service-filtered retrieve above proves the family for this strap.
            familyProof = (p.identifier, model)
            if p.state == .connected {
                state.connected = true
                resetScanFeedback()
                // macOS already holds the link, so there is no didConnect: publish the strap + proven model
                // here so the registry row still adopts its id and records the exact model.
                publishConnectedStrap(p, provenModel: model)
                discoverPrimaryServices(on: p)
                enableLiveNotifications(reason: "attached connection")
            } else {
                central.connect(p, options: nil)
            }
            return
        }
        // Pinned to a specific strap that isn't already open → connect it DIRECTLY by identifier. A scan
        // would let any in-range WHOOP satisfy the connect and could land on the wrong one; the targeted
        // retrieve can only ever return the strap we asked for.
        if let preferred = preferredPeripheralUUID,
           let p = central.retrievePeripherals(withIdentifiers: [preferred]).first {
            log("Connecting to selected strap \(preferred) — targeted")
            preparePeripheral(p)
            // A targeted connect never scans, so it needs its own feedback: "connecting", with the same
            // 20 s timeout if the strap never answers (out of range / asleep / held by the phone app).
            beginScanFeedback(phase: ScanFeedback.phaseOnTargetedConnect(.poweredOn))
            central.connect(p, options: nil)
            return
        }
        beginScanFeedback()
        startScan(for: model, allowFallback: true)
    }

    public func disconnect() {
        intentionalDisconnect = true
        cancelScanFallback()
        resetScanFeedback()
        // A user-initiated teardown is a clean slate: clear any #80 marginal-radio fallback so the next
        // (manual) reconnect attempts the full R10/R11 stream again rather than inheriting old suspicion.
        marginalRadio.reset()
        postBondLoop.reset()   // #617: a clean teardown clears the bond-loop streak so a manual reconnect starts fresh
        readoptingTo = nil   // #52: a clean teardown abandons any in-flight pin handoff
        standardHRFallback = false
        state.standardHRMode = nil
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        central.stopScan()
    }

    /// #78: fully RELEASE a strap when the user removes it from the Devices screen. Archiving the registry
    /// row alone left the strap connected — NOOP kept re-grabbing it (the 3s disconnect→reconnect timer, the
    /// targeted-connect pin, and iOS state restoration ALL still pointed at it), so it stayed connected and
    /// the user could never put it into pairing mode to re-pair (the #78 deadlock: a WHOOP that's connected
    /// can't show its blue pairing LEDs). Stop auto-reconnect, drop the live link, and clear the targeting +
    /// restoration references that point at this strap so NOOP lets go for good — until the user deliberately
    /// reconnects (which clears `intentionalDisconnect` again via connect()).
    public func forgetDevice(_ peripheralId: String?) {
        let target = peripheralId.flatMap { UUID(uuidString: $0) }
        let isCurrent = target == nil || peripheral?.identifier == target
        intentionalDisconnect = true            // defuses the disconnect→3s-reconnect loop's guard
        cancelScanFallback()
        resetScanFeedback()                      // no scan/connect is pending any more — clear pill + timeout
        readoptingTo = nil                       // abandon any in-flight #52 pin handoff
        // Clear the targeted-connect pin + the iOS state-restoration peripheral if they point at this strap,
        // so connect()/restoration can't re-target it.
        if target == nil || preferredPeripheralUUID == target { setPreferredPeripheral(nil) }
        if target == nil || restoredPeripheral?.identifier == target { restoredPeripheral = nil }
        // Drop the live BLE link so the strap is free to enter pairing mode.
        if isCurrent, let p = peripheral {
            central.cancelPeripheralConnection(p)
            peripheral = nil
            resetCharacteristics()
            state.connected = false
            state.bonded = false
            state.encryptedBond = false
            state.pairingHint = nil
            bondRefusalStreak = 0
        }
        central.stopScan()
        log("Device removed — released the strap: stopped auto-reconnect, dropped the link, cleared targeting. Put it in pairing mode (blue LEDs) to re-pair if you want it back. (#78)")
    }

    /// Switch which strap we'll connect to next: drop the current strap and clear the **sticky** bond
    /// state so a newly-picked model bonds fresh. `bonded` deliberately survives a disconnect (it means
    /// "this strap is paired"), but that left a user with BOTH a WHOOP 4 and a 5/MG unable to switch —
    /// `bonded` stayed true from the first strap, which hid the strap picker and kept the scan pointed at
    /// the old family's service. Call this when the user changes the strap selection.
    public func prepareForModelSwitch() {
        disconnect()
        state.connected = false
        state.bonded = false
        state.encryptedBond = false
    }

    /// Idle the engine before presenting an Add-a-WHOOP scan — but ONLY when we're not already
    /// connected to a strap of this same family. Opening the scan must NOT tear down a live, bonded
    /// same-family connection: a WHOOP 5/MG that just bonded refuses the encrypted re-bond on the
    /// reconnect ("Encryption/Authentication is insufficient") and loops forever (#74). A genuine
    /// family switch (e.g. a connected 4.0 while scanning for a 5/MG, or nothing connected) still
    /// idles via `prepareForModelSwitch()` so the scan starts clean. `connect()` reuses the live
    /// same-family peripheral on its "Already connected — refreshing" path.
    public func prepareForPresentScan(model: WhoopModel) {
        if state.connected, selectedModel.deviceFamily == model.deviceFamily {
            log("Add-a-WHOOP scan: keeping the live \(selectedModel.displayName) connection (#74) — presenting nearby straps without dropping it")
            return
        }
        prepareForModelSwitch()
    }

    func preparePeripheral(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        resetCharacteristics()
    }

    func discoverPrimaryServices(on p: CBPeripheral) {
        p.discoverServices([
            selectedModel.scanService, BLEManager.heartRateService, BLEManager.batteryService,
        ])
    }

    func resetCharacteristics() {
        cmdCharacteristic = nil
        cmdNotifyCharacteristic = nil
        eventNotifyCharacteristic = nil
        dataNotifyCharacteristic = nil
        heartRateCharacteristic = nil
        batteryCharacteristic = nil
        whoop5NotifyCharacteristics.removeAll()
    }

    /// Start a service-filtered scan for `model`, re-framing the inbound stream for its family (so a
    /// fallback rotation decodes the strap it actually finds, not the family we started from). When
    /// `allowFallback` is true, schedule a one-shot rotation to the other WHOOP family after
    /// `scanFallbackDelaySeconds` of no discovery — recovers reconnect when the persisted preference is
    /// stale after an update/restore. Discovery/connect cancels the pending rotation. (PR#195)
    private func startScan(for model: WhoopModel, allowFallback: Bool) {
        cancelScanFallback()
        selectedModel = model
        reassemblers.reset(family: model.deviceFamily)
        router.family = model.deviceFamily
        configureCollectorFamily()
        central.stopScan()
        log("Scanning for \(model.displayName)…")
        central.scanForPeripherals(
            withServices: [model.scanService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        guard allowFallback else { return }
        let fallback = model.fallbackScanModel
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.central.isScanning, !self.state.connected else { return }
            self.log("No \(model.displayName) found yet — trying \(fallback.displayName)")
            self.startScan(for: fallback, allowFallback: true)
        }
        scanFallbackWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + BLEManager.scanFallbackDelaySeconds,
            execute: work
        )
    }

    func cancelScanFallback() {
        scanFallbackWorkItem?.cancel()
        scanFallbackWorkItem = nil
    }

    /// Show `phase` (default: "searching") for a fresh scan / targeted-connect request and arm the one-shot
    /// timeout that turns it into `.timedOut` if nothing is found / nothing connects. A scan keeps running
    /// and a pending `central.connect` stays pending after the timeout.
    private func beginScanFeedback(phase: ScanPhase = ScanFeedback.phaseOnStart(.poweredOn)) {
        cancelScanTimeout()
        state.scanPhase = phase
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let before = self.state.scanPhase
            let next = ScanFeedback.phaseAfterTimeout(current: before, connected: self.state.connected)
            guard next != before else { return }
            self.state.scanPhase = next
            if before == .connecting {
                self.log("Selected WHOOP didn't connect after \(Int(ScanFeedback.timeoutSeconds))s — check that it is nearby and not held by the WHOOP phone app; still trying")
            } else {
                self.log("No WHOOP found after \(Int(ScanFeedback.timeoutSeconds))s — put the strap in pairing mode and close the WHOOP phone app; still scanning")
            }
        }
        scanTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ScanFeedback.timeoutSeconds, execute: work)
    }

    /// Nothing is searching / connecting any more: drop the pending timeout and clear the pill.
    func resetScanFeedback() {
        cancelScanTimeout()
        let idle = ScanFeedback.phaseAfterScanStopped()
        if state.scanPhase != idle { state.scanPhase = idle }
    }

    /// Publish the connected strap for the app (registry adoption + model record). The model is cleared
    /// BEFORE the uuid is republished so a subscriber never pairs the new strap with the previous strap's
    /// model, then set again once this strap's family is proven (`provenModel`, or later from service
    /// discovery via `noteFamilyFound`).
    func publishConnectedStrap(_ p: CBPeripheral, provenModel: WhoopModel?) {
        if connectedModel != nil { connectedModel = nil }
        connectedPeripheralUUID = p.identifier.uuidString
        if let provenModel {
            WhoopModel.recordConnected(provenModel)
            connectedModel = provenModel
        }
    }

    /// The family's service was actually found on the connected strap — the proof the targeted-reconnect
    /// path lacks. Records it for the next scan and publishes it for the registry row.
    func noteFamilyFound(_ model: WhoopModel, on p: CBPeripheral) {
        guard p.identifier == peripheral?.identifier, connectedModel != model else { return }
        WhoopModel.recordConnected(model)
        connectedModel = model
    }

    func cancelScanTimeout() {
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = nil
    }

    func enableLiveNotifications(reason: String) {
        guard let p = peripheral, p.state == .connected else { return }
        let chars = [
            cmdNotifyCharacteristic,
            eventNotifyCharacteristic,
            dataNotifyCharacteristic,
            heartRateCharacteristic,
            batteryCharacteristic,
        ].compactMap { $0 }
        for c in chars where !c.isNotifying {
            requestNotify(c, on: p, reason: reason)
        }
    }

    func requestNotify(_ c: CBCharacteristic, on p: CBPeripheral, reason: String) {
        guard c.properties.contains(.notify) || c.properties.contains(.indicate) else {
            log("Notify unavailable \(c.uuid) (\(reason))")
            return
        }
        if c.isNotifying {
            log("Notify already active \(c.uuid) (\(reason))")
            return
        }
        p.setNotifyValue(true, for: c)
        log("Notify requested \(c.uuid) (\(reason))")
    }
}

import Foundation
import CoreBluetooth
import WhoopProtocol

// MARK: - CBCentralManagerDelegate
extension BLEManager: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Central state: \(central.state.rawValue) (5 = poweredOn)")
        let availability = BluetoothAvailability(central.state)
        state.bluetoothAvailability = availability
        let nextPhase = ScanFeedback.phaseOnAvailabilityChange(availability, current: state.scanPhase)
        if nextPhase != state.scanPhase { state.scanPhase = nextPhase }
        guard central.state == .poweredOn else { return }
        // Bootstrap the async store once on first poweredOn (idempotent if already set).
        Task { @MainActor in await bootstrapStore() }
        if let p = restoredPeripheral {
            log("poweredOn with restored peripheral — reconnecting \(p.identifier)")
            if p.state != .connected {
                central.connect(p, options: nil)
            } else {
                discoverPrimaryServices(on: p)
            }
        } else {
            connect()
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "unknown"
        // Multi-WHOOP present-scan (Add-a-WHOOP wizard): collect the strap, do NOT auto-connect, and
        // return before touching the connect flow. Only reachable when the wizard explicitly turned on
        // `isPresentingScan` via scanForWhoops(); on the default path (false) this branch is skipped
        // entirely and the auto-connect code below runs exactly as before.
        if isPresentingScan {
            let uuid = peripheral.identifier.uuidString
            if let i = discoveredWhoops.firstIndex(where: { $0.uuid == uuid }) {
                discoveredWhoops[i] = (uuid: uuid, name: name, rssi: RSSI.intValue)   // refresh RSSI
            } else {
                discoveredWhoops.append((uuid: uuid, name: name, rssi: RSSI.intValue))
            }
            return
        }
        // Multi-WHOOP preferred-peripheral filter: when the app has pinned a specific strap, ignore any
        // OTHER discovered WHOOP and keep scanning. When `preferredPeripheralUUID == nil` (the single-
        // WHOOP default) this guard is skipped and the original "connect to the first discovered" path
        // below is byte-for-byte unchanged.
        if let preferred = preferredPeripheralUUID, peripheral.identifier != preferred {
            log("Discovered \(name) (\(peripheral.identifier)) — not the preferred strap; ignoring")
            return
        }
        cancelScanFallback()
        cancelScanTimeout()
        state.scanPhase = .connecting
        // Persist the family that actually advertised (the scan is service-filtered, so this is proven) so
        // the next scan starts on the right service — this is what makes a one-time rotation stick after a
        // stale-preference reconnect. (PR#195) Attributed to THIS peripheral until its didConnect.
        WhoopModel.recordConnected(selectedModel)
        familyProof = (peripheral.identifier, selectedModel)
        log("Discovered \(name) (rssi \(RSSI)) — connecting")
        central.stopScan()
        preparePeripheral(peripheral)
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        cancelScanFallback()
        cancelScanTimeout()
        state.scanPhase = .idle
        failedConnectAttempts = 0   // a successful connect clears the reconnect backoff (#414)
        restoredPeripheral = nil
        preparePeripheral(peripheral)
        // Clear the per-connection bond BEFORE publishing the connected uuid below. SourceCoordinator's #52
        // re-adoption gate keys off `encryptedBond` at the instant `connectedPeripheralUUID` is observed —
        // an ordinary `didConnect` publish must always read false (only the deliberate post-bond #52
        // handoff republish carries it true), so this clear has to precede the publish, not follow it.
        state.encryptedBond = false   // re-proved per connection at the genuine-bond site (#69)
        // Multi-WHOOP: publish the strap's stable BLE identity so the app can persist it onto the active
        // registry device (it observes this and calls registry.setPeripheralId). Additive observation
        // only — BLEManager stays decoupled from the store and the connect flow below is unchanged.
        // Only a PROVEN family is recorded (see `connectedModel`): the discovery that led here, if any.
        // A targeted reconnect has no such proof yet — the family's service found during service
        // discovery supplies it (`noteFamilyFound`), so a 4.0 can never be recorded as 5/MG by assumption.
        let proof = familyProof.flatMap { $0.peripheral == peripheral.identifier ? $0.model : nil }
        publishConnectedStrap(peripheral, provenModel: proof)
        state.connected = true
        state.reconnectGuide = nil    // a connect succeeded — the stale-bond guide (if shown) is resolved
        lastDataAt = Date()
        log("Connected — discovering services")
        discoverPrimaryServices(on: peripheral)
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        Task { @MainActor in await collector?.flush() }
        judgeConnectionEnd(error: error)
        tearDownLinkState()
        if !intentionalDisconnect {
            log("Disconnected\(error.map { " — \($0.localizedDescription)" } ?? ""); rescanning in 3s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.intentionalDisconnect else { return }
                self.connect()
            }
        } else {
            log("Disconnected (intentional)")
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        log("Failed to connect\(error.map { " — \($0.localizedDescription)" } ?? "")")
        cancelScanTimeout()
        if state.scanPhase == .connecting { state.scanPhase = .idle }   // the retry below re-enters its own phase
        // The strap wiped its bond (a firmware update, or the official WHOOP app re-bonding it). macOS keeps
        // re-presenting the now-stale pairing key, so every reconnect loops on this same error with no
        // recovery and no user guidance. Surface an actionable re-pair guide instead of failing silently —
        // NOOP itself works fine on the new firmware once the stale bond is cleared. (5/MG firmware reset, 2026-06)
        if let cbErr = error as? CBError, cbErr.code == .peerRemovedPairingInformation {
            state.reconnectGuide = """
            Your strap's Bluetooth pairing was reset — usually by a WHOOP firmware update, or the official WHOOP app reconnecting. NOOP works fine on the new firmware; you just need to re-pair:

            1. Quit the official WHOOP app (or turn off Bluetooth on that phone).
            2. Open System Settings → Bluetooth and Forget “WHOOP MG” if it's listed.
            3. Tap the strap repeatedly until its LEDs flash blue (pairing mode).
            4. Come back here and reconnect.
            """
            return
        }
        // Any other connect failure (e.g. a weak-signal encrypted-handshake timeout on a 5/MG at the
        // edge of range — #414). The disconnect path reschedules a rescan, but didFailToConnect never
        // did, so the loop died here until a manual reconnect. Reschedule with a capped exponential
        // backoff (3, 6, 12, 24, 48, 60s…) so a strap that's genuinely out of range doesn't hammer BLE.
        guard !intentionalDisconnect else { return }
        failedConnectAttempts += 1
        let delay = min(60.0, 3.0 * pow(2.0, Double(failedConnectAttempts - 1)))
        log("Reconnecting in \(Int(delay))s (attempt \(failedConnectAttempts))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.intentionalDisconnect else { return }
            self.connect()
        }
    }

    /// State restoration entry point (M3 background collection).
    /// Stores the restored peripheral and — if already connected — immediately
    /// re-discovers services so `cmdCharacteristic` is re-acquired and
    /// notifications are re-routed without user interaction.
    public func centralManager(_ central: CBCentralManager,
                               willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let p = peripherals.first else {
            log("Restore: no peripherals in state dict")
            return
        }
        self.peripheral = p
        self.restoredPeripheral = p
        p.delegate = self
        resetCharacteristics()
        // Re-derive the inbound-decode family from the persisted model. connect()/startScan() set the
        // reassembler + router family, but NEITHER runs on the restore path — so without this a restored
        // WHOOP 5/MG would decode its puffin notify frames with the default .whoop4 framing (different
        // length offset + constant), producing corrupt/empty data for the whole unattended session until
        // the user manually taps connect.
        selectedModel = .persisted
        reassemblers.reset(family: selectedModel.deviceFamily)
        router.family = selectedModel.deviceFamily
        configureCollectorFamily()
        // Collection only runs post-bond, so a restored link was already bonded;
        // seed those flags now. `didWriteValueFor` won't re-fire on its own.
        state.bonded = true
        state.encryptedBond = true   // a restored link was genuinely encrypted-bonded before (#69)
        didBond = true
        noteGenuineBond(of: p)   // #52: a restored link was genuinely bonded; eligible as a re-adopt target
        // clockRef is nil in the fresh process after restore, so we must re-request it.
        // Reset the flag so the post-restore didWriteValueFor issues exactly one getClock.
        clockRequested = false
        // Ensure the store is ready before restored BLE data arrives (idempotent; no-op if already built).
        Task { @MainActor in await bootstrapStore() }
        if p.state == .connected {
            state.connected = true
            log("Restored CONNECTED peripheral \(p.identifier) — re-discovering services")
            discoverPrimaryServices(on: p)
        } else {
            state.connected = false
            log("Restored DISCONNECTED peripheral \(p.identifier) — reconnect on poweredOn")
            if central.state == .poweredOn { central.connect(p, options: nil) }
        }
    }
}

extension BLEManager {
    /// Feed the #80 marginal-radio and #617 bond-loop detectors with this drop. Must run BEFORE
    /// `tearDownLinkState` clears the arm / bond timestamps they read.
    private func judgeConnectionEnd(error: Error?) {
        // #80 marginal-radio detection: judge this drop BEFORE the state resets below clobber the
        // arm timestamp. A drop that is unintentional, error-bearing, and lands shortly after we armed
        // the R10/R11 burst is the marginal-radio tell. Feed the detector; if it trips, the NEXT connect
        // skips the heavy arm (the flag is intentionally NOT reset on disconnect so it survives rescan).
        let timedOut = !intentionalDisconnect && error != nil
        let sinceArm = realtimeArmedAt.map { Date().timeIntervalSince($0) }
        if marginalRadio.connectionEnded(wasArmed: realtimeArmedAt != nil,
                                         secondsSinceArm: sinceArm,
                                         timedOut: timedOut) {
            standardHRFallback = true
            log("Marginal radio (#80): \(marginalRadio.consecutiveArmTimeouts) arm-then-timeout cycles — next connect uses standard-HR mode (0x2A37 only)")
        }
        // #617 bond-loop detection: same pre-reset read. The bond-loop tell is a CONNECTION TIMEOUT that
        // lands within seconds of a genuine bond — bond → drop → rescan → bond → drop, forever. We require
        // the OS to classify the drop as a connection timeout (`CBError.connectionTimeout`), not merely any
        // error, so a one-off radio blip or a different failure doesn't get mistaken for the loop. Once it
        // trips, surface the EXISTING re-pair guide (the same forget-and-re-pair steps the #74/firmware-reset
        // path shows) rather than letting the link loop silently and drain the battery.
        let connTimedOut: Bool = (error as? CBError)?.code == .connectionTimeout
        let sinceBond = bondedAt.map { Date().timeIntervalSince($0) }
        if postBondLoop.connectionEnded(wasBonded: bondedAt != nil,
                                        secondsSinceBond: sinceBond,
                                        timedOut: connTimedOut && !intentionalDisconnect) {
            log("Bond-loop (#617): \(postBondLoop.consecutiveBondTimeouts) bond-then-timeout cycles — surfacing the re-pair guide")
            if state.reconnectGuide == nil {
                state.reconnectGuide = """
                Your strap keeps connecting and then dropping a second later. This is almost always a stale Bluetooth pairing — usually after a WHOOP firmware update, or the official WHOOP app holding the strap. NOOP works fine once it's re-paired:

                1. Quit the official WHOOP app (or turn off Bluetooth on that phone).
                2. Open System Settings → Bluetooth and Forget your WHOOP if it's listed.
                3. Tap the strap repeatedly until its LEDs flash blue (pairing mode).
                4. Come back here and reconnect.
                """
            }
        }
    }

    /// Reset every per-connection flag, counter and timer so the next connect starts clean.
    private func tearDownLinkState() {
        bondedAt = nil   // cleared after the bond-loop detector above read it (#617)
        state.connected = false
        state.encryptedBond = false   // cleared with didBond; next session must re-prove the bond (#69)
        state.charging = nil          // a stale charging flag must not outlive the link
        state.clearBiometrics()       // and a stale HR / R-R must not outlive the link either
        state.liveFeedActive = false  // a drop while Live is open must not leave a stale "Stop live feed"
        didBond = false
        whoop5RealtimeArmed = false
        // The strap forgets the realtime-HR toggle across a disconnect; the post-bond branch re-arms it
        // from `wantsRealtime`. Clear only the "what we last sent" flag — `screenWantsRealtime` /
        // `keepRealtimeForData` (and thus `wantsRealtime`) are intent and must survive a reconnect so the
        // stream comes back automatically.
        realtimeArmed = false
        whoop5SessionStarted = false
        clockRequested = false
        connectHandshakeDone = false
        realtimeArmedAt = nil   // cleared after the marginal-radio detector above read it (#80)
        // Reset backfill state so the next connect starts a fresh offload (incl. the syncing pill —
        // a dropped link mid-offload must not leave "Syncing strap history…" stuck on, #77).
        backfillStarted = false
        // #364: the auto-continue streak + spin-detector are per-connection — a fresh connection earns a
        // fresh budget of back-to-back re-kicks and starts its trim-advance comparison from scratch.
        consecutiveAutoContinues = 0
        autoContinueStreakStartedAt = nil
        loggedHistoryFrontierUnavailable = false
        lastSessionEndTrim = nil
        backfilling = false
        state.backfilling = false
        state.syncChunksThisSession = 0
        // A mid-sync disconnect bypasses exitBackfilling, so clear the reject counters here too —
        // otherwise a stale non-zero count survives until the next beginBackfill. (#77/#91)
        state.rejectedFramesThisSession = 0
        state.rejectedFramesUnarchived = 0
        state.decodedChunksThisSession = 0
        state.consoleChunksThisSession = 0
        state.r22FlagsAccepted = 0
        state.deepPacketsThisSession = 0
        lastOffloadFrameAt = nil   // #174: don't carry a stale cooldown reference into the next session
        // #580: a fresh connection earns a fresh empty-offload streak — a strap that was history-empty last
        // session might bank this time (or vice-versa). Clear the experimental note too; the next offload
        // re-derives it. (The honest flag is per-link, like the syncing pill / reject counters above.)
        whoop5EmptyOffload.reset()
        state.historySyncExperimental = false
        backfillTimeout?.cancel()
        backfillTimeout = nil
        backfillFrameQueue.removeAll()
        backfillDraining = false
        releaseSyncActivityNow()   // the link is gone — nothing left to keep out of App Nap
        uploadTimer?.cancel()
        uploadTimer = nil
        backfillTimer?.cancel()
        backfillTimer = nil
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        resetCharacteristics()
        reassemblers.reset()   // a half frame from the dropped link must not swallow the next stream's head
        flushUnmappedTap(context: "disconnect")
        puffinRecorder.flush()   // persist any buffered puffin capture frames before reconnect
        Task { @MainActor in await collector?.flushStandardHR() }   // persist any buffered 0x2A37 HR
    }
}

import Foundation
import CoreBluetooth
import WhoopProtocol

// MARK: - CBPeripheralDelegate
extension BLEManager: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("Service discovery failed: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        log("Services discovered: \(services.map { $0.uuid.uuidString }.joined(separator: ", "))")
        for s in services {
            // Finding a family's service is proof of the family (discovery only asked for the selected one).
            if let proven = WhoopModel.proven(byService: s.uuid) { noteFamilyFound(proven, on: peripheral) }
            switch s.uuid {
            case BLEManager.customService:
                peripheral.discoverCharacteristics(
                    [BLEManager.cmdWriteChar, BLEManager.cmdNotifyChar,
                     BLEManager.eventNotifyChar, BLEManager.dataNotifyChar], for: s)
            case BLEManager.heartRateService:
                peripheral.discoverCharacteristics([BLEManager.heartRateChar], for: s)
            case BLEManager.batteryService:
                peripheral.discoverCharacteristics([BLEManager.batteryChar], for: s)
            case BLEManager.whoop5Service:
                // EXPERIMENTAL WHOOP 5.0/MG path: discover the puffin command + notify characteristics
                // so we can send CLIENT_HELLO and receive frames. Live HR/battery still arrive over the
                // standard 0x2A37/0x2A19 profiles (discovered alongside this); this custom path is
                // unverified on MG hardware.
                log("WHOOP 5/MG detected — discovering puffin characteristics (experimental).")
                peripheral.discoverCharacteristics(
                    [BLEManager.whoop5CmdWriteChar] + BLEManager.whoop5NotifyChars, for: s)
            default: break
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        if let error {
            log("Characteristic discovery failed for \(service.uuid): \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else { return }
        for c in chars {
            switch c.uuid {
            case BLEManager.cmdWriteChar:
                cmdCharacteristic = c
                // THE BONDING TRICK: one confirmed write triggers just-works bonding.
                // GET_BATTERY_LEVEL is benign and what the Mac prototype uses.
                seq = seq &+ 1
                let bondFrame = WhoopCommand.getBatteryLevel.frame(seq: seq, payload: [0x00])
                log("Bonding: confirmed write GET_BATTERY_LEVEL to 61080002")
                peripheral.writeValue(Data(bondFrame), for: c, type: .withResponse)
            case BLEManager.whoop5CmdWriteChar:
                // EXPERIMENTAL WHOOP 5.0/MG: a 5/MG strap starts a session with the static CLIENT_HELLO
                // frame, not the WHOOP4 confirmed-write bond. We write it UNacknowledged (it is a
                // complete framed command), so the WHOOP4 didWriteValueFor bond+handshake path never
                // fires for a 5/MG strap. Live HR/battery come from the standard profiles; this just
                // opens the puffin session. Unverified on real MG hardware.
                cmdCharacteristic = c
                if let hello = selectedModel.deviceFamily.clientHello {
                    // CONTRIBUTOR FIX (issue #17 — diagnosed from the logs, unverified on hardware here):
                    // write CLIENT_HELLO with .withResponse so CoreBluetooth runs just-works bonding when
                    // the link needs authenticating, AND so didWriteValueFor fires. That callback is where
                    // we mark the link established and (re)subscribe the puffin notify chars — the strap
                    // rejects them with "Authentication is insufficient" until the connection is encrypted,
                    // and the old .withoutResponse write never triggered bonding, so it hung forever at
                    // "Finishing the secure pairing handshake…".
                    log("WHOOP 5/MG: writing CLIENT_HELLO to fd4b0002 with response (to trigger bonding, experimental).")
                    state.pairingHint = nil   // fresh attempt; clear any stale pairing-mode guidance
                    peripheral.writeValue(Data(hello), for: c, type: .withResponse)
                }
                // The realtime-HR stream is armed POST-bond (in didWriteValueFor / startRealtime) with
                // puffin framing — not here. Writing it pre-bond on an unauthenticated link did nothing.
            case BLEManager.cmdNotifyChar,
                 BLEManager.eventNotifyChar,
                 BLEManager.dataNotifyChar,
                 BLEManager.heartRateChar,
                 BLEManager.batteryChar:
                switch c.uuid {
                case BLEManager.cmdNotifyChar: cmdNotifyCharacteristic = c
                case BLEManager.eventNotifyChar: eventNotifyCharacteristic = c
                case BLEManager.dataNotifyChar: dataNotifyCharacteristic = c
                case BLEManager.heartRateChar: heartRateCharacteristic = c
                case BLEManager.batteryChar:
                    batteryCharacteristic = c
                    if c.properties.contains(.read) {
                        peripheral.readValue(for: c)
                    }
                default: break
                }
                requestNotify(c, on: peripheral, reason: "discovery")
            default:
                // WHOOP 5.0/MG puffin notify characteristics (fd4b0003/0004/0005/0007). Retain them but DO
                // NOT subscribe yet — on an unauthenticated link the strap rejects them with "Authentication
                // is insufficient", which (per a 5/MG owner's verified flow, issue #17) also wedges the bond.
                // didWriteValueFor subscribes them once the CLIENT_HELLO .withResponse write confirms.
                if BLEManager.whoop5NotifyChars.contains(c.uuid) {
                    whoop5NotifyCharacteristics.append(c)
                }
            }
        }
    }

    /// Confirmed-write completion = bonding succeeded (no error).
    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error = error {
            log("Confirmed write failed: \(error.localizedDescription)")
            let insufficient = error.localizedDescription.lowercased().contains("encryption")
                || error.localizedDescription.lowercased().contains("authentication")
            // WHOOP 5/MG first connect: CoreBluetooth won't start a fresh just-works bond against a strap
            // still bonded to the official WHOOP app, so the CLIENT_HELLO .withResponse write fails with
            // "Encryption/Authentication is insufficient" and the link never authenticates. Surface
            // actionable pairing-mode guidance instead of failing silently (issue #17).
            if selectedModel.deviceFamily == .whoop5, !didBond, insufficient {
                bondRefusalStreak += 1
                // #78: surface the pairing-mode guidance once refusals are PERSISTENT — the strap is
                // genuinely refusing the encrypted bond (held by the official WHOOP app, or iOS holds a
                // stale/half pairing it can't re-encrypt, e.g. after a "Restored CONNECTED peripheral").
                // A SINGLE refusal right after a known-good bond (#74) is a transient reconnect race, so we
                // stay quiet on streak 1; from streak 2 we tell the user how to make the strap pairable.
                // (Earlier 5.2.3 logic keyed this off lastBondedPeripheralUUID and wrongly hid the guidance
                // for users whose strap had bonded in a PRIOR session but won't now — exactly #78.)
                if bondRefusalStreak >= 2 {
                    state.pairingHint = "NOOP can see your strap but it's refusing to pair — it's likely still bonded to the official WHOOP app, or your phone is holding an old pairing. To fix it: (1) fully close the WHOOP app, (2) on a 5.0/MG, tap the band repeatedly until the LEDs flash blue (pairing mode), (3) if your strap is listed under iPhone Settings → Bluetooth, tap it and choose Forget This Device, then reconnect in NOOP."
                    log("WHOOP 5/MG: bond refused \(bondRefusalStreak)× with no successful bond — the strap is refusing the encrypted link (WHOOP app holds it, or a stale iOS pairing). Surfacing pairing-mode + forget-device guidance (#78).")
                } else {
                    log("WHOOP 5/MG: bond write refused (insufficient) — retrying once; will surface pairing-mode guidance if it persists (#78).")
                }
            }
            // Multi-WHOOP stale-pin recovery (#52). When a stale registry pin points at a strap that keeps
            // refusing the encrypted bond ("Encryption/Authentication is insufficient") but a DIFFERENT
            // strap has bonded fine this run, connect() otherwise drops the working strap and loops forever
            // on the dead pin — encryptedBond never turns true (which also kills buzz/haptics that gate on
            // it). Count consecutive refusals on the PINNED peripheral; after `pinBondRefusalLimit`, hand
            // the pin off to the live-bonding strap so the registry re-adopts it (handoff republishes the
            // working uuid on the connectedPeripheralUUID seam SourceCoordinator already observes).
            if insufficient, !didBond,
               let pinned = preferredPeripheralUUID, peripheral.identifier == pinned {
                pinnedBondRefusals += 1
                if pinnedBondRefusals >= pinBondRefusalLimit,
                   let working = lastBondedPeripheralUUID, working != pinned {
                    readoptWorkingStrap(working, awayFrom: pinned)
                }
            }
            return
        }

        // EXPERIMENTAL WHOOP 5.0/MG (issue #17): the CLIENT_HELLO is now a .withResponse write, so this
        // fires once the strap acks it — after just-works bonding if the link needed authenticating.
        // Treat that as the link being established: mark bonded (which clears the "Finishing the secure
        // pairing handshake…" status) and re-subscribe the puffin notify chars + standard HR/battery,
        // which the strap refused before the link was encrypted. Do NOT run the WHOOP4 command handshake
        // below — a 5/MG strap rejects WHOOP4-framed commands (the send() guard drops them anyway).
        if selectedModel.deviceFamily == .whoop5 {
            if !didBond {
                didBond = true
                state.bonded = true
                state.encryptedBond = true   // genuine encrypted bond (not the live-HR shortcut) — #69
                bondedAt = Date()            // #617: start the bond→drop stopwatch for the bond-loop detector
                state.pairingHint = nil
                bondRefusalStreak = 0         // #78: a genuine bond resets the refusal streak
                noteGenuineBond(of: peripheral)   // #52: this strap bonds fine; clears any pin-refusal streak
                log("WHOOP 5/MG: CLIENT_HELLO acked — link established; subscribing notify chars (experimental).")
            }
            for c in whoop5NotifyCharacteristics where !c.isNotifying {
                requestNotify(c, on: peripheral, reason: "post-bond puffin")
            }
            enableLiveNotifications(reason: "post-bond 5/MG")   // standard HR/battery that failed pre-bond
            // Arm realtime HR with puffin framing — the verified step that makes a bonded 5/MG strap start
            // streaming (issue #17). Once per connection; keep-alive skips 5/MG, so this is the trigger.
            // (Opening Live later also arms it via startRealtime(), now that send() routes the 5/MG toggle.)
            if wantsRealtime && !whoop5RealtimeArmed {
                whoop5RealtimeArmed = true
                realtimeArmed = true   // keep reconcileRealtime()'s edge tracking in sync with the arm
                log("WHOOP 5/MG: arming realtime HR (puffin TOGGLE_REALTIME_HR)")
                send(.toggleRealtimeHR, payload: [0x01])
            }
            startKeepAlive()                                    // re-subscribe + liveness watchdog
            // Kick the historical offload ONCE per connection — this is the 5/MG edition of the WHOOP4
            // connect-handshake (lines below). didWriteValueFor re-enters this `.whoop5` branch on EVERY
            // .withResponse ack during the offload (each HISTORY_END ack), so the trigger work MUST fire
            // once or it would re-issue SEND_HISTORICAL_DATA mid-stream and storm the strap. The notify
            // re-subscribe + realtime-arm above are idempotent and intentionally run on every re-entry;
            // only this block is gated. `whoop5SessionStarted` resets on disconnect.
            if !whoop5SessionStarted {
                whoop5SessionStarted = true
                connectHandshakeDone = true     // unblocks beginBackfill()'s guard
                log("WHOOP 5/MG: connect handshake done — backfill unblocked")
                // Re-apply the Broadcast-HR device-config flag if the user opted in (#181).
                if PuffinExperiment.broadcastHrEnabled { setBroadcastHr(true) }
                // Clock the strap BEFORE history: an un-clocked WHOOP 5 discards sensor data ("RTC
                // timestamp … is invalid; not saving data to flash") and history offloads "succeed"
                // with metadata only. Same 8-byte payload as the WHOOP4 handshake, puffin-framed;
                // GET_CLOCK's reply rides the puffin notify chars and never touches the WHOOP4
                // clockRef correlation path. The 1.5s deferral below keeps clock-before-history.
                // Hardware-validated ordering (#78 fork).
                send(.setClock, payload: BLEManager.setClockPayload())
                send(.getClock, payload: [])
                log("WHOOP 5/MG: clock synced (set/get) — strap can persist history now")
                log("WHOOP 5/MG: scheduling first historical offload (connect)")
                // Deferred ~1.5s so the puffin notify subscriptions settle before SEND_HISTORICAL_DATA,
                // mirroring the WHOOP4 kick. requestSync → beginBackfill is itself gated on
                // connectHandshakeDone, so a racing foreground/restore trigger can't fire it early.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.requestSync(.connect) }
                startBackfillTimer()            // re-offload the type-47 store every backfillIntervalSeconds
            }
            return
        }

        if !didBond {
            didBond = true
            state.bonded = true
            state.encryptedBond = true   // WHOOP 4 confirmed-write bond is always genuine — #69
            bondedAt = Date()            // #617: start the bond→drop stopwatch for the bond-loop detector
            noteGenuineBond(of: peripheral)   // #52: this strap bonds fine; clears any pin-refusal streak
            log("BONDED (confirmed write acknowledged) — custom channels should now flow")
        }
        // Run the connect handshake EXACTLY ONCE per connection. didWriteValueFor re-fires on EVERY
        // .withResponse write — the bond write, every SEND_HISTORICAL, every HISTORY_END ack. Without
        // this guard those re-entries re-sent hello/SET_CLOCK at the strap *during* the offload and
        // stopped it from streaming type-47. This was THE iOS-side root cause: the Mac prototype pulls
        // type-47 fine because it runs the sequence once on a stable connection; the app stormed it.
        guard !connectHandshakeDone else { return }
        connectHandshakeDone = true
        backfillStarted = true

        // WHOOP-faithful connect lifecycle: hello → set RTC,
        // then offload. Hello is NOT strictly required to serve — verified on this strap via the Mac
        // ground-truth test: plain SEND_HISTORICAL_DATA serves type-47 with no hello and no high-freq-sync
        // (PHASE A = 50 records; PHASE B high-freq = 0). We still exchange hello to mirror WHOOP exactly.
        send(.getHelloHarvard)
        send(.getAdvertisingNameHarvard)
        sendSetClockBothForms()
        if clockRef == nil && !clockRequested {
            clockRequested = true
            // GET_CLOCK's payload length is firmware-specific, exactly like SET_CLOCK's: newer
            // firmware answers the EMPTY form and ignores [0x00], while fw 41.17.x answers [0x00] and
            // ignores the empty form (#120). Send both — the strap answers whichever its firmware
            // accepts, and the `clockRef == nil` correlation guard makes a second reply a no-op.
            // Without the [0x00] form, correlation never establishes on 41.17.x, so a lost RTC (the
            // 1971 clock behind #120) stays invisible and ClockPolicy can never re-fix it. Both
            // GET_CLOCKs ride behind both SET_CLOCKs above, so the reply reflects the corrected clock.
            // (Offload doesn't depend on this — Backfiller falls back to an identity clockRef — but a
            // real correlation drives realtime decode and the drift re-set.)
            send(.getClock, payload: [])
            send(.getClock, payload: [0x00])
        }
        send(.sendR10R11Realtime, payload: [0x00])   // stop the type-43 realtime flood (BLE airtime/battery)
        send(.getDataRange)                          // refresh the strap's stored range for the watchdog
        // Plain offload (no high-freq-sync), rate-limited (first connect always runs; reconnect-flaps are
        // throttled by BackfillPolicy). Deferred ~1.5s so SET_CLOCK/GET_DATA_RANGE round-trip first and
        // SEND_HISTORICAL runs on a settled link, like the paced Mac prototype. beginBackfill is itself
        // gated on connectHandshakeDone so a racing foreground/restore trigger can't fire it early.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.requestSync(.connect) }
        startBackfillTimer()   // re-offload the type-47 store every backfillIntervalSeconds
        startKeepAlive()       // always-ping: re-arm realtime, poll battery, watchdog the link
        enableLiveNotifications(reason: "post-bond")   // includes 0x2A37 standard HR — the fallback path
        if wantsRealtime {
            if standardHRFallback {
                // #80: this radio repeatedly dropped the link the instant we armed the R10/R11 burst.
                // Skip the heavy stream entirely; live HR rides the already-subscribed low-bandwidth
                // 0x2A37 standard profile (subscribed by enableLiveNotifications above). SAFE either way:
                // if 0x2A37 emits the user gets live HR on a radio that otherwise died; if it doesn't, at
                // least the arm→die loop stops.
                log("Realtime HR: standard-HR mode (low bandwidth) — skipping R10/R11 arm (#80)")
                state.standardHRMode = "Standard HR mode (low bandwidth) — your Bluetooth radio couldn't sustain the full stream; live heart rate via the standard profile."
            } else {
                log("Realtime HR: arming after bond")
                realtimeArmed = true   // keep reconcileRealtime()'s edge tracking in sync with the arm
                send(.sendR10R11Realtime, payload: [0x01])
                send(.toggleRealtimeHR, payload: [0x01])
                realtimeArmedAt = Date()   // start the arm→drop stopwatch for the marginal-radio detector
            }
        }
    }




    /// Newest plausible-unix marker in a GET_DATA_RANGE COMMAND_RESPONSE = the strap's newest stored
    /// record. Mirrors re/diagnose_biometrics.py: scan u32 LE words in the response body (data starts at
    /// frame[7], after [type,seq,cmd]), keep those in the unix range, return the max. nil if none.
    static func dataRangeNewestUnix(from frame: [UInt8]) -> Int? {
        guard frame.count > 7 else { return nil }
        let body = Array(frame[7...]); var newest: Int? = nil; var i = 0
        while i + 4 <= body.count {
            let w = Int(body[i]) | Int(body[i+1]) << 8 | Int(body[i+2]) << 16 | Int(body[i+3]) << 24
            if w >= 1_700_000_000 && w <= 1_900_000_000 { newest = max(newest ?? 0, w) }
            i += 4
        }
        return newest
    }

    /// The OLDEST plausible record timestamp in a GET_DATA_RANGE frame — the start of the strap's stored
    /// history. Same scan as `dataRangeNewestUnix` but keeps the minimum, so one connect can report the
    /// full banked SPAN (oldest…newest). For the recurring "last night didn't sync" reports (#364) that
    /// span is the backlog DEPTH at a glance: a strap that banked weeks of un-synced history has a wide
    /// span and simply needs time to drain oldest-first, vs. a narrow span that should clear quickly.
    static func dataRangeOldestUnix(from frame: [UInt8]) -> Int? {
        guard frame.count > 7 else { return nil }
        let body = Array(frame[7...]); var oldest: Int? = nil; var i = 0
        while i + 4 <= body.count {
            let w = Int(body[i]) | Int(body[i+1]) << 8 | Int(body[i+2]) << 16 | Int(body[i+3]) << 24
            if w >= 1_700_000_000 && w <= 1_900_000_000 { oldest = min(oldest ?? .max, w) }
            i += 4
        }
        return oldest
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error {
            log("Notify update failed for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        lastDataAt = Date()   // feed the liveness watchdog on every notification

        switch characteristic.uuid {
        case BLEManager.heartRateChar:
            parseStandardHR(bytes)
            // EXPERIMENTAL WHOOP 5.0/MG: there is no confirmed-write bond for a 5/MG strap, so once
            // live HR actually streams over the standard profile we treat the link as established —
            // otherwise the UI sits on "Connecting…" forever even though data is flowing (issue #8).
            if selectedModel.deviceFamily == .whoop5, !state.bonded {
                state.bonded = true
                log("WHOOP 5/MG: live HR streaming — marking the link established (experimental).")
            }
        case BLEManager.batteryChar:
            // 0x2A19 = percent — 5/MG ONLY. The WHOOP 4.0's 0x2A19 is a stub constant 100 (real value =
            // GET_BATTERY_LEVEL response, u16/10) and it's subscribed, so an unsolicited stub
            // notification was reverting the true reading back to 100% (#77).
            if selectedModel.deviceFamily != .whoop4, let pct = bytes.first {
                state.setBattery(Double(pct))
            }
        case BLEManager.dataNotifyChar,
             BLEManager.cmdNotifyChar,
             BLEManager.eventNotifyChar:
            // Reassemble (no-op for already-complete frames) then route each complete frame.
            for frame in reassemblers.feed(bytes, channel: characteristic.uuid.uuidString) {
                if backfilling, BLEManager.isOffloadFrame(frame, family: .whoop4) {
                    // Historical replay is bulk sync traffic, not live UI traffic. Feed it only to
                    // the Backfiller; parsing every record through FrameRouter updates SwiftUI for
                    // no user-visible benefit and can make the app feel hung during long offloads.
                    touchBackfillTimeout()
                    routeBackfillFrame(frame)
                    // …but a REAL-TIME physical gesture (double-tap / wrist) must still fire even mid-
                    // offload (#69). Gated on ts≈now so replayed historical EVENTs (old ts) are ignored.
                    // Only EVENT frames can carry a gesture: skip the full CRC + String-allocating parseFrame for every
                    // type-47 record (the bulk of an offload) on the main thread.
                    if BLEManager.isEventFrame(frame, family: .whoop4) {
                        router.dispatchLiveGestureIfFresh(frame: frame, now: strapClockNow)
                    }
                    continue
                }
                unmappedTap.note(frame, family: .whoop4)          // forensics: count types no handler persists
                router.handle(frame: frame)                       // live/UI path
                if frame.count > 6, frame[6] == WhoopCommand.getDataRange.rawValue {
                    // #451: the decoded "newest" can latch a stale/wrong-epoch field (claypilat saw 2024 when
                    // the real newest was 2026). To tell a genuinely-stale strap apart from a frame-alignment
                    // bug in dataRangeNewestUnix WITHOUT guessing, dump the raw GET_DATA_RANGE response bytes
                    // (logged unconditionally on a data-range reply, even if decode returns nil) so the field
                    // offsets are inspectable straight from a normal strap-log export. Short frame.
                    let hex = frame.map { String(format: "%02x", $0) }.joined()
                    log("Get Data Range raw frame (#451 — for offset analysis): \(hex)")
                    if let newest = BLEManager.dataRangeNewestUnix(from: frame) {
                        strapNewestTs = newest                    // feeds the liveness watchdog
                        // #547 SESSION-RELATIVE gate: publish the strap's banked-record window to the
                        // Backfiller so the historical ingest gate can reject a record dated months outside
                        // THIS strap's own [oldest, newest] (wandering-clock pollution that clears the
                        // absolute 2023-11 floor). The newest marker alone gives an upper bound; the oldest
                        // (set below when present) closes the lower bound. The gate ignores a half/malformed
                        // window, so setting newest before oldest is decoded is safe.
                        backfiller?.sessionNewestUnix = newest
                        // Observability for the "last night didn't sync" reports (#364): print the NEWEST
                        // record the strap actually holds. With the persisted-N line this lets one connect tell
                        // a banked-but-not-yet-reached backlog (newest == last night, cursor still grinding)
                        // apart from a genuinely un-banked night (newest is older) — no more guessing.
                        let d = ISO8601DateFormatter()
                        d.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
                        log("Strap newest banked record: \(d.string(from: Date(timeIntervalSince1970: TimeInterval(newest)))) (from data range)")
                        // Also surface the OLDEST banked record so one connect shows the full backlog SPAN — the
                        // depth a deep oldest-first drain has to cover before recent nights land (#364).
                        if let oldest = BLEManager.dataRangeOldestUnix(from: frame), oldest < newest {
                            backfiller?.sessionOldestUnix = oldest   // #547: closes the session-relative window
                            let spanDays = (newest - oldest) / 86_400
                            log("Strap banked history span: \(d.string(from: Date(timeIntervalSince1970: TimeInterval(oldest)))) → newest (~\(spanDays) day\(spanDays == 1 ? "" : "s") of backlog, drained oldest-first)")
                        }
                    }
                }
                // Clock correlation runs in both live and backfill modes. Once established it
                // unblocks both the Collector (live path) and the Backfiller (chunk decoding).
                if clockRef == nil {
                    let parsed = parseFrame(frame)
                    if let ref = ClockCorrelation.clockRef(from: parsed, wall: Int(Date().timeIntervalSince1970)) {
                        clockRef = ref
                        collector?.clockRef = ref                  // unblocks buffered persistence
                        backfiller?.clockRef = ref                 // unblocks historical chunk decode
                        log("Clock correlated: device=\(ref.device) wall=\(ref.wall)")
                        // Conditional SET_CLOCK (mirrors WHOOP): only when the strap RTC has drifted /
                        // is frozen — not blindly every connect. Offload doesn't depend on this (it uses
                        // clockRef for decoding); SET_CLOCK only keeps FUTURE logging timestamps sane.
                        if ClockPolicy.shouldSetClock(deviceClock: ref.device, wallNow: ref.wall) {
                            log("Clock drift detected — issuing SET_CLOCK")
                            sendSetClockBothForms()
                        }
                    }
                }
                if !backfilling {
                    // Live path (unchanged): synchronous ingest preserves delegate arrival order.
                    collector?.ingest(frame)
                }
            }
        default:
            // EXPERIMENTAL WHOOP 5.0/MG puffin notify chars (fd4b0003/0004/0005/0007): reassemble with
            // the family-aware reassembler and route through the family-aware FrameRouter so the UI
            // reflects arriving frames. The historical offload uses the WHOOP4 backfill machinery
            // (family-aware), and live puffin frames are now persisted too — see below. (Clock: the
            // Collector runs an identity ref for 5/MG via configureCollectorFamily, since live puffin
            // timestamps are already real-unix seconds.) Live HR/battery still also come from the
            // standard 0x2A37 / 0x2A19 profiles handled above.
            if BLEManager.whoop5NotifyChars.contains(characteristic.uuid) {
                for frame in reassemblers.feed(bytes, channel: characteristic.uuid.uuidString) {
                    let isOffload = backfilling && BLEManager.isOffloadFrame(frame, family: .whoop5)
                    noteWhoop5R22Telemetry(frame, duringOffload: isOffload)   // #174 deep-data telemetry
                    if isOffload {
                        // Same policy as WHOOP4: historical offload frames are bulk sync traffic.
                        // Keep them out of the live UI parser during backfill and let Backfiller
                        // preserve/order/process them in the sliced drain.
                        touchBackfillTimeout()
                        routeBackfillFrame(frame)
                        // A real-time double-tap / wrist gesture still fires during a 5/MG offload (which
                        // runs for minutes, #69); the ts≈now gate rejects replayed historical EVENTs.
                        if BLEManager.isEventFrame(frame, family: .whoop5) {
                            router.dispatchLiveGestureIfFresh(frame: frame, now: strapClockNow)
                        }
                        continue
                    }
                    unmappedTap.note(frame, family: .whoop5)   // forensics: 51…55 / unknown types are otherwise dropped
                    router.handle(frame: frame)
                    // NOTE: we deliberately do NOT ingest live 5/MG REALTIME_DATA into the Collector
                    // here. For a 5/MG the standard 0x2A37 Heart-Rate profile is already the RELIABLE,
                    // continuously-persisted live source (see didUpdateValueFor 0x2A37 → ingestStandardHR);
                    // decoding HR a second time off the puffin stream stored a duplicate row per heartbeat
                    // at a slightly different second (strap-unix vs Mac-receive), inflating the sample
                    // store. 0x2A37 stays the single authoritative live HR/RR source for 5/MG.
                    // Capture for protocol mapping (no-op unless the Settings toggle is on). PR #20.
                    puffinRecorder.capture(frame: frame, char: characteristic.uuid)
                }
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error = error {
            log("Notify enable failed for \(characteristic.uuid): \(error.localizedDescription)")
        } else {
            log("Notify \(characteristic.isNotifying ? "active" : "off") \(characteristic.uuid)")
        }
    }

    /// Parse a standard BLE Heart Rate Measurement (0x2A37) via the pure StandardHeartRate parser.
    private func parseStandardHR(_ data: [UInt8]) {
        guard let m = StandardHeartRate.parse(data) else {
            log("HR notify parse failed: \(hex(data))")
            return
        }
        let now = Date()
        if lastStandardHRLogAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
            lastStandardHRLogAt = now
            let plausibility = (30...220).contains(m.hr) ? "" : " ignored"
            log("HR notify: \(m.hr) bpm\(plausibility), rr=\(m.rr.count)")
        }
        // R-R: the standard profile is the RELIABLE source (the custom REALTIME_DATA stream
        // usually reports rr_count=0), so always surface intervals when present. setRRIntervals also
        // feeds the Live console's rolling rrRecent buffer.
        if !m.rr.isEmpty { state.setRRIntervals(m.rr) }
        // HR: the standard 0x2A37 profile is the RELIABLE source (BLE-standard, ~1Hz). Let it
        // drive the value whenever it's physiologically plausible; reject 0/garbage (off-wrist).
        // AppModel medians these into a stable display value. live perf: only publish on a real
        // change so a steady resting HR doesn't re-render the whole Live console every second.
        if m.hr >= 30 && m.hr <= 220, state.heartRate != m.hr { state.heartRate = m.hr }
        // Record it continuously — independent of the realtime stream or the open screen.
        collector?.ingestStandardHR(hr: m.hr, rr: m.rr, at: Int(Date().timeIntervalSince1970))
    }
}

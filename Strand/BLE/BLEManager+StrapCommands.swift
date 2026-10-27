import Foundation
import CoreBluetooth
import WhoopProtocol

// Strap writes: the single `send` gate, battery, clock, raw-accel capture, alarm and haptics commands.
extension BLEManager {
    /// Capture raw accelerometer (type-43 IMU) frames on demand for a bounded window, then stop.
    /// Persists raw even when the global research toggle is off (that's the point: on-demand, not
    /// 24/7). The Collector's window auto-expires at its deadline so a dropped stop can't leak raw.
    public func captureRawAccel(seconds: TimeInterval = 30) {
        guard !rawCaptureInFlight else {
            log("Raw-accel capture: already in flight — ignoring")
            return
        }
        rawCaptureInFlight = true
        let secs = RawCaptureWindow.clamp(seconds)
        collector?.beginRawCapture(seconds: secs)
        send(.startRawData, payload: [0x01])
        send(.toggleIMUMode, payload: [0x01])
        log("Raw-accel capture: started for \(secs)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
            guard let self else { return }
            // Only stop the raw stream if the 24/7 research toggle is OFF.  When it's ON, the
            // continuous stream must keep running — we just flush/upload the bounded window we
            // captured without halting the wider session.
            if !UserDefaults.standard.bool(forKey: "enableRawCapture") {
                self.send(.stopRawData, payload: [0x01])
            }
            self.rawCaptureInFlight = false
            Task { @MainActor in
                await self.collector?.endRawCapture()
            }
            self.log("Raw-accel capture: stopped + flushed")
        }
    }

    /// Send a command to the WHOOP strap.
    /// - Parameters:
    ///   - command: The command to send.
    ///   - payload: Command payload bytes (default `[0x00]`).
    ///   - writeType: BLE write type; defaults to `.withoutResponse` so all existing call
    ///     sites are unaffected. Pass `.withResponse` for acked commands (e.g. historicalDataResult).
    public func send(_ command: WhoopCommand, payload: [UInt8] = [0x00],
                     writeType: CBCharacteristicWriteType = .withoutResponse) {
        // #314 parity: CoreBluetooth already covers both Android defects here — this `p.state == .connected`
        // guard makes a write a no-op once the radio powers off (no DeadObjectException to crash on), and
        // centralManagerDidUpdateState publishes state.connected = false on .poweredOff, so the iOS/macOS UI
        // can't show a stale-connected link. The Android fix re-creates both behaviours; no Swift change needed.
        guard state.connected, let p = peripheral, p.state == .connected, let ch = cmdCharacteristic else {
            let reason = state.connected ? "command characteristic unavailable" : "not connected"
            log("send(\(command.label)) ignored — \(reason)")
            return
        }
        // WHOOP 5.0/MG uses puffin (CRC16) command framing, not the WHOOP4 frame; which commands may reach
        // it, and with which body, is decided by the unit-tested StrapCommandPolicy. WHOOP 4.0 is unaffected.
        switch StrapCommandPolicy.write(for: command, payload: payload, family: selectedModel.deviceFamily,
                                        experiments: .current) {
        case .denied(let reason):
            log("send(\(command.label)) skipped — \(reason)")
        case .whoop4(let body):
            p.writeValue(Data(command.frame(seq: nextCommandSeq(), payload: body)), for: ch, type: writeType)
            log("→ \(command.label) payload=\(hex(body))")
        case .puffin(let opcode, let body):
            p.writeValue(Data(puffinCommandFrame(cmd: opcode, seq: nextCommandSeq(), payload: body)),
                         for: ch, type: writeType)
            if command == .historicalDataResult {
                historicalAckLogCounter += 1
                if historicalAckLogCounter == 1 || historicalAckLogCounter.isMultiple(of: 25) {
                    log("→ \(command.label) ack #\(historicalAckLogCounter) payload=\(hex(body)) (puffin)")
                }
                return
            }
            let cmdNote = opcode == command.rawValue ? "" : String(format: " cmd=0x%02X", opcode)
            log("→ \(command.label) payload=\(hex(body)) (puffin\(cmdNote))")
        }
    }

    /// Refresh the battery reading on demand. Source is FAMILY-SPECIFIC (#77): on a WHOOP 4.0 the
    /// standard 0x2A19 characteristic is a STUB that reports a constant 100 — the real charge only
    /// comes from the proprietary GET_BATTERY_LEVEL command (COMMAND_RESPONSE, u16/10). Reading both
    /// flashed 100% before the true value corrected it (and a stub notification could revert a real
    /// 94% back to 100%). So WHOOP 4 uses ONLY the command; WHOOP 5/MG uses ONLY 0x2A19.
    public func refreshBattery() {
        guard state.connected, let p = peripheral, p.state == .connected else {
            log("refreshBattery ignored — not connected")
            return
        }

        if selectedModel.deviceFamily == .whoop4 {
            send(.getBatteryLevel, payload: [0x00])
            return
        }

        if let batteryCharacteristic {
            if batteryCharacteristic.properties.contains(.read) {
                p.readValue(for: batteryCharacteristic)
                log("Reading standard Battery Level")
            } else {
                log("Battery Level read unavailable; waiting for notifications")
            }
        } else {
            log("Battery Level characteristic unavailable")
        }
    }

    /// Arm the strap's firmware alarm for `date` (UTC).
    ///
    /// WHOOP 4.0 sequence: SET_CLOCK first to ensure the strap RTC is UTC-correct, then the
    /// rev-1 SET_ALARM_TIME. WHOOP 5/MG sends the REVISION_4 body alone — the strap maintains
    /// its RTC (set during the connect handshake / history sync) and the official app's alarm
    /// path doesn't re-set it (wire observation; mirrors Android WhoopBleClient.armStrapAlarm).
    /// Either way the strap will buzz at `date` even if the app is backgrounded or force-quit
    /// (event STRAP_DRIVEN_ALARM_EXECUTED=57). This is the only alarm path: the strap fires at
    /// the fixed time — NOOP has no light-sleep early-wake layer.
    ///
    /// UNCONFIRMED on 5/MG: the byte-identical Android rev-4 frame has been ACKed by a real 5/MG when
    /// arming, but a strap-driven wake fire has NOT been captured on our side (no
    /// STRAP_DRIVEN_ALARM_EXECUTED event observed yet). It is therefore armed whenever the alarm is
    /// enabled (no Experimental gate) and AppModel runs a Mac-driven haptic fallback for the same
    /// instant (see `WakeAlarmPolicy`), so the wake does not depend on the firmware firing.
    func armStrapAlarm(at date: Date) {
        // Log the wake time in the user's LOCAL zone. `Date` prints in UTC by default, so an alarm
        // for (say) 07:00 in New York logged as "11:00:00 +0000" reads like a timezone bug — but it
        // isn't: SET_ALARM_TIME carries the absolute instant of the chosen local time, and the strap
        // fires at that instant regardless of how its UTC RTC is labelled.
        let localFmt = DateFormatter()
        localFmt.dateFormat = "EEE HH:mm zzz"
        guard WakeAlarmPolicy.mayArmFirmwareAlarm(family: selectedModel.deviceFamily) else {
            // Never SET_ALARM_TIME on a 5/MG: its rev-4 body carries overallLoop 7, which made a real
            // strap (fw 50.42.1.0) vibrate non-stop for ~20 min while ignoring every stop command.
            // Clear whatever alarm the strap may still hold instead.
            send(.disableAlarm, payload: AlarmPayload.disableRev2())
            log("Alarm: refused to arm the 5/MG firmware alarm for \(localFmt.string(from: date)) (overallLoop-7 vibration incident) — sent DISABLE_ALARM rev2 instead")
            return
        }
        // Clamp rather than trap: an out-of-range alarm date (pre-1970 / post-2106) must not crash.
        let epochSec = UInt32(clamping: Int64(date.timeIntervalSince1970))
        sendSetClockBothForms()
        send(.setAlarmTime, payload: WhoopCommand.setAlarmPayload(epochSec: epochSec))
        log("Alarm: armed for \(localFmt.string(from: date)) — your local wake time (sent as UTC epoch \(epochSec))")
    }

    /// Disarm the currently-armed firmware alarm.
    func disableStrapAlarm() {
        if selectedModel.deviceFamily == .whoop5 {
            // 5/MG DISABLE_ALARM is REVISION_2 [0x02, 0xFF]; the rev-1 [0x01] form below is WHOOP4.
            send(.disableAlarm, payload: AlarmPayload.disableRev2())
            log("Alarm: disarmed (5/MG rev2)")
            return
        }
        send(.disableAlarm, payload: [0x01])
        log("Alarm: disarmed")
    }

    /// Request the currently-armed alarm time from the strap (response arrives on cmd-notify char).
    /// Parsing the reply is optional/bonus — the raw bytes will appear in the BLE log.
    func getStrapAlarm() {
        send(.getAlarmTime, payload: [0x01])
        log("Alarm: requested current alarm time")
    }

    /// Stop any haptic pattern the strap is playing (STOP_HAPTICS 122, payload [0x00]) and disarm the
    /// firmware alarm. Best effort: a WHOOP 5.0 ignored both during a runaway buzz, so this is not a safety net.
    func stopStrapHaptics() {
        StrapHapticsStop.run(cancelling: hapticClockPulses, family: selectedModel.deviceFamily) {
            send($0, payload: $1)
        }
        log("Haptics: stop requested (stopHaptics + disableAlarm)")
    }

    /// Haptic Clock (#460): buzz the current wall-clock time out on the strap so the user can read it
    /// off their wrist without a screen. The pure, unit-tested `HapticClock` encoder turns now into an
    /// ordered pulse list (long = a "ten", short = a "unit", in HH-tens / HH-units / MM-tens / MM-units
    /// order); we then schedule each pulse on the cancellable `hapticClockPulses`, firing the EXISTING
    /// maverick notification buzz (`runHapticsPattern`, remapped to the cmd-0x13 notify body in `send`)
    /// at each pulse's start. Only the SCHEDULE is new — the buzz itself is the hardware-confirmed one.
    ///
    /// `is24h` controls 12- vs 24-hour reading; a Settings toggle should supply it (default 12h — see
    /// `concerns`). Public so a Settings button can trigger it. Long-press / double-tap strap input is
    /// hardware-dependent and not wired (no tap event is parsed yet — see `hardwareUnverifiable`).
    ///
    /// Each WHOOP notification buzz is a fixed-length motor pulse, so we can't vary the on-time per
    /// pulse from the app; instead we map a LONG pulse to two stacked buzzes and a SHORT pulse to one,
    /// which the wrist feels as "longer vs shorter". Pulse-feel timing can only be confirmed on a real
    /// strap motor — best-effort here (see `hardwareUnverifiable`).
    public func buzzTimeNow(is24h: Bool = false, at date: Date = Date()) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: date)
        let pulses = HapticClock.pulses(hour: comps.hour ?? 0, minute: comps.minute ?? 0, is24h: is24h)
        guard !pulses.isEmpty else {
            log("Haptic Clock: nothing to buzz (00:00 in 24h form).")
            return
        }
        log("Haptic Clock: buzzing \(pulses.count) pulses for the current time (\(is24h ? "24h" : "12h")).")
        // Walk the encoder's pulse list, converting each (durationMs,gapMs) into a scheduled buzz.
        // A long pulse is felt as a heavier buzz (2 stacked loops); a short pulse as a light one (1).
        hapticClockPulses.cancelAll()
        var offsetMs = 0
        for pulse in pulses {
            let loops = pulse.isLong ? 2 : 1
            hapticClockPulses.schedule(afterMs: offsetMs) { [weak self] in
                // patternId/loops payload — send() remaps this to the 5/MG maverick notify buzz; on a
                // WHOOP 4.0 it's the native runHapticsPattern. Same call the inactivity nudge uses.
                self?.send(.runHapticsPattern, payload: [2, UInt8(clamping: loops), 0, 0, 0])
            }
            offsetMs += pulse.durationMs + pulse.gapMs
        }
    }

    /// SET_CLOCK(10) payload — the 8-byte form `[seconds u32 LE][subseconds u32 LE]`, subseconds in
    /// 1/32768 s (0 is fine). The payload LENGTH is firmware-specific and LOAD-BEARING: newer WHOOP 4
    /// firmware latches this form, but fw 41.17.x ignores it outright — no COMMAND_RESPONSE, RTC
    /// unchanged — and latches only the legacy 9-byte form below. A strap that misses the set keeps an
    /// invalid RTC and stops banking sensor data to flash entirely, which surfaces as endless
    /// console-only syncs and no sleep/recovery (#120). Send WHOOP 4 through sendSetClockBothForms()
    /// so either firmware latches.
    static func setClockPayload(now: UInt32 = UInt32(Date().timeIntervalSince1970)) -> [UInt8] {
        [UInt8(now & 0xFF), UInt8((now >> 8) & 0xFF),
         UInt8((now >> 16) & 0xFF), UInt8((now >> 24) & 0xFF),
         0, 0, 0, 0]
    }

    /// SET_CLOCK(10) payload — the legacy 9-byte form `[seconds u32 LE][5 zero]` required by WHOOP 4
    /// fw 41.17.x, which ignores the 8-byte form. On a strap whose RTC was stuck in the past, days of
    /// 8-byte sends drew no response; the 9-byte form was ack'd (COMMAND_RESPONSE cmd 10), the clock
    /// latched and ticked, and the strap resumed banking history to flash (#120). On newer firmware
    /// this form is ack'd but NOT latched, so sending it after the 8-byte form is a no-op there — both
    /// forms carry the same seconds, so whichever one latches sets the same time.
    static func setClockPayloadLegacy(now: UInt32 = UInt32(Date().timeIntervalSince1970)) -> [UInt8] {
        [UInt8(now & 0xFF), UInt8((now >> 8) & 0xFF),
         UInt8((now >> 16) & 0xFF), UInt8((now >> 24) & 0xFF),
         0, 0, 0, 0, 0]
    }

    /// Send SET_CLOCK in every payload form the WHOOP 4 firmware family is known to accept (8-byte for
    /// newer firmware, 9-byte for 41.17.x — each a no-op on the other). Both carry the same `now`, so
    /// double-latching is harmless. WHOOP 5/MG keeps its single hardware-validated 8-byte send (its
    /// connect path calls setClockPayload() directly; the 9-byte form is unverified on that family), so
    /// the legacy form is gated to WHOOP 4. (#120)
    func sendSetClockBothForms() {
        let now = UInt32(Date().timeIntervalSince1970)
        send(.setClock, payload: BLEManager.setClockPayload(now: now))
        if selectedModel.deviceFamily == .whoop4 {
            send(.setClock, payload: BLEManager.setClockPayloadLegacy(now: now))
        }
    }
}

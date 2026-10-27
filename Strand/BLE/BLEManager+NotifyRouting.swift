import Foundation
import CoreBluetooth
import WhoopProtocol

// Inbound notification routing: per-family frame dispatch, GET_DATA_RANGE, clock correlation, standard HR.
extension BLEManager {
    /// One complete WHOOP 4 frame: offload frames go to the Backfiller, everything else to the live path.
    func routeWhoop4Frame(_ frame: [UInt8]) {
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
            return
        }
        unmappedTap.note(frame, family: .whoop4)          // forensics: count types no handler persists
        router.handle(frame: frame)                       // live/UI path
        noteDataRange(frame)
        correlateClockIfNeeded(frame)
        if !backfilling {
            // Live path (unchanged): synchronous ingest preserves delegate arrival order.
            collector?.ingest(frame)
        }
    }

    /// GET_DATA_RANGE reply: record the strap's banked window for the watchdog and the #547 ingest gate.
    private func noteDataRange(_ frame: [UInt8]) {
        guard frame.count > 6, frame[6] == WhoopCommand.getDataRange.rawValue else { return }
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

    /// Clock correlation runs in both live and backfill modes. Once established it
    /// unblocks both the Collector (live path) and the Backfiller (chunk decoding).
    private func correlateClockIfNeeded(_ frame: [UInt8]) {
        guard clockRef == nil else { return }
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

    /// One complete WHOOP 5/MG puffin frame from a notify characteristic.
    func routeWhoop5Frame(_ frame: [UInt8], from characteristic: CBCharacteristic) {
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
            return
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

    /// Parse a standard BLE Heart Rate Measurement (0x2A37) via the pure StandardHeartRate parser.
    func parseStandardHR(_ data: [UInt8]) {
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

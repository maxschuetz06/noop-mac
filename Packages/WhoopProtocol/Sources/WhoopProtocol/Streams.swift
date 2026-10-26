import Foundation

// MARK: - Decoded stream rows (the durable, compact local record)
// Phase E and WhoopStore depend on these EXACT shapes. ts is wall-clock unix seconds
// EXCEPT inside extractStreams' inputs; the structs themselves always carry wall-clock ts.

public struct HRSample: Equatable, Codable, Sendable {
    public let ts: Int          // wall-clock unix seconds
    public let bpm: Int
    public init(ts: Int, bpm: Int) { self.ts = ts; self.bpm = bpm }
}

public struct RRInterval: Equatable, Codable, Sendable {
    public let ts: Int          // wall-clock unix seconds
    public let rrMs: Int
    public init(ts: Int, rrMs: Int) { self.ts = ts; self.rrMs = rrMs }
}

public struct WhoopEvent: Equatable, Codable, Sendable {
    public let ts: Int          // real unix seconds (event RTC; never offset)
    public let kind: String
    public let payload: [String: ParsedValue]
    public init(ts: Int, kind: String, payload: [String: ParsedValue]) {
        self.ts = ts; self.kind = kind; self.payload = payload
    }
}

public struct BatterySample: Equatable, Codable, Sendable {
    public let ts: Int          // unix seconds — event RTC for BATTERY_LEVEL events, else wallClockRef
    public let soc: Double?
    public let mv: Int?
    public let charging: Bool?  // only the BATTERY_LEVEL event reports this; nil otherwise
    public init(ts: Int, soc: Double?, mv: Int?, charging: Bool? = nil) {
        self.ts = ts; self.soc = soc; self.mv = mv; self.charging = charging
    }
}

// MARK: - type-47 HISTORICAL_DATA biometric rows. JSON keys MUST match
// biometric_streams_golden.json exactly (see extract_historical_streams).

public struct SpO2Sample: Equatable, Codable, Sendable {
    public let ts: Int
    public let red: Int
    public let ir: Int
    public let unit: String     // "raw_adc"
    public init(ts: Int, red: Int, ir: Int, unit: String = "raw_adc") {
        self.ts = ts; self.red = red; self.ir = ir; self.unit = unit
    }
}

public struct SkinTempSample: Equatable, Codable, Sendable {
    public let ts: Int
    public let raw: Int
    public let unit: String     // "raw_adc"
    public init(ts: Int, raw: Int, unit: String = "raw_adc") {
        self.ts = ts; self.raw = raw; self.unit = unit
    }
}

public struct RespSample: Equatable, Codable, Sendable {
    public let ts: Int
    public let raw: Int
    public let unit: String     // "raw_adc"
    public init(ts: Int, raw: Int, unit: String = "raw_adc") {
        self.ts = ts; self.raw = raw; self.unit = unit
    }
}

public struct GravitySample: Equatable, Codable, Sendable {
    public let ts: Int
    public let x: Double
    public let y: Double
    public let z: Double
    public let unit: String     // "g"
    public init(ts: Int, x: Double, y: Double, z: Double, unit: String = "g") {
        self.ts = ts; self.x = x; self.y = y; self.z = z; self.unit = unit
    }
}

/// WHOOP 5/MG cumulative u16 step / motion counter (step_motion_counter@57). APPROXIMATE — the @57
/// step semantics are unverified against the official WHOOP app (#78). Mirrors Android StepSample.
///
/// `activityClass` is the per-record activity-class enum decoded from @63 (community finding #316):
/// 0=still, 1=walk, 2=run; nil when the byte was 0xFF/invalid or absent. A lightweight, no-cloud
/// activity readout that rides alongside the counter. Optional + defaulted so existing call sites and
/// the persisted store (which carries only ts/counter today) are unchanged.
public struct StepSample: Equatable, Codable, Sendable {
    public let ts: Int
    public let counter: Int
    public let activityClass: Int?
    public init(ts: Int, counter: Int, activityClass: Int? = nil) {
        self.ts = ts; self.counter = counter; self.activityClass = activityClass
    }
}

/// Per-second strap-reported wear/sleep state from a WHOOP 5/MG v18 history record (`@81`, one status
/// byte per record). Both fields are stored EXACTLY as `decodeWhoop5Historical` produces them — no
/// semantics are invented here:
///   • `onWrist`    = `byte & 3` (decoder field `onwrist`, note "on-wrist/validity flag (b0-1)"), raw 0…3.
///                    The decoder does not pin which value means worn vs. off-wrist; consumers must
///                    derive that empirically from data.
///   • `sleepState` = `(byte >> 4) & 3` (decoder field `sleep_state`, note "0 wake/1 still/2 asleep/3 up
///                    (band state; not deep/REM/light)") — the decoder's enum values, raw 0…3.
/// Persisted in `strapStateSample` (migration v20). Only v18 records produce it.
public struct StrapStateSample: Equatable, Codable, Sendable {
    public let ts: Int
    public let onWrist: Int
    public let sleepState: Int
    public init(ts: Int, onWrist: Int, sleepState: Int) {
        self.ts = ts; self.onWrist = onWrist; self.sleepState = sleepState
    }
}

public struct Streams: Equatable, Codable, Sendable {
    public var hr: [HRSample]
    public var rr: [RRInterval]
    public var spo2: [SpO2Sample]
    public var skinTemp: [SkinTempSample]
    public var resp: [RespSample]
    public var gravity: [GravitySample]
    public var steps: [StepSample]
    /// PPG-derived per-second HR from the WHOOP 5.0 v26 optical buffer (issue #156). Kept separate from
    /// `hr` (the measured stream) so consumers can COALESCE without conflating the two sources.
    public var ppgHr: [PpgHrSample]
    /// Strap-reported per-second wear/sleep state (v18 `@81`); persist-only, see `StrapStateSample`.
    /// Deliberately NOT part of `isEmpty` (that flag is the "chunk decoded no biometrics" diagnostic and
    /// must not change meaning) and not set via `init` — it is filled by `extractHistoricalStreams`.
    public var strapState: [StrapStateSample] = []
    public var events: [WhoopEvent]
    public var battery: [BatterySample]
    /// #547 diagnostic: how many historical records `extractHistoricalStreams` DROPPED this chunk for an
    /// implausible own-timestamp (a bad-clock strap: far-past / bogus-2027 / future-dated). NOT persisted
    /// and NOT round-tripped through Codable (excluded from `CodingKeys`) — it is a transient observability
    /// count the Backfiller surfaces to the strap log. Defaults to 0 so it never affects golden fixtures.
    public var droppedImplausible: Int = 0
    public init(hr: [HRSample] = [], rr: [RRInterval] = [],
                spo2: [SpO2Sample] = [], skinTemp: [SkinTempSample] = [],
                resp: [RespSample] = [], gravity: [GravitySample] = [],
                steps: [StepSample] = [], ppgHr: [PpgHrSample] = [],
                events: [WhoopEvent] = [], battery: [BatterySample] = []) {
        self.hr = hr; self.rr = rr
        self.spo2 = spo2; self.skinTemp = skinTemp; self.resp = resp; self.gravity = gravity
        self.steps = steps; self.ppgHr = ppgHr
        self.events = events; self.battery = battery
    }

    /// True when no decoded rows landed in any stream — used to flag a historical chunk whose frames
    /// all dropped (CRC fail / unmapped layout / out-of-range timestamp), the silent-data-loss
    /// diagnostic in `Backfiller.finishChunk` (#77).
    public var isEmpty: Bool {
        hr.isEmpty && rr.isEmpty && spo2.isEmpty && skinTemp.isEmpty && resp.isEmpty
            && gravity.isEmpty && steps.isEmpty && ppgHr.isEmpty && events.isEmpty && battery.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case hr, rr, spo2, skinTemp = "skin_temp", resp, gravity, steps
        case ppgHr = "ppg_hr"
        case strapState = "strap_state"
        case events, battery
    }

    // Custom decode so older fixtures (streams_golden.json / historical_golden.json) that
    // lack the new biometric keys still decode — missing arrays default to empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hr = try c.decodeIfPresent([HRSample].self, forKey: .hr) ?? []
        rr = try c.decodeIfPresent([RRInterval].self, forKey: .rr) ?? []
        spo2 = try c.decodeIfPresent([SpO2Sample].self, forKey: .spo2) ?? []
        skinTemp = try c.decodeIfPresent([SkinTempSample].self, forKey: .skinTemp) ?? []
        resp = try c.decodeIfPresent([RespSample].self, forKey: .resp) ?? []
        gravity = try c.decodeIfPresent([GravitySample].self, forKey: .gravity) ?? []
        steps = try c.decodeIfPresent([StepSample].self, forKey: .steps) ?? []
        ppgHr = try c.decodeIfPresent([PpgHrSample].self, forKey: .ppgHr) ?? []
        strapState = try c.decodeIfPresent([StrapStateSample].self, forKey: .strapState) ?? []
        events = try c.decodeIfPresent([WhoopEvent].self, forKey: .events) ?? []
        battery = try c.decodeIfPresent([BatterySample].self, forKey: .battery) ?? []
    }
}

extension Streams { public static let empty = Streams() }

/// Map a device-epoch timestamp to wall-clock unix seconds via a pure linear offset.
/// Assumes strap clock and wall clock tick at the same rate (no skew/drift). Port of _to_wall.
private func toWall(_ deviceTs: Int?, _ deviceClockRef: Int, _ wallClockRef: Int) -> Int? {
    guard let deviceTs = deviceTs else { return nil }
    return wallClockRef + (deviceTs - deviceClockRef)
}

/// Turn parsed frames into datastore rows. Port of interpreter.extract_streams.
///
/// HR/R-R are taken ONLY from REALTIME_DATA (type 40). REALTIME_RAW_DATA (type 43) also
/// carries an HR byte but streams alongside type-40 during raw collection, so routing both
/// would double-count HR for the same instants. CRC-failed and non-ok frames are skipped.
public func extractStreams(_ parsed: [ParsedFrame],
                           deviceClockRef: Int, wallClockRef: Int) -> Streams {
    var out = Streams()
    for r in parsed {
        if !r.ok || r.crcOK == false { continue }
        let p = r.parsed
        switch r.typeName {
        case "REALTIME_DATA":
            let ts = toWall(p["timestamp"]?.intValue, deviceClockRef, wallClockRef)
            if let ts = ts, let bpm = p["heart_rate"]?.intValue {
                out.hr.append(HRSample(ts: ts, bpm: bpm))
            }
            // Unlike Python, drop RR rows when timestamp is absent (a ts-less RR row is unstorable).
            if let ts = ts, let rrs = p["rr_intervals"]?.intArrayValue {
                for rr in rrs { out.rr.append(RRInterval(ts: ts, rrMs: rr)) }
            }
        case "EVENT":
            // EVENT timestamps are real RTC unix seconds — already wall-clock, NOT offset.
            guard let ts = p["event_timestamp"]?.intValue else { continue }
            let kind = p["event"]?.stringValue ?? ""
            // BATTERY_LEVEL events (every ~8 min) carry SoC/mV/charging + a real RTC ts →
            // the DENSE battery series (the post-hook decoded the fields).
            if kind.hasPrefix("BATTERY_LEVEL") { appendBattery(&out, ts: ts, p: p) }  // "BATTERY_LEVEL(3)"
            var payload = p
            payload.removeValue(forKey: "event")
            payload.removeValue(forKey: "event_timestamp")
            out.events.append(WhoopEvent(ts: ts, kind: kind, payload: payload))
        case "COMMAND_RESPONSE":
            // No device timestamp on COMMAND_RESPONSE → stamp battery at wallClockRef.
            appendBattery(&out, ts: wallClockRef, p: p)
        default:
            continue
        }
    }
    return out
}

/// Append a BatterySample from a parsed frame's battery_pct/battery_mV/battery_charging
/// fields (no-op when neither soc nor mv is present). charging is a real Bool only when the
/// frame reported it (BATTERY_LEVEL events); command responses leave it nil.
func appendBattery(_ out: inout Streams, ts: Int, p: [String: ParsedValue]) {
    let soc = p["battery_pct"]?.doubleValue
    let mv = p["battery_mV"]?.intValue
    guard soc != nil || mv != nil else { return }
    let charging = p["battery_charging"]?.intValue.map { $0 != 0 }
    out.battery.append(BatterySample(ts: ts, soc: soc, mv: mv, charging: charging))
}

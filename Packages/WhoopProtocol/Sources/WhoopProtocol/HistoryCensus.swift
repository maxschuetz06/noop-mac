import Foundation

// MARK: - History record census + diagnostic frame selection
//
// Forensics for the "the strap offloaded, but no sensor rows landed" class of night. A completed
// offload used to leave no trace of WHAT the strap actually handed over: layouts that decode to
// nothing were only archived when they were HR-/gravity-less type-47 frames, v26 PPG was skipped by
// design, and any packet type outside the offload set (e.g. 51…55 IMU / puffin events) went to the
// live UI parser and vanished. These pure helpers give the Backfiller / BLEManager:
//   • `HistoryCensus`        — per-label record counts (type / layout version / CRC state) for the log,
//   • `diagnosticHistoryFrames` — a BOUNDED sample of the frames that did NOT turn into sensor rows,
//                               to be stored raw for offline analysis,
//   • `UnmappedFrameTap`     — counts + samples of frames whose packet type no handler persists.
// Observation only: nothing here changes what is decoded, persisted or acked.

/// Label scheme shared by the census, the diagnostic sampler and the tap: `"<type>"` for every packet
/// type, `"47/v<version>"` for HISTORICAL_DATA (the layout version byte is what decides decodability),
/// `"short"` for a frame too short to carry a type byte.
public enum HistoryFrameLabel {
    /// Index of the packet-type byte: inner-record start, `frame[4]` on WHOOP 4.0, `frame[8]` on 5/MG.
    public static func typeIndex(_ family: DeviceFamily) -> Int { family == .whoop5 ? 8 : 4 }
    /// Index of the historical layout-version byte: `frame[5]` on WHOOP 4.0, `frame[9]` on 5/MG.
    public static func versionIndex(_ family: DeviceFamily) -> Int { family == .whoop5 ? 9 : 5 }

    /// Packet type byte of `frame`, or nil when the frame is too short.
    public static func packetType(_ frame: [UInt8], family: DeviceFamily) -> Int? {
        let i = typeIndex(family)
        return frame.count > i ? Int(frame[i]) : nil
    }

    public static func label(for frame: [UInt8], family: DeviceFamily) -> String {
        guard let t = packetType(frame, family: family) else { return "short" }
        let vi = versionIndex(family)
        if t == 47, frame.count > vi { return "47/v\(frame[vi])" }
        return "\(t)"
    }
}

/// Per-label record counts for one offload (a chunk, or accumulated over a session). A label carries a
/// `!crc` suffix when the frame failed its integrity check, so a layout that only ever arrives corrupt
/// is visible as such instead of looking like an absent layout.
public struct HistoryCensus: Equatable, Sendable {
    public private(set) var counts: [String: Int] = [:]
    public init() {}

    public var isEmpty: Bool { counts.isEmpty }
    /// All counted frames.
    public var total: Int { counts.values.reduce(0, +) }
    /// Type-47 sensor records (any layout version, any CRC state).
    public var type47Total: Int {
        counts.reduce(0) { $0 + ($1.key == "47" || $1.key.hasPrefix("47/") ? $1.value : 0) }
    }
    public func count(_ label: String) -> Int { counts[label] ?? 0 }

    public mutating func note(_ frame: [UInt8], family: DeviceFamily, crcOK: Bool?) {
        var label = HistoryFrameLabel.label(for: frame, family: family)
        if crcOK == false { label += "!crc" }
        counts[label, default: 0] += 1
    }

    public mutating func merge(_ other: HistoryCensus) {
        for (k, v) in other.counts { counts[k, default: 0] += v }
    }

    /// Deterministic one-line rendering, e.g. `47/v18×312, 47/v26×40, 48×4`. Sorted by label so two
    /// logs diff cleanly. "none" when empty.
    public var summary: String {
        guard !counts.isEmpty else { return "none" }
        return counts.keys.sorted { lhs, rhs in
            let (a, b) = (Self.sortKey(lhs), Self.sortKey(rhs))
            return a == b ? lhs < rhs : a.lexicographicallyPrecedes(b)
        }.map { "\($0)×\(counts[$0]!)" }.joined(separator: ", ")
    }

    /// (type, version) numeric key so "47/v18" sorts before "47/v26" and "48" after "47/…".
    private static func sortKey(_ label: String) -> [Int] {
        let core = label.replacingOccurrences(of: "!crc", with: "")
        let parts = core.split(separator: "/")
        let type = Int(parts.first ?? "") ?? Int.max
        let version = parts.count > 1 ? (Int(parts[1].dropFirst()) ?? Int.max) : -1
        return [type, version, label.hasSuffix("!crc") ? 1 : 0]
    }
}

/// Pick the frames of one history chunk that did NOT turn into sensor rows, for raw storage.
///
/// "Stored" means the frame parsed CRC-valid AND decoded a heart rate or a gravity vector (exactly the
/// signal `rejectedHistoricalRecords` and the unmapped-layout log use). Everything else that is not a
/// bookkeeping frame (EVENT 48 / METADATA 49 / CONSOLE 50 / puffin METADATA 56, which are either
/// decoded into events/cursors or debug text by design) is a candidate: v26 PPG, v20/v21 bulk optical,
/// unmapped layout versions, truncated/CRC-failed records, unknown packet types.
///
/// Bounded three ways so a bulk layout can't flood the DB: at most `perLabelCap` frames per label, at
/// most `maxFrames` frames and `maxBytes` bytes per chunk. Order is preserved (arrival order).
///
/// `frames` and `parsed` must be index-aligned (`parsed[i] == parseFrame(frames[i], family:)`).
public func diagnosticHistoryFrames(frames: [[UInt8]], parsed: [ParsedFrame], family: DeviceFamily,
                                    perLabelCap: Int = 2, maxFrames: Int = 32,
                                    maxBytes: Int = 48 * 1024) -> [[UInt8]] {
    precondition(frames.count == parsed.count, "frames/parsed must be index-aligned")
    var perLabel: [String: Int] = [:]
    var out: [[UInt8]] = []
    var bytes = 0
    for (frame, p) in zip(frames, parsed) {
        if out.count >= maxFrames { break }
        let type = HistoryFrameLabel.packetType(frame, family: family)
        if let t = type, [48, 49, 50, 56].contains(t) { continue }   // bookkeeping by design
        let crcBad = !p.ok || p.crcOK == false
        let decodedSensor = !crcBad
            && (p.parsed["heart_rate"]?.intValue != nil || p.parsed["gravity_x"]?.doubleValue != nil)
        if decodedSensor { continue }
        var label = HistoryFrameLabel.label(for: frame, family: family)
        if crcBad { label += "!crc" }
        if perLabel[label, default: 0] >= perLabelCap { continue }
        if bytes + frame.count > maxBytes { continue }
        perLabel[label, default: 0] += 1
        bytes += frame.count
        out.append(frame)
    }
    return out
}

/// Counts (and a few raw samples) of frames whose packet type NO handler persists: anything arriving on
/// the notify channels that is not a command echo/response (35–38), live data (40/43), or one of the
/// offload types the Backfiller owns (47/48/49/50/56). On a 5/MG that is exactly where the IMU /
/// puffin-event streams (51…55) land — they used to fall through to the live UI parser and disappear
/// without a trace. Value type; owned by BLEManager (main actor) and drained at backfill end.
public struct UnmappedFrameTap: Equatable, Sendable {
    /// Packet types that have a persisting (or deliberately ignoring) handler.
    public static let handledTypes: Set<Int> = [35, 36, 37, 38, 40, 43, 47, 48, 49, 50, 56]
    public static let samplesPerType = 2
    public static let maxSampleFrames = 16
    public static let maxSampleBytes = 32 * 1024

    /// Packet-type → count.
    public private(set) var counts: [Int: Int] = [:]
    public private(set) var samples: [[UInt8]] = []
    private var sampleBytes = 0
    private var samplesPerTypeTaken: [Int: Int] = [:]

    public init() {}

    public var isEmpty: Bool { counts.isEmpty }

    /// Count `frame` if its type is unhandled. Returns true when it was counted.
    @discardableResult
    public mutating func note(_ frame: [UInt8], family: DeviceFamily) -> Bool {
        guard let t = HistoryFrameLabel.packetType(frame, family: family),
              !Self.handledTypes.contains(t) else { return false }
        counts[t, default: 0] += 1
        if samples.count < Self.maxSampleFrames,
           samplesPerTypeTaken[t, default: 0] < Self.samplesPerType,
           sampleBytes + frame.count <= Self.maxSampleBytes {
            samplesPerTypeTaken[t, default: 0] += 1
            sampleBytes += frame.count
            samples.append(frame)
        }
        return true
    }

    /// `51×120, 52×4` (types ascending).
    public var summary: String {
        counts.keys.sorted().map { "\($0)×\(counts[$0]!)" }.joined(separator: ", ")
    }

    /// Hand back the accumulated counts/samples and reset.
    public mutating func drain() -> (counts: [Int: Int], samples: [[UInt8]], summary: String) {
        let out = (counts, samples, summary)
        self = UnmappedFrameTap()
        return out
    }
}

/// Per-characteristic frame reassembly. The 5/MG exposes four notify characteristics (fd4b0003/4/5/7)
/// and a WHOOP 4 three; a large record (a 2140-byte v20) is fragmented across many notifications, and
/// the strap may interleave a frame from ANOTHER characteristic between two fragments. One shared
/// `Reassembler` then splices the foreign bytes into the large frame (CRC failure → the record, or a
/// HISTORY_END that must be acked, is lost) and leaves the buffer misaligned. Keeping one reassembler
/// per channel makes that impossible; `reset` also drops any half frame left from a dropped link so it
/// can't swallow the head of the next connection's stream.
public final class ReassemblerBank {
    private var family: DeviceFamily
    private var byChannel: [String: Reassembler] = [:]

    public init(family: DeviceFamily = .whoop4) { self.family = family }

    public func feed(_ fragment: [UInt8], channel: String) -> [[UInt8]] {
        let r: Reassembler
        if let existing = byChannel[channel] { r = existing } else {
            r = Reassembler(family: family)
            byChannel[channel] = r
        }
        return r.feed(fragment)
    }

    /// Drop every partial buffer; optionally switch the frame-length convention (family change).
    public func reset(family: DeviceFamily? = nil) {
        if let family { self.family = family }
        byChannel.removeAll()
    }
}

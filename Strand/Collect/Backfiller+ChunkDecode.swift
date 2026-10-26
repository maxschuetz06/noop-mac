import Foundation
import WhoopProtocol
import WhoopStore

// Pure, off-main chunk decode: frame classification, record extraction and per-chunk tallies.
extension Backfiller {
    /// Classify one raw frame for the offload state machine. Almost every frame in a history sync is a
    /// type-47 data record, and a full `parseFrame` (CRC + dozens of String allocations) just to learn
    /// "not METADATA" used to dominate main-thread time. `quickHistoricalMetaCandidate` rejects those from
    /// one packet-type byte; only possible METADATA frames take the full parse, so the CRC integrity gate
    /// inside `classifyHistoricalMeta` still guards every START/END/COMPLETE exactly as before.
    nonisolated static func classify(_ frame: [UInt8], family: DeviceFamily) -> HistoricalMeta {
        guard quickHistoricalMetaCandidate(frame, family: family) else { return .other }
        return classifyHistoricalMeta(parseFrame(frame, family: family))
    }

    /// Everything `finishChunk` derives from a chunk's raw frames WITHOUT touching actor state: a pure
    /// function of (frames, family, clock refs, session range, extractor). `Sendable` value types only, so
    /// it can be computed on a background task and handed back to the main actor.
    struct DecodedChunk: Sendable {
        /// First `hist_version` seen in the chunk (drives the once-per-session layout log).
        var firstLayoutVersion: Int?
        /// Distinct hist_versions, in first-seen order, whose records decoded to no HR / gravity / PPG.
        /// The main actor filters these against its already-logged set (that set is actor state).
        var unmappedVersions: [Int]
        var streams: Streams
        var rejected: [[UInt8]]
        /// Per-label record counts of this chunk's data frames (type / layout version / CRC state).
        var census: HistoryCensus
        /// Bounded sample of the frames that did NOT become sensor rows (v26 PPG, v20/v21, unmapped
        /// layouts, CRC failures, unknown types) — stored raw for offline analysis. Never acked-against.
        var diagnostic: [[UInt8]]
    }

    /// Pure CPU decode of one chunk (parse → layout/unmapped scan → extract → reject classification).
    nonisolated static func decodeChunk(frames: [[UInt8]],
                                        family: DeviceFamily,
                                        deviceClock: Int, wallClock: Int,
                                        sessionOldestUnix: Int?, sessionNewestUnix: Int?,
                                        extract: Extractor) -> DecodedChunk {
        let parsed = frames.map { parseFrame($0, family: family) }
        let firstLayoutVersion = parsed.lazy.compactMap { $0.parsed["hist_version"]?.intValue }.first
        // "Decoded nothing" must cover every mapped layout's signature field: v18 emits heart_rate,
        // v25 emits gravity_x (no per-second HR — it's PPG-derived), v26 emits ppg_waveform (no HR
        // either) — checking heart_rate alone false-flagged v25/v26 as unmapped (#156, sudden-break).
        // v20/v21 raw bulk-sensor records (raw sample channels, no HR/gravity by design) are a decoded,
        // known layout too: they were wrongly reported as "doesn't decode yet / no motion data" even
        // though the v18 records of the same chunk carry HR, gravity, skin temp, steps and wear state.
        var unmapped: [Int] = []
        for p in parsed {
            guard let v = p.parsed["hist_version"]?.intValue,
                  p.parsed["heart_rate"] == nil,
                  p.parsed["gravity_x"] == nil,
                  p.parsed["ppg_waveform"] == nil,
                  !isRawSensorChannelRecord(p),
                  !unmapped.contains(v) else { continue }
            unmapped.append(v)
        }
        let streams = extract(parsed, deviceClock, wallClock, sessionOldestUnix, sessionNewestUnix)
        let rejected = rejectedHistoricalRecords(frames, family: family)
        var census = HistoryCensus()
        for (f, p) in zip(frames, parsed) { census.note(f, family: family, crcOK: p.ok ? p.crcOK : false) }
        let diagnostic = diagnosticHistoryFrames(frames: frames, parsed: parsed, family: family,
                                                 perLabelCap: Backfiller.diagnosticFramesPerLabel)
        return DecodedChunk(firstLayoutVersion: firstLayoutVersion, unmappedVersions: unmapped,
                            streams: streams, rejected: rejected, census: census, diagnostic: diagnostic)
    }

    /// The 8-byte `end_data` the high-freq-sync ack requires: metadata.data[10:18].
    /// metadata.data begins at frame[7] (after [type,seq,cmd]), so end_data = frame[17:25].
    /// trim cursor = the first u32 of end_data (data[10:14]). Returns nil if the frame is too
    /// short to contain the field (shouldn't happen for a real HISTORY_END, which is >=14 data
    /// bytes, but guards against a malformed frame).
    static func endData(from frame: [UInt8], family: DeviceFamily) -> [UInt8]? {
        // metadata.data begins at frame[7] (WHOOP4) / frame[11] (WHOOP5, the +4 puffin envelope); the
        // ack's end_data = data[10:18] → frame[17:25] (WHOOP4) or frame[21:29] (WHOOP5). The WHOOP5 slice
        // is verified on a real HISTORY_END (trim=112193 = frame[21..25]) in Whoop5HistoricalTests.
        let start = family == .whoop5 ? 21 : 17
        guard frame.count >= start + 8 else { return nil }
        return Array(frame[start..<(start + 8)])
    }

    /// Pure per-chunk persistence tally (#150). `rows` = biometric rows actually inserted (HR, R-R, SpO2,
    /// skin-temp, resp, gravity — battery/events are housekeeping, not biometric history). `motion` =
    /// gravity rows (the sleep-critical signal). `nights` = the distinct day-keys (ts / 86400) the chunk's
    /// records covered. Summed across a session by finishChunk to drive the success summary line.
    nonisolated static func chunkTally(
        counts: (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int),
        timestamps: [Int]
    ) -> (rows: Int, motion: Int, nights: Set<Int>) {
        let rows = counts.hr + counts.rr + counts.spo2 + counts.skinTemp + counts.resp + counts.gravity
        return (rows, counts.gravity, Set(timestamps.map { $0 / 86400 }))
    }

    /// Newest timestamp among the rows of `s` that only the historical offload produces (gravity, strap
    /// state, skin temp, steps, resp, SpO₂, PPG-derived HR) — i.e. NOT the HR/R-R the live stream also writes.
    nonisolated static func newestHistoryTs(of s: Streams) -> Int? {
        [s.gravity.map(\.ts).max(), s.strapState.map(\.ts).max(), s.skinTemp.map(\.ts).max(),
         s.steps.map(\.ts).max(), s.resp.map(\.ts).max(), s.spo2.map(\.ts).max(),
         s.ppgHr.map(\.ts).max()].compactMap { $0 }.max()
    }
}

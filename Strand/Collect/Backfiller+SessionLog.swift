import Foundation
import WhoopProtocol

// Strap-log lines that summarise an offload session.
extension Backfiller {
    /// Log line for a historical layout version NOOP has no field map for. The "no motion data, so sleep
    /// can't be computed" consequence is only true when nothing in the chunk supplied gravity — when other
    /// records of the same chunk (the v18 per-second records) did, those rows persist and sleep is unaffected.
    nonisolated static func unmappedLayoutLogLine(version: Int, chunkHasMotion: Bool) -> String {
        if chunkHasMotion {
            return "Historical records of layout v\(version) are not decoded by NOOP (raw bytes are sampled); this chunk's other records supplied HR and motion, so sleep is unaffected. Please report this (issue #30)."
        }
        return "Historical records use firmware layout v\(version), which NOOP doesn't decode yet — no motion data, so sleep can't be computed from the strap. Please report this (issue #30)."
    }

    /// The one-line session success summary (#150) — the success-side log that never existed. Returns nil
    /// when nothing persisted (so a console-only / caught-up session stays quiet and the existing
    /// empty-banking diagnostics speak instead).
    nonisolated static func sessionSummaryLine(rows: Int, motion: Int, nights: Int) -> String? {
        guard rows > 0 else { return nil }
        return "Backfill: session persisted \(rows) rows (\(motion) with motion) across \(nights) night(s)."
    }

    /// One-line session throughput summary: how long the session ran, how many chunks it committed, and how
    /// much of that time was our own chunk commit (decode + store write + archive + ack) vs waiting for the strap.
    nonisolated static func sessionTimingLine(chunks: Int, elapsed: TimeInterval,
                                              chunkWork: TimeInterval, maxChunkWork: TimeInterval) -> String {
        let perChunk = chunks > 0 ? elapsed / Double(chunks) : 0
        return String(format: "Backfill: session timing — %d chunk(s) in %.1f s (%.2f s/chunk); our commit work %.2f s total, slowest chunk %.2f s.",
                      chunks, elapsed, perChunk, chunkWork, maxChunkWork)
    }

    /// One log line describing what a finished offload actually contained. Always emitted (also for an
    /// empty session) — "0 type-47 records" is exactly the evidence a no-rows night needs.
    nonisolated static func sessionCensusLine(census: HistoryCensus, chunks: Int, diagnosticFrames: Int) -> String {
        let kept = diagnosticFrames > 0 ? " Kept \(diagnosticFrames) raw diagnostic frame(s) of non-decoded records." : ""
        guard !census.isEmpty else {
            return "Backfill: record census — no data records in \(chunks) chunk(s) (the strap handed over only bookkeeping, or nothing).\(kept)"
        }
        return "Backfill: record census — \(census.summary) in \(chunks) chunk(s); \(census.type47Total) type-47 sensor record(s).\(kept)"
    }
}

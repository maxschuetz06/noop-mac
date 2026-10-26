import Foundation
import GRDB

/// One persisted history-offload census (see `WhoopStore.recordHistoryCensus`).
public struct HistoryCensusRecord: Equatable, Sendable {
    /// Wall-clock unix seconds at which the backfill session ended.
    public let ts: Int
    /// Census label → record count, exactly as `HistoryCensus.counts` (`"47/v18"`, `"48"`, `"47/v18!crc"`…).
    public let counts: [String: Int]
    /// Number of HISTORY_END chunks the session finished.
    public let chunks: Int
    /// Number of raw diagnostic frames kept for non-decoded records.
    public let diagnosticFrames: Int
    public init(ts: Int, counts: [String: Int], chunks: Int, diagnosticFrames: Int) {
        self.ts = ts; self.counts = counts; self.chunks = chunks; self.diagnosticFrames = diagnosticFrames
    }
}

extension WhoopStore {
    /// `event.kind` of the per-session history census row. Every NOOP-internal row in `event` uses the
    /// `NOOP_` prefix; `events(...)` and the raw CSV export exclude that prefix, so these rows are never
    /// treated as strap events. They exist so the census is readable from the DB mirror.
    public static let historyCensusEventKind = "NOOP_HISTORY_CENSUS"

    /// Census rows older than this are deleted whenever a new one is written (one row per backfill
    /// session is tiny, but sessions are frequent and the census is only forensic evidence).
    public static let historyCensusRetentionSeconds = 30 * 24 * 3600

    private struct CensusPayload: Codable {
        let counts: [String: Int]
        let chunks: Int
        let diagnosticFrames: Int
    }

    /// Persist one census row for a finished backfill session: kind `NOOP_HISTORY_CENSUS`, `payloadJSON` =
    /// `{"chunks":N,"counts":{label:count},"diagnosticFrames":M}` (sorted keys). Written even for an empty
    /// session — "0 records" is the evidence a no-rows night needs. A second row with the identical
    /// `(deviceId, ts)` replaces the first. Census rows older than `historyCensusRetentionSeconds` (relative
    /// to `ts`) are pruned in the same transaction.
    public func recordHistoryCensus(deviceId: String, ts: Int, counts: [String: Int],
                                    chunks: Int, diagnosticFrames: Int) async throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = String(decoding: try enc.encode(
            CensusPayload(counts: counts, chunks: chunks, diagnosticFrames: diagnosticFrames)), as: UTF8.self)
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO event (deviceId, ts, kind, payloadJSON) VALUES (?, ?, ?, ?)
                ON CONFLICT(deviceId, ts, kind) DO UPDATE SET payloadJSON = excluded.payloadJSON
                """, arguments: [deviceId, ts, Self.historyCensusEventKind, json])
            try db.execute(sql: "DELETE FROM event WHERE deviceId = ? AND kind = ? AND ts < ?",
                           arguments: [deviceId, Self.historyCensusEventKind,
                                       ts - Self.historyCensusRetentionSeconds])
        }
    }

    /// Census rows with `ts` in `[from, to]`, oldest first. Rows with an unreadable payload are skipped.
    public func historyCensusRecords(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [HistoryCensusRecord] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, payloadJSON FROM event
                WHERE deviceId = ? AND kind = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, Self.historyCensusEventKind, from, to, limit])
                .compactMap { row -> HistoryCensusRecord? in
                    let json: String = row["payloadJSON"]
                    guard let p = try? JSONDecoder().decode(CensusPayload.self, from: Data(json.utf8)) else { return nil }
                    return HistoryCensusRecord(ts: row["ts"], counts: p.counts, chunks: p.chunks,
                                               diagnosticFrames: p.diagnosticFrames)
                }
        }
    }
}

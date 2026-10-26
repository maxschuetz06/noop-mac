import Foundation
import GRDB

// MARK: - v9 cache: generic long-format metric store
// The substrate for a metric explorer. Where MetricsCache / JournalWorkoutAppleCache use a
// WIDE column-per-metric layout (one table per source, typed nullable columns), this is the
// TALL/EAV counterpart: one row per (deviceId, day, key) with a single REAL `value`. Any scalar
// metric — whatever its origin — can be projected into this one table and read back uniformly by
// key, so the explorer can list/compare metrics without knowing each source's schema.
// Mirrors the established pattern exactly: Codable struct, idempotent ON CONFLICT upsert keyed by
// natural key, range-read accessors, all GRDB work via the actor's syncWrite/syncRead helpers.

/// One point in the long-format metric store. Natural key (deviceId, day, key).
public struct MetricPoint: Equatable, Codable, Sendable {
    public let day: String           // YYYY-MM-DD
    public let key: String           // metric identifier, e.g. "restingHr", "steps", "recovery"
    public let value: Double
    public init(day: String, key: String, value: Double) {
        self.day = day; self.key = key; self.value = value
    }
}

/// Per-(deviceId, key) availability summary of the long-format metric store: how many points exist and
/// the latest one. One row per series — lets a screen learn which metrics have data in a single query.
public struct MetricSeriesSummary: Equatable, Sendable {
    public let deviceId: String
    public let key: String
    public let count: Int
    public let latestDay: String     // YYYY-MM-DD
    public let latestValue: Double
    public init(deviceId: String, key: String, count: Int, latestDay: String, latestValue: Double) {
        self.deviceId = deviceId; self.key = key; self.count = count
        self.latestDay = latestDay; self.latestValue = latestValue
    }
}

extension WhoopStore {

    // MARK: - Upsert (idempotent by natural key; latest value wins on conflict)

    /// Upsert metric points. Natural key (deviceId, day, key). Returns rows changed.
    /// Idempotent: re-upserting the same (deviceId, day, key) updates `value` in place rather than
    /// creating a duplicate.
    @discardableResult
    public func upsertMetricSeries(_ rows: [MetricPoint], deviceId: String) async throws -> Int {
        try syncWrite { db in
            var n = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO metricSeries
                        (deviceId, day, key, value)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, day, key) DO UPDATE SET
                        value = excluded.value
                    """, arguments: [deviceId, r.day, r.key, r.value])
                n += db.changesCount
            }
            return n
        }
    }

    // MARK: - Reads

    /// Points for a single `key` on days in [from, to] (lexicographic YYYY-MM-DD compare),
    /// oldest day first. Served index-only by idx_metricSeries_device_key_day.
    public func metricSeries(deviceId: String, key: String, from: String, to: String) async throws -> [MetricPoint] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT day, key, value FROM metricSeries
                WHERE deviceId = ? AND key = ? AND day >= ? AND day <= ?
                ORDER BY day ASC
                """, arguments: [deviceId, key, from, to])
                .map { MetricPoint(day: $0["day"], key: $0["key"], value: $0["value"]) }
        }
    }

    /// Distinct metric keys present for a device, sorted ascending.
    public func metricKeys(deviceId: String) async throws -> [String] {
        try syncRead { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT key FROM metricSeries
                WHERE deviceId = ?
                ORDER BY key ASC
                """, arguments: [deviceId])
        }
    }

    /// Earliest and latest day for a given metric `key`, or nil if the key has no points.
    public func metricDays(deviceId: String, key: String) async throws -> (earliest: String, latest: String)? {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT MIN(day) AS earliest, MAX(day) AS latest FROM metricSeries
                WHERE deviceId = ? AND key = ?
                """, arguments: [deviceId, key]),
                let earliest: String = row["earliest"],
                let latest: String = row["latest"]
            else { return nil }
            return (earliest, latest)
        }
    }

    /// Count + latest point of EVERY (deviceId, key) series in one batched query (index-only grouping on
    /// idx_metricSeries_device_key_day, then a primary-key join for the latest value). Replaces N
    /// per-metric `metricSeries` reads when a screen only needs to know which series have data.
    public func metricSeriesSummaries() async throws -> [MetricSeriesSummary] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT m.deviceId AS deviceId, m.key AS key, c.n AS n, m.day AS day, m.value AS value
                FROM (SELECT deviceId, key, COUNT(*) AS n, MAX(day) AS d
                      FROM metricSeries GROUP BY deviceId, key) c
                JOIN metricSeries m
                  ON m.deviceId = c.deviceId AND m.key = c.key AND m.day = c.d
                """)
                .map { MetricSeriesSummary(deviceId: $0["deviceId"], key: $0["key"], count: $0["n"],
                                           latestDay: $0["day"], latestValue: $0["value"]) }
        }
    }
}

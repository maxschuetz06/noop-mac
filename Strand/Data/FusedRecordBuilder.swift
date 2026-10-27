import Foundation
import WhoopStore
import StrandAnalytics

/// v5 local multi-device fusion adapter: assembles today's per-source values per metric and runs
/// `FusionResolver` so the "Your Data, Fused" screen (FusedRecordView) can show the best-sourced number
/// + provenance + agreement. This does NOT touch the core resolvedSeries waterfall — it's an additive
/// read that reuses the rows the store already holds, exactly the seam the view's header documents.
@MainActor
enum FusedRecordBuilder {
    /// The metrics surfaced, in importance-first display order, with a label + accent.
    private static let specs: [(key: String, label: String, accent: String?)] = [
        ("rhr", "Resting HR", nil),
        ("hrv", "HRV", nil),
        ("sleep_total_min", "Sleep", nil),
        ("steps", "Steps", nil),
        ("skin_temp", "Skin temp", nil),
        ("spo2", "Blood oxygen", nil),
    ]

    /// Build today's fused record (best signal per metric across every source, with agreement). Reads each
    /// declared-fusable metric's latest per-source daily value, runs the pure `FusionResolver`, and maps
    /// the result into the view's `FusedRecord`. Honest single-source degradation falls out of the engine
    /// (a one-WHOOP user gets `.single` agreement and `contributingSourceCount == 1`).
    static func today(store: WhoopStore?, whoopDeviceId: String, appleDeviceId: String) async -> FusedRecord {
        let empty = FusedRecord(rows: [], dayOwner: nil, contributingSourceCount: 0)
        guard let store else { return empty }
        // Every source that could carry a value, mapped to its stored device id. (FusionSource.rawValue
        // IS the canonical source id, but the strap's real id is `deviceId`/`computed` — map explicitly.)
        let sources: [(FusionSource, String)] = [
            (.whoopImport, whoopDeviceId),
            (.noopComputed, whoopDeviceId + SourceID.computedSuffix),
            (.appleHealth, appleDeviceId),
            (.xiaomiBand, FusionSource.xiaomiBand.rawValue),
        ]

        let now = Date()
        let fromDay = Repository.dayString(now.addingTimeInterval(-3 * 86_400))
        let toDay = Repository.dayString(now.addingTimeInterval(86_400))

        // Read each source's daily rows once, then pick the freshest per metric for the latest day.
        var rowsBySource: [FusionSource: DailyMetric] = [:]
        for (src, id) in sources {
            let rows = (try? await store.dailyMetrics(deviceId: id, from: fromDay, to: toDay)) ?? []
            if let latest = rows.sorted(by: { $0.day < $1.day }).last { rowsBySource[src] = latest }
        }
        guard !rowsBySource.isEmpty else { return empty }
        return fuse(rowsBySource)
    }

    private static func fuse(_ rowsBySource: [FusionSource: DailyMetric]) -> FusedRecord {
        var fusedRows: [FusedRow] = []
        var contributingSources = Set<FusionSource>()
        for spec in specs {
            var inputs: [FusionInput] = []
            for (src, daily) in rowsBySource {
                if let v = column(key: spec.key, day: daily) {
                    inputs.append(FusionInput(source: src, value: v))
                    contributingSources.insert(src)
                }
            }
            guard let point = FusionResolver.resolve(metricKey: spec.key, inputs: inputs) else { continue }
            fusedRows.append(FusedRow(point: point, label: spec.label, accentHex: spec.accent))
        }

        // The day-owner = the highest-priority source that actually contributed (the scores' single owner).
        let owner = contributingSources.min(by: {
            MetricArbitrationPolicy.sourcePriority($0) < MetricArbitrationPolicy.sourcePriority($1)
        })
        return FusedRecord(rows: fusedRows, dayOwner: owner,
                           contributingSourceCount: contributingSources.count)
    }

    /// The DailyMetric column a fusion metric key maps to (mirrors Repository.dailyColumn for the keys
    /// the fused record surfaces). nil when the source row doesn't carry that metric.
    private static func column(key: String, day d: DailyMetric) -> Double? {
        switch key {
        case "rhr":             return d.restingHr.map(Double.init)
        case "hrv":             return d.avgHrv
        case "sleep_total_min": return d.totalSleepMin
        case "steps":           return d.steps.map(Double.init)
        case "skin_temp":       return d.skinTempDevC
        case "spo2":            return d.spo2Pct
        default:                return nil
        }
    }
}

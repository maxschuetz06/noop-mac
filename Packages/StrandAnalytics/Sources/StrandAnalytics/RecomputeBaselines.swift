import Foundation
import WhoopStore

/// The two baseline folds of a recompute run. HRV honours the manual "Recalibrate baseline" epoch;
/// resting HR / respiration / skin temp honour the Charge-wide recovery epoch, so Recalibrate restarts the
/// whole Charge build-up together. A 0 epoch is byte-identical to the plain fold.
enum RecomputeBaselines {
    /// Pass-1 baselines from the imported history only (outliers winsorized by `foldHistory`).
    static func importedOnly(_ history: [DailyMetric], request: RecomputeRequest) -> AnalyticsEngine.ProfileBaselines {
        let dayKeys = history.map { $0.day }
        let hrv = Baselines.foldHistory(history.map { $0.avgHrv }, dayKeys: dayKeys, cfg: Baselines.hrvCfg,
                                        baselineEpoch: request.hrvBaselineEpoch)
        let rhr = Baselines.foldHistory(history.map { $0.restingHr.map(Double.init) }, dayKeys: dayKeys,
                                        cfg: Baselines.restingHRCfg, baselineEpoch: request.recoveryBaselineEpoch)
        return AnalyticsEngine.ProfileBaselines(hrv: hrv, restingHR: rhr)
    }

    /// Pass-2 baselines seeded from the UNION of imported nightly history + the pass-1 values — THE
    /// BLE-only recovery fix: the computed nightly avgHrv/restingHr finally let a strap-only user cross
    /// `Baselines.minNightsSeed`. IMPORTED values win per day: a day imported with a nil value stays
    /// imported (`dict[day] == nil` is true only when the KEY is absent). Skin temp is on-device-only
    /// (imports carry the deviation, not the raw mean). Resp and skin temp are only used once `usable`:
    /// a CALIBRATING baseline would let one noisy night move recovery.
    static func seeded(history: [DailyMetric], nights: [ScoredNight],
                       request: RecomputeRequest) -> AnalyticsEngine.ProfileBaselines {
        var hrvByDay: [String: Double?] = [:]
        var rhrByDay: [String: Double?] = [:]
        var respByDay: [String: Double?] = [:]
        for d in history {
            hrvByDay[d.day] = d.avgHrv
            rhrByDay[d.day] = d.restingHr.map(Double.init)
            respByDay[d.day] = d.respRateBpm
        }
        var skinByDay: [String: Double?] = [:]
        for n in nights {
            if hrvByDay[n.daily.day] == nil { hrvByDay[n.daily.day] = n.daily.avgHrv }
            if rhrByDay[n.daily.day] == nil { rhrByDay[n.daily.day] = n.daily.restingHr.map(Double.init) }
            if respByDay[n.daily.day] == nil { respByDay[n.daily.day] = n.daily.respRateBpm }
            skinByDay[n.daily.day] = n.nightlySkin
        }
        let epoch = request.recoveryBaselineEpoch
        let resp = fold(respByDay, cfg: Baselines.respCfg, epoch: epoch)
        let skin = fold(skinByDay, cfg: Baselines.skinTempCfg, epoch: epoch)
        return AnalyticsEngine.ProfileBaselines(
            hrv: fold(hrvByDay, cfg: Baselines.hrvCfg, epoch: request.hrvBaselineEpoch),
            restingHR: fold(rhrByDay, cfg: Baselines.restingHRCfg, epoch: epoch),
            resp: resp.usable ? resp : nil,
            skinTemp: skin.usable ? skin : nil)
    }

    /// Fold per-day values in chronological ("yyyy-MM-dd" sorts by date) order.
    private static func fold(_ byDay: [String: Double?], cfg: MetricCfg, epoch: Double) -> BaselineState {
        let dayKeys = byDay.keys.sorted()
        return Baselines.foldHistory(dayKeys.map { byDay[$0] ?? nil }, dayKeys: dayKeys, cfg: cfg, baselineEpoch: epoch)
    }
}

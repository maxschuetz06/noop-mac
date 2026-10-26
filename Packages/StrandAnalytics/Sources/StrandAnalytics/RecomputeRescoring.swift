import Foundation
import WhoopStore

/// Pass-2 output: everything the persistence stage writes, in pass-1 night order (newest first).
struct RescoredNights {
    var days: [RecomputedDay] = []
    var dailies: [DailyMetric] = []
    var cachedSleep: [CachedSleepSession] = []
    var workoutRows: [WorkoutRow] = []
    /// Rest composite (0–100) per night, persisted as `sleep_performance` so the dashboard's Rest score
    /// reflects the composite, not raw efficiency.
    var restPoints: [MetricPoint] = []
    /// Absolute wear-gated nightly skin temperature (°C), persisted as `skin_temp_abs`; the DailyMetric
    /// only carries the deviation.
    var skinAbsPoints: [MetricPoint] = []
}

/// User-corrected sleep windows override the detected sleep when scoring a day's sleep aggregates, so
/// Rest + recovery honour the edit — not just the Sleep tab. Scope (#318): only the computed source; an
/// imported night's dashboard numbers come verbatim from the export.
struct SleepEditOverlay {
    let editsByStart: [Int: CachedSleepSession]
    let habitualMidsleepSec: Int?
    let offsetSec: Int

    /// Substitute each edited block (matched by its stable detected startTs) for its detected twin and
    /// recompute total sleep / efficiency / stage minutes, picking the SAME main night the Sleep tab shows
    /// (#525/#547). A hand-logged nap (an edit with no detected twin) folds in through the manual channel
    /// (#518/#508). Each block's onset is its EFFECTIVE (user-corrected) start. No edit touching the
    /// night → the detected daily unchanged.
    func apply(to daily: DailyMetric, detected: [CachedSleepSession]) -> DailyMetric {
        guard !editsByStart.isEmpty else { return daily }
        let detectedTuples = detected.map { (startTs: $0.startTs, stagesJSON: $0.stagesJSON) }
        let editedStages = editsByStart.mapValues { $0.stagesJSON }
        let detectedStarts = Set(detected.map { $0.startTs })
        let manualTuples = editsByStart
            .filter { !detectedStarts.contains($0.key) }
            .map { (startTs: $0.key, stagesJSON: $0.value.stagesJSON) }
        var onsetByStart: [Int: Int] = [:]
        for d in detected {
            onsetByStart[d.startTs] = editsByStart[d.startTs]?.effectiveStartTs ?? d.effectiveStartTs
        }
        for (start, edit) in editsByStart where !detectedStarts.contains(start) {
            onsetByStart[start] = edit.effectiveStartTs
        }
        guard let r = SleepStageTotals.dailyAggregateHonoringEdits(detected: detectedTuples,
                                                                   edited: editedStages,
                                                                   manual: manualTuples,
                                                                   onsetByStart: onsetByStart,
                                                                   offsetSec: offsetSec,
                                                                   habitualMidsleepSec: habitualMidsleepSec),
              r.editApplied else { return daily }
        let agg = r.sleep
        return daily.with(totalSleepMin: agg.totalSleepMin, efficiency: agg.efficiency,
                          deepMin: agg.deepMin, remMin: agg.remMin, lightMin: agg.lightMin)
    }
}

extension RecomputeContext {
    /// Pass 2: re-score ONLY recovery (and the skin-temp deviation) against the seeded baselines; every
    /// other field is final from pass 1. Recovery stays nil until the HRV baseline is usable — honest
    /// cold-start via RecoveryScorer's usable gate. Detected workouts overlapping a real one are skipped.
    func rescore(_ nights: [ScoredNight], baselines: AnalyticsEngine.ProfileBaselines, overlay: SleepEditOverlay,
                 provenance: DayProvenanceSets, realWorkouts: [WorkoutRow]) async -> RescoredNights {
        var out = RescoredNights()
        for night in nights {
            let daily = overlay.apply(to: night.daily, detected: night.cachedSleep)
            let recovery = Self.recovery(daily, baselines)
            let skinDev = Self.skinTempDeviation(night.nightlySkin, baselines.skinTemp)
            let source = provenance.classify(daily.day)
            out.days.append(RecomputedDay(day: daily.day, recovery: recovery, strain: night.strain,
                                          sleepMin: daily.totalSleepMin, hrv: daily.avgHrv,
                                          rhr: daily.restingHr, source: source))
            // Per-day scoring diagnostic (Sleep overhaul §2.5): day key, FINAL total-sleep minutes, matched
            // blocks and provenance. Counts + a rounded minute only — no HR/HRV/timestamps.
            let tsmLog = daily.totalSleepMin.map { String(Int($0.rounded())) } ?? "nil"
            await host.log("sleep day=\(daily.day) totalSleepMin=\(tsmLog) "
                           + "matched=\(night.cachedSleep.count) source=\(source.logToken)")
            out.dailies.append(daily.with(recovery: recovery, skinTempDevC: skinDev))
            if let rest = AnalyticsEngine.Rest.composite(daily: daily) {
                out.restPoints.append(MetricPoint(day: daily.day, key: "sleep_performance", value: rest))
            }
            if let skinAbs = OnDeviceNightlySeries.skinTempAbsPoint(day: daily.day,
                                                                    nightlySkinTempC: night.nightlySkin) {
                out.skinAbsPoints.append(skinAbs)
            }
            out.cachedSleep.append(contentsOf: night.cachedSleep)
            for s in night.workouts where !realWorkouts.contains(where: { s.start < $0.endTs && $0.startTs < s.end }) {
                out.workoutRows.append(detectedWorkoutRow(s))
            }
        }
        return out
    }

    /// sport = "detected"; energyKcal is the APPROXIMATE Keytel/BMR total.
    private func detectedWorkoutRow(_ s: ExerciseSession) -> WorkoutRow {
        WorkoutRow(startTs: s.start, endTs: s.end, sport: "detected", source: request.computedId,
                   durationS: s.durationS, energyKcal: s.caloriesKcal, avgHr: Int(s.avgHR), maxHr: s.peakHR,
                   strain: s.strain, distanceM: nil, zonesJSON: nil, notes: nil)
    }

    /// Recovery composite against a (re-seeded) baseline. Charge enrichment: the Rest COMPOSITE (÷100) is
    /// the sleep-quality term (raw efficiency as fallback) and the night's skin-temp deviation folds in.
    /// Mirrors Android IntelligenceEngine.recomputeRecovery. (#78)
    static func recovery(_ daily: DailyMetric, _ baselines: AnalyticsEngine.ProfileBaselines) -> Double? {
        guard let hrvVal = daily.avgHrv, let rhrVal = daily.restingHr, let hrvBase = baselines.hrv else { return nil }
        let restQuality = AnalyticsEngine.Rest.composite(daily: daily).map { $0 / 100.0 } ?? daily.efficiency
        return RecoveryScorer.recovery(hrv: hrvVal, rhr: Double(rhrVal), resp: daily.respRateBpm,
                                       hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
                                       respBaseline: baselines.resp, sleepPerf: restQuality,
                                       skinTempDev: daily.skinTempDevC)
    }

    /// Skin-temperature deviation (°C) against the seeded baseline, rounded to 2 dp. Nil without a
    /// wear-gated nightly mean or a usable baseline (honest cold-start). APPROXIMATE.
    static func skinTempDeviation(_ nightly: Double?, _ base: BaselineState?) -> Double? {
        guard let v = nightly, let b = base, b.usable else { return nil }
        return (Baselines.deviation(v, state: b).delta * 100.0).rounded() / 100.0
    }
}

private extension DailyMetric {
    /// Rebuild the immutable DailyMetric with a substituted recovery + skin-temp deviation. (#78)
    func with(recovery r: Double?, skinTempDevC sd: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: deepMin,
                    remMin: remMin, lightMin: lightMin, disturbances: disturbances, restingHr: restingHr,
                    avgHrv: avgHrv, recovery: r, strain: strain, exerciseCount: exerciseCount,
                    spo2Pct: spo2Pct, skinTempDevC: sd, respRateBpm: respRateBpm,
                    steps: steps, activeKcalEst: activeKcalEst)
    }

    /// Rebuild with substituted sleep-derived fields (a user-corrected wake window). (#318)
    func with(totalSleepMin tsm: Double?, efficiency eff: Double?,
              deepMin dm: Double?, remMin rm: Double?, lightMin lm: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: tsm, efficiency: eff, deepMin: dm, remMin: rm, lightMin: lm,
                    disturbances: disturbances, restingHr: restingHr, avgHrv: avgHrv, recovery: recovery,
                    strain: strain, exerciseCount: exerciseCount, spo2Pct: spo2Pct,
                    skinTempDevC: skinTempDevC, respRateBpm: respRateBpm, steps: steps,
                    activeKcalEst: activeKcalEst)
    }
}

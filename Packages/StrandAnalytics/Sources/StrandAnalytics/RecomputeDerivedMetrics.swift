import Foundation
import WhoopProtocol
import WhoopStore

/// Metrics derived from the freshly scored dailies: the weekly headlines and the WHOOP 4.0 steps estimate.
extension RecomputeContext {
    /// Fitness Age (Phase 2) and Vitality / Body Age (Phase 7) from the last 7 scored days, keyed to the
    /// week's Saturday so the number refines through the week and finalises on Saturday (idempotent).
    func persistWeeklyHeadlines(_ dailies: [DailyMetric]) async {
        let week = Array(dailies.sorted { $0.day < $1.day }.suffix(7))
        let saturday = RecomputePipeline.saturdayKey(onOrBefore: newestDay, timeZone: request.timeZone)
        let profile = request.profile
        if let fitness = WeeklyHeadlines.fitnessAge(week: week, profile: profile, saturday: saturday) {
            _ = try? await store.upsertMetricSeries(fitness, deviceId: request.computedId)
        }
        if let vitality = WeeklyHeadlines.vitality(week: week, profile: profile, saturday: saturday) {
            _ = try? await store.upsertMetricSeries(vitality, deviceId: request.computedId)
        }
    }

    /// Steps ESTIMATE (WHOOP 4.0 sends no step count over BLE): calibrate the strap's daily MOTION VOLUME
    /// against the phone's real step count on days both exist (a 60-day window, so enough overlap
    /// accumulates), then estimate the strap-only scored days. Inert until calibrated or a manual
    /// coefficient is set. Returns the calibration state to mirror into the profile (#589 progress when
    /// not yet calibrated).
    func estimateSteps(scoredDailies: [DailyMetric]) async -> StepsCalibrationUpdate? {
        let calDays = 60
        let calOldest = AnalyticsEngine.dayString(nowLocalMidnight - (calDays - 1) * 86_400, offsetSec: tzOffset)
        // #693: the phone count lives in `appleDaily.steps`, never in a dailyMetric `steps` row.
        let appleRows = (try? await store.appleDaily(deviceId: FusionSource.appleHealth.rawValue,
                                                     from: calOldest, to: newestDay)) ?? []
        var refStepsByDay: [String: Double] = [:]
        for r in appleRows { if let s = r.steps, s > 0 { refStepsByDay[r.day] = Double(s) } }
        let motionByDay = await dailyMotion(days: calDays)
        let calPoints = motionByDay.compactMap { (day, motion) -> StepsEstimateEngine.CalibrationPoint? in
            guard let s = refStepsByDay[day] else { return nil }
            return StepsEstimateEngine.CalibrationPoint(motion: motion, steps: s)
        }
        let manualOverride = request.profile.stepsManualOverride
        guard let cal = StepsEstimateEngine.calibrate(calPoints, manualOverride: manualOverride) else {
            guard case let .needsMoreDays(have, _) = StepsEstimateEngine.status(calPoints, manualOverride: manualOverride)
            else { return nil }
            return StepsCalibrationUpdate(coefficient: 0, sampleDays: have, confidence: 0, manual: false)
        }
        // Days the phone DID count keep their real value; only strap-only days get an estimate.
        var estPts: [MetricPoint] = []
        for dm in scoredDailies where refStepsByDay[dm.day] == nil {
            guard let motion = motionByDay[dm.day],
                  let est = StepsEstimateEngine.estimate(motion: motion, calibration: cal) else { continue }
            estPts.append(MetricPoint(day: dm.day, key: "steps_est", value: Double(est)))
        }
        if !estPts.isEmpty { _ = try? await store.upsertMetricSeries(estPts, deviceId: request.computedId) }
        return StepsCalibrationUpdate(coefficient: cal.coefficient, sampleDays: cal.sampleDays,
                                      confidence: cal.confidence, manual: cal.manual)
    }

    /// Per-LOCAL-day motion volume over `[localMidnight, +24h)` from the owner-resolved strap gravity.
    private func dailyMotion(days: Int) async -> [String: Double] {
        var motionByDay: [String: Double] = [:]
        for off in 0..<days {
            let dayMid = RecomputePipeline.midnightLocal(nowLocalMidnight - off * 86_400, offsetSec: tzOffset)
            let dayEnd = dayMid + 86_400 - 1
            let dayKey = AnalyticsEngine.dayString(dayMid, offsetSec: tzOffset)
            let owner = await owners.owner(day: dayKey, from: dayMid, to: dayEnd)
            let grav = (try? await store.gravitySamples(deviceId: owner, from: dayMid, to: dayEnd, limit: 200_000)) ?? []
            let m = StepsEstimateEngine.dayMotionIntensity(grav)
            if m > 0 { motionByDay[dayKey] = m }
        }
        return motionByDay
    }
}

/// The weekly headline models fed from a week of computed dailies. Engines: FitnessAgeEngine (Nes/HUNT;
/// the body term cancels so the headline needs no body metric) and VitalityEngine (mortality hazard, gated
/// on ≥3 inputs; VO₂max omitted — fitness is its own headline).
enum WeeklyHeadlines {
    static func fitnessAge(week: [DailyMetric], profile: RecomputeProfile, saturday: String) -> [MetricPoint]? {
        let user = profile.user
        let rhrs = week.compactMap { $0.restingHr }.map(Double.init)
        let activeStrains = week.compactMap { $0.strain }.filter { $0 >= 30 }
        let meanActiveStrain = activeStrains.isEmpty ? 0 : activeStrains.reduce(0, +) / Double(activeStrains.count)
        let waist: Double? = profile.waistCm > 0 ? profile.waistCm : nil
        let ready = FitnessAgeEngine.assessReadiness(
            hasAge: user.age > 0, hasSex: !user.sex.isEmpty,
            rhrDays: rhrs.count, activityDays: week.compactMap { $0.strain }.count,
            hasHeightWeight: user.heightCm > 0 && user.weightKg > 0, hasWaist: waist != nil)
        guard ready.canCompute,
              let res = FitnessAgeEngine.compute(
                age: user.age, sex: user.sex, restingHR: ComparisonEngine.median(rhrs),
                paIndex: FitnessAgeEngine.physicalActivityIndexFromStrain(
                    activeDaysPerWeek: activeStrains.count, meanActiveStrain: meanActiveStrain),
                waistCm: waist) else { return nil }
        var pts = [MetricPoint(day: saturday, key: "fitness_age", value: res.fitnessAge)]
        if let v = res.vo2max { pts.append(MetricPoint(day: saturday, key: "vo2max_est", value: v)) }
        return pts
    }

    static func vitality(week: [DailyMetric], profile: RecomputeProfile, saturday: String) -> [MetricPoint]? {
        let age = profile.user.age
        let rhrs = week.compactMap { $0.restingHr }.map(Double.init)
        let nights = week.compactMap { $0.totalSleepMin }.map { Double($0) / 60.0 }.filter { $0 > 0 }
        let hrvs = week.compactMap { $0.avgHrv }
        let steps = week.compactMap { $0.steps }.map(Double.init)
        let inputs = VitalityEngine.Inputs(
            chronoAge: age,
            restingHR: rhrs.isEmpty ? nil : ComparisonEngine.median(rhrs),
            sleepHours: nights.isEmpty ? nil : nights.reduce(0, +) / Double(nights.count),
            sleepConsistency: VitalityEngine.sleepConsistency(nightlyHours: nights),
            rmssd: hrvs.isEmpty ? nil : ComparisonEngine.median(hrvs),
            rmssdNorm: VitalityEngine.rmssdNorm(forAge: age),
            steps: steps.isEmpty ? nil : steps.reduce(0, +) / Double(steps.count))
        guard let res = VitalityEngine.compute(inputs) else { return nil }
        return [MetricPoint(day: saturday, key: "vitality", value: res.vitality),
                MetricPoint(day: saturday, key: "body_age", value: res.bodyAge)]
    }
}

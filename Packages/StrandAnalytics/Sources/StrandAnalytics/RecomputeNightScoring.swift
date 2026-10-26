import Foundation
import WhoopProtocol
import WhoopStore

/// One night's pass-1 result. Only this small summary is kept, NOT the raw streams: every field except
/// recovery is baseline-independent, so pass 2 only re-scores the cheap recovery composite and the
/// hr/rr/resp/gravity arrays go out of scope per night (memory stays bounded).
struct ScoredNight {
    let daily: DailyMetric
    let strain: Double?
    let cachedSleep: [CachedSleepSession]
    let workouts: [ExerciseSession]
    let nightlySkin: Double?
    let sessionMotion: [Int: [Double]]
}

/// The owner-resolved streams `analyzeDay` needs besides the night's HR.
private struct NightStreams {
    let rr: [RRInterval]
    let resp: [RespSample]
    let gravity: [GravitySample]
    let steps: [StepSample]
    let skin: [SkinTempSample]
    let wristOff: [(start: Int, end: Int)]
    let dayHr: [HRSample]
    let daySteps: [StepSample]
    let dayGravity: [GravitySample]
    let bandSleepState: [(ts: Int, state: Int)]
}

extension RecomputeContext {
    /// Pass 1: analyse each offloaded night (newest first) against `baselines`. For a BLE-only user the
    /// imported baseline isn't usable yet and recovery is nil here — but each night's avgHrv/restingHr are
    /// computed baseline-INDEPENDENTLY and seed the pass-2 baseline.
    func scoreNights(baselines: AnalyticsEngine.ProfileBaselines, habitualMidsleepSec: Int?) async -> [ScoredNight] {
        var nights: [ScoredNight] = []
        for offset in 0..<request.maxDays {
            let dayStart = nowLocalMidnight - offset * 86_400
            guard let night = await scoreNight(dayStart: dayStart, baselines: baselines,
                                               habitualMidsleepSec: habitualMidsleepSec) else { continue }
            nights.append(night)
            await Task.yield()
        }
        return nights
    }

    private func scoreNight(dayStart: Int, baselines: AnalyticsEngine.ProfileBaselines,
                            habitualMidsleepSec: Int?) async -> ScoredNight? {
        let day = AnalyticsEngine.dayString(dayStart, offsetSec: tzOffset)
        // Read a generous window around the night that ends on `day`; the stager finds the span. A PAST
        // day reads through to the next local midnight so a late wake isn't truncated (#500); TODAY keeps
        // the 18:00 cap (an in-progress nap shouldn't be read as a finished night).
        let from = dayStart - 30 * 3_600
        let to = (dayStart < nowLocalMidnight) ? dayStart + 86_400 : dayStart + 18 * 3_600
        // I2: read the streams of the single device that owns this day.
        let owner = await owners.owner(day: day, from: from, to: to)
        let hr = (try? await store.hrSamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
        guard hr.count >= 200 else { return nil }   // need real raw data, not a stray sample
        let s = await nightStreams(owner: owner, from: from, to: to, dayStart: dayStart)

        let profile = request.profile
        let maxHR = profile.hrMaxOverride > 0 ? Double(profile.hrMaxOverride) : nil
        let tzOffset = tzOffset
        let useV2 = request.useSleepStagerV2
        let res = await Task.detached(priority: .utility) {
            AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: s.rr, resp: s.resp, gravity: s.gravity,
                                       steps: s.steps, dayHr: s.dayHr, daySteps: s.daySteps,
                                       dayGravity: s.dayGravity, skinTemp: s.skin,
                                       profile: profile.user, baselines: baselines, maxHROverride: maxHR,
                                       tzOffsetSeconds: tzOffset, wristOff: s.wristOff,
                                       habitualMidsleepSec: habitualMidsleepSec,
                                       bandSleepState: s.bandSleepState, useSleepStagerV2: useV2)
        }.value
        await logRestingHrFloor(res, hr: hr)
        return ScoredNight(daily: res.daily, strain: res.strain, cachedSleep: res.cachedSleep,
                           workouts: res.workouts, nightlySkin: res.nightlySkinTempC,
                           sessionMotion: res.sessionMotionByStart)
    }

    private func nightStreams(owner: String, from: Int, to: Int, dayStart: Int) async -> NightStreams {
        let rr = (try? await store.rrIntervals(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
        let resp = (try? await store.respSamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
        let grav = (try? await store.gravitySamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
        let steps = (try? await store.stepSamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
        let skin = (try? await store.skinTempSamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
        // Wrist-wear events paired into off-wrist [start, end) intervals for the fractional off-wrist sleep
        // backstop (#500/#504); a span still open at the window end closes at `to`.
        let wristEvents = (try? await store.events(deviceId: owner, from: from, to: to, limit: 50_000)) ?? []
        // The exact LOCAL calendar day for the additive totals (steps + calories) and full-day workout
        // detection, so late-day hours and an evening workout count on their own day (#277). The store
        // range is inclusive, so end at -1 s. Same owner as the night window (I2).
        let dayMid = RecomputePipeline.midnightLocal(dayStart, offsetSec: tzOffset)
        let dayEnd = dayMid + 86_400 - 1
        let dayHr = (try? await store.hrSamples(deviceId: owner, from: dayMid, to: dayEnd, limit: 200_000)) ?? []
        let daySteps = (try? await store.stepSamples(deviceId: owner, from: dayMid, to: dayEnd, limit: 200_000)) ?? []
        let dayGrav = (try? await store.gravitySamples(deviceId: owner, from: dayMid, to: dayEnd, limit: 200_000)) ?? []
        let band = await RecomputePipeline.bandSleepStateSamples(store: store, computedId: request.computedId,
                                                                 from: from, to: to)
        return NightStreams(rr: rr, resp: resp, gravity: grav, steps: steps, skin: skin,
                            wristOff: AnalyticsEngine.offWristIntervals(events: wristEvents, windowEnd: to),
                            dayHr: dayHr, daySteps: daySteps, dayGravity: dayGrav, bandSleepState: band)
    }

    /// RHR floor-vs-mean diagnostic (#691): NOOP's resting HR is the WHOOP-style FLOOR, a "sleeping HR"
    /// app reports the night MEAN — logging both over the SAME matched in-bed span makes a "NOOP reads
    /// lower" report explainable. A night with no banked floor logs nothing. Logging only.
    private func logRestingHrFloor(_ res: AnalyticsEngine.DayResult, hr: [HRSample]) async {
        guard let floor = res.daily.restingHr else { return }
        let inBedBpms = hr.filter { s in
            res.cachedSleep.contains { s.ts >= $0.startTs && s.ts < $0.endTs }
        }.map { $0.bpm }
        await host.log(RecomputePipeline.rhrFloorMeanLogLine(day: res.daily.day, floor: floor, inBedBpms: inBedBpms))
    }
}

extension RecomputePipeline {
    /// The per-day RHR floor-vs-mean diagnostic line (#691). The mean always sits at-or-above the floor, so
    /// NOOP reading lower is BY DESIGN. `inBedBpms` is every HR sample inside a matched in-bed session;
    /// empty → nightMean is "nil". Counts/bpm only — no timestamps or PII. Byte-identical to the Android
    /// `rhrFloorMeanLogLine`.
    public static func rhrFloorMeanLogLine(day: String, floor: Int, inBedBpms: [Int]) -> String {
        let meanLog: String = inBedBpms.isEmpty ? "nil"
            : String(Int((Double(inBedBpms.reduce(0, +)) / Double(inBedBpms.count)).rounded()))
        return "rhr day=\(day) floor=\(floor) nightMean=\(meanLog) inBedSamples=\(inBedBpms.count) "
            + "(floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)"
    }
}

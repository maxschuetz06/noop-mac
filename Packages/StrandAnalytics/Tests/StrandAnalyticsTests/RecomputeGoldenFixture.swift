import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Deterministic 21-day dataset for the recompute golden test: a fixed "now", a fixed non-UTC time zone
/// and LCG-generated raw strap streams (sleep, daytime wear, workouts, skin temp, steps) plus the
/// imported rows that feed baselines, provenance, steps calibration, workout de-duplication and the
/// manual-workout rescore.
enum RecomputeGoldenFixture {
    static let deviceId = "my-whoop"
    static let computedId = "my-whoop-noop"
    static let appleHealthId = "apple-health"
    static let maxDays = 21
    /// 2024-03-20 15:00:00 UTC (16:00 in Berlin, CET — no DST change inside the 60-day steps window).
    static let now = 1_710_946_800
    static let timeZone = TimeZone(identifier: "Europe/Berlin")!
    /// Berlin local midnight of 2024-03-20 (UTC+1).
    static let todayMidnight = 1_710_889_200
    /// A 34-year-old male, 180 cm / 78 kg / 84 cm waist, no HR-max or steps override, no recalibration.
    static let request = RecomputeRequest(
        deviceId: deviceId, now: now, timeZone: timeZone, maxDays: maxDays,
        profile: RecomputeProfile(user: UserProfile(weightKg: 78, heightCm: 180, age: 34, sex: "male"),
                                  waistCm: 84, hrMaxOverride: 0, hrMax: 184, stepsManualOverride: nil))

    struct LCG {
        var s: UInt64
        mutating func next() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double((s >> 33) & 0xFFFFFF) / Double(0x1000000)
        }
        mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * next() }
    }

    static func dayKey(back: Int) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date(timeIntervalSince1970: TimeInterval(todayMidnight - back * 86_400 + 3_600)))
    }

    static func populate(_ store: WhoopStore) async throws {
        var rng = LCG(s: 0x6011_D3A7)
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")
        var stepCounter = 0
        for back in stride(from: maxDays, through: 0, by: -1) {
            let streams = dayStreams(back: back, rng: &rng, stepCounter: &stepCounter)
            try await store.insert(streams, deviceId: deviceId)
        }
        try await store.upsertDailyMetrics(importedDailies(rng: &rng), deviceId: deviceId)
        try await store.upsertDailyMetrics([appleHealthDaily()], deviceId: appleHealthId)
        try await store.upsertAppleDaily(appleSteps(rng: &rng), deviceId: appleHealthId)
        try await store.upsertWorkouts(importedWorkouts(), deviceId: deviceId)
    }

    /// One local day: the night ending on it (≈22:30 → 06:30), daytime wear until the next onset, and an
    /// afternoon workout every third day. Night samples every 10 s, workout every 4 s, other daytime wear every 15 s.
    private static func dayStreams(back: Int, rng: inout LCG, stepCounter: inout Int) -> Streams {
        let midnight = todayMidnight - back * 86_400
        let onset = midnight - 90 * 60 + Int(rng.range(-1_200, 1_200))
        let wake = midnight + 390 * 60 + Int(rng.range(-1_200, 1_200))
        let baseHr = rng.range(48, 56)
        let rmssd = rng.range(18, 48)
        let skinRaw = Int(rng.range(3_320, 3_380))
        var s = Streams()
        var phase = 1.0
        for t in stride(from: onset, to: wake, by: 10) {
            let bpm = Int((baseHr + rng.range(0, 3) + 3 * sin(Double(t - onset) / 2_700)).rounded())
            s.hr.append(HRSample(ts: t, bpm: bpm))
            let rolled = (t - onset) % 5_400 < 40
            s.gravity.append(GravitySample(ts: t, x: rolled ? 0.6 : rng.range(-0.002, 0.002),
                                           y: rng.range(-0.002, 0.002), z: rolled ? 0.8 : 1))
            s.rr.append(RRInterval(ts: t, rrMs: Int((60_000 / Double(bpm) + phase * rmssd / 2).rounded())))
            phase = -phase
            if (t - onset) % 60 == 0 { s.skinTemp.append(SkinTempSample(ts: t, raw: skinRaw + Int(rng.range(-8, 8)))) }
        }
        let dayEnd = min(midnight + 22 * 3_600 + 1_800, now)
        var t = wake
        while t < dayEnd {
            let workout = back % 3 == 1 && t >= midnight + 17 * 3_600 && t < midnight + 17 * 3_600 + 3_000
            let bpm = workout ? Int(rng.range(138, 166)) : Int(rng.range(68, 96))
            s.hr.append(HRSample(ts: t, bpm: bpm))
            let swing = workout ? 0.9 : 0.04
            s.gravity.append(GravitySample(ts: t, x: rng.range(-swing, swing), y: rng.range(-swing, swing),
                                           z: workout ? rng.range(0.3, 1) : rng.range(0.97, 1)))
            stepCounter = (stepCounter + Int(rng.range(0, workout ? 40 : 14))) & 0xFFFF
            s.steps.append(StepSample(ts: t, counter: stepCounter))
            t += workout ? 4 : 15
        }
        return s
    }

    /// WHOOP-export history: 24 nights before the window (seed the baselines) plus one in-window day that
    /// wins the dashboard merge (whoopImport provenance).
    private static func importedDailies(rng: inout LCG) -> [DailyMetric] {
        (Array(22...45) + [6]).map { back in
            DailyMetric(day: dayKey(back: back), totalSleepMin: rng.range(380, 470), efficiency: rng.range(0.82, 0.95),
                        deepMin: rng.range(60, 90), remMin: rng.range(80, 110), lightMin: rng.range(200, 260),
                        disturbances: Int(rng.range(5, 20)), restingHr: Int(rng.range(49, 57)),
                        avgHrv: rng.range(22, 46), recovery: rng.range(30, 90), strain: rng.range(30, 70),
                        exerciseCount: 1, spo2Pct: rng.range(95, 98), skinTempDevC: rng.range(-0.3, 0.3),
                        respRateBpm: rng.range(13, 16))
        }
    }

    private static func appleHealthDaily() -> DailyMetric {
        DailyMetric(day: dayKey(back: 9), totalSleepMin: 420, efficiency: 0.9, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: 55, avgHrv: nil, recovery: nil, strain: nil,
                    exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)
    }

    /// Phone step counts on eight strap days, so the steps-estimate calibration fits a coefficient.
    private static func appleSteps(rng: inout LCG) -> [AppleDaily] {
        (1...8).map { back in
            AppleDaily(day: dayKey(back: back), steps: Int(rng.range(6_000, 11_000)), activeKcal: nil,
                       basalKcal: nil, vo2max: nil, avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: nil)
        }
    }

    /// An imported WHOOP workout overlapping the detected bout four days back (de-dup), and an
    /// under-scored manual workout over the bout seven days back (manual rescore).
    private static func importedWorkouts() -> [WorkoutRow] {
        func bout(back: Int) -> Int { todayMidnight - back * 86_400 + 17 * 3_600 }
        return [
            WorkoutRow(startTs: bout(back: 4), endTs: bout(back: 4) + 3_000, sport: "Running", source: "whoop",
                       durationS: 3_000, energyKcal: 520, avgHr: 150, maxHr: 166, strain: 60, distanceM: nil,
                       zonesJSON: nil, notes: nil),
            WorkoutRow(startTs: bout(back: 7), endTs: bout(back: 7) + 3_000, sport: "Cycling", source: "manual",
                       durationS: 3_000, energyKcal: 1, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                       zonesJSON: nil, notes: nil),
        ]
    }

    // MARK: - Fingerprint

    /// Everything the recompute persists, rendered losslessly (Double via its shortest round-trip form),
    /// one row per line, so two runs are byte-identical exactly when their outputs are.
    static func persistedFingerprint(_ store: WhoopStore) async throws -> [String] {
        var lines = try await store.dailyMetrics(deviceId: computedId, from: "0000-01-01", to: "9999-12-31")
            .sorted { $0.day < $1.day }.map(render)
        let keys = ["sleep_performance", "skin_temp_abs", "fitness_age", "vo2max_est", "vitality", "body_age",
                    "steps_est"]
        for key in keys {
            let pts = try await store.metricSeries(deviceId: computedId, key: key, from: "0000-01-01", to: "9999-12-31")
            lines += pts.sorted { $0.day < $1.day }.map { "series \(key) \($0.day) \(n($0.value))" }
        }
        let sleeps = try await store.sleepSessions(deviceId: computedId, from: 0, to: Int.max, limit: 10_000)
        lines += sleeps.sorted { $0.startTs < $1.startTs }.map { s in
            "sleep \(s.startTs)-\(s.endTs) eff=\(n(s.efficiency)) rhr=\(n(s.restingHr)) hrv=\(n(s.avgHrv)) "
                + "stages=\(fnv(s.stagesJSON ?? ""))"
        }
        for source in [computedId, deviceId] {
            let rows = try await store.workouts(deviceId: source, from: 0, to: Int.max, limit: 10_000)
            lines += rows.sorted { $0.startTs < $1.startTs }.map { w in
                "workout \(source) \(w.startTs)-\(w.endTs) \(w.sport) \(w.source) dur=\(n(w.durationS)) "
                    + "kcal=\(n(w.energyKcal)) hr=\(n(w.avgHr))/\(n(w.maxHr)) strain=\(n(w.strain))"
            }
        }
        return lines
    }

    static func render(_ d: DailyMetric) -> String {
        "daily \(d.day) tsm=\(n(d.totalSleepMin)) eff=\(n(d.efficiency)) deep=\(n(d.deepMin)) rem=\(n(d.remMin)) "
            + "light=\(n(d.lightMin)) dist=\(n(d.disturbances)) rhr=\(n(d.restingHr)) hrv=\(n(d.avgHrv)) "
            + "rec=\(n(d.recovery)) strain=\(n(d.strain)) ex=\(n(d.exerciseCount)) spo2=\(n(d.spo2Pct)) "
            + "skin=\(n(d.skinTempDevC)) resp=\(n(d.respRateBpm)) steps=\(n(d.steps)) kcal=\(n(d.activeKcalEst))"
    }

    static func n(_ v: Double?) -> String { v.map { "\($0)" } ?? "nil" }
    static func n(_ v: Int?) -> String { v.map { "\($0)" } ?? "nil" }

    private static func fnv(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

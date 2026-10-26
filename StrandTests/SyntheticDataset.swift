import Foundation
import WhoopStore
import WhoopProtocol
@testable import Strand

/// Deterministic generator: ~400 days of imported daily rows, 329 nights + 30 naps, 221 workouts, 753
/// journal rows over 6 questions, 33 metric-series keys, ~20 k HR samples + a few thousand RR intervals,
/// and a handful of on-device computed ("-noop") rows for the most recent days.
enum SyntheticDataset {
    struct LCG {
        var s: UInt64
        mutating func next() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double((s >> 33) & 0xFFFFFF) / Double(0x1000000)
        }
        mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * next() }
    }

    static let metricKeys = [
        "avg_hr", "awake_min", "energy_kcal", "hours_vs_needed_pct", "hr_zone1_min", "hr_zone2_min",
        "hr_zone3_min", "hr_zone4_min", "hr_zone5_min", "hr_zones13_min", "hr_zones45_min",
        "hr_zones_all_min", "hrv", "in_bed_min", "max_hr", "recovery", "resp_rate", "restorative_min",
        "restorative_pct", "rhr", "skin_temp", "sleep_consistency", "sleep_debt_min", "sleep_deep_min",
        "sleep_efficiency", "sleep_light_min", "sleep_need_min", "sleep_performance", "sleep_rem_min",
        "sleep_total_min", "spo2", "strain", "stress",
    ]
    static let journalQuestions = ["Alcohol?", "Fish oil?", "Caffeine?", "Creatine?", "Late meal?", "Reading in bed?"]
    static let sports = ["Activity", "Weightlifting", "Running", "Yoga", "Skiing"]

    @MainActor
    static func populate(_ store: WhoopStore, deviceId: String, days: Int = 400) async throws {
        var rng = LCG(s: 0x5EED_2026)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func dayStr(_ back: Int) -> String {
            Repository.dayString(cal.date(byAdding: .day, value: -back, to: today)!)
        }
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")

        var daily: [DailyMetric] = []
        var points: [MetricPoint] = []
        var sleeps: [CachedSleepSession] = []
        var workouts: [WorkoutRow] = []
        var journal: [JournalEntry] = []

        for back in stride(from: days, through: 1, by: -1) {
            let day = dayStr(back)
            let dayStart = cal.date(byAdding: .day, value: -back, to: today)!
            let total = rng.range(330, 520)
            let deep = total * rng.range(0.12, 0.22), rem = total * rng.range(0.18, 0.26)
            let light = total - deep - rem
            let rec = rng.range(8, 98), strain = rng.range(2, 19)
            daily.append(DailyMetric(day: day, totalSleepMin: total, efficiency: rng.range(80, 97),
                                     deepMin: deep, remMin: rem, lightMin: light, disturbances: Int(rng.range(5, 30)),
                                     restingHr: Int(rng.range(46, 62)), avgHrv: rng.range(35, 110),
                                     recovery: rec, strain: strain, exerciseCount: Int(rng.range(0, 3)),
                                     spo2Pct: rng.range(94, 99), skinTempDevC: rng.range(-1, 1),
                                     respRateBpm: rng.range(13, 17)))
            // ~285 of the 400 days carry the long-format series (like the real export).
            if back % 7 != 0 && back % 11 != 0 {
                for key in metricKeys {
                    points.append(MetricPoint(day: day, key: key, value: rng.range(1, 100)))
                }
            }
            // Night: ends on `day` ~07:00 local, started the previous evening.
            if back % 5 != 0 {
                let wake = Int(dayStart.timeIntervalSince1970) + 7 * 3600 + Int(rng.range(-1800, 1800))
                let start = wake - Int(total * 60 + rng.range(600, 3000))
                let stages = "{\"light\":\(Int(light)),\"deep\":\(Int(deep)),\"rem\":\(Int(rem)),\"awake\":\(Int(rng.range(10, 60)))}"
                sleeps.append(CachedSleepSession(startTs: start, endTs: wake, efficiency: rng.range(80, 97),
                                                 restingHr: Int(rng.range(46, 62)), avgHrv: rng.range(35, 110),
                                                 stagesJSON: stages))
            }
            if back % 13 == 0 {
                let s = Int(dayStart.timeIntervalSince1970) + 14 * 3600
                let stages = "{\"light\":20,\"deep\":3,\"rem\":0,\"awake\":2}"
                sleeps.append(CachedSleepSession(startTs: s, endTs: s + 1500, efficiency: 90, restingHr: nil,
                                                 avgHrv: nil, stagesJSON: stages, isNap: true))
            }
            if back % 2 == 0 || back % 9 == 0 {
                let s = Int(dayStart.timeIntervalSince1970) + 17 * 3600
                let dur = rng.range(1500, 5400)
                workouts.append(WorkoutRow(startTs: s, endTs: s + Int(dur), sport: sports[Int(rng.range(0, 5)) % 5],
                                           source: "whoop", durationS: dur, energyKcal: rng.range(150, 700),
                                           avgHr: Int(rng.range(110, 150)), maxHr: Int(rng.range(150, 185)),
                                           strain: rng.range(5, 18), distanceM: nil,
                                           zonesJSON: "{\"z1\":40,\"z2\":30,\"z3\":20,\"z4\":8,\"z5\":2}", notes: nil))
            }
            if back <= 140 {
                for (i, q) in journalQuestions.enumerated() where (back + i) % 6 != 5 {
                    journal.append(JournalEntry(day: day, question: q, answeredYes: rng.next() > 0.5, notes: nil))
                }
            }
        }
        // Trim to the real export's proportions (221 workouts).
        workouts = Array(workouts.prefix(221))

        try await store.upsertDailyMetrics(daily, deviceId: deviceId)
        try await store.upsertDailyMetrics(Array(daily.suffix(5)), deviceId: deviceId + "-noop")
        try await store.upsertSleepSessions(sleeps, deviceId: deviceId)
        try await store.upsertMetricSeries(points, deviceId: deviceId)
        try await store.upsertWorkouts(workouts, deviceId: deviceId)
        try await store.upsertJournal(journal, deviceId: deviceId)

        // ~20 k HR samples over the last ~6 days + RR intervals.
        let nowTs = Int(Date().timeIntervalSince1970)
        var hr: [HRSample] = [], rr: [RRInterval] = []
        for i in 0..<20_000 { hr.append(HRSample(ts: nowTs - 6 * 86_400 + i * 26, bpm: 50 + Int(rng.range(0, 60)))) }
        for i in 0..<5_000 { rr.append(RRInterval(ts: nowTs - 6 * 86_400 + i * 100, rrMs: Int(rng.range(600, 1100)))) }
        try await store.insert(Streams(hr: hr, rr: rr), deviceId: deviceId)
    }
}

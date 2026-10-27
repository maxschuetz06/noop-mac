import Foundation
import WhoopProtocol
import WhoopStore

/// Resolves the SINGLE device that owns a day (invariant I2), so the day is scored from exactly one source
/// — never a mix. The registry snapshot is read once per run: the paired-device list and the active id
/// are stable for the run.
///
/// Single-device install: the only paired row is the seeded active 'my-whoop' (== `fallbackId`). Its
/// candidate is priority 0 with data for any day the strap collected HR, so `owner` returns `fallbackId`
/// and the caller's reads are byte-identical to the pre-I2 code.
struct DayOwnerLookup {
    let store: WhoopStore
    let registry: DeviceRegistryStore
    let devices: [PairedDevice]
    let activeId: String
    let fallbackId: String

    init(store: WhoopStore, fallbackId: String) {
        self.store = store
        self.fallbackId = fallbackId
        registry = DeviceRegistryStore(dbQueue: store.registryQueue)
        devices = (try? registry.all()) ?? []
        activeId = (try? registry.activeDeviceId()) ?? fallbackId
    }

    /// A locked override wins outright. Otherwise one candidate per non-archived device with a priority
    /// (0 = the active strap, 1 = other live straps, 2 = imports; lower wins) and a CHEAP presence flag
    /// (one `LIMIT 1` HR read in `[from, to]`). Falls back to `fallbackId` when nothing resolves.
    func owner(day: String, from: Int, to: Int) async -> String {
        if let locked = (try? registry.dayOwner(day))?.deviceId {
            return locked
        }
        guard !devices.isEmpty else { return fallbackId }

        var candidates: [DayOwnerResolver.Candidate] = []
        for d in devices where d.status != .archived {
            let isImport = d.sourceKind == .cloudImport || d.sourceKind == .fileImport
            let priority = d.id == activeId ? 0 : (isImport ? 2 : 1)
            let hasData = !((try? await store.hrSamples(deviceId: d.id, from: from, to: to, limit: 1)) ?? []).isEmpty
            candidates.append(DayOwnerResolver.Candidate(deviceId: d.id, priority: priority, hasData: hasData))
        }
        return DayOwnerResolver.resolve(day: day, lockedOwner: nil, candidates: candidates) ?? fallbackId
    }
}

extension RecomputePipeline {
    /// The stored imported + computed sleep sessions a habitual-midsleep learn reads.
    public struct HabitualMidsleepSources: Sendable {
        public let importedId: String
        public let computedId: String
        public init(importedId: String, computedId: String) {
            self.importedId = importedId; self.computedId = computedId
        }
    }

    /// The user's habitual midsleep (local time-of-day seconds), or nil under `habitualMinDays` of history
    /// (cold-start). One `HistoryBlock` per stored session in `window` — start/end are the EFFECTIVE
    /// (edited) bounds so a corrected bedtime is learned, dayKey is the LOCAL day of the midpoint — and
    /// `SleepStageTotals.habitualMidsleepSec` keeps the longest block per day (naps drop out). (#547)
    public static func habitualMidsleep(store: WhoopStore, sources: HabitualMidsleepSources,
                                        window: ClosedRange<Int>, offsetSec: Int) async -> Int? {
        let imported = (try? await store.sleepSessions(deviceId: sources.importedId, from: window.lowerBound,
                                                       to: window.upperBound, limit: 4000)) ?? []
        let computed = (try? await store.sleepSessions(deviceId: sources.computedId, from: window.lowerBound,
                                                       to: window.upperBound, limit: 4000)) ?? []
        let blocks = (imported + computed).compactMap { s -> SleepStageTotals.HistoryBlock? in
            let start = s.effectiveStartTs, end = s.endTs
            guard end > start else { return nil }
            let mid = start + (end - start) / 2
            let dayKey = AnalyticsEngine.dayString(mid, offsetSec: offsetSec)
            return SleepStageTotals.HistoryBlock(start: start, end: end, dayKey: dayKey)
        }
        return SleepStageTotals.habitualMidsleepSec(blocks, offsetSec: offsetSec)
    }

    /// CONSUME (#531 / H8): the prior pass's persisted v18 BAND sleep_state for computed sessions
    /// overlapping `[from, to]`, expanded to `(ts, state)` samples on `SleepStager`'s 30 s epoch grid, for
    /// the H7 morning-stillness guard's re-onset confirmation. Empty when nothing is banded yet (first pass
    /// / imported night), so the guard falls back to the HR bar — never a fabricated reading.
    static func bandSleepStateSamples(store: WhoopStore, computedId: String,
                                      from: Int, to: Int) async -> [(ts: Int, state: Int)] {
        let epochS = 30
        let sessions = (try? await store.sleepSessions(deviceId: computedId, from: from, to: to,
                                                       limit: 4000)) ?? []
        var samples: [(ts: Int, state: Int)] = []
        for s in sessions {
            guard let states = try? await store.sessionSleepState(deviceId: computedId,
                                                                  sessionStart: s.startTs),
                  !states.isEmpty else { continue }
            for (i, st) in states.enumerated() {
                samples.append((ts: s.startTs + i * epochS, state: st))
            }
        }
        return samples
    }

    /// Floor a unix-seconds timestamp to 00:00:00 of its LOCAL calendar day (#277). `offsetSec` is seconds
    /// EAST of UTC: shift into local time, floor to the local day, shift back. The Euclidean modulo keeps
    /// the floor correct for negative offsets and timestamps (Swift's `%` takes the dividend's sign).
    /// Mirrors the Android IntelligenceEngine.midnightLocal byte-for-byte.
    public static func midnightLocal(_ ts: Int, offsetSec: Int) -> Int {
        let r = (ts + offsetSec) % 86_400
        return ts - (r < 0 ? r + 86_400 : r)
    }

    /// The Saturday on-or-before a "yyyy-MM-dd" local-day string — the weekly key Fitness Age and
    /// Vitality write to.
    static func saturdayKey(onOrBefore dayStr: String, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let fmt = DayKey.makeFormatter(timeZone: timeZone)
        guard let d = fmt.date(from: dayStr) else { return dayStr }
        let back = cal.component(.weekday, from: d) % 7   // Sat(7)→0, Sun(1)→1 … Fri(6)→6
        let sat = cal.date(byAdding: .day, value: -back, to: d) ?? d
        return fmt.string(from: sat)
    }
}

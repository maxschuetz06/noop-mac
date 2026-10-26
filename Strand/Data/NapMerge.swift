import Foundation
import WhoopStore

/// Where a displayed nap came from.
enum NapSource {
    /// A nap imported from a WHOOP export (`isNap`). Read-only on screen.
    case imported
    /// A nap the strap's own detector produced (a non-main block of the day). Editable.
    case detected
}

/// One row of the Sleep screen's Naps card after de-duplication.
struct NapEntry {
    let session: CachedSleepSession
    let source: NapSource
    /// True when an imported nap absorbed an overlapping detected nap, so the row stands for both.
    let mergedWithDetected: Bool

    var startTs: Int { session.effectiveStartTs }
    var endTs: Int { session.endTs }
}

/// Pure helpers for the Naps card. Display-only: nothing here feeds any nightly computation.
enum NapMerge {

    /// Two naps count as the same nap when they overlap by at least this fraction of the SHORTER one.
    static let overlapThreshold = 0.5

    /// Overlapping seconds of [aStart, aEnd) and [bStart, bEnd); 0 when disjoint or merely adjacent.
    static func overlapSeconds(_ aStart: Int, _ aEnd: Int, _ bStart: Int, _ bEnd: Int) -> Int {
        max(0, min(aEnd, bEnd) - max(aStart, bStart))
    }

    /// True when the two windows overlap by ≥ `overlapThreshold` of the shorter one. A zero-length
    /// (or inverted) window never matches, and touching windows (overlap 0) are separate naps.
    static func isSameNap(_ aStart: Int, _ aEnd: Int, _ bStart: Int, _ bEnd: Int) -> Bool {
        let shorter = min(aEnd - aStart, bEnd - bStart)
        guard shorter > 0 else { return false }
        let overlap = overlapSeconds(aStart, aEnd, bStart, bEnd)
        return Double(overlap) >= Double(shorter) * overlapThreshold
    }

    /// Merge a day's imported and detected naps into one list, oldest first. A detected nap that is the
    /// same nap as any imported one is dropped and the imported row is flagged `mergedWithDetected`
    /// (imported wins). Imported naps are never merged with each other, nor detected ones.
    static func merge(imported: [CachedSleepSession], detected: [CachedSleepSession]) -> [NapEntry] {
        var absorbed = Set<Int>()   // indices into `detected`
        var entries: [NapEntry] = []
        for imp in imported {
            var merged = false
            for (i, det) in detected.enumerated()
            where isSameNap(imp.effectiveStartTs, imp.endTs, det.effectiveStartTs, det.endTs) {
                absorbed.insert(i)
                merged = true
            }
            entries.append(NapEntry(session: imp, source: .imported, mergedWithDetected: merged))
        }
        for (i, det) in detected.enumerated() where !absorbed.contains(i) {
            entries.append(NapEntry(session: det, source: .detected, mergedWithDetected: false))
        }
        return entries.sorted {
            ($0.startTs, $0.endTs, $0.source == .imported ? 0 : 1)
                < ($1.startTs, $1.endTs, $1.source == .imported ? 0 : 1)
        }
    }

    /// The LOCAL calendar day (midnight) a nap starts on.
    static func startDay(of nap: CachedSleepSession, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(nap.effectiveStartTs)))
    }

    /// Naps whose start falls on the local calendar day `day`, oldest first.
    static func naps(startingOn day: Date, in naps: [CachedSleepSession],
                     calendar: Calendar = .current) -> [CachedSleepSession] {
        let target = calendar.startOfDay(for: day)
        return naps
            .filter { startDay(of: $0, calendar: calendar) == target }
            .sorted { $0.effectiveStartTs < $1.effectiveStartTs }
    }

    /// Days that have naps but no night, newest day first (at most `limit`), naps oldest first within a
    /// day. `nightDays` holds the local midnights of days that already show a night (and its Naps card).
    static func napOnlyDays(naps: [CachedSleepSession], nightDays: Set<Date>, limit: Int = 14,
                            calendar: Calendar = .current) -> [(day: Date, naps: [CachedSleepSession])] {
        let grouped = Dictionary(grouping: naps, by: { startDay(of: $0, calendar: calendar) })
        return grouped.keys
            .filter { !nightDays.contains($0) }
            .sorted(by: >)
            .prefix(limit)
            .map { day in
                (day: day, naps: (grouped[day] ?? []).sorted { $0.effectiveStartTs < $1.effectiveStartTs })
            }
    }
}

import XCTest
import Foundation
import WhoopStore
@testable import Strand

/// The Naps card de-duplicates imported WHOOP naps against strap-detected ones and keys naps by the
/// LOCAL calendar day of their start.
final class NapMergeTests: XCTestCase {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private let base = 1_785_000_000 - (1_785_000_000 % 86_400)   // a UTC midnight

    private func nap(_ startMin: Int, _ endMin: Int, dayOffset: Int = 0) -> CachedSleepSession {
        let day = base + dayOffset * 86_400
        return CachedSleepSession(startTs: day + startMin * 60, endTs: day + endMin * 60, efficiency: nil,
                                  restingHr: nil, avgHrv: nil, stagesJSON: nil)
    }

    // MARK: overlap rule

    func testIdenticalWindowsAreTheSameNap() {
        XCTAssertTrue(NapMerge.isSameNap(0, 3600, 0, 3600))
    }

    func testContainedShorterNapIsTheSameNapEvenWhenTheOuterIsMuchLonger() {
        // 30 min nap fully inside a 2 h block: overlap = 100 % of the shorter one.
        XCTAssertTrue(NapMerge.isSameNap(0, 7200, 1800, 3600))
    }

    func testExactlyHalfOfTheShorterIsTheThreshold() {
        // shorter = 60 min, overlap = 30 min → exactly 50 % → same nap.
        XCTAssertTrue(NapMerge.isSameNap(0, 3600, 1800, 5400))
    }

    func testJustUnderHalfIsNotTheSameNap() {
        XCTAssertFalse(NapMerge.isSameNap(0, 3600, 1801, 5401))
    }

    func testAdjacentNapsDoNotOverlap() {
        XCTAssertFalse(NapMerge.isSameNap(0, 3600, 3600, 7200))
    }

    func testDisjointAndZeroLengthNeverMatch() {
        XCTAssertFalse(NapMerge.isSameNap(0, 600, 7200, 7800))
        XCTAssertFalse(NapMerge.isSameNap(100, 100, 0, 3600))
    }

    // MARK: merge

    func testOverlappingDetectedNapIsDroppedAndImportedIsFlagged() {
        let merged = NapMerge.merge(imported: [nap(780, 840)], detected: [nap(785, 835)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].source, .imported)
        XCTAssertTrue(merged[0].mergedWithDetected)
        XCTAssertEqual(merged[0].startTs, nap(780, 840).startTs)
    }

    func testNonOverlappingNapsAreAllKeptOldestFirst() {
        let merged = NapMerge.merge(imported: [nap(900, 960)], detected: [nap(780, 840)])
        XCTAssertEqual(merged.map(\.source), [.detected, .imported])
        XCTAssertEqual(merged.map(\.mergedWithDetected), [false, false])
    }

    func testAdjacentImportedAndDetectedNapsStaySeparate() {
        let merged = NapMerge.merge(imported: [nap(840, 900)], detected: [nap(780, 840)])
        XCTAssertEqual(merged.count, 2)
    }

    func testDetectedOnlyAndImportedOnlyPassThrough() {
        XCTAssertEqual(NapMerge.merge(imported: [], detected: [nap(780, 840)]).map(\.source), [.detected])
        XCTAssertEqual(NapMerge.merge(imported: [nap(780, 840)], detected: []).map(\.source), [.imported])
        XCTAssertTrue(NapMerge.merge(imported: [], detected: []).isEmpty)
    }

    func testOneImportedNapAbsorbsEveryDetectedNapItMatches() {
        let merged = NapMerge.merge(imported: [nap(780, 900)], detected: [nap(780, 820), nap(830, 900)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].mergedWithDetected)
    }

    // MARK: day keying

    func testNapsAreKeyedByTheLocalDayOfTheirStart() {
        let lateEvening = nap(23 * 60 + 40, 24 * 60 + 20)      // starts 23:40, ends after midnight
        let nextMorning = nap(9 * 60, 9 * 60 + 30, dayOffset: 1)
        let day0 = Date(timeIntervalSince1970: TimeInterval(base))
        let day1 = Date(timeIntervalSince1970: TimeInterval(base + 86_400))
        XCTAssertEqual(NapMerge.naps(startingOn: day0, in: [nextMorning, lateEvening], calendar: utc).count, 1)
        XCTAssertEqual(NapMerge.naps(startingOn: day0, in: [nextMorning, lateEvening], calendar: utc)[0].startTs,
                       lateEvening.startTs)
        XCTAssertEqual(NapMerge.naps(startingOn: day1, in: [nextMorning, lateEvening], calendar: utc)[0].startTs,
                       nextMorning.startTs)
    }

    func testNapsOnDifferentDaysDoNotMergeThroughTheDayFilter() {
        let day0 = Date(timeIntervalSince1970: TimeInterval(base))
        let importedToday = NapMerge.naps(startingOn: day0, in: [nap(780, 840), nap(780, 840, dayOffset: 1)],
                                          calendar: utc)
        XCTAssertEqual(importedToday.count, 1)
        let merged = NapMerge.merge(imported: importedToday, detected: [nap(785, 835, dayOffset: 1)])
        XCTAssertEqual(merged.count, 2)
        XCTAssertFalse(merged[0].mergedWithDetected)
    }

    func testNapOnlyDaysSkipDaysThatHaveANightAndAreNewestFirst() {
        let d0 = utc.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(base)))
        let d1 = d0.addingTimeInterval(86_400), d2 = d1.addingTimeInterval(86_400)
        let naps = [nap(600, 650), nap(600, 650, dayOffset: 1), nap(700, 740, dayOffset: 1), nap(600, 650, dayOffset: 2)]
        let days = NapMerge.napOnlyDays(naps: naps, nightDays: [d1], calendar: utc)
        XCTAssertEqual(days.map(\.day), [d2, d0])
        XCTAssertEqual(days[1].naps.count, 1)
    }

    func testNapOnlyDaysRespectTheLimit() {
        let naps = (0..<20).map { nap(600, 650, dayOffset: $0) }
        XCTAssertEqual(NapMerge.napOnlyDays(naps: naps, nightDays: [], limit: 5, calendar: utc).count, 5)
    }
}

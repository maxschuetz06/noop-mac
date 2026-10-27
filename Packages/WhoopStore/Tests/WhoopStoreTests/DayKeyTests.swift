import XCTest
import WhoopStore

/// Day keys name stored rows, so they must not depend on the user's calendar, digits or a DST shift.
final class DayKeyTests: XCTestCase {
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    func testKeysAreGregorianInTheRequestedZone() {
        let instant = Date(timeIntervalSince1970: 1_792_969_200)   // 2026-10-25 23:00 UTC = 10-26 00:00 CET
        XCTAssertEqual(DayKey.string(from: instant, timeZone: DayKey.utc), "2026-10-25")
        XCTAssertEqual(DayKey.string(from: instant, timeZone: berlin), "2026-10-26")
        XCTAssertEqual(DayKey.string(from: instant, timeZone: TimeZone(secondsFromGMT: 0)), "2026-10-25")
    }

    func testParsingReturnsTheZonesMidnight() {
        XCTAssertEqual(DayKey.date(from: "2026-10-25", timeZone: DayKey.utc),
                       Date(timeIntervalSince1970: 1_792_886_400))
        XCTAssertEqual(DayKey.date(from: "2026-10-26", timeZone: berlin),
                       Date(timeIntervalSince1970: 1_792_969_200))
        XCTAssertNil(DayKey.date(from: "June 1st", timeZone: DayKey.utc))
        XCTAssertNil(DayKey.date(from: "2026-02-30", timeZone: DayKey.utc), "impossible days are rejected")
        XCTAssertNil(DayKey.makeFormatter().date(from: "2026-13-01"))
    }

    func testFormatterUsesGregorianPosixWhateverTheUsersLocale() {
        let f = DayKey.makeFormatter(timeZone: berlin)
        XCTAssertEqual(f.calendar.identifier, .gregorian)
        XCTAssertEqual(f.locale.identifier, "en_US_POSIX")
        XCTAssertEqual(f.string(from: Date(timeIntervalSince1970: 1_792_969_200)), "2026-10-26")
    }
}

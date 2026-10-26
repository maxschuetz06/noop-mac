import XCTest
@testable import Strand

/// `HomeFormat` replaced hard-coded de_DE formatters: German output must read exactly as before,
/// other locales get their own conventions.
final class HomeFormatTests: XCTestCase {
    private let german = HomeFormat(locale: Locale(identifier: "de_DE"))
    private let english = HomeFormat(locale: Locale(identifier: "en_US"))
    private let morning = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9, minute: 5))!

    func testGermanOutputMatchesThePreviousFormatters() {
        XCTAssertEqual(german.headerDate(morning), "Mo., 26. Okt. 2026")
        XCTAssertEqual(german.clock(morning), "09:05")
        XCTAssertEqual(german.decimal(7.46, digits: 1), "7,5")
        XCTAssertEqual(german.decimal(1234.56, digits: 1), "1234,6", "decimals are never grouped")
        XCTAssertEqual(german.grouped(10_000), "10.000")
    }

    func testEnglishFollowsItsOwnLocale() {
        XCTAssertEqual(english.headerDate(morning), "Mon, Oct 26, 2026")
        XCTAssertTrue(english.clock(morning).hasPrefix("9:05"), english.clock(morning))
        XCTAssertEqual(english.decimal(7.46, digits: 1), "7.5")
        XCTAssertEqual(english.grouped(10_000), "10,000")
    }
}

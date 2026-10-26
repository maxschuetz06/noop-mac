import XCTest
@testable import StrandAnalytics

/// The integer-math fast paths behind `VitalBands.calendarSeries` and `CorrelationEngine.shiftDay` must be
/// indistinguishable from the original Foundation implementations (kept as `…ViaFoundation`).
final class CanonicalDayEqualityTests: XCTestCase {

    private struct LCG {
        var s: UInt64
        mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 }
        mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
    }

    private func key(_ y: Int, _ m: Int, _ d: Int) -> String { String(format: "%04d-%02d-%02d", y, m, d) }

    func testShiftDayMatchesFoundationOnEveryDayOfSeveralYears() {
        // Every day 1999-12-25 … 2029-01-05 (covers leap years 2000/2004/…/2028 and century rules) × deltas.
        let deltas = [-400, -31, -30, -7, -2, -1, 1, 2, 3, 7, 14, 30, 31, 365, 366, 1_000]
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        var d = cal.date(from: DateComponents(year: 1999, month: 12, day: 25))!
        let end = cal.date(from: DateComponents(year: 2029, month: 1, day: 5))!
        var checked = 0
        while d <= end {
            let c = cal.dateComponents([.year, .month, .day], from: d)
            let k = key(c.year!, c.month!, c.day!)
            for delta in deltas {
                XCTAssertEqual(CorrelationEngine.shiftDay(k, by: delta),
                               CorrelationEngine.shiftDayViaFoundation(k, by: delta), "\(k) \(delta)")
                checked += 1
            }
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        XCTAssertGreaterThan(checked, 100_000)
    }

    func testShiftDayMatchesFoundationOnRandomAndMalformedInput() {
        var rng = LCG(s: 42)
        var inputs: [String] = ["", "x", "2026-1-5", "2026-01-5", "26-01-05", "2026-13-01", "2026-00-10", "2026-02-30",
                                "2026-04-31", "2026-01-00", "2024-02-29", "2023-02-29", "1582-10-04", "1500-03-01",
                                "0001-01-01", "9999-12-31", "2026/01/05", "2026-01-05 ", " 2026-01-05", "２０２６-01-05",
                                "2026-01-05T00", "+026-01-05", "2026--1-05"]
        for _ in 0..<3_000 {
            let y = rng.int(1590...9100), m = rng.int(0...13), d = rng.int(0...32)
            inputs.append(key(y, m, d))
        }
        for k in inputs {
            for delta in [0, 1, -1, 5, -40, 400, 100_000, -100_000, 20_000_000] {
                XCTAssertEqual(CorrelationEngine.shiftDay(k, by: delta),
                               CorrelationEngine.shiftDayViaFoundation(k, by: delta), "\(k) \(delta)")
            }
        }
    }

    func testCalendarSeriesMatchesFoundationOnRandomSeries() {
        var rng = LCG(s: 7)
        for round in 0..<300 {
            var rows: [(day: String, value: Double?)] = []
            var day = CanonicalDay.dayNumber("2025-01-01")! + rng.int(0...400)
            let n = rng.int(0...120)
            for _ in 0..<n {
                day += rng.int(0...4)
                let v: Double? = rng.int(0...5) == 0 ? nil : Double(rng.int(0...1_000)) / 10
                rows.append((CanonicalDay.key(forDayNumber: day), v))
                // Duplicate key (last write wins) every so often.
                if rng.int(0...9) == 0 { rows.append((CanonicalDay.key(forDayNumber: day), Double(round))) }
            }
            let fast = VitalBands.calendarSeries(rows)
            let ref = VitalBands.calendarSeriesViaFoundation(rows)
            XCTAssertEqual(fast, ref, "round \(round)")
        }
    }

    func testCalendarSeriesFallsBackIdenticallyOnNonCanonicalKeys() {
        let sets: [[(day: String, value: Double?)]] = [
            [("2026-06-01", 50), ("garbage", 1), ("2026-06-04", 52)],
            [("2026-6-1", 50), ("2026-06-04", 52)],
            [("2026-02-30", 5), ("2026-03-01", 6)],
            [("1500-01-01", 5), ("1500-01-03", 6)],
            [("2026-06-04", nil), ("2026-06-01", 3)],
            [],
        ]
        for rows in sets {
            XCTAssertEqual(VitalBands.calendarSeries(rows), VitalBands.calendarSeriesViaFoundation(rows))
        }
    }

    func testDayNumberRoundTripAndKnownAnchors() {
        XCTAssertEqual(CanonicalDay.dayNumber("1970-01-01"), 0)
        XCTAssertEqual(CanonicalDay.dayNumber("2000-03-01"), 11_017)
        XCTAssertEqual(CanonicalDay.key(forDayNumber: 11_017), "2000-03-01")
        XCTAssertNil(CanonicalDay.dayNumber("2026-02-29"))
        XCTAssertNotNil(CanonicalDay.dayNumber("2024-02-29"))
        for n in stride(from: CanonicalDay.dayNumber("1600-01-01")!, through: CanonicalDay.dayNumber("2100-12-31")!, by: 7) {
            XCTAssertEqual(CanonicalDay.dayNumber(CanonicalDay.key(forDayNumber: n)), n)
        }
    }
}

import Foundation

/// Allocation-free arithmetic on canonical `yyyy-MM-dd` day keys (proleptic Gregorian, no time zone).
///
/// The calendar helpers in this package (`VitalBands.calendarSeries`, `CorrelationEngine.shiftDay`) are
/// called per row / per lag from SwiftUI `body` evaluations on the main thread, where creating a
/// `DateFormatter` / `Calendar` and formatting with `String(format:)` for every call cost tens of
/// milliseconds per screen refresh. For strictly canonical keys the same answer is pure integer math, so
/// those helpers take this fast path and fall back to their original Foundation implementation for
/// anything else (non-padded, out-of-range, pre-1600 …) — results are identical by construction and
/// covered by equality tests against the Foundation reference.
enum CanonicalDay {
    /// Years inside which Foundation's Gregorian calendar agrees with the proleptic Gregorian arithmetic
    /// below (it switches to Julian before the 1582 cutover).
    static let supportedYears = 1600...9000

    /// Days since 1970-01-01 for a strictly canonical key — exactly 10 ASCII bytes `dddd-dd-dd` with a
    /// real calendar date — else nil (the caller then uses its Foundation path).
    static func dayNumber(_ key: String) -> Int? {
        var key = key
        return key.withUTF8 { b -> Int? in
            guard b.count == 10, b[4] == 0x2D, b[7] == 0x2D else { return nil }
            @inline(__always) func digit(_ i: Int) -> Int? {
                let v = Int(b[i]) - 0x30
                return (0...9).contains(v) ? v : nil
            }
            guard let y0 = digit(0), let y1 = digit(1), let y2 = digit(2), let y3 = digit(3),
                  let m0 = digit(5), let m1 = digit(6), let d0 = digit(8), let d1 = digit(9) else { return nil }
            let y = y0 * 1000 + y1 * 100 + y2 * 10 + y3
            let m = m0 * 10 + m1
            let d = d0 * 10 + d1
            guard supportedYears.contains(y), (1...12).contains(m), d >= 1, d <= daysInMonth(y, m) else { return nil }
            return daysFromCivil(y, m, d)
        }
    }

    /// The canonical `yyyy-MM-dd` key for a day number (inverse of `dayNumber`, valid inside `supportedYears`).
    static func key(forDayNumber n: Int) -> String {
        let (y, m, d) = civil(fromDays: n)
        var s = ""
        s.reserveCapacity(10)
        s += pad(y, 4); s += "-"; s += pad(m, 2); s += "-"; s += pad(d, 2)
        return s
    }

    static func year(ofDayNumber n: Int) -> Int { civil(fromDays: n).y }

    private static func pad(_ v: Int, _ width: Int) -> String {
        let s = String(v)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    private static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    private static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 2: return isLeap(y) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    // Howard Hinnant's civil-date algorithms.
    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civil(fromDays z0: Int) -> (y: Int, m: Int, d: Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }
}

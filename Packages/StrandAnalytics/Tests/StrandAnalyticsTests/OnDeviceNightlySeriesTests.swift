import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Pins what the on-device nightly pipeline PERSISTS from a night's raw streams: the absolute nightly
/// skin temperature (`skin_temp_abs`, new) and the RSA respiratory rate (`DailyMetric.respRateBpm`,
/// already persisted — proven here so it can't silently regress). A synthetic night is fed through the
/// real `AnalyticsEngine.analyzeDay` and the series point is built by the exact helper the Mac/iOS
/// IntelligenceEngine uses. All values APPROXIMATE (wrist skin temp, RSA breathing estimate).
final class OnDeviceNightlySeriesTests: XCTestCase {

    /// A 7 h still night ending 06:00 UTC on `day`, with RSA-modulated R-R (planted 15 breaths/min) and
    /// worn skin temp at `skinRaw` centidegrees (3400 = 34.00 °C) across the whole night.
    private func syntheticNight(day: String, skinRaw: Int?) -> AnalyticsEngine.DayResult {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        let end = Int(fmt.date(from: day)!.timeIntervalSince1970) + 6 * 3600
        let start = end - 7 * 3600

        let hr = (start..<end).map { HRSample(ts: $0, bpm: 50) }
        let grav = (start..<end).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        var rr: [RRInterval] = []
        var t = 0.0
        while t < Double(end - start) {
            let ms = 1200.0 + 40.0 * sin(2.0 * Double.pi * 0.25 * t)   // 15 breaths/min
            t += ms / 1000.0
            rr.append(RRInterval(ts: start + Int(t), rrMs: Int(ms)))
        }
        let skin: [SkinTempSample] = skinRaw.map { raw in
            (start..<end).map { SkinTempSample(ts: $0, raw: raw) }
        } ?? []
        return AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, gravity: grav, skinTemp: skin,
                                          profile: UserProfile(age: 30))
    }

    func testSyntheticNightYieldsAbsoluteSkinTempPointUnderTheStableKey() throws {
        let day = "2026-10-12"
        let result = syntheticNight(day: day, skinRaw: 3412)   // 34.12 °C
        let point = try XCTUnwrap(OnDeviceNightlySeries.skinTempAbsPoint(
            day: result.daily.day, nightlySkinTempC: result.nightlySkinTempC))
        XCTAssertEqual(point.key, "skin_temp_abs")
        XCTAssertEqual(point.key, OnDeviceNightlySeries.skinTempAbsKey)
        XCTAssertEqual(point.day, result.daily.day)
        XCTAssertEqual(point.value, 34.12, accuracy: 1e-9)
    }

    func testNightWithoutSkinSamplesWritesNoPoint() {
        let result = syntheticNight(day: "2026-10-13", skinRaw: nil)
        XCTAssertNil(result.nightlySkinTempC)
        XCTAssertNil(OnDeviceNightlySeries.skinTempAbsPoint(day: result.daily.day,
                                                            nightlySkinTempC: result.nightlySkinTempC))
    }

    func testImplausibleOrNonFiniteMeansAreNeverPersisted() {
        for bad in [Double.nan, .infinity, 22.5, 27.99, 42.01, 120.0, -3.0] {
            XCTAssertNil(OnDeviceNightlySeries.skinTempAbsPoint(day: "2026-10-14", nightlySkinTempC: bad),
                         "\(bad) must not become a series point")
        }
        XCTAssertNil(OnDeviceNightlySeries.skinTempAbsPoint(day: "2026-10-14", nightlySkinTempC: nil))
        XCTAssertNotNil(OnDeviceNightlySeries.skinTempAbsPoint(day: "2026-10-14", nightlySkinTempC: 28.0))
        XCTAssertNotNil(OnDeviceNightlySeries.skinTempAbsPoint(day: "2026-10-14", nightlySkinTempC: 42.0))
    }

    func testValueIsRoundedToCentidegrees() throws {
        let p = try XCTUnwrap(OnDeviceNightlySeries.skinTempAbsPoint(day: "2026-10-14",
                                                                     nightlySkinTempC: 33.456789))
        XCTAssertEqual(p.value, 33.46, accuracy: 1e-9)
    }

    func testRespiratoryRateFromRSAIsOnTheDailyMetricForOnDeviceNights() throws {
        // The RSA respiratory rate is persisted via DailyMetric.respRateBpm (no separate series needed):
        // it must be present on the produced row, near the planted 15 breaths/min, and survive the
        // Codable round-trip WhoopStore uses for the daily cache.
        let result = syntheticNight(day: "2026-10-12", skinRaw: 3400)
        let resp = try XCTUnwrap(result.daily.respRateBpm)
        XCTAssertEqual(resp, 15.0, accuracy: 3.0)
        XCTAssertTrue(SleepStager.respPlausibleRangeBpm.contains(resp))
        let decoded = try JSONDecoder().decode(DailyMetric.self, from: JSONEncoder().encode(result.daily))
        XCTAssertEqual(decoded.respRateBpm, resp)
    }
}

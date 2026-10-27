import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// Health-screen vital tiles: the absolute nightly skin temperature (`skin_temp_abs`) replaces the
/// ±deviation when the on-device pipeline has it, an SpO₂ tile with no data stays "—" with an honest
/// caption, and the new series round-trips through the real store + explore read path.
final class HealthVitalsOverlayTests: XCTestCase {

    private func daily(_ day: String, spo2: Double? = nil, skinDev: Double? = nil,
                       resp: Double? = nil, rhr: Int? = nil, hrv: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil, strain: nil,
                    exerciseCount: nil, spo2Pct: spo2, skinTempDevC: skinDev, respRateBpm: resp,
                    steps: nil, activeKcalEst: nil)
    }

    private func readings(_ rows: [SourcedDailyMetric]) -> [BodyVitalReading] {
        BodyVitalSigns.readings(sourceRows: rows, temperatureUnit: .celsius)
    }

    private func series(_ values: [Double], endingOn lastDay: Int = 14) -> [(day: String, value: Double)] {
        values.enumerated().map { (i, v) in
            (day: String(format: "2026-10-%02d", lastDay - (values.count - 1 - i)), value: v)
        }
    }

    // MARK: - Skin temperature

    func testAbsoluteSeriesReplacesTheDeviationTileWithLatestValueAnd14DayTrend() throws {
        let rows = [SourcedDailyMetric(metric: daily("2026-10-13", skinDev: 0.2), source: .noopComputed)]
        let vals = (0..<20).map { 33.0 + Double($0) * 0.04 }
        let out = HealthVitalsOverlay.apply(to: readings(rows), skinAbs: series(vals, endingOn: 20),
                                            temperatureUnit: .celsius)
        let skin = try XCTUnwrap(out.first { $0.key == "skin" })
        XCTAssertEqual(try XCTUnwrap(skin.value), vals.last!, accuracy: 1e-9)
        XCTAssertEqual(skin.day, "2026-10-20")
        XCTAssertEqual(skin.source, .noopComputed)
        XCTAssertEqual(skin.sparkline?.count, 14, "14-day trend")
        XCTAssertEqual(skin.sparkline?.last, vals.last)
        XCTAssertEqual(skin.unit, "°C")
        XCTAssertEqual(skin.formattedValue, "33.8 °C")
    }

    func testFahrenheitUsesTheFullConversion() throws {
        let out = HealthVitalsOverlay.apply(
            to: BodyVitalSigns.readings(sourceRows: [], temperatureUnit: .fahrenheit),
            skinAbs: series([34.0, 34.0]), temperatureUnit: .fahrenheit)
        let skin = try XCTUnwrap(out.first { $0.key == "skin" })
        XCTAssertEqual(skin.formattedValue, "93.2 °F")   // 34 °C absolute, ×9/5 + 32
    }

    func testNoAbsoluteSeriesKeepsTheDeviationReading() throws {
        let rows = [SourcedDailyMetric(metric: daily("2026-10-13", skinDev: 0.2), source: .noopComputed)]
        let base = readings(rows)
        let out = HealthVitalsOverlay.apply(to: base, skinAbs: [], temperatureUnit: .celsius)
        let skin = try XCTUnwrap(out.first { $0.key == "skin" })
        XCTAssertEqual(skin.value, 0.2)
        XCTAssertEqual(skin.day, "2026-10-13")
    }

    func testNewerImportedAbsoluteValueBeatsAnOlderOnDeviceSeries() throws {
        let rows = [SourcedDailyMetric(metric: daily("2026-10-14", skinDev: 34.4), source: .whoopImport)]
        let out = HealthVitalsOverlay.apply(to: readings(rows), skinAbs: series([33.0, 33.2], endingOn: 13),
                                            temperatureUnit: .celsius)
        let skin = try XCTUnwrap(out.first { $0.key == "skin" })
        XCTAssertEqual(skin.value, 34.4)
        XCTAssertEqual(skin.source, .whoopImport)
    }

    // MARK: - SpO₂ honesty

    func testMissingSpo2StaysEmptyAndNeverFabricatesANumber() throws {
        let rows = [SourcedDailyMetric(metric: daily("2026-10-13", resp: 14.5, rhr: 52, hrv: 70),
                                       source: .noopComputed)]
        let out = HealthVitalsOverlay.apply(to: readings(rows), skinAbs: [], temperatureUnit: .celsius)
        let spo2 = try XCTUnwrap(out.first { $0.key == "spo2" })
        XCTAssertNil(spo2.value)
        XCTAssertNil(spo2.formattedValue)
        XCTAssertEqual(spo2.stateCaption, String(localized: "Not yet available from WHOOP 5.0 on this Mac"))
    }

    func testPresentSpo2IsUntouched() throws {
        let rows = [SourcedDailyMetric(metric: daily("2026-10-13", spo2: 97), source: .whoopImport)]
        let out = HealthVitalsOverlay.apply(to: readings(rows), skinAbs: [], temperatureUnit: .celsius)
        XCTAssertEqual(try XCTUnwrap(out.first { $0.key == "spo2" }).value, 97)
    }

    func testRespRhrHrvAreStillTheDailyRowValues() throws {
        let rows = [SourcedDailyMetric(metric: daily("2026-10-13", resp: 14.5, rhr: 52, hrv: 70),
                                       source: .noopComputed)]
        let out = HealthVitalsOverlay.apply(to: readings(rows), skinAbs: [], temperatureUnit: .celsius)
        XCTAssertEqual(out.first { $0.key == "resp" }?.value, 14.5)
        XCTAssertEqual(out.first { $0.key == "rhr" }?.value, 52)
        XCTAssertEqual(out.first { $0.key == "hrv" }?.value, 70)
    }

    // MARK: - Catalog + store round-trip

    func testSkinTempAbsIsRegisteredInTheMetricCatalog() throws {
        let m = try XCTUnwrap(MetricCatalog.all.first { $0.key == OnDeviceNightlySeries.skinTempAbsKey })
        XCTAssertEqual(m.source, "my-whoop")
        XCTAssertEqual(m.unit, "°C")
        XCTAssertEqual(m.format(34.2, system: .metric, temperature: .celsius), "34.2 °C")
        XCTAssertEqual(MetricCatalog.all.filter { $0.id == m.id }.count, 1)
    }

    func testSkinTempAbsAndRespRateRoundTripThroughTheStoreUnderTheComputedSource() async throws {
        let store = try await WhoopStore.inMemory()
        let computed = "my-whoop-noop"
        let point = try XCTUnwrap(OnDeviceNightlySeries.skinTempAbsPoint(day: "2026-10-13",
                                                                         nightlySkinTempC: 33.87))
        _ = try await store.upsertMetricSeries([point], deviceId: computed)
        _ = try await store.upsertDailyMetrics([daily("2026-10-13", resp: 14.8)], deviceId: computed)

        let pts = try await store.metricSeries(deviceId: computed, key: "skin_temp_abs",
                                               from: "2026-10-01", to: "2026-10-31")
        XCTAssertEqual(pts.map(\.day), ["2026-10-13"])
        XCTAssertEqual(try XCTUnwrap(pts.first).value, 33.87, accuracy: 1e-9)
        let days = try await store.dailyMetrics(deviceId: computed, from: "2026-10-01", to: "2026-10-31")
        XCTAssertEqual(days.first?.respRateBpm, 14.8)
    }
}

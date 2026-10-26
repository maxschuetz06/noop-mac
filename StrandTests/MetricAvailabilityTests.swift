import XCTest
import WhoopStore
@testable import Strand

/// Explore / Compare list only metrics that have data. The filtering is pure (`MetricAvailabilityIndex`),
/// so it is verified here against synthetic summaries and daily rows.
final class MetricAvailabilityTests: XCTestCase {
    private func metric(_ key: String, source: String = "my-whoop") throws -> MetricDescriptor {
        try XCTUnwrap(MetricCatalog.all.first { $0.key == key && $0.source == source }, "\(source):\(key)")
    }

    private func summary(_ device: String, _ key: String, count: Int = 3,
                         day: String = "2026-07-23", value: Double = 54) -> MetricSeriesSummary {
        MetricSeriesSummary(deviceId: device, key: key, count: count, latestDay: day, latestValue: value)
    }

    private func daily(_ day: String, recovery: Double? = nil, steps: Int? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: nil, avgHrv: nil, recovery: recovery, strain: nil,
                    exerciseCount: nil, steps: steps)
    }

    private func build(_ summaries: [MetricSeriesSummary], days: [DailyMetric] = []) -> [String: MetricAvailability] {
        MetricAvailabilityIndex.build(catalog: MetricCatalog.all, summaries: summaries,
                                      deviceId: "my-whoop", days: days)
    }

    func testNoDataMeansNoMetricHasAvailability() {
        XCTAssertTrue(build([]).isEmpty)
    }

    func testSeriesSummaryMakesWhoopMetricAvailableWithLatestPoint() throws {
        let hrv = try metric("hrv")
        let a = build([summary("my-whoop", "hrv", day: "2026-07-23", value: 54)])
        XCTAssertEqual(a[hrv.id], MetricAvailability(latestDay: "2026-07-23", latestValue: 54))
        XCTAssertNil(a[try metric("rhr").id])
    }

    func testOtherSourcesAreNotCountedForWhoopMetricsAndViceVersa() throws {
        // An Apple-Health series with the same key must not light up the Whoop metric…
        let a = build([summary("apple-health", "hrv")])
        XCTAssertNil(a[try metric("hrv").id])
        // …and a Whoop series must not light up a Mi Band / Apple metric of the same key.
        let xiaomi = MetricCatalog.all.filter { $0.source == "xiaomi-band" }
        XCTAssertFalse(xiaomi.isEmpty)
        let b = build(MetricCatalog.all.filter { $0.source == "my-whoop" }.map { summary("my-whoop", $0.key) })
        for m in MetricCatalog.all where m.source != "my-whoop" { XCTAssertNil(b[m.id], m.id) }
    }

    func testComputedSourceCountsAndImportedWinsOnTheSameDay() throws {
        let rec = try metric("recovery")
        let a = build([summary("my-whoop-noop", "recovery", day: "2026-07-22", value: 40)])
        XCTAssertEqual(a[rec.id]?.latestValue, 40)
        let b = build([summary("my-whoop-noop", "recovery", day: "2026-07-23", value: 40),
                       summary("my-whoop", "recovery", day: "2026-07-23", value: 66)])
        XCTAssertEqual(b[rec.id]?.latestValue, 66)
        // A newer computed day beats an older imported day.
        let c = build([summary("my-whoop-noop", "recovery", day: "2026-07-24", value: 40),
                       summary("my-whoop", "recovery", day: "2026-07-23", value: 66)])
        XCTAssertEqual(c[rec.id], MetricAvailability(latestDay: "2026-07-24", latestValue: 40))
    }

    func testDailyColumnMakesStrapOnlyMetricAvailable() throws {
        let days = [daily("2026-07-20", recovery: 30), daily("2026-07-22", recovery: 71), daily("2026-07-21")]
        let a = build([], days: days)
        XCTAssertEqual(a[try metric("recovery").id], MetricAvailability(latestDay: "2026-07-22", latestValue: 71))
        XCTAssertNil(a[try metric("strain").id], "no strain values in any daily row")
    }

    func testSplitPreservesOrderAndSeparatesEmptyMetrics() throws {
        let hrv = try metric("hrv"), rhr = try metric("rhr"), rec = try metric("recovery")
        let avail = ["my-whoop:recovery": MetricAvailability(latestDay: "2026-07-23", latestValue: 1),
                     "my-whoop:hrv": MetricAvailability(latestDay: "2026-07-23", latestValue: 2)]
        let r = MetricAvailabilityIndex.split([hrv, rhr, rec], availability: avail)
        XCTAssertEqual(r.withData.map(\.key), ["hrv", "recovery"])
        XCTAssertEqual(r.withoutData.map(\.key), ["rhr"])
    }

    func testNilAvailabilityNeverHidesAnything() {
        let r = MetricAvailabilityIndex.split(MetricCatalog.all, availability: nil)
        XCTAssertEqual(r.withData.count, MetricCatalog.all.count)
        XCTAssertTrue(r.withoutData.isEmpty)
        XCTAssertEqual(MetricAvailabilityIndex.visible(MetricCatalog.all, availability: nil, showAll: false).count,
                       MetricCatalog.all.count)
    }

    func testVisibleHidesEmptyUnlessShowAllOrKept() throws {
        let hrv = try metric("hrv"), rhr = try metric("rhr")
        let avail = [hrv.id: MetricAvailability(latestDay: "2026-07-23", latestValue: 2)]
        XCTAssertEqual(MetricAvailabilityIndex.visible([hrv, rhr], availability: avail, showAll: false), [hrv])
        XCTAssertEqual(MetricAvailabilityIndex.visible([hrv, rhr], availability: avail, showAll: true), [hrv, rhr])
        XCTAssertEqual(MetricAvailabilityIndex.visible([hrv, rhr], availability: avail, showAll: false,
                                                       keeping: [rhr.id]), [hrv, rhr])
    }

    func testShortDate() {
        XCTAssertEqual(MetricAvailabilityIndex.shortDate("2026-07-23", currentYear: 2026), "23 Jul")
        XCTAssertEqual(MetricAvailabilityIndex.shortDate("2025-01-05", currentYear: 2026), "5 Jan 2025")
        XCTAssertNil(MetricAvailabilityIndex.shortDate("garbage", currentYear: 2026))
        XCTAssertNil(MetricAvailabilityIndex.shortDate("2026-13-01", currentYear: 2026))
    }

    func testStoreSummariesReturnCountAndLatestPoint() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("avail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await WhoopStore(path: dir.appendingPathComponent("t.sqlite").path)
        try await store.upsertMetricSeries([MetricPoint(day: "2026-07-01", key: "hrv", value: 40),
                                            MetricPoint(day: "2026-07-03", key: "hrv", value: 55),
                                            MetricPoint(day: "2026-07-02", key: "rhr", value: 58)],
                                           deviceId: "my-whoop")
        try await store.upsertMetricSeries([MetricPoint(day: "2026-07-09", key: "hrv", value: 70)],
                                           deviceId: "apple-health")
        let s = try await store.metricSeriesSummaries()
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.first { $0.deviceId == "my-whoop" && $0.key == "hrv" },
                       MetricSeriesSummary(deviceId: "my-whoop", key: "hrv", count: 2, latestDay: "2026-07-03", latestValue: 55))
        XCTAssertEqual(s.first { $0.deviceId == "apple-health" }?.latestValue, 70)
    }
}

import XCTest
@testable import Strand

/// Every metric key the WHOOP export importer writes into `metricSeries` must have a catalog
/// descriptor, otherwise the series is stored but can never be shown in Explore / Compare.
final class WhoopImporterCatalogTests: XCTestCase {

    /// Mirrors every `add(day, "<key>", …)` call in `WhoopImporter.swift` (the importer does not expose
    /// its key list). Keep in sync when the importer gains a new series.
    private static let importerKeys: [String] = [
        "recovery", "strain", "rhr", "hrv", "spo2", "skin_temp", "resp_rate", "energy_kcal",
        "avg_hr", "max_hr", "sleep_total_min", "in_bed_min", "sleep_deep_min", "sleep_rem_min",
        "sleep_light_min", "awake_min", "sleep_efficiency", "sleep_performance", "sleep_consistency",
        "sleep_need_min", "sleep_debt_min", "restorative_min", "restorative_pct", "hours_vs_needed_pct",
        "stress",
        "hr_zone1_min", "hr_zone2_min", "hr_zone3_min", "hr_zone4_min", "hr_zone5_min",
        "hr_zones13_min", "hr_zones45_min", "hr_zones_all_min", "strength_min",
    ]

    func testEveryWhoopImporterKeyHasACatalogDescriptor() {
        let catalogKeys = Set(MetricCatalog.all.filter { $0.source == "my-whoop" }.map(\.key))
        let missing = Self.importerKeys.filter { !catalogKeys.contains($0) }
        XCTAssertTrue(missing.isEmpty, "WHOOP importer keys missing from MetricCatalog: \(missing)")
    }

    func testNewImporterDescriptorsAreWellFormed() throws {
        let awake = try XCTUnwrap(MetricCatalog.all.first { $0.id == "my-whoop:awake_min" })
        XCTAssertEqual(awake.title, "Awake Time")
        XCTAssertEqual(awake.category, "Rest")
        XCTAssertEqual(awake.unit, "min")
        XCTAssertEqual(awake.higherIsBetter, false)
        for n in 1...5 {
            let z = try XCTUnwrap(MetricCatalog.all.first { $0.id == "my-whoop:hr_zone\(n)_min" })
            XCTAssertEqual(z.title, "HR Zone \(n)")
            XCTAssertEqual(z.category, "Effort")
            XCTAssertNil(z.higherIsBetter)
        }
    }

    func testCatalogIdsStayUnique() {
        let ids = MetricCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }
}

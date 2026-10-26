import XCTest
import SwiftUI
@testable import Strand

/// `CompareSeries` precomputes its min/max at init (they used to be recomputed per `normalized(_:)` call,
/// i.e. O(n²) per overlay-chart build). The precomputed values must equal the old computed properties.
final class CompareSeriesTests: XCTestCase {
    private func series(_ values: [Double]) throws -> CompareSeries {
        let metric = try XCTUnwrap(MetricCatalog.all.first)
        let rows = values.enumerated().map { (day: String(format: "2026-01-%02d", $0.offset % 28 + 1), value: $0.element) }
        return CompareSeries(metric: metric, color: .green, rows: rows)
    }

    /// The implementation the stored properties replaced.
    private func referenceNormalized(_ values: [Double], _ v: Double) -> Double {
        let lo = values.min() ?? 0, hi = values.max() ?? 0
        guard hi > lo else { return 0.5 }
        return min(max((v - lo) / (hi - lo), 0), 1)
    }

    func testMinMaxAndNormalizationMatchReference() throws {
        var rng = SystemRandomNumberGenerator()
        var cases: [[Double]] = [[], [4], [3, 3, 3], [-5, 0, 12.5, 7], [0.1, 0.2, 0.30000000000000004]]
        for _ in 0..<20 { cases.append((0..<Int.random(in: 2...400, using: &rng)).map { _ in Double.random(in: -300...300, using: &rng) }) }
        for values in cases {
            let s = try series(values)
            XCTAssertEqual(s.realMin, values.min() ?? 0)
            XCTAssertEqual(s.realMax, values.max() ?? 0)
            for v in values + [-1_000, 1_000] {
                XCTAssertEqual(s.normalized(v), referenceNormalized(values, v), accuracy: 0)
            }
        }
    }
}

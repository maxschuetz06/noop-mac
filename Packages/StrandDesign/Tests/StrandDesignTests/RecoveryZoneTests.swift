import XCTest
@testable import StrandDesign

final class RecoveryZoneTests: XCTestCase {
    func testBandsSplitAt34And67() {
        XCTAssertEqual(RecoveryZone(score: 100), .high)
        XCTAssertEqual(RecoveryZone(score: 67), .high)
        XCTAssertEqual(RecoveryZone(score: 66.9), .medium)
        XCTAssertEqual(RecoveryZone(score: 34), .medium)
        XCTAssertEqual(RecoveryZone(score: 33.9), .low)
        XCTAssertEqual(RecoveryZone(score: 0), .low)
    }
}

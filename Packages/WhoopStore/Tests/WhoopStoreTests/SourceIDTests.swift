import XCTest
import WhoopStore

/// Source ids are written into every stored row; a changed value would orphan existing data.
final class SourceIDTests: XCTestCase {
    func testStoredSourceIdsKeepTheirValues() {
        XCTAssertEqual(SourceID.whoop, "my-whoop")
        XCTAssertEqual(SourceID.whoopComputed, "my-whoop-noop")
        XCTAssertEqual(SourceID.computedSuffix, "-noop")
        XCTAssertEqual(SourceID.appleHealth, "apple-health")
        XCTAssertEqual(SourceID.healthConnect, "health-connect")
    }
}

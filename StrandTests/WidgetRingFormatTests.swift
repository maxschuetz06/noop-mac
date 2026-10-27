import XCTest

final class WidgetRingFormatTests: XCTestCase {
    func testRecoveryZoneFollowsTheSharedBands() {
        XCTAssertEqual(WidgetRingFormat.recoveryZone(67), .green)
        XCTAssertEqual(WidgetRingFormat.recoveryZone(66), .yellow)
        XCTAssertEqual(WidgetRingFormat.recoveryZone(34), .yellow)
        XCTAssertEqual(WidgetRingFormat.recoveryZone(33), .red)
        XCTAssertEqual(WidgetRingFormat.recoveryZone(nil), .unknown)
    }
}

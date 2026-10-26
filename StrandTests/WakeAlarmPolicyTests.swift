import XCTest
import WhoopProtocol
@testable import Strand

/// Strap safety: the firmware alarm may never be armed on a WHOOP 5/MG (non-stop vibration incident), and
/// the 5/MG clearing body stays the rev-2 DISABLE_ALARM form.
final class WakeAlarmPolicyTests: XCTestCase {

    func testWhoop5MayNeverArmTheFirmwareAlarm() {
        XCTAssertFalse(WakeAlarmPolicy.mayArmFirmwareAlarm(family: .whoop5))
        XCTAssertTrue(WakeAlarmPolicy.mayArmFirmwareAlarm(family: .whoop4))
    }

    func testDisableRev2IsTheClearingBody() {
        XCTAssertEqual(AlarmPayload.disableRev2(), [0x02, 0xFF])
    }
}

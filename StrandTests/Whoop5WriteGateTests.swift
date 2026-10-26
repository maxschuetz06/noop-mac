import XCTest
@testable import Strand

/// Pins the runtime gate for the WHOOP 5/MG strap-writing features (R22 deep data, Broadcast HR).
/// There is deliberately no operating-system parameter: macOS CoreBluetooth completes the encrypted
/// bond and the command-characteristic writes work there, so only the live link state may decide.
final class Whoop5WriteGateTests: XCTestCase {

    func testDeepDataReadyOnlyWithEncryptedBondAndWornStrap() {
        XCTAssertEqual(Whoop5WriteGate.deepData(encryptedBond: true, worn: true), .ready)
        XCTAssertTrue(Whoop5WriteGate.deepData(encryptedBond: true, worn: true).isReady)
    }

    func testDeepDataWithoutEncryptedBondNeedsTheBond_regardlessOfWear() {
        XCTAssertEqual(Whoop5WriteGate.deepData(encryptedBond: false, worn: true), .needsEncryptedBond)
        XCTAssertEqual(Whoop5WriteGate.deepData(encryptedBond: false, worn: false), .needsEncryptedBond)
    }

    func testDeepDataBondedButOffWristNeedsWear() {
        let status = Whoop5WriteGate.deepData(encryptedBond: true, worn: false)
        XCTAssertEqual(status, .needsWear)
        XCTAssertFalse(status.isReady)
    }

    func testBroadcastHrNeedsOnlyTheEncryptedBond() {
        XCTAssertEqual(Whoop5WriteGate.broadcastHr(encryptedBond: true), .ready)
        XCTAssertEqual(Whoop5WriteGate.broadcastHr(encryptedBond: false), .needsEncryptedBond)
    }

    func testCaptionsExplainTheUnmetConditionAndNeverBlameTheOperatingSystem() {
        for status in [Whoop5WriteGate.Status.ready, .needsEncryptedBond, .needsWear] {
            let text = Whoop5WriteGate.deepDataCaption(status)
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("iPhone or Android"))
            XCTAssertFalse(text.localizedCaseInsensitiveContains("Mac can't"))
        }
        XCTAssertNotEqual(Whoop5WriteGate.deepDataCaption(.needsEncryptedBond),
                          Whoop5WriteGate.deepDataCaption(.needsWear))
        XCTAssertNil(Whoop5WriteGate.broadcastHrCaption(.ready))
        XCTAssertNotNil(Whoop5WriteGate.broadcastHrCaption(.needsEncryptedBond))
    }
}

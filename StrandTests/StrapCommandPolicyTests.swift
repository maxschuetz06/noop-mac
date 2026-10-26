import XCTest
import WhoopProtocol
@testable import Strand

/// Pins the strap write gate: a WHOOP 5/MG never receives a strap-held alarm or a looping haptic
/// (fw 50.42.1.0 vibrated ~20 min on overallLoop 7), and WHOOP 4.0 is passed through unchanged.
final class StrapCommandPolicyTests: XCTestCase {
    private let off = StrapCommandExperiments(deepData: false, broadcastHr: false)
    private let on = StrapCommandExperiments(deepData: true, broadcastHr: true)

    private func whoop5(_ command: WhoopCommand, _ payload: [UInt8] = [0x00],
                        _ experiments: StrapCommandExperiments? = nil) -> StrapWrite {
        StrapCommandPolicy.write(for: command, payload: payload, family: .whoop5,
                                 experiments: experiments ?? off)
    }

    private func isDenied(_ write: StrapWrite) -> Bool {
        if case .denied = write { return true }
        return false
    }

    func testWhoop5NeverGetsAStrapHeldAlarmEvenWithEveryExperimentOn() {
        for experiments in [off, on] {
            XCTAssertTrue(isDenied(whoop5(.setAlarmTime, [0x04], experiments)))
            XCTAssertTrue(isDenied(whoop5(.runAlarm, [0x02, 0x01], experiments)))
        }
    }

    func testWhoop5HapticsAlwaysSendTheFixedOneShotNotifyBody() {
        let oneShot: [UInt8] = [0x01, 0x2F, 0x98, 0, 0, 0, 0, 0, 0, 0, 0, 0x00]
        for payload: [UInt8] in [[2, 3, 0, 0, 0], [2, 255, 0, 0, 0], [7, 1], [], AlarmPayload.setAlarmRev4(wakeEpochMs: 0)] {
            XCTAssertEqual(whoop5(.runHapticsPattern, payload, on), .puffin(opcode: 0x13, payload: oneShot))
        }
    }

    func testWhoop5AllowlistIsExactlyPinned() {
        let allowed: Set<WhoopCommand> = [
            .toggleRealtimeHR, .runHapticsPattern, .stopHaptics, .getAlarmTime, .disableAlarm,
            .sendHistoricalData, .historicalDataResult, .setClock, .getClock,
        ]
        for command in WhoopCommand.allCases {
            XCTAssertEqual(!isDenied(whoop5(command)), allowed.contains(command), "\(command)")
        }
    }

    func testWhoop5PassesAllowedPayloadsThroughOnTheirOwnOpcode() {
        XCTAssertEqual(whoop5(.disableAlarm, AlarmPayload.disableRev2()),
                       .puffin(opcode: WhoopCommand.disableAlarm.rawValue, payload: [0x02, 0xFF]))
        XCTAssertEqual(whoop5(.stopHaptics), .puffin(opcode: WhoopCommand.stopHaptics.rawValue, payload: [0x00]))
    }

    func testWhoop5ConfigWritesNeedTheirOwnOptIn() {
        let deepOnly = StrapCommandExperiments(deepData: true, broadcastHr: false)
        let broadcastOnly = StrapCommandExperiments(deepData: false, broadcastHr: true)
        XCTAssertEqual(whoop5(.setConfig, [0x01], deepOnly), .puffin(opcode: WhoopCommand.setConfig.rawValue, payload: [0x01]))
        XCTAssertTrue(isDenied(whoop5(.setConfig, [0x01], broadcastOnly)))
        XCTAssertEqual(whoop5(.setDeviceConfig, [0x01], broadcastOnly),
                       .puffin(opcode: WhoopCommand.setDeviceConfig.rawValue, payload: [0x01]))
        XCTAssertTrue(isDenied(whoop5(.setDeviceConfig, [0x01], deepOnly)))
    }

    func testWhoop4IsPassedThroughUnchanged() {
        for command in WhoopCommand.allCases {
            XCTAssertEqual(StrapCommandPolicy.write(for: command, payload: [2, 3, 0, 0, 0], family: .whoop4,
                                                    experiments: off),
                           .whoop4(payload: [2, 3, 0, 0, 0]), "\(command)")
        }
    }
}

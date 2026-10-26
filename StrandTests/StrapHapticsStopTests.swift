import XCTest
import WhoopProtocol
@testable import Strand

final class StrapHapticsStopTests: XCTestCase {
    private let queue = DispatchQueue(label: "StrapHapticsStopTests")

    func testStopDropsQueuedHapticClockPulses() {
        let pulses = HapticPulseSchedule(queue: queue)
        let fired = expectation(description: "no Haptic Clock pulse fires after the stop")
        fired.isInverted = true
        fired.assertForOverFulfill = false
        pulses.schedule(afterMs: 50) { fired.fulfill() }
        pulses.schedule(afterMs: 100) { fired.fulfill() }

        StrapHapticsStop.run(cancelling: pulses, family: .whoop5) { _, _ in }

        wait(for: [fired], timeout: 0.3)
    }

    func testStopSendsStopHapticsThenTheFamilyAlarmDisable() {
        XCTAssertEqual(sentCommands(family: .whoop5), [
            Sent(command: .stopHaptics, payload: [0x00]),
            Sent(command: .disableAlarm, payload: AlarmPayload.disableRev2()),
        ])
        XCTAssertEqual(sentCommands(family: .whoop4), [
            Sent(command: .stopHaptics, payload: [0x00]),
            Sent(command: .disableAlarm, payload: [0x01]),
        ])
    }

    private struct Sent: Equatable {
        let command: WhoopCommand
        let payload: [UInt8]
    }

    private func sentCommands(family: DeviceFamily) -> [Sent] {
        var sent: [Sent] = []
        StrapHapticsStop.run(cancelling: HapticPulseSchedule(queue: queue), family: family) {
            sent.append(Sent(command: $0, payload: $1))
        }
        return sent
    }
}

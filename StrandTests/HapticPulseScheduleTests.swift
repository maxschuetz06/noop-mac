import XCTest
@testable import Strand

final class HapticPulseScheduleTests: XCTestCase {
    private let queue = DispatchQueue(label: "HapticPulseScheduleTests")

    func testCancelAllDropsEveryPulseNotYetFired() {
        let schedule = HapticPulseSchedule(queue: queue)
        let fired = expectation(description: "no pulse fires after cancelAll")
        fired.isInverted = true
        fired.assertForOverFulfill = false
        schedule.schedule(afterMs: 50) { fired.fulfill() }
        schedule.schedule(afterMs: 100) { fired.fulfill() }

        schedule.cancelAll()

        wait(for: [fired], timeout: 0.3)
    }

    func testScheduledPulsesFireWhenNotCancelled() {
        let schedule = HapticPulseSchedule(queue: queue)
        let fired = expectation(description: "both pulses fire")
        fired.expectedFulfillmentCount = 2
        schedule.schedule(afterMs: 10) { fired.fulfill() }
        schedule.schedule(afterMs: 20) { fired.fulfill() }

        wait(for: [fired], timeout: 2)
    }
}

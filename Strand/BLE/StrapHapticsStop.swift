import WhoopProtocol

/// The stop sequence behind "Stop haptics": queued Haptic Clock pulses are dropped first so none fires
/// after the stop, then the strap is asked to stop its current pattern (STOP_HAPTICS 122) and to disarm
/// its firmware alarm with the family's payload.
enum StrapHapticsStop {
    static func run(cancelling pulses: HapticPulseSchedule, family: DeviceFamily,
                    send: (WhoopCommand, [UInt8]) -> Void) {
        pulses.cancelAll()
        send(.stopHaptics, [0x00])
        switch family {
        case .whoop5: send(.disableAlarm, AlarmPayload.disableRev2())
        case .whoop4: send(.disableAlarm, [0x01])
        }
    }
}

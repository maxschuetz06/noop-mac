import WhoopProtocol

/// Opt-ins that unlock a persistent strap-config write on a WHOOP 5/MG.
struct StrapCommandExperiments: Equatable {
    var deepData: Bool
    var broadcastHr: Bool

    static var current: StrapCommandExperiments {
        StrapCommandExperiments(deepData: PuffinExperiment.deepDataEnabled,
                                broadcastHr: PuffinExperiment.broadcastHrEnabled)
    }
}

/// What goes on the wire for one strap command, or why it must not be sent.
enum StrapWrite: Equatable {
    /// WHOOP 4.0 frame carrying the command's own number and payload.
    case whoop4(payload: [UInt8])
    /// WHOOP 5/MG puffin (CRC16) frame.
    case puffin(opcode: UInt8, payload: [UInt8])
    case denied(reason: String)
}

/// The single gate every strap write passes through (`BLEManager.send`). WHOOP 4.0 is passed through
/// unchanged. A WHOOP 5/MG only gets an allowlisted command set on its puffin transport, and never a
/// strap-held alarm or a looping haptic: fw 50.42.1.0 vibrated ~20 min on an overallLoop-7 body while
/// ignoring every stop command, so longer vibrations are driven from the host with one-shot buzzes.
enum StrapCommandPolicy {
    /// RUN_HAPTIC_PATTERN_MAVERICK — the 5/MG rejects RUN_HAPTICS_PATTERN (79) with result 0x03 (#48).
    static let maverickHapticsOpcode: UInt8 = 0x13

    /// The only haptic body a 5/MG ever receives: the "notify" one-shot, overallLoop 0.
    static let whoop5OneShotBuzz = MaverickHaptics.notificationBuzz(loops: 0)

    /// Commands a 5/MG accepts over puffin framing: live HR, one-shot buzz and stop, the alarm query and
    /// disarm, the historical offload + its ack, and the clock pair (an un-clocked 5/MG saves no history).
    private static let whoop5Allowed: Set<WhoopCommand> = [
        .toggleRealtimeHR, .runHapticsPattern, .stopHaptics,
        .getAlarmTime, .disableAlarm,
        .sendHistoricalData, .historicalDataResult,
        .setClock, .getClock,
    ]

    static func write(for command: WhoopCommand, payload: [UInt8], family: DeviceFamily,
                      experiments: StrapCommandExperiments) -> StrapWrite {
        switch family {
        case .whoop4: return .whoop4(payload: payload)
        case .whoop5: return whoop5Write(for: command, payload: payload, experiments: experiments)
        }
    }

    private static func whoop5Write(for command: WhoopCommand, payload: [UInt8],
                                    experiments: StrapCommandExperiments) -> StrapWrite {
        switch command {
        case .setAlarmTime, .runAlarm:
            return .denied(reason: "strap-held alarms loop the WHOOP 5/MG motor beyond any stop command")
        case .runHapticsPattern:
            return .puffin(opcode: maverickHapticsOpcode, payload: whoop5OneShotBuzz)
        // Persistent strap-config writes (R22 deep-data unlock #174, broadcast HR #181): only while opted in.
        case .setConfig where experiments.deepData, .setDeviceConfig where experiments.broadcastHr:
            return .puffin(opcode: command.rawValue, payload: payload)
        default:
            guard whoop5Allowed.contains(command) else {
                return .denied(reason: "no WHOOP 5/MG framing for this command")
            }
            return .puffin(opcode: command.rawValue, payload: payload)
        }
    }
}

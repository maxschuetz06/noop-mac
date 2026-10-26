import WhoopProtocol

/// Strap-safety gate for the firmware alarm. The macOS app has no wake alarm and arms none, but
/// `BLEManager.armStrapAlarm` keeps this guard so no caller can ever send SET_ALARM_TIME to a WHOOP 5/MG:
/// a real WHOOP 5.0 (fw 50.42.1.0) vibrated non-stop for ~20 minutes after its firmware alarm was armed
/// and ignored every stop command.
enum WakeAlarmPolicy {
    /// Whether SET_ALARM_TIME may ever be sent to a strap of this family. Never on a WHOOP 5/MG: the rev-4
    /// body carries overallLoop 7, the loop form that made the strap vibrate non-stop.
    static func mayArmFirmwareAlarm(family: DeviceFamily) -> Bool { family == .whoop4 }
}

import Foundation
import WhoopProtocol

/// Pure decisions behind the dependable wake alarm (firmware alarm + Mac-driven haptic fallback).
///
/// The strap's firmware alarm is a single absolute instant and its firing is unconfirmed on a WHOOP 5/MG,
/// so the Mac (which stays awake/connected overnight) runs its own timer for the same instant and plays a
/// haptic wake pattern if the firmware did not fire. Everything that can be decided without a clock, a
/// timer or a strap lives here so it can be unit-tested against a fixed `now`.
enum WakeAlarmPolicy {

    // MARK: Feature availability

    /// The wake alarm was removed from the macOS app: a real WHOOP 5.0 (fw 50.42.1.0) vibrated non-stop for
    /// ~20 minutes after the firmware alarm / long haptic loop was armed and ignored every stop command.
    /// On macOS the Smart Alarm screen is hidden, nothing arms the strap, and the Mac fallback never rings.
    static let removedOnThisPlatform: Bool = {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }()

    /// The alarm-enabled flag that may actually drive anything. A stale persisted `true` (from before the
    /// removal) is ignored where the feature is removed.
    static func effectiveEnabled(stored: Bool, removed: Bool = removedOnThisPlatform) -> Bool {
        !removed && stored
    }

    /// Whether SET_ALARM_TIME may ever be sent to a strap of this family. Never on a WHOOP 5/MG: the rev-4
    /// body carries overallLoop 7, the loop form that made the strap vibrate non-stop.
    static func mayArmFirmwareAlarm(family: DeviceFamily) -> Bool { family == .whoop4 }

    // MARK: Constants

    /// If the firmware reported its alarm within this window before the fallback timer fires, the strap
    /// already woke the user and the Mac stays quiet.
    static let firmwareConfirmationWindow: TimeInterval = 2 * 60
    /// Buzzes per round (a burst). On WHOOP 5.0 one `buzz()` is a single short haptic pulse, so a round
    /// is several pulses in quick succession to actually wake someone.
    static let burstBuzzCount = 3
    /// Gap between two buzzes inside one burst.
    static let burstSpacing: TimeInterval = 1
    /// Gap between the START of two consecutive rounds.
    static let roundInterval: TimeInterval = 30
    /// Rounds in one real alarm run (the first one is immediate).
    static let maxRounds = 5
    /// Rounds played by the manual "Test" button.
    static let testRounds = 1
    /// An alarm instant that passed at most this long ago and was not handled yet (e.g. a re-bond called
    /// `applySmartAlarm()` between the instant and the timer's actual fire) is still fired, not skipped.
    static let reconnectGrace: TimeInterval = 60
    /// Timer slack handed to the OS (≤ 5 s so the alarm is never noticeably late).
    static let timerTolerance: TimeInterval = 5
    /// A fallback timer that fires later than this after its scheduled instant (typically a Mac that
    /// slept through the alarm) is not played any more: buzzing the wrist hours late is worse than silence.
    static let maxLateness: TimeInterval = 10 * 60

    // MARK: Scheduling

    /// The next instant the Mac fallback timer should fire, or nil when the alarm is off or no enabled
    /// weekday exists. Same date math as the firmware arm (`AppModel.nextSmartAlarmDate`).
    static func nextFireDate(enabled: Bool,
                             minutes: Int,
                             weekdays: Set<Int>,
                             from now: Date = Date(),
                             calendar: Calendar = .current) -> Date? {
        guard enabled else { return nil }
        return AppModel.nextSmartAlarmDate(minutes: minutes, weekdays: weekdays,
                                           from: now, calendar: calendar)
    }

    /// What the scheduler does with the alarm after a (re)schedule request.
    enum ScheduleDecision: Equatable {
        /// Fire this still-pending instant immediately (it just passed and was not handled).
        case fireNow(Date)
        /// Arm the one-shot timer for this future instant.
        case arm(Date)
        /// Alarm off / no valid weekday: nothing to schedule.
        case none
    }

    /// Decide how to (re)schedule. A pending instant that is ≤ `reconnectGrace` in the past, not yet
    /// handled and still valid under the current settings wins over "skip to the next occurrence" — so a
    /// reconnect between T and the timer's fire cannot swallow today's fallback.
    static func scheduleDecision(pendingInstant: Date?,
                                 handledInstant: Date?,
                                 enabled: Bool,
                                 minutes: Int,
                                 weekdays: Set<Int>,
                                 now: Date,
                                 calendar: Calendar = .current) -> ScheduleDecision {
        guard let next = nextFireDate(enabled: enabled, minutes: minutes, weekdays: weekdays,
                                      from: now, calendar: calendar) else { return .none }
        if let pending = pendingInstant,
           pending != handledInstant,
           pending <= now,
           now.timeIntervalSince(pending) <= reconnectGrace,
           // Still an instant the current settings would produce (settings may have just been edited).
           nextFireDate(enabled: enabled, minutes: minutes, weekdays: weekdays,
                        from: pending.addingTimeInterval(-1), calendar: calendar) == pending {
            return .fireNow(pending)
        }
        return .arm(next)
    }

    // MARK: Fire decision

    enum FireDecision: Equatable {
        /// Run the haptic wake pattern.
        case fire
        /// The firmware alarm was observed just before — nothing to do.
        case firmwareAlreadyFired
        /// The timer fired far too late (Mac slept through it) — do not buzz.
        case tooLate
    }

    /// Decide what the fallback timer does when it fires for `scheduledFor` at `now`.
    static func decideFallback(scheduledFor: Date,
                               now: Date,
                               lastFirmwareFiredAt: Date?) -> FireDecision {
        if now.timeIntervalSince(scheduledFor) > maxLateness { return .tooLate }
        if let fired = lastFirmwareFiredAt, wasRecentFirmwareFire(fired, now: now) {
            return .firmwareAlreadyFired
        }
        return .fire
    }

    /// Convenience: true exactly when the fallback pattern should run.
    static func shouldFallbackFire(scheduledFor: Date, now: Date, lastFirmwareFiredAt: Date?) -> Bool {
        decideFallback(scheduledFor: scheduledFor, now: now, lastFirmwareFiredAt: lastFirmwareFiredAt) == .fire
    }

    /// True when `firedAt` is within the confirmation window before `now` (a timestamp slightly in the
    /// future, e.g. from clock jitter, counts as recent).
    static func wasRecentFirmwareFire(_ firedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(firedAt) <= firmwareConfirmationWindow
    }

    // MARK: Firmware event while the Mac pattern rings

    enum FirmwareEventAction: Equatable {
        /// No Mac pattern is playing — nothing to stop.
        case nothingRinging
        /// The real Mac pattern is ringing for an instant the firmware just also announced: stop it, the
        /// strap already woke the user (avoids a double wake).
        case stopMacPattern
        /// Keep ringing (manual test, or the firmware event is unrelated to the ringing instant).
        case keepRinging
    }

    /// Decide what to do when the firmware alarm event arrives. `ringingInstant` is the scheduled instant
    /// T of the running real (non-test) pattern.
    static func firmwareEventAction(macPatternRinging: Bool,
                                    isTest: Bool,
                                    ringingInstant: Date?,
                                    now: Date) -> FirmwareEventAction {
        guard macPatternRinging else { return .nothingRinging }
        guard !isTest, let t = ringingInstant,
              now.timeIntervalSince(t) < firmwareConfirmationWindow else { return .keepRinging }
        return .stopMacPattern
    }

    // MARK: Pattern

    /// Rounds a run plays: one for the manual test, `maxRounds` for a real alarm.
    static func rounds(isTest: Bool) -> Int { isTest ? testRounds : maxRounds }

    /// Duration of one burst, first to last buzz.
    static var burstDuration: TimeInterval { TimeInterval(max(burstBuzzCount - 1, 0)) * burstSpacing }

    /// Delay after buzz number `buzzIndex` (0-based) inside a burst, or nil after the last buzz.
    static func delayAfterBuzz(inBurstIndex buzzIndex: Int) -> TimeInterval? {
        buzzIndex + 1 < burstBuzzCount ? burstSpacing : nil
    }

    /// Delay after the burst of round number `roundsSent` (1-based, i.e. rounds already played) so the
    /// next round STARTS `roundInterval` after the previous one started; nil when the run is complete.
    static func delayAfterRound(roundsSent: Int, totalRounds: Int) -> TimeInterval? {
        roundsSent < totalRounds ? max(roundInterval - burstDuration, 0) : nil
    }

    /// Offsets (seconds from the start of the run) of every buzz of a run — the full pattern timeline.
    static func buzzOffsets(totalRounds: Int) -> [TimeInterval] {
        (0..<max(totalRounds, 0)).flatMap { round in
            (0..<burstBuzzCount).map { TimeInterval(round) * roundInterval + TimeInterval($0) * burstSpacing }
        }
    }

    // MARK: Result (surfaced in the UI)

    enum Outcome: Equatable {
        /// The pattern ran to the end.
        case completed(buzzes: Int)
        /// The user stopped it with a strap double-tap.
        case stoppedByDoubleTap(buzzes: Int)
        /// The user pressed Stop in the app.
        case stoppedInApp(buzzes: Int)
        /// The strap's firmware alarm fired (before the Mac pattern, or while it was ringing and was
        /// stopped), the Mac had nothing more to do.
        case firmwareHandled
        /// The alarm time came but the strap was not connected.
        case strapNotConnected
        /// The Mac was asleep through the alarm time.
        case missedWhileAsleep
    }

    struct Record: Equatable {
        let date: Date
        let outcome: Outcome
        let isTest: Bool
    }
}

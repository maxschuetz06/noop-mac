import XCTest
import WhoopProtocol
@testable import Strand

/// Pure decisions behind the dependable wake alarm: next fire instant, whether the Mac fallback should
/// buzz given the firmware's last fire, and the buzz repeat schedule.
final class WakeAlarmPolicyTests: XCTestCase {

    /// Fixed UTC calendar so the math is deterministic regardless of the test machine's zone.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 2026-06-17 is a Wednesday (weekday 4).
    private func wed(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: hour, minute: minute, second: second))!
    }

    // MARK: nextFireDate

    func testNextFireDate_disabledIsNil() {
        XCTAssertNil(WakeAlarmPolicy.nextFireDate(enabled: false, minutes: 6 * 60 + 30, weekdays: [],
                                                  from: wed(5, 0), calendar: cal))
    }

    func testNextFireDate_matchesNextSmartAlarmDate() {
        let now = wed(5, 0)
        let expected = AppModel.nextSmartAlarmDate(minutes: 6 * 60 + 30, weekdays: [4], from: now, calendar: cal)
        XCTAssertEqual(WakeAlarmPolicy.nextFireDate(enabled: true, minutes: 6 * 60 + 30, weekdays: [4],
                                                    from: now, calendar: cal), expected)
        XCTAssertEqual(expected, wed(6, 30))
    }

    func testNextFireDate_afterTodaysTimeRollsToNextEnabledDay() {
        // Wed 07:00, alarm 06:30 on Wednesdays only → next Wednesday.
        let next = WakeAlarmPolicy.nextFireDate(enabled: true, minutes: 6 * 60 + 30, weekdays: [4],
                                                from: wed(7, 0), calendar: cal)
        XCTAssertEqual(next, cal.date(byAdding: .day, value: 7, to: wed(6, 30)))
    }

    func testNextFireDate_noValidWeekdayIsNil() {
        XCTAssertNil(WakeAlarmPolicy.nextFireDate(enabled: true, minutes: 6 * 60, weekdays: [0, 9],
                                                  from: wed(5, 0), calendar: cal))
    }

    // MARK: decideFallback / shouldFallbackFire

    func testFallbackFires_whenFirmwareNeverReported() {
        let at = wed(6, 30)
        XCTAssertEqual(WakeAlarmPolicy.decideFallback(scheduledFor: at, now: at, lastFirmwareFiredAt: nil), .fire)
        XCTAssertTrue(WakeAlarmPolicy.shouldFallbackFire(scheduledFor: at, now: at, lastFirmwareFiredAt: nil))
    }

    func testFallbackQuiet_whenFirmwareFiredWithinTwoMinutes() {
        let at = wed(6, 30)
        let fired = at.addingTimeInterval(-30)
        XCTAssertEqual(WakeAlarmPolicy.decideFallback(scheduledFor: at, now: at, lastFirmwareFiredAt: fired),
                       .firmwareAlreadyFired)
        XCTAssertFalse(WakeAlarmPolicy.shouldFallbackFire(scheduledFor: at, now: at, lastFirmwareFiredAt: fired))
    }

    func testFallbackQuiet_atExactlyTwoMinutes_butFiresJustBeyond() {
        let at = wed(6, 30)
        let edge = at.addingTimeInterval(-WakeAlarmPolicy.firmwareConfirmationWindow)
        XCTAssertEqual(WakeAlarmPolicy.decideFallback(scheduledFor: at, now: at, lastFirmwareFiredAt: edge),
                       .firmwareAlreadyFired)
        let stale = at.addingTimeInterval(-WakeAlarmPolicy.firmwareConfirmationWindow - 1)
        XCTAssertEqual(WakeAlarmPolicy.decideFallback(scheduledFor: at, now: at, lastFirmwareFiredAt: stale), .fire)
    }

    func testFallbackFires_whenFirmwareFireIsFromYesterday() {
        let at = wed(6, 30)
        let yesterday = at.addingTimeInterval(-24 * 3600)
        XCTAssertEqual(WakeAlarmPolicy.decideFallback(scheduledFor: at, now: at, lastFirmwareFiredAt: yesterday), .fire)
    }

    func testFallbackQuiet_whenFirmwareEventSlightlyInFuture() {
        // Clock jitter: strap event stamped a moment after the Mac's "now" still counts as recent.
        let at = wed(6, 30)
        XCTAssertEqual(WakeAlarmPolicy.decideFallback(scheduledFor: at, now: at,
                                                      lastFirmwareFiredAt: at.addingTimeInterval(2)),
                       .firmwareAlreadyFired)
    }

    func testFallbackTooLate_whenMacSleptThroughAlarm() {
        let at = wed(6, 30)
        let late = at.addingTimeInterval(WakeAlarmPolicy.maxLateness + 1)
        XCTAssertEqual(WakeAlarmPolicy.decideFallback(scheduledFor: at, now: late, lastFirmwareFiredAt: nil), .tooLate)
    }

    func testFallbackStillFires_whenSlightlyLate() {
        let at = wed(6, 30)
        let late = at.addingTimeInterval(WakeAlarmPolicy.maxLateness)
        XCTAssertEqual(WakeAlarmPolicy.decideFallback(scheduledFor: at, now: late, lastFirmwareFiredAt: nil), .fire)
    }

    // MARK: scheduleDecision (reconnect-safe)

    private func decision(pending: Date?, handled: Date? = nil, now: Date,
                          enabled: Bool = true, minutes: Int = 6 * 60 + 30) -> WakeAlarmPolicy.ScheduleDecision {
        WakeAlarmPolicy.scheduleDecision(pendingInstant: pending, handledInstant: handled, enabled: enabled,
                                         minutes: minutes, weekdays: [], now: now, calendar: cal)
    }

    func testSchedule_futureInstantIsArmed() {
        XCTAssertEqual(decision(pending: nil, now: wed(5, 0)), .arm(wed(6, 30)))
        XCTAssertEqual(decision(pending: wed(6, 30), now: wed(6, 29, 59)), .arm(wed(6, 30)))
    }

    func testSchedule_justPassedUnhandledInstantFiresNow_notTomorrow() {
        // Re-bond 3 s after T, timer not fired yet → keep today's alarm.
        XCTAssertEqual(decision(pending: wed(6, 30), now: wed(6, 30, 3)), .fireNow(wed(6, 30)))
        // Exactly at the grace edge still fires.
        XCTAssertEqual(decision(pending: wed(6, 30), now: wed(6, 31, 0)), .fireNow(wed(6, 30)))
    }

    func testSchedule_beyondGraceSkipsToNextOccurrence() {
        let tomorrow = cal.date(byAdding: .day, value: 1, to: wed(6, 30))!
        XCTAssertEqual(decision(pending: wed(6, 30), now: wed(6, 31, 1)), .arm(tomorrow))
    }

    func testSchedule_alreadyHandledInstantIsNotFiredAgain() {
        let tomorrow = cal.date(byAdding: .day, value: 1, to: wed(6, 30))!
        XCTAssertEqual(decision(pending: wed(6, 30), handled: wed(6, 30), now: wed(6, 30, 3)), .arm(tomorrow))
    }

    func testSchedule_disabledOrNoWeekdayIsNone_evenWithPendingInstant() {
        XCTAssertEqual(decision(pending: wed(6, 30), now: wed(6, 30, 3), enabled: false), .none)
        XCTAssertEqual(WakeAlarmPolicy.scheduleDecision(pendingInstant: wed(6, 30), handledInstant: nil,
                                                        enabled: true, minutes: 390, weekdays: [0, 9],
                                                        now: wed(6, 30, 3), calendar: cal), .none)
    }

    func testSchedule_pendingInstantNoLongerMatchingSettingsIsDropped() {
        // User moved the alarm to 07:00 right after 06:30 passed → don't fire the stale 06:30.
        XCTAssertEqual(decision(pending: wed(6, 30), now: wed(6, 30, 3), minutes: 7 * 60), .arm(wed(7, 0)))
    }

    // MARK: firmwareEventAction (no double wake)

    func testFirmwareEvent_stopsMacPatternWithinTwoMinutesOfInstant() {
        let t = wed(6, 30)
        for dt in [0.0, 5, 60, 119] {
            XCTAssertEqual(WakeAlarmPolicy.firmwareEventAction(macPatternRinging: true, isTest: false,
                                                               ringingInstant: t, now: t.addingTimeInterval(dt)),
                           .stopMacPattern, "dt=\(dt)")
        }
    }

    func testFirmwareEvent_keepsRingingAtOrBeyondTwoMinutes() {
        let t = wed(6, 30)
        XCTAssertEqual(WakeAlarmPolicy.firmwareEventAction(macPatternRinging: true, isTest: false,
                                                           ringingInstant: t, now: t.addingTimeInterval(120)),
                       .keepRinging)
        XCTAssertEqual(WakeAlarmPolicy.firmwareEventAction(macPatternRinging: true, isTest: false,
                                                           ringingInstant: t, now: t.addingTimeInterval(300)),
                       .keepRinging)
    }

    func testFirmwareEvent_neverStopsManualTestOrUnknownInstant() {
        let t = wed(6, 30)
        XCTAssertEqual(WakeAlarmPolicy.firmwareEventAction(macPatternRinging: true, isTest: true,
                                                           ringingInstant: t, now: t), .keepRinging)
        XCTAssertEqual(WakeAlarmPolicy.firmwareEventAction(macPatternRinging: true, isTest: false,
                                                           ringingInstant: nil, now: t), .keepRinging)
    }

    func testFirmwareEvent_nothingRingingWhenIdle() {
        XCTAssertEqual(WakeAlarmPolicy.firmwareEventAction(macPatternRinging: false, isTest: false,
                                                           ringingInstant: nil, now: wed(6, 30)), .nothingRinging)
    }

    // MARK: pattern schedule (bursts)

    func testPatternConstants() {
        XCTAssertEqual(WakeAlarmPolicy.burstBuzzCount, 3)
        XCTAssertEqual(WakeAlarmPolicy.burstSpacing, 1)
        XCTAssertEqual(WakeAlarmPolicy.roundInterval, 30)
        XCTAssertEqual(WakeAlarmPolicy.maxRounds, 5)
        XCTAssertEqual(WakeAlarmPolicy.testRounds, 1)
        XCTAssertEqual(WakeAlarmPolicy.reconnectGrace, 60)
        XCTAssertEqual(WakeAlarmPolicy.firmwareConfirmationWindow, 120)
        XCTAssertLessThanOrEqual(WakeAlarmPolicy.timerTolerance, 5)
    }

    func testRounds_testIsOneRealIsFive() {
        XCTAssertEqual(WakeAlarmPolicy.rounds(isTest: true), 1)
        XCTAssertEqual(WakeAlarmPolicy.rounds(isTest: false), 5)
    }

    func testDelayInsideBurst_spacedUntilLastBuzz() {
        XCTAssertEqual(WakeAlarmPolicy.delayAfterBuzz(inBurstIndex: 0), 1)
        XCTAssertEqual(WakeAlarmPolicy.delayAfterBuzz(inBurstIndex: 1), 1)
        XCTAssertNil(WakeAlarmPolicy.delayAfterBuzz(inBurstIndex: 2))
    }

    func testDelayAfterRound_keepsThirtySecondCadenceUntilLastRound() {
        // Burst takes 2 s, so 28 s remain until the next round starts (30 s start-to-start).
        for sent in 1..<WakeAlarmPolicy.maxRounds {
            XCTAssertEqual(WakeAlarmPolicy.delayAfterRound(roundsSent: sent, totalRounds: 5), 28, "after round \(sent)")
        }
        XCTAssertNil(WakeAlarmPolicy.delayAfterRound(roundsSent: 5, totalRounds: 5))
        XCTAssertNil(WakeAlarmPolicy.delayAfterRound(roundsSent: 1, totalRounds: 1))   // test: one round only
    }

    func testBuzzOffsets_realRunIsFifteenBuzzesOverTwoMinutes() {
        let offsets = WakeAlarmPolicy.buzzOffsets(totalRounds: 5)
        XCTAssertEqual(offsets.count, 15)
        XCTAssertEqual(Array(offsets.prefix(4)), [0, 1, 2, 30])
        XCTAssertEqual(offsets.last, 122)
    }

    func testBuzzOffsets_testRunIsOneBurst() {
        XCTAssertEqual(WakeAlarmPolicy.buzzOffsets(totalRounds: WakeAlarmPolicy.rounds(isTest: true)), [0, 1, 2])
    }
}

/// The wake alarm is removed on macOS (WHOOP 5.0 non-stop vibration incident): nothing may arm or ring it.
final class WakeAlarmRemovalTests: XCTestCase {

    func testWakeAlarmIsRemovedOnMacOS() {
        #if os(macOS)
        XCTAssertTrue(WakeAlarmPolicy.removedOnThisPlatform)
        #else
        XCTAssertFalse(WakeAlarmPolicy.removedOnThisPlatform)
        #endif
    }

    func testStalePersistedEnabledFlagIsIgnoredWhereRemoved() {
        XCTAssertFalse(WakeAlarmPolicy.effectiveEnabled(stored: true, removed: true))
        XCTAssertFalse(WakeAlarmPolicy.effectiveEnabled(stored: false, removed: true))
    }

    func testStoredFlagStillDrivesTheAlarmWhereNotRemoved() {
        XCTAssertTrue(WakeAlarmPolicy.effectiveEnabled(stored: true, removed: false))
        XCTAssertFalse(WakeAlarmPolicy.effectiveEnabled(stored: false, removed: false))
    }

    func testWhoop5MayNeverArmTheFirmwareAlarm() {
        XCTAssertFalse(WakeAlarmPolicy.mayArmFirmwareAlarm(family: .whoop5))
        XCTAssertTrue(WakeAlarmPolicy.mayArmFirmwareAlarm(family: .whoop4))
    }

    func testDisableRev2IsTheClearingBody() {
        XCTAssertEqual(AlarmPayload.disableRev2(), [0x02, 0xFF])
    }
}

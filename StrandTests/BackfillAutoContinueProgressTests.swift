import XCTest
@testable import Strand

/// The auto-continue decision after the WHOOP 5/MG 50.42.x finding: the strap slices a deep backlog into many
/// tiny sessions (~15 strap-seconds each), so (a) the "is there backlog" test must use the HISTORY frontier —
/// max HR ts is dragged to "now" by the live 0x2A37 stream — and (b) a healthy drain must not be cut off by a
/// per-connection cap of 6; it continues while EVERY session shows progress (trim advanced + new rows + history
/// frontier moved), stops on a frozen cursor / no rows / stalled frontier, and keeps a large safety bound.
final class BackfillAutoContinueProgressTests: XCTestCase {

    private let now = 1_800_000_000

    /// A healthy session result: trim moved, rows landed, the history frontier moved.
    private func decide(frontier: Int?, newest: Int? = 1_800_000_000, rows: Int = 240, trim: Bool = true,
                        frontierAdvanced: Bool = true, count: Int = 0, elapsed: TimeInterval = 0,
                        connected: Bool = true) -> BackfillContinuation.Decision {
        BackfillContinuation.decide(stillConnected: connected, now: now, strapNewestTs: newest, ourFrontierTs: frontier,
                                    rowsPersistedThisSession: rows, lastTrimAdvanced: trim,
                                    historyFrontierAdvanced: frontierAdvanced, consecutiveCount: count,
                                    streakElapsedSeconds: elapsed)
    }

    // MARK: live HR at "now" must not stop the drain

    func testHistoryFrontierDaysBehindKeepsDrainingWhileLiveHrIsAtNow() {
        let historyFrontier = now - 5 * 86_400      // offload is 5 days behind (newest gravity / strap-state row)
        XCTAssertEqual(decide(frontier: historyFrontier), .proceed)
    }

    /// Documents WHY the frontier source matters: fed the live-HR-driven "max HR ts" (== now) the very same
    /// healthy session reads as "caught up" and the drain would stop after one slice.
    func testHrFrontierPinnedToNowWouldHaveReadAsCaughtUp() {
        XCTAssertEqual(decide(frontier: now), .stop(.caughtUp))
    }

    func testReachingTheStrapsNewestStopsAsCaughtUp() {
        XCTAssertEqual(decide(frontier: now - 60), .stop(.caughtUp))
        // Strap says it is 5+ min ahead, but the frontier is still inside the 10-min wall-clock live edge.
        XCTAssertEqual(decide(frontier: now - 301), .stop(.caughtUp))
        XCTAssertEqual(decide(frontier: now - 601), .proceed)
    }

    func testStaleStrapNewestIsIgnoredWhenProgressIsProven() {
        // GET_DATA_RANGE latched an old epoch (#451): newest far older than our frontier.
        XCTAssertEqual(decide(frontier: now - 86_400, newest: now - 400 * 86_400), .proceed)
    }

    func testUnknownRangeOrFrontierStillDrainsOnProvenProgress() {
        // Unknown range + far behind the wall clock ⇒ real backlog is flowing ⇒ proceed.
        XCTAssertEqual(decide(frontier: now - 86_400, newest: nil), .proceed)
        XCTAssertEqual(decide(frontier: nil), .proceed)   // nothing persisted yet / read unavailable
    }

    /// WHOOP 5/MG regression: `strapNewestTs` is never set, and a worn caught-up strap yields fresh seconds on
    /// every re-kick (rows + trim + frontier all "advance"). Only the wall clock can end that streak.
    func testUnknownRangeWithFrontierNearNowStopsAsCaughtUp() {
        XCTAssertEqual(decide(frontier: now - 30, newest: nil), .stop(.caughtUp))
        XCTAssertEqual(decide(frontier: now - 599, newest: nil), .stop(.caughtUp))
        XCTAssertEqual(decide(frontier: now, newest: nil), .stop(.caughtUp))
        XCTAssertEqual(decide(frontier: now - 601, newest: nil), .proceed)
        // A stale/wrong-epoch range must not mask the wall-clock live edge either.
        XCTAssertEqual(decide(frontier: now - 30, newest: now - 400 * 86_400), .stop(.caughtUp))
    }

    // MARK: no progress ⇒ stop (spin guard)

    func testFrozenTrimStopsEvenWithRowsAndFrontierBehind() {
        XCTAssertEqual(decide(frontier: now - 86_400, trim: false), .stop(.trimFrozen))
    }

    func testZeroRowsStopsEvenIfTrimAdvancedAndStrapIsAhead() {
        // Empty / console-only ENDs advance the trim u32 without delivering anything.
        XCTAssertEqual(decide(frontier: now - 86_400, rows: 0), .stop(.noRowsPersisted))
    }

    func testStalledHistoryFrontierStops() {
        // Rows landed but nothing newer than the frontier we started from (re-sent / older rows only).
        XCTAssertEqual(decide(frontier: now - 86_400, frontierAdvanced: false), .stop(.frontierStalled))
    }

    func testDisconnectedWinsOverEverything() {
        XCTAssertEqual(decide(frontier: now - 86_400, connected: false), .stop(.disconnected))
    }

    // MARK: safety bound

    func testCapIsLargeAndRespected() {
        let cap = BackfillContinuation.defaultMaxAutoContinues
        XCTAssertGreaterThan(cap, 6, "the old per-connection cap of 6 throttled a healthy sliced drain")
        XCTAssertEqual(decide(frontier: now - 86_400, count: cap - 1), .proceed)
        XCTAssertEqual(decide(frontier: now - 86_400, count: cap), .stop(.capReached))
        XCTAssertEqual(decide(frontier: now - 86_400, count: cap + 3), .stop(.capReached))
    }

    func testWallTimeBudgetIsRespected() {
        let budget = BackfillContinuation.defaultStreakBudgetSeconds
        XCTAssertEqual(decide(frontier: now - 86_400, elapsed: budget - 1), .proceed)
        XCTAssertEqual(decide(frontier: now - 86_400, elapsed: budget), .stop(.budgetExhausted))
    }

    // MARK: simulated sliced drain

    /// The field case: ~12 h of backlog, ~17 strap-seconds per session. Every session shows progress, so the
    /// drain runs far past 6 sessions and ends only when it is level with the strap's newest record.
    func testSlicedTwelveHourBacklogDrainsToCaughtUpPastTheOldCap() {
        var frontier = now - 12 * 3600
        var sessions = 0, count = 0
        var elapsed: TimeInterval = 0
        while case .proceed = BackfillContinuation.decide(
            stillConnected: true, now: now, strapNewestTs: now, ourFrontierTs: frontier, rowsPersistedThisSession: 17,
            lastTrimAdvanced: true, historyFrontierAdvanced: true, consecutiveCount: count,
            streakElapsedSeconds: elapsed) {
            frontier += 17
            count += 1
            sessions += 1
            elapsed += 2          // a couple of seconds per tiny session
            XCTAssertLessThan(sessions, 10_000, "must terminate")
        }
        XCTAssertGreaterThan(sessions, 6)
        XCTAssertGreaterThanOrEqual(frontier, now - BackfillContinuation.defaultWallClockBehindSeconds,
                                    "stopped because it caught up, not because of a bound")
        XCTAssertLessThan(count, BackfillContinuation.defaultMaxAutoContinues + 1)
    }

    /// A strap that keeps "progressing" forever is still bounded by the cap / budget.
    func testEndlessFakeProgressIsBounded() {
        var count = 0
        var elapsed: TimeInterval = 0
        while case .proceed = BackfillContinuation.decide(
            stillConnected: true, now: now, strapNewestTs: now, ourFrontierTs: now - 30 * 86_400, rowsPersistedThisSession: 5,
            lastTrimAdvanced: true, historyFrontierAdvanced: true, consecutiveCount: count,
            streakElapsedSeconds: elapsed) {
            count += 1
            elapsed += 2
            XCTAssertLessThan(count, 100_000)
        }
        XCTAssertLessThanOrEqual(count, BackfillContinuation.defaultMaxAutoContinues)
    }

    /// The Bool form stays in lock-step with `decide`.
    func testBooleanFormMatchesDecision() {
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: now, strapNewestTs: now, ourFrontierTs: now - 86_400,
            rowsPersistedThisSession: 10, lastTrimAdvanced: true, consecutiveCount: 0))
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: now, strapNewestTs: now, ourFrontierTs: now - 86_400,
            rowsPersistedThisSession: 10, lastTrimAdvanced: false, consecutiveCount: 0))
    }
}

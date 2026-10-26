import XCTest
@testable import Strand

/// Pins the #364 historical-sync auto-continue decision. The real bug: the strap offloads OLDEST-first
/// at ~60s/session with a 15-min floor and NO auto-continue, so on a deep backlog each connection drains
/// only one oldest pass then waits — "last night" can take many connections to reach even while the
/// strap stays connected. `BackfillContinuation.shouldAutoContinue` decides whether a session that ended
/// on the 60s IDLE cap (not a true HISTORY_COMPLETE) should immediately re-kick instead of tearing down
/// to the floor. Pure value type → no CoreBluetooth seam needed (mirrors MarginalRadioDetectorTests).
final class BackfillContinuationTests: XCTestCase {

    /// The happy path: still connected, the strap is well ahead of our frontier, the trim advanced this
    /// session, and we're under the cap ⇒ continue immediately.
    func testContinuesWhenConnectedBehindAndAdvancing() {
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: 1_800_000_000,
            strapNewestTs: 1_800_000_000,            // strap newest
            ourFrontierTs: 1_800_000_000 - 86_400,   // our frontier a full day behind
            rowsPersistedThisSession: 100,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// A dropped link must NOT auto-continue — the normal reconnect path owns it.
    func testStopsWhenDisconnected() {
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: false, now: 1_800_000_000,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// Caught up: the strap is NOT meaningfully ahead of our frontier ⇒ nothing left to fetch, don't spin.
    func testStopsWhenCaughtUp() {
        // Within the behind-gap (300s default): treat as caught up.
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: 1_800_000_000,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 120,      // only 2 min behind, under the 5-min gap
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// Exactly at the gap boundary is NOT "behind" (strictly-greater), so it stops — caught-up wins ties.
    func testGapBoundaryIsNotBehind() {
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: 1_800_000_000,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 300,      // exactly the 300s gap
            rowsPersistedThisSession: 100,
            lastTrimAdvanced: true,
            consecutiveCount: 0,
            behindGapSeconds: 300,
            wallClockBehindSeconds: 0))     // isolate the strap-range gap from the wall-clock live edge
        // One second past the gap IS behind.
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: 1_800_000_000,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 301,
            rowsPersistedThisSession: 100,
            lastTrimAdvanced: true,
            consecutiveCount: 0,
            behindGapSeconds: 300,
            wallClockBehindSeconds: 0))     // isolate the strap-range gap from the wall-clock live edge
    }

    /// The spin-detector: if the trim cursor did NOT advance this session (strap handing back
    /// console-only / refusing to trim), re-kicking would loop forever — so stop even though we're behind.
    func testStopsWhenTrimFrozen() {
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: 1_800_000_000,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            lastTrimAdvanced: false,                 // frozen cursor
            consecutiveCount: 0))
    }

    /// The hard per-connection cap: once we've already auto-continued maxAutoContinues times, stop and
    /// let the 15-min floor take over — a pathological strap can't pin the radio.
    func testStopsAtCap() {
        let cap = BackfillContinuation.defaultMaxAutoContinues
        // One below the cap still continues.
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: 1_800_000_000,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            rowsPersistedThisSession: 100,
            lastTrimAdvanced: true,
            consecutiveCount: cap - 1))
        // At the cap, stop.
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: 1_800_000_000,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            rowsPersistedThisSession: 100,
            lastTrimAdvanced: true,
            consecutiveCount: cap))
        // Above the cap, still stop.
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: 1_800_000_000,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 86_400,
            rowsPersistedThisSession: 100,
            lastTrimAdvanced: true,
            consecutiveCount: cap + 5))
    }

    /// Unknown range (no GET_DATA_RANGE yet) or unknown frontier (nothing persisted yet) WITHOUT any proof of
    /// flowing backlog: this session persisted ZERO rows, so there is nothing to continue on ⇒ stop and let the
    /// periodic floor handle it. (With rows flowing the same unknowns correctly keep draining — see
    /// `testContinuesWhenRangeUnknownButRowsFlowing`; this test pins the no-rows side explicitly.)
    func testStopsWhenRangeUnknownAndNoRowsPersisted() {
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: 1_800_000_000,
            strapNewestTs: nil,                       // no GET_DATA_RANGE answer
            ourFrontierTs: 1_700_000_000,
            rowsPersistedThisSession: 0,              // nothing persisted ⇒ no proof of backlog
            lastTrimAdvanced: true,
            consecutiveCount: 0))
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: 1_800_000_000,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: nil,                       // nothing persisted yet
            rowsPersistedThisSession: 0,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// WHOOP 5/MG never learns `strapNewestTs`: a worn, caught-up strap hands over fresh seconds every
    /// re-kick. The wall-clock check must end the streak on its own (no GET_DATA_RANGE needed).
    func testWallClockCaughtUpStopsWithoutAnyRangeAnswer() {
        XCTAssertEqual(BackfillContinuation.decide(
            stillConnected: true, now: 1_800_000_000,
            strapNewestTs: nil,
            ourFrontierTs: 1_800_000_000 - 120,       // 2 min behind the wall clock
            rowsPersistedThisSession: 17,             // fresh seconds again
            lastTrimAdvanced: true,
            consecutiveCount: 3), .stop(.caughtUp))
    }

    /// #451: GET_DATA_RANGE latched a STALE / wrong-epoch "newest" (e.g. a 2024 value when the real newest
    /// is 2026), which reads as BEHIND our frontier — the 2a "strap ahead" test fails and the old code
    /// concluded "caught up" and stopped after ONE session. But the trim advanced AND this session
    /// persisted real sensor rows, so the strap is demonstrably still handing over backlog ⇒ continue.
    func testContinuesWhenNewestStaleButRowsFlowing() {
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: 1_800_000_000,
            strapNewestTs: 1_700_000_000,            // stale 2023/24-epoch range answer…
            ourFrontierTs: 1_800_000_000 - 86_400,   // …reads as BEHIND our real frontier (a day short of now)
            rowsPersistedThisSession: 240,           // but real rows came in this pass
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// The discriminator that keeps the #451 fallback safe: a genuinely caught-up / console-only strap
    /// persists ZERO rows, so even with the trim nudging it must NOT spin — the 0-row fallback returns false.
    func testStopsWhenNewestStaleAndNoRows() {
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: 1_800_000_000,
            strapNewestTs: 1_700_000_000,            // stale/behind range answer
            ourFrontierTs: 1_800_000_000,
            rowsPersistedThisSession: 0,             // nothing actually persisted ⇒ caught up / stuck
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// GET_DATA_RANGE not answered at all (nil) but real rows are flowing and the trim advanced ⇒ keep
    /// draining. Without the rows fallback this would have stalled on the unknown-range guard.
    func testContinuesWhenRangeUnknownButRowsFlowing() {
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: 1_800_000_000,
            strapNewestTs: nil,                       // no GET_DATA_RANGE answer
            ourFrontierTs: 1_800_000_000 - 86_400,    // a day behind the wall clock ⇒ real backlog remains
            rowsPersistedThisSession: 180,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// The rows-flowing fallback never overrides the earlier guards: a frozen trim, the cap, and a dropped
    /// link still stop even with rows > 0 (guards 1/3/4 are checked before 2b).
    func testRowsFallbackStillRespectsHardGuards() {
        // Frozen trim wins over rows.
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: 1_800_000_000,
            strapNewestTs: 1_700_000_000,
            ourFrontierTs: 1_800_000_000,
            rowsPersistedThisSession: 240,
            lastTrimAdvanced: false,                  // frozen cursor
            consecutiveCount: 0))
        // The cap wins over rows.
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: 1_800_000_000,
            strapNewestTs: 1_700_000_000,
            ourFrontierTs: 1_800_000_000,
            rowsPersistedThisSession: 240,
            lastTrimAdvanced: true,
            consecutiveCount: BackfillContinuation.defaultMaxAutoContinues))
        // A dropped link wins over rows.
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: false, now: 1_800_000_000,
            strapNewestTs: 1_700_000_000,
            ourFrontierTs: 1_800_000_000,
            rowsPersistedThisSession: 240,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// A multi-pass drain: a deep backlog continues pass after pass (each advancing the frontier toward
    /// the strap's newest) and stops exactly when it has caught up — it neither stalls at pass 1 nor
    /// (with the old cap of 6) gets cut off a week short.
    func testMultiPassDrainRunsUntilCaughtUp() {
        let strapNewest = 1_800_000_000
        var frontier = strapNewest - 7 * 86_400      // a full week behind
        var count = 0
        while BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: 1_800_000_000,
            strapNewestTs: strapNewest,
            ourFrontierTs: frontier,
            rowsPersistedThisSession: 100,
            lastTrimAdvanced: true,
            consecutiveCount: count) {
            // Each pass drains ~a day of the oldest backlog and counts as one auto-continue.
            frontier += 86_400
            count += 1
            XCTAssertLessThanOrEqual(count, BackfillContinuation.defaultMaxAutoContinues,
                                     "auto-continue must stay bounded")
        }
        XCTAssertEqual(count, 7, "7 day-sized passes close a 7-day gap; the 8th check sees 'caught up'")
        XCTAssertGreaterThan(count, 6, "the old per-connection cap of 6 would have cut this drain short")
    }

    // MARK: #25 — HISTORY_COMPLETE-sliced offloads

    /// #25: the user goes to bed with a charged strap, the phone dies, and overnight banks a deep backlog.
    /// Some strap firmware segments that offload into many SMALL HISTORY_COMPLETE slices rather than one
    /// long session. Before #25, exitBackfilling only auto-continued on a 60s TIMEOUT, so a strap that
    /// completed-then-stopped between slices stalled until the 15-min floor — "last night" drained an hour
    /// at a time. The predicate is reason-agnostic: a small completion that is STILL far behind the strap's
    /// newest, with the trim advancing and real rows banked, must auto-continue exactly as a timeout would.
    func testSmallHistoryCompleteStillBehindContinues() {
        XCTAssertTrue(BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: 1_800_000_000,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 6 * 3600,   // still 6 h behind after this slice
            rowsPersistedThisSession: 90,              // a small slice, but real rows landed
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// #25: the LAST slice of the overnight drain brings us level with the strap's newest record. Firing
    /// the auto-continue on HISTORY_COMPLETE must NOT spin a caught-up strap — the frontier is now within
    /// the behind-gap, so the predicate returns false and the session tears down to the periodic floor.
    func testFinalHistoryCompleteCaughtUpStops() {
        XCTAssertFalse(BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: 1_800_000_000,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 60,         // within the 5-min gap ⇒ caught up
            // A genuinely caught-up strap hands over NO new rows on the final END (empty / console-only),
            // so the #451 guard-2b "keep draining if still persisting real backlog" does not fire and the
            // predicate returns false. (12 rows + advanced trim would correctly KEEP going per #451.)
            rowsPersistedThisSession: 0,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    /// #25: a pathological strap that emits an endless run of tiny far-behind HISTORY_COMPLETE slices must
    /// still be bounded by the per-connection cap — otherwise firing on completion would let it pin the
    /// radio. Each slice persists rows and stays behind, yet the drain stops at exactly maxAutoContinues.
    func testHistoryCompleteSlicesAreCappedNotRunaway() {
        var count = 0
        var continued = 0
        while BackfillContinuation.shouldAutoContinue(
            stillConnected: true, now: 1_800_000_000,
            strapNewestTs: 1_800_000_000,
            ourFrontierTs: 1_800_000_000 - 7 * 86_400, // never catches up — frontier stays far behind
            rowsPersistedThisSession: 30,              // every tiny slice banks a few rows
            lastTrimAdvanced: true,
            consecutiveCount: count) {
            count += 1
            continued += 1
            XCTAssertLessThanOrEqual(continued, BackfillContinuation.defaultMaxAutoContinues + 1,
                                     "HISTORY_COMPLETE slices must be capped, not spin forever")
        }
        XCTAssertEqual(count, BackfillContinuation.defaultMaxAutoContinues)
    }
}

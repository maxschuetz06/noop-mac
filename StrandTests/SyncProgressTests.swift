import XCTest
import SQLite3
import WhoopProtocol
@testable import Strand

/// Long-offload visibility + per-session cost guards (synthetic values only — no health data).
final class HistoryProgressPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testDoesNotSignalBeforeTheIntervalElapsed() {
        XCTAssertFalse(HistoryProgressPolicy.shouldSignal(now: t0.addingTimeInterval(599), lastSignalAt: t0,
                                                          rowsPersisted: 500, frontierAdvanced: true))
    }

    func testSignalsOnceTheIntervalElapsedWithRealProgress() {
        XCTAssertTrue(HistoryProgressPolicy.shouldSignal(now: t0.addingTimeInterval(600), lastSignalAt: t0,
                                                         rowsPersisted: 1, frontierAdvanced: true))
        XCTAssertTrue(HistoryProgressPolicy.shouldSignal(now: t0.addingTimeInterval(3_600), lastSignalAt: t0,
                                                         rowsPersisted: 500, frontierAdvanced: true))
    }

    func testNeverSignalsWithoutNewRows() {
        XCTAssertFalse(HistoryProgressPolicy.shouldSignal(now: t0.addingTimeInterval(7_200), lastSignalAt: t0,
                                                          rowsPersisted: 0, frontierAdvanced: true))
    }

    func testNeverSignalsWhenTheHistoryFrontierDidNotAdvance() {
        // Rows landed but all older than the frontier we started from (a re-sent chunk / live-only rows).
        XCTAssertFalse(HistoryProgressPolicy.shouldSignal(now: t0.addingTimeInterval(7_200), lastSignalAt: t0,
                                                          rowsPersisted: 500, frontierAdvanced: false))
    }

    func testNoReferenceYetMeansNoSignal() {
        // BLEManager seeds the reference at the first drain start; until then there is nothing to measure.
        XCTAssertFalse(HistoryProgressPolicy.shouldSignal(now: t0, lastSignalAt: nil,
                                                          rowsPersisted: 500, frontierAdvanced: true))
    }

    func testCustomIntervalIsHonoured() {
        XCTAssertTrue(HistoryProgressPolicy.shouldSignal(now: t0.addingTimeInterval(30), lastSignalAt: t0,
                                                         rowsPersisted: 5, frontierAdvanced: true, minInterval: 30))
    }

    /// A multi-hour drain that never reaches HISTORY_COMPLETE emits a signal roughly every 10 minutes —
    /// not once per session (thousands) and not never (the bug).
    func testLongDrainSignalsAboutEveryTenMinutes() {
        var last: Date? = t0
        var signals = 0
        var now = t0
        // 5 hours of ~60 s sessions, each persisting rows and advancing the frontier.
        for _ in 0..<300 {
            now = now.addingTimeInterval(60)
            if HistoryProgressPolicy.shouldSignal(now: now, lastSignalAt: last, rowsPersisted: 200, frontierAdvanced: true) {
                signals += 1
                last = now
            }
        }
        XCTAssertEqual(signals, 30)   // 300 min / 10 min
    }
}

final class RawPrunePolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstRunIsAlwaysDue() {
        XCTAssertTrue(RawPrunePolicy.isDue(now: t0, lastPruneAt: nil))
    }

    func testNotDueWithinTheInterval() {
        XCTAssertFalse(RawPrunePolicy.isDue(now: t0.addingTimeInterval(599), lastPruneAt: t0))
        XCTAssertTrue(RawPrunePolicy.isDue(now: t0.addingTimeInterval(600), lastPruneAt: t0))
    }

    /// 1000 back-to-back short sessions used to mean 1000 full-table prunes; now it is bounded by wall time.
    func testAThousandShortSessionsPruneOnlyAHandfulOfTimes() {
        var last: Date?
        var prunes = 0
        var now = t0
        for _ in 0..<1_000 {
            now = now.addingTimeInterval(5)           // short HISTORY_COMPLETE slices, 5 s apart
            if RawPrunePolicy.isDue(now: now, lastPruneAt: last) { prunes += 1; last = now }
        }
        XCTAssertLessThanOrEqual(prunes, 9)           // 5000 s / 600 s + the first run
        XCTAssertGreaterThanOrEqual(prunes, 1)
    }
}

final class BackfillWatchdogPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testRearmsWhenNeverArmed() {
        XCTAssertTrue(BackfillWatchdogPolicy.shouldRearm(now: t0, lastArmedAt: nil))
    }

    func testBurstOfFramesWithinASecondDoesNotRearm() {
        XCTAssertFalse(BackfillWatchdogPolicy.shouldRearm(now: t0.addingTimeInterval(0.2), lastArmedAt: t0))
        XCTAssertFalse(BackfillWatchdogPolicy.shouldRearm(now: t0.addingTimeInterval(0.99), lastArmedAt: t0))
        XCTAssertTrue(BackfillWatchdogPolicy.shouldRearm(now: t0.addingTimeInterval(1), lastArmedAt: t0))
    }

    func testEffectiveTimeoutStaysWithinOneSecondOfNominal() {
        XCTAssertLessThanOrEqual(BackfillWatchdogPolicy.minRearmSeconds, 1)
        XCTAssertEqual(BLEManager.backfillIdleTimeoutSeconds, 60)
    }
}

final class SyncActivityHoldTests: XCTestCase {
    private final class Token: NSObject {}

    func testAcquireIsIdempotentAndReleaseEndsExactlyOnce() {
        var began = 0, ended = 0
        let hold = SyncActivityHold(begin: { began += 1; return Token() }, end: { _ in ended += 1 })
        XCTAssertFalse(hold.isHeld)
        hold.acquire(); hold.acquire(); hold.acquire()
        XCTAssertTrue(hold.isHeld)
        XCTAssertEqual(began, 1)
        hold.release(); hold.release()
        XCTAssertFalse(hold.isHeld)
        XCTAssertEqual(ended, 1)
    }

    func testCanBeReacquiredAfterRelease() {
        var began = 0, ended = 0
        let hold = SyncActivityHold(begin: { began += 1; return Token() }, end: { _ in ended += 1 })
        hold.acquire(); hold.release(); hold.acquire()
        XCTAssertEqual(began, 2)
        XCTAssertEqual(ended, 1)
        XCTAssertTrue(hold.isHeld)
    }

    func testReleaseWithoutAcquireIsANoOp() {
        var ended = 0
        let hold = SyncActivityHold(begin: { Token() }, end: { _ in ended += 1 })
        hold.release()
        XCTAssertEqual(ended, 0)
    }

    /// A begin that yields no token (iOS) must not wedge the hold into a state that never retries.
    func testNilTokenLeavesTheHoldNotHeld() {
        var began = 0
        let hold = SyncActivityHold(begin: { began += 1; return nil }, end: { _ in })
        hold.acquire(); hold.acquire()
        XCTAssertFalse(hold.isHeld)
        XCTAssertEqual(began, 2)
    }

    #if os(macOS)
    func testSystemActivityRoundTrips() {
        let hold = SyncActivityHold()
        hold.acquire()
        XCTAssertTrue(hold.isHeld)
        hold.release()
        XCTAssertFalse(hold.isHeld)
    }
    #endif
}

final class BackfillThroughputTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testNoLineBeforeTheWindowElapsed() {
        var tracker = BackfillThroughputTracker(now: t0)
        for _ in 0..<5 { tracker.record(reason: "timeout", chunks: 4, rows: 100) }
        XCTAssertNil(tracker.flushIfDue(now: t0.addingTimeInterval(599)))
        XCTAssertEqual(tracker.sessions, 5)
    }

    func testLineSummarisesTheWindowAndResetsIt() throws {
        var tracker = BackfillThroughputTracker(now: t0)
        tracker.record(reason: "HISTORY_COMPLETE", chunks: 10, rows: 600)
        tracker.record(reason: "timeout", chunks: 2, rows: 60)
        tracker.record(reason: "timeout", chunks: 3, rows: 90)
        let line = try XCTUnwrap(tracker.flushIfDue(now: t0.addingTimeInterval(600)))
        XCTAssertTrue(line.contains("3 session(s)"), line)
        XCTAssertTrue(line.contains("1 HISTORY_COMPLETE"), line)
        XCTAssertTrue(line.contains("2 idle-timeout"), line)
        XCTAssertTrue(line.contains("15 chunk(s)"), line)
        XCTAssertTrue(line.contains("750 row(s)"), line)
        XCTAssertTrue(line.contains("75 rows/min"), line)
        XCTAssertEqual(tracker.sessions, 0)
        XCTAssertEqual(tracker.rows, 0)
        XCTAssertEqual(tracker.windowStart, t0.addingTimeInterval(600))
    }

    func testQuietWindowEmitsNothingButStillRolls() {
        var tracker = BackfillThroughputTracker(now: t0)
        tracker.record(reason: "HISTORY_COMPLETE", chunks: 1, rows: 10)   // one normal periodic offload
        XCTAssertNil(tracker.flushIfDue(now: t0.addingTimeInterval(900)))
        XCTAssertEqual(tracker.sessions, 0)
        XCTAssertEqual(tracker.windowStart, t0.addingTimeInterval(900))
    }
}

@MainActor
final class OffloadEventFrameTests: XCTestCase {
    func testWhoop4TypeByteIsAtIndexFour() {
        var f = [UInt8](repeating: 0, count: 12)
        f[4] = 48
        XCTAssertTrue(BLEManager.isEventFrame(f, family: .whoop4))
        f[4] = 47
        XCTAssertFalse(BLEManager.isEventFrame(f, family: .whoop4))
    }

    func testWhoop5TypeByteIsAtIndexEight() {
        var f = [UInt8](repeating: 0, count: 16)
        f[8] = 48
        XCTAssertTrue(BLEManager.isEventFrame(f, family: .whoop5))
        f[8] = 47
        XCTAssertFalse(BLEManager.isEventFrame(f, family: .whoop5))
        // A 48 at the WHOOP 4 position must not read as an event on a puffin frame.
        f[4] = 48
        XCTAssertFalse(BLEManager.isEventFrame(f, family: .whoop5))
    }

    func testShortFramesAreNeverEvents() {
        XCTAssertFalse(BLEManager.isEventFrame([], family: .whoop4))
        XCTAssertFalse(BLEManager.isEventFrame([0xAA, 0, 0, 0, 48], family: .whoop5))
    }

    /// Agrees with `isOffloadFrame`: every event frame is an offload frame, so gating the gesture dispatch on
    /// it can only drop frames that could never have carried a gesture.
    func testEveryEventFrameIsAnOffloadFrame() {
        for family in [DeviceFamily.whoop4, .whoop5] {
            var f = [UInt8](repeating: 0, count: 16)
            f[family == .whoop5 ? 8 : 4] = 48
            XCTAssertTrue(BLEManager.isEventFrame(f, family: family))
            XCTAssertTrue(BLEManager.isOffloadFrame(f, family: family))
        }
    }
}

@MainActor
final class CodexMirrorHistoryProgressTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-progress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A history-progress stamp (a long offload with no HISTORY_COMPLETE) must request a mirror run without
    /// `lastSyncedAt` ever changing.
    func testHistoryProgressStampTriggersAMirrorRunWithoutLastSyncedAt() async throws {
        let source = dir.appendingPathComponent("whoop.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE t(x INTEGER); INSERT INTO t VALUES (1);", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let mirrorDir = dir.appendingPathComponent("NOOP-Daten", isDirectory: true)
        let path = source.path
        let scheduler = CodexMirrorScheduler(directory: mirrorDir, minInterval: 0, sourcePath: { path })
        let live = LiveState()
        scheduler.attachHistoryProgress(live.$historyProgressAt)

        XCTAssertNil(scheduler.lastMirrorAt)
        live.historyProgressAt = 1_800_000_000

        var waited = 0.0
        while scheduler.lastMirrorAt == nil, waited < 10 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        XCTAssertNotNil(scheduler.lastMirrorAt, "progress stamp should have triggered a mirror run")
        XCTAssertNil(scheduler.lastMirrorError)
        XCTAssertNil(live.lastSyncedAt, "a half-finished drain must not stamp lastSyncedAt")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: mirrorDir.appendingPathComponent(CodexMirrorPolicy.fileName).path))
    }

    func testInitialNilValueDoesNotTriggerARun() async throws {
        let scheduler = CodexMirrorScheduler(directory: dir.appendingPathComponent("m", isDirectory: true),
                                             minInterval: 0, sourcePath: { "/nonexistent" })
        let live = LiveState()
        scheduler.attachHistoryProgress(live.$historyProgressAt)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(scheduler.lastMirrorAt)
        XCTAssertNil(scheduler.lastMirrorError)
    }
}

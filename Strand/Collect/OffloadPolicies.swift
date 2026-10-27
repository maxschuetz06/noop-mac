import Foundation

/// Decides whether a finished backfill session (a 60s idle-cap exit OR a HISTORY_COMPLETE) should immediately
/// re-kick another offload instead of tearing down to wait for the next periodic / strap-event trigger
/// (#364, #25). The strap offloads OLDEST-first and some firmware (WHOOP 5/MG 50.42.x) slices a deep backlog
/// into many small sessions, so waiting 15 min (periodic) or ~10 min (strap prompt) between slices drains
/// "last night" at a crawl. Auto-continuing keeps draining back-to-back while every session demonstrably
/// makes progress, and stops the moment one does not.
///
/// Pure + value-typed so the decision is unit-testable without a CoreBluetooth seam
/// (BackfillContinuationTests). Android (WhoopBleClient.shouldAutoContinue) still carries the older rule —
/// it has NOT been updated to the history-frontier / wall-clock semantics below.
///
/// Stop conditions, checked in this order (anything else ⇒ `.proceed`):
///  1. `disconnected` — a dropped link goes through the normal reconnect path.
///  2. `capReached` / `budgetExhausted` — a SAFETY BOUND only (a large session count and a wall-time budget for
///     one back-to-back streak). Progress is required every session (below), so these never throttle a drain
///     that is really moving; they only cap a pathological strap that fakes progress. After either, the streak
///     is cleared and the next natural trigger (periodic / strap prompt, themselves floored) may start a new one.
///  3. `trimFrozen` — the strap's trim cursor did not move: it is re-sending / console-only; re-kicking spins.
///  4. `noRowsPersisted` — the session persisted no NEW biometric rows. (Empty ENDs advance the trim u32
///     even when the strap hands over nothing, so the trim alone is not progress.)
///  5. `frontierStalled` — rows persisted but the HISTORY frontier did not move forward (no history-only row
///     newer than where the session started). `historyFrontierAdvanced` comes from the Backfiller.
///  6. `caughtUp` — (a) WALL CLOCK: our history frontier is within `wallClockBehindSeconds` (10 min) of `now`.
///     Checked first and independent of GET_DATA_RANGE, because on WHOOP 5/MG `strapNewestTs` is never set
///     (only the WHOOP-4 path requests it, once at connect): a worn, caught-up strap yields fresh seconds on
///     every re-kick and would otherwise `.proceed` for the whole streak budget, over and over (near-continuous
///     radio use). (b) RANGE: the strap's newest banked record (GET_DATA_RANGE) is within `behindGapSeconds` of
///     our history frontier. A newest that reads far OLDER than our frontier is a stale / wrong-epoch range
///     answer (#451) and is ignored: rows + trim + frontier progress already prove real backlog is flowing.
///
/// `ourFrontierTs` MUST be the HISTORY frontier (`WhoopStore.latestHistoryTs`: newest gravity / strap-state /
/// skin-temp / step / resp / SpO₂ / PPG-HR row), NOT max HR ts: the live 0x2A37 / type-40 stream writes
/// `hrSample` and keeps it at "now" while the offload is still days behind.
struct BackfillContinuation {
    /// Safety cap on consecutive auto-continues in one streak. High on purpose: progress is required every
    /// session, so this only bounds a pathological strap. The old cap of 6 throttled a healthy drain of a
    /// strap that serves ~15 strap-seconds per session (12 h of backlog ≈ 2 500 such sessions).
    static let defaultMaxAutoContinues = 5000
    /// Wall-time budget (2 h) for one back-to-back streak before it rests until the next natural trigger.
    static let defaultStreakBudgetSeconds: TimeInterval = 7200
    /// How far ahead the strap must be (seconds) before "more backlog remains" is real, not clock noise.
    /// Matches StuckStrapDetector.behindGapSeconds (5 min) so the two agree on "behind".
    static let defaultBehindGapSeconds = 300
    /// Wall-clock "caught up" margin: a history frontier this close to `now` means the offload has reached the
    /// live edge, whether or not the strap ever answered GET_DATA_RANGE (WHOOP 5/MG never does here).
    static let defaultWallClockBehindSeconds = 600

    enum StopReason: String, Equatable {
        case disconnected, capReached, budgetExhausted, trimFrozen, noRowsPersisted, frontierStalled, caughtUp
    }
    enum Decision: Equatable {
        case proceed
        case stop(StopReason)
    }

    /// `stillConnected`: link up + command channel usable. `strapNewestTs`: newest record the strap holds
    /// (GET_DATA_RANGE). `ourFrontierTs`: our HISTORY frontier (see the type doc). `rowsPersistedThisSession`:
    /// new biometric rows the just-ended session inserted. `lastTrimAdvanced`: it moved the trim cursor.
    /// `historyFrontierAdvanced`: it persisted a history row newer than the frontier it started from.
    /// `consecutiveCount` / `streakElapsedSeconds`: how far into the current back-to-back streak we are.
    /// `now`: wall-clock Unix seconds (injected for testability) for the live-edge `caughtUp` stop.
    static func decide(stillConnected: Bool,
                       now: Int,
                       strapNewestTs: Int?,
                       ourFrontierTs: Int?,
                       rowsPersistedThisSession: Int = 0,
                       lastTrimAdvanced: Bool,
                       historyFrontierAdvanced: Bool = true,
                       consecutiveCount: Int,
                       streakElapsedSeconds: TimeInterval = 0,
                       maxAutoContinues: Int = defaultMaxAutoContinues,
                       streakBudgetSeconds: TimeInterval = defaultStreakBudgetSeconds,
                       behindGapSeconds: Int = defaultBehindGapSeconds,
                       wallClockBehindSeconds: Int = defaultWallClockBehindSeconds) -> Decision {
        guard stillConnected else { return .stop(.disconnected) }
        guard consecutiveCount < maxAutoContinues else { return .stop(.capReached) }
        guard streakElapsedSeconds < streakBudgetSeconds else { return .stop(.budgetExhausted) }
        guard lastTrimAdvanced else { return .stop(.trimFrozen) }
        guard rowsPersistedThisSession > 0 else { return .stop(.noRowsPersisted) }
        guard historyFrontierAdvanced else { return .stop(.frontierStalled) }
        // Live edge reached (wall clock) — needs no GET_DATA_RANGE, so it also ends WHOOP 5/MG drains.
        if let frontier = ourFrontierTs, frontier >= now - wallClockBehindSeconds { return .stop(.caughtUp) }
        if let newest = strapNewestTs, let frontier = ourFrontierTs {
            let ahead = newest - frontier
            if ahead > behindGapSeconds { return .proceed }            // strap holds clearly newer data
            if ahead >= -behindGapSeconds { return .stop(.caughtUp) }   // level with the strap's newest
            // else: newest is far OLDER than our frontier ⇒ stale / wrong-epoch range (#451) — ignore it.
        }
        // Range or frontier unknown, or a stale newest: real rows + advancing trim + advancing frontier
        // already prove the strap is still handing over backlog.
        return .proceed
    }

    /// Boolean form of `decide` (kept for the call sites / tests that only need go / no-go).
    static func shouldAutoContinue(stillConnected: Bool,
                                   now: Int,
                                   strapNewestTs: Int?,
                                   ourFrontierTs: Int?,
                                   rowsPersistedThisSession: Int = 0,
                                   lastTrimAdvanced: Bool,
                                   historyFrontierAdvanced: Bool = true,
                                   consecutiveCount: Int,
                                   streakElapsedSeconds: TimeInterval = 0,
                                   maxAutoContinues: Int = defaultMaxAutoContinues,
                                   streakBudgetSeconds: TimeInterval = defaultStreakBudgetSeconds,
                                   behindGapSeconds: Int = defaultBehindGapSeconds,
                                   wallClockBehindSeconds: Int = defaultWallClockBehindSeconds) -> Bool {
        decide(stillConnected: stillConnected, now: now, strapNewestTs: strapNewestTs, ourFrontierTs: ourFrontierTs,
               rowsPersistedThisSession: rowsPersistedThisSession, lastTrimAdvanced: lastTrimAdvanced,
               historyFrontierAdvanced: historyFrontierAdvanced, consecutiveCount: consecutiveCount,
               streakElapsedSeconds: streakElapsedSeconds, maxAutoContinues: maxAutoContinues,
               streakBudgetSeconds: streakBudgetSeconds, behindGapSeconds: behindGapSeconds,
               wallClockBehindSeconds: wallClockBehindSeconds) == .proceed
    }
}

// MARK: - Long-offload progress, maintenance throttling, App Nap guard

/// Decides when a LONG offload publishes an intermediate "history progress" signal.
///
/// `lastSyncedAt` is only stamped on HISTORY_COMPLETE. A WHOOP 5.0 with a multi-day backlog serves ~15
/// strap-seconds per session and ends most sessions on the 60 s idle watchdog, so a drain can run for hours
/// without a single HISTORY_COMPLETE — and everything keyed to `lastSyncedAt` (Codex mirror, dashboard
/// refresh, analysis) stays stale. The signal fires at most once per `minIntervalSeconds` and only for a
/// session that really persisted rows AND moved the history frontier forward, so it can neither fire
/// for an empty/frozen session nor be mistaken for "synced".
struct HistoryProgressPolicy {
    /// Matches the Codex mirror's own minimum run interval (`CodexMirrorPolicy.minInterval`).
    static let minIntervalSeconds: TimeInterval = 600

    /// `lastSignalAt`: the reference point — the last progress signal, the last HISTORY_COMPLETE (which
    /// already triggers the same downstream work) or the start of the first offload, whichever is newest.
    /// nil ⇒ never signal yet (the caller seeds it at offload start, so the first signal is one interval in).
    static func shouldSignal(now: Date, lastSignalAt: Date?, rowsPersisted: Int, frontierAdvanced: Bool,
                             minInterval: TimeInterval = minIntervalSeconds) -> Bool {
        guard rowsPersisted > 0, frontierAdvanced else { return false }
        guard let last = lastSignalAt else { return false }
        return now.timeIntervalSince(last) >= minInterval
    }
}

/// Rate limit for the raw-outbox maintenance (`Collector.prune`) that used to run after EVERY offload
/// session. Its cost is O(rows in rawBatch): `pruneRaw` does an unindexed `SELECT … ORDER BY capturedAt`
/// over the whole table (materialising a Row per batch) and `pruneDiagnosticRaw` a full scan with a
/// `substr(batchId…)` predicate — and the store serialises it with the chunk inserts on one DatabaseQueue.
/// During a back-to-back auto-continue streak (thousands of short sessions) that is thousands of full
/// scans; the retention windows are days / a 50 MB cap, so once per 10 min is more than enough.
struct RawPrunePolicy {
    static let minIntervalSeconds: TimeInterval = 600
    static func isDue(now: Date, lastPruneAt: Date?, minInterval: TimeInterval = minIntervalSeconds) -> Bool {
        guard let last = lastPruneAt else { return true }
        return now.timeIntervalSince(last) >= minInterval
    }
}

/// The idle watchdog is re-armed on every offload frame. Allocating a DispatchWorkItem + a 60 s main-queue
/// timer per frame (hundreds per second on a healthy drain) is pure churn — cancelled items stay in
/// libdispatch until their deadline. Re-arming at most once per `minRearmSeconds` keeps the effective
/// timeout within 1 s of the nominal 60 s.
struct BackfillWatchdogPolicy {
    static let minRearmSeconds: TimeInterval = 1
    static func shouldRearm(now: Date, lastArmedAt: Date?, minRearm: TimeInterval = minRearmSeconds) -> Bool {
        guard let last = lastArmedAt else { return true }
        return now.timeIntervalSince(last) >= minRearm
    }
}

/// Holds ONE process-activity assertion across a whole offload streak so macOS cannot App-Nap the app
/// mid-drain. NOOP has no visible window most of the time (menu bar / background); an App-Napped process
/// gets throttled timers, lowered QoS and throttled disk I/O — at ~1 % CPU, with every chunk commit
/// (SQLite WAL fsync) and ack slowed, and the strap paces its offload on our acks. Nothing in the app took
/// such an assertion before. The begin/end closures are injected so the hold logic is unit-testable.
final class SyncActivityHold {
    private let begin: () -> NSObjectProtocol?
    private let end: (NSObjectProtocol) -> Void
    private var token: NSObjectProtocol?

    init(begin: @escaping () -> NSObjectProtocol? = SyncActivityHold.systemBegin,
         end: @escaping (NSObjectProtocol) -> Void = SyncActivityHold.systemEnd) {
        self.begin = begin
        self.end = end
    }

    var isHeld: Bool { token != nil }

    /// Idempotent: a second `acquire` while held does nothing.
    func acquire() {
        guard token == nil else { return }
        token = begin()
    }

    /// Idempotent: releasing while not held does nothing.
    func release() {
        guard let t = token else { return }
        token = nil
        end(t)
    }

    /// `.userInitiatedAllowingIdleSystemSleep`: opts out of App Nap (and automatic/sudden termination) WITHOUT
    /// keeping the Mac awake — a sleeping Mac drops the BLE link anyway, and a multi-hour drain must not pin
    /// the machine on.
    nonisolated static func systemBegin() -> NSObjectProtocol? {
        return ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                     reason: "NOOP strap history offload")
    }

    nonisolated static func systemEnd(_ token: NSObjectProtocol) {
        ProcessInfo.processInfo.endActivity(token)
    }
}

/// Rolling throughput of back-to-back offload sessions, summarised into one strap-log line per window.
/// Throughput degradation over a long app session was previously only visible as a flat DB-size curve; this
/// makes "sessions ending on the idle watchdog with few rows" vs "healthy HISTORY_COMPLETE slices"
/// readable straight from a strap log.
struct BackfillThroughputTracker {
    static let windowSeconds: TimeInterval = 600
    /// Below this many sessions in a window the line is skipped (a normal 15-min periodic offload is quiet).
    static let minSessionsForLine = 3

    private(set) var windowStart: Date
    private(set) var sessions = 0
    private(set) var completed = 0
    private(set) var timedOut = 0
    private(set) var chunks = 0
    private(set) var rows = 0

    init(now: Date = Date()) { windowStart = now }

    mutating func record(reason: String, chunks: Int, rows: Int) {
        sessions += 1
        if reason == "HISTORY_COMPLETE" { completed += 1 } else if reason == "timeout" { timedOut += 1 }
        self.chunks += chunks
        self.rows += rows
    }

    /// Returns the summary line once the window has elapsed (then starts a new window); nil otherwise.
    mutating func flushIfDue(now: Date, windowSeconds: TimeInterval = windowSeconds) -> String? {
        let elapsed = now.timeIntervalSince(windowStart)
        guard elapsed >= windowSeconds else { return nil }
        defer {
            windowStart = now
            sessions = 0; completed = 0; timedOut = 0; chunks = 0; rows = 0
        }
        guard sessions >= Self.minSessionsForLine else { return nil }
        let minutes = max(elapsed / 60, 0.001)
        return String(format: "Backfill: throughput over %.1f min — %d session(s) (%d HISTORY_COMPLETE, %d idle-timeout), %d chunk(s), %d row(s) persisted (%.0f rows/min).",
                      minutes, sessions, completed, timedOut, chunks, rows, Double(rows) / minutes)
    }
}

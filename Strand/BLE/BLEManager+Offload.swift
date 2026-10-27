import Foundation
import WhoopProtocol

// Historical offload session: triggers, frame routing, idle watchdog, App Nap hold, ack and reject archive.
extension BLEManager {
    /// Ack one HISTORY_END chunk so the strap may trim it. Confirmed write — the strap forgets
    /// the chunk once this lands (link-layer half of safe-trim; decoded + raw already persisted).
    ///
    /// High-freq-sync ack form (matches re/sync_openwhoop.py, which pulled 762 type-47 records):
    /// HISTORICAL_DATA_RESULT(23) payload = `[0x01] + end_data`, where end_data is the verbatim
    /// 8 bytes of the HISTORY_END metadata.data[10:18] (trim u32 at [10:14] + next u32 at [14:18]).
    /// The `trim` argument (= end_data first u32) is already persisted as the strap_trim cursor by
    /// the Backfiller; it is passed here only for logging.
    func ackHistoricalChunk(trim: UInt32, endData: [UInt8]) {
        send(.historicalDataResult, payload: [0x01] + endData, writeType: .withResponse)
        // Progress signal for the "Syncing strap history…" UI (#77). Same main-queue delegate path as
        // the other state mutations (e.g. lastSyncedAt in exitBackfilling). NOT historicalAckLogCounter
        // — that's a puffin-write log throttle that never increments on WHOOP 4.
        state.syncChunksThisSession += 1
        // A long drain may never reach HISTORY_COMPLETE for hours: surface intermediate progress (rate-limited).
        publishHistoryProgressIfDue()
    }

    /// Publish the intermediate history-progress signal when this session has persisted new rows, moved the
    /// history frontier forward, and `HistoryProgressPolicy.minIntervalSeconds` passed since the last signal /
    /// HISTORY_COMPLETE / drain start. Does NOT touch `lastSyncedAt` — a half-finished drain is not "synced".
    /// Subscribers (Codex mirror, AppModel dashboard refresh + analysis) re-run their own work on the change.
    func publishHistoryProgressIfDue() {
        guard let bf = backfiller else { return }
        let now = Date()
        guard HistoryProgressPolicy.shouldSignal(now: now, lastSignalAt: lastHistoryProgressSignalAt,
                                                 rowsPersisted: bf.sessionRowsPersisted,
                                                 frontierAdvanced: bf.sessionHistoryFrontierAdvanced) else { return }
        lastHistoryProgressSignalAt = now
        state.historyProgressAt = now.timeIntervalSince1970
        let frontier = bf.sessionNewestHistoryTs.map(String.init) ?? "?"
        log("Backfill: history progress — \(bf.sessionRowsPersisted) row(s) this session, history frontier at \(frontier); refreshing mirror + analysis while the offload continues (lastSyncedAt untouched).")
    }

    /// Take the App-Nap guard and cancel any pending delayed release.
    private func holdSyncActivity() {
        syncActivityReleaseWork?.cancel()
        syncActivityReleaseWork = nil
        syncActivity.acquire()
    }

    /// Release the App-Nap guard shortly after a session ends unless another session started meanwhile.
    func scheduleSyncActivityRelease() {
        syncActivityReleaseWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.backfilling else { return }
            self.syncActivity.release()
            self.syncActivityReleaseWork = nil
        }
        syncActivityReleaseWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + BLEManager.syncActivityLingerSeconds, execute: item)
    }

    /// Release the App-Nap guard right now (link dropped).
    func releaseSyncActivityNow() {
        syncActivityReleaseWork?.cancel()
        syncActivityReleaseWork = nil
        syncActivity.release()
    }

    /// Raw-outbox maintenance at most once per `RawPrunePolicy.minIntervalSeconds` (see its doc for the cost).
    func pruneRawIfDue() {
        let now = Date()
        guard RawPrunePolicy.isDue(now: now, lastPruneAt: lastRawPruneAt) else { return }
        lastRawPruneAt = now
        pruneRaw()
    }

    /// Start a historical-offload session: tell the store machine to begin, flip the routing
    /// flag, kick the strap with sendHistoricalData, and arm the idle timeout.
    @discardableResult
    private func beginBackfill() -> Bool {
        // Never offload before the connect handshake has run: a racing foreground/restore trigger
        // firing SEND_HISTORICAL ahead of hello/SET_CLOCK was part of the storm that stopped serving.
        guard connectHandshakeDone else {
            log("Backfill: deferred — connect handshake not done yet")
            return false
        }
        guard let backfiller else {
            // Store not built yet (bootstrapStore failed or hasn't run). Do NOT force live HR — the
            // type-47 backfill is the metric source. RE-ATTEMPT the bootstrap here so a transient
            // first-open failure self-heals: on iOS the data-protected store is unreadable while the
            // phone is locked, so a background-reconnect bootstrap can fail and, with no retry, stay
            // dead forever (#222). Each periodic tick now retries; the first one that runs after the
            // device is unlocked rebuilds the store and backfill proceeds. bootstrapStore() guards on
            // `collector == nil`, so this is a no-op once the store is up.
            log("Backfill: store not ready — re-attempting bootstrap, will retry next tick")
            Task { @MainActor in await self.bootstrapStore() }
            return false
        }
        // Capture the family at begin() (not init): selectedModel is reliably set by connect() before any
        // backfill starts, whereas bootstrapStore() can build the Backfiller before the family is known.
        backfiller.begin(family: selectedModel.deviceFamily)
        backfilling = true
        state.backfilling = true
        // Stay out of App Nap for the whole streak; seed the progress-signal reference at the first drain start
        // so the first intermediate signal comes one interval in, not on the very first acked chunk.
        holdSyncActivity()
        if lastHistoryProgressSignalAt == nil { lastHistoryProgressSignalAt = Date() }
        state.syncChunksThisSession = 0
        state.rejectedFramesThisSession = 0
        state.rejectedFramesUnarchived = 0
        state.decodedChunksThisSession = 0
        state.consoleChunksThisSession = 0
        state.r22FlagsAccepted = 0
        state.deepPacketsThisSession = 0
        historicalAckLogCounter = 0
        // Payload MUST be [0x00], NOT empty: verified on-device that this strap serves type-47 only with
        // [0x00] (empty → 0 frames on a clean stable link with ~2k records pending); the Mac ground-truth
        // offload (re/sync_openwhoop.py, re/diagnose_biometrics.py) uses [0x00] too. Plain offload — the
        // strap streams HISTORY_START → type-47 records → HISTORY_END (acked) … → HISTORY_COMPLETE.
        send(.sendHistoricalData, payload: [0x00], writeType: .withResponse)
        armBackfillTimeout()
        log("Backfill: session started — historical offload requested")
        return true
    }

    /// Feed a frame to the Backfiller preserving exact arrival order (see `OffloadFrameDrain`).
    func routeBackfillFrame(_ frame: [UInt8]) {
        // Opt-in raw PPG research capture (v20/v21/v26): fire-and-forget enqueue, independent of the
        // Backfiller's persistence/ack path — it can neither block nor fail a sync.
        rawFrameSink.submitStreamFrame(frame, family: selectedModel.deviceFamily)
        offloadDrain.enqueue(frame)
    }

    /// One drain step: ingest the frame, close the session on HISTORY_COMPLETE, and report whether the
    /// session is still running (false drops the frames still queued).
    func ingestOffloadFrame(_ frame: [UInt8]) async -> Bool {
        await backfiller?.ingest(frame)
        afterBackfillIngest()
        return backfilling
    }

    /// Called after every Backfiller.ingest completes. If the Backfiller has consumed all
    /// historical data (isBackfilling drops to false), exit the backfill session cleanly.
    private func afterBackfillIngest() {
        guard backfilling, backfiller?.isBackfilling == false else { return }
        exitBackfilling(reason: "HISTORY_COMPLETE")
    }

    /// True when a frame is part of the historical offload (HISTORICAL_DATA=47, EVENT=48,
    /// METADATA=49 / puffin METADATA=56, CONSOLE_LOGS=50) rather than the live stream (REALTIME_DATA=40,
    /// REALTIME_RAW_DATA=43). The live type-43 raw flood streams continuously and unprompted on
    /// this firmware, so the backfill idle-watchdog must NOT be re-armed by it — only by genuine
    /// offload progress — otherwise the session can neither complete nor time out.
    static func isOffloadFrame(_ frame: [UInt8], family: DeviceFamily) -> Bool {
        // The type byte sits at the inner-record start: frame[4] on WHOOP 4.0, frame[8] on WHOOP 5/MG
        // (the puffin envelope is 4 bytes longer). Reading frame[4] for a puffin frame misclassifies
        // EVERY offload frame as live-flood and routes nothing to the Backfiller.
        let typeIndex = family == .whoop5 ? 8 : 4
        guard frame.count > typeIndex else { return false }
        switch frame[typeIndex] {
        case 47, 48, 49, 50, 56: return true   // HISTORICAL_DATA / EVENT / METADATA / CONSOLE_LOGS
        default: return false              // 40 REALTIME_DATA, 43 REALTIME_RAW_DATA (live flood)
        }
    }

    /// Re-arm the idle watchdog. Called on every offload frame during backfill so the timer resets
    /// as long as the strap keeps sending HISTORY; if the strap goes silent the timer fires and we
    /// exit the session (the durable strap_trim cursor means the next session resumes where we left
    /// off). Timeout is generous (60 s, not 20 s): the unstoppable ~2/s type-43 raw flood eats BLE
    /// airtime, so genuine offload frames can arrive in bursts with multi-second lulls between chunks
    /// — a short watchdog cut sessions short mid-drain. Longer = more records drained per session.
    static let backfillIdleTimeoutSeconds = 60

    private func armBackfillTimeout() {
        backfillTimeout?.cancel()
        lastBackfillTimeoutArmAt = Date()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.backfiller?.timeoutFired()
            self.exitBackfilling(reason: "timeout")
        }
        backfillTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(BLEManager.backfillIdleTimeoutSeconds), execute: item)
    }

    /// Per-offload-frame watchdog refresh: re-arms at most once per `BackfillWatchdogPolicy.minRearmSeconds`
    /// (see its doc) instead of allocating a work item + timer for every frame.
    func touchBackfillTimeout() {
        guard BackfillWatchdogPolicy.shouldRearm(now: Date(), lastArmedAt: lastBackfillTimeoutArmAt) else { return }
        armBackfillTimeout()
    }

    /// True for a historical/live EVENT frame (packet type 48) — the only offload frame type that can carry a
    /// real-time gesture (double-tap / wrist on/off). Same type-byte position as `isOffloadFrame`.
    nonisolated static func isEventFrame(_ frame: [UInt8], family: DeviceFamily) -> Bool {
        let typeIndex = family == .whoop5 ? 8 : 4
        guard frame.count > typeIndex else { return false }
        return frame[typeIndex] == 48
    }

    /// Log + store (bounded raw sample) the frames the notify channels delivered whose packet type no handler
    /// persists, then reset the tap. No-op when nothing was seen. Never touches the ack path.
    func flushUnmappedTap(context: String) {
        guard !unmappedTap.isEmpty else { return }
        let drained = unmappedTap.drain()
        log("Frames outside the handled packet types (\(context)): \(drained.summary) — no handler persists these; \(drained.samples.count) raw sample(s) kept for analysis.")
        guard !drained.samples.isEmpty, let backfiller else { return }
        let tag = "tap-\(Int(Date().timeIntervalSince1970))"
        let samples = drained.samples
        Task { @MainActor in await backfiller.archiveDiagnostic(frames: samples, tag: tag) }
    }

    /// Durably archive undecodable record frames (append-only JSONL, fsynced) BEFORE the Backfiller
    /// acks the trim — the user's only remaining copy of an unmapped firmware's records once the
    /// strap frees them, and the corpus a later layout mapping re-ingests. Updates the session
    /// counters that drive the honest sync status. Returns false ONLY on a genuine write failure,
    /// which makes the Backfiller hold the cursor/ack so the strap re-sends the chunk (no data loss
    /// either way). Frames carry sensor payloads, not identifiers — no serials/MACs are archived.
    func archiveRejectedFrames(_ frames: [[UInt8]], trim: UInt32, family: DeviceFamily) -> Bool {
        // Opt-in raw PPG research capture of other unmapped layouts (v20/v21/v26 are taken at the stream
        // hook). Fire-and-forget: NOT part of the result below, so it can never hold or delay the ack.
        rawFrameSink.submitRejected(frames, family: family)
        switch rejectedHistoryArchive.archive(frames, trim: trim, family: family) {
        case .written(let count):
            state.rejectedFramesThisSession += count
            return true
        case .capReached(let count):
            // Cap reached: succeed WITHOUT writing (wedging the offload over a full archive would be
            // worse; ample sample bytes exist by now), counted separately so the sync status never
            // claims "saved" for bytes that were not.
            state.rejectedFramesUnarchived += count
            log("Backfill: rejected-frame archive is FULL — \(count) frame(s) NOT preserved (acking anyway so the offload can finish)")
            return true
        case .failed:
            log("Backfill: rejected-frame archive FAILED — holding ack so the strap re-sends")
            return false
        }
    }

    /// The Backfiller's reject sink, holding `owner` weakly. Fails closed: once the owner is gone nothing
    /// was archived, so the chunk must not be acked (the ack frees the strap's only copy).
    static func rejectedFrameSink<Owner: AnyObject>(
        owner: Owner,
        archive: @escaping (Owner, [[UInt8]], UInt32, DeviceFamily) -> Bool
    ) -> ([[UInt8]], UInt32, DeviceFamily) -> Bool {
        { [weak owner] frames, trim, family in
            guard let owner else { return false }
            return archive(owner, frames, trim, family)
        }
    }

    /// Pure decision: should the periodic timer kick off another historical offload? Only when
    /// connected + bonded and NOT already mid-backfill. Extracted so the gate is unit-testable
    /// without a CoreBluetooth seam. Note this intentionally does NOT consult `backfillStarted`
    /// (that flag guards the once-per-connect INITIAL kick); the periodic re-trigger is separate.
    static func shouldRunPeriodicBackfill(connected: Bool, bonded: Bool, backfilling: Bool) -> Bool {
        connected && bonded && !backfilling
    }

    /// Start (or restart) the periodic backfill timer. Each tick re-runs the type-47 historical
    /// offload while connected+bonded and not already backfilling — the primary metric sync.
    func startBackfillTimer() {
        backfillTimer?.cancel()
        let interval = BLEManager.backfillIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in self?.triggerPeriodicBackfill() }
        t.resume()
        backfillTimer = t
    }

    /// The single gated entry point for every historical-offload kick. Applies the connection/state
    /// gate AND the BackfillPolicy rate-limiter for the trigger. On a go: records the attempt time
    /// (persisted) and starts the offload.
    func requestSync(_ trigger: BackfillTrigger) {
        guard BLEManager.shouldRunPeriodicBackfill(
            connected: state.connected, bonded: state.bonded, backfilling: backfilling) else { return }
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.object(forKey: BLEManager.backfillLastAtKey) as? Double
        guard BackfillPolicy.shouldRun(trigger: trigger, now: now, lastBackfillAt: last,
                                       emptyStreak: emptySyncTracker.consecutiveEmptySyncs) else {
            log("Backfill: \(trigger) skipped (rate-limited; last \(last.map { Int(now - $0) } ?? -1)s ago)")
            return
        }
        if beginBackfill() {
            UserDefaults.standard.set(now, forKey: BLEManager.backfillLastAtKey)
        }
    }

    /// Periodic-timer callback: routes through the rate-limited requestSync entry point.
    private func triggerPeriodicBackfill() {
        requestSync(.periodic)
    }

    /// User-tappable "Sync now" (#364): kick a historical offload IMMEDIATELY, bypassing the 15-min
    /// periodic floor. Routes through the SAME gated `requestSync` as every other trigger with the
    /// `.manual` tier — so it always passes the BackfillPolicy floor but still honours the
    /// connected+bonded+not-already-backfilling gate (a no-op, honestly, when there's no strap or a
    /// sync is already running). The caller (Health screen) only enables the control while connected, so
    /// a tap is meaningful; this guard is the belt-and-braces. Mirrors the Android `WhoopBleClient.syncNow`.
    public func syncNow() {
        guard state.connected, state.bonded else {
            log("Sync now: no strap connected — ignored.")
            return
        }
        if backfilling {
            log("Sync now: a sync is already in progress.")
            return
        }
        log("Sync now: manual sync requested by user.")
        requestSync(.manual)
    }
}

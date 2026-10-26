import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

// End of an offload session: forensics, honest sync status, auto-continue, liveness and inactivity hooks.
extension BLEManager {
    /// Tear down the backfill session. Does NOT auto-start live HR: the periodic type-47 backfill
    /// is the primary metric source now, mirroring how WHOOP syncs. Live HR is opt-in only (the
    /// manual "Start HR" button in LiveView). Between backfills the Collector sees only the live
    /// type-43 flood, which extractStreams ignores — the data comes from the next periodic offload.
    func exitBackfilling(reason: String) {
        guard backfilling else { return }
        backfilling = false
        state.backfilling = false
        // #174: a backfill just ended. Start (or extend) the deep-packet cooldown from this instant so
        // any type-0x2F records the strap flushes in the seconds after the session aren't miscounted as
        // the live R22 stream — they're the offload's tail.
        lastOffloadFrameAt = Date()
        backfillTimeout?.cancel()
        backfillTimeout = nil
        backfillFrameQueue.removeAll()
        scheduleSyncActivityRelease()
        log("Backfill: session ended — reason=\(reason)")
        // Forensics: what did the strap actually hand over this session (packet types / layout versions),
        // plus any frames no handler persists? Logged for EVERY ended session, empty ones included — "0
        // type-47 records" is the evidence a no-rows night needs. The bounded raw sample is already stored.
        if let bf = backfiller {
            log(Backfiller.sessionCensusLine(census: bf.sessionCensus, chunks: bf.sessionChunks,
                                             diagnosticFrames: bf.sessionDiagnosticFrames))
            log(Backfiller.sessionTimingLine(chunks: bf.sessionChunks, elapsed: bf.sessionElapsedSeconds,
                                             chunkWork: bf.sessionChunkWorkSeconds,
                                             maxChunkWork: bf.sessionMaxChunkWorkSeconds))
            // Same census, durable: one NOOP_HISTORY_CENSUS event row so it is readable from the DB mirror.
            // Snapshot now (a new session's begin() resets the counters), write off the critical path.
            let censusSnapshot = bf.sessionCensusSnapshot()
            Task { @MainActor in await bf.persistSessionCensus(censusSnapshot) }
        }
        flushUnmappedTap(context: "backfill \(reason)")
        pruneRawIfDue()   // age out diagnostic samples (14 d) + enforce the raw byte cap — at most every 10 min
        // Streak throughput line (strap log) + intermediate progress signal for a drain that has not completed.
        if let bf = backfiller {
            throughputTracker.record(reason: reason, chunks: bf.sessionChunks, rows: bf.sessionRowsPersisted)
            if let line = throughputTracker.flushIfDue(now: Date()) { log(line) }
            // A HISTORY_COMPLETE stamps lastSyncedAt below, which triggers the same downstream work itself.
            if reason != "HISTORY_COMPLETE" { publishHistoryProgressIfDue() }
        }
        // Inactivity reminder (#419): read-only hook on the natural offload completion (no cadence
        // change). Only on a true HISTORY_COMPLETE — a timeout/disconnect didn't bring a fresh window.
        if reason == "HISTORY_COMPLETE" { maybeBuzzInactivity() }
        // Success-side summary (#150 forensics): we logged failures (decoded-to-0) but never successes,
        // so a strap log couldn't tell a banking strap from a broken one. Emit the per-session persistence
        // tally whenever anything actually landed — the win-rate signal a log previously lacked.
        if let bf = backfiller,
           let summary = Backfiller.sessionSummaryLine(rows: bf.sessionRowsPersisted, motion: bf.sessionMotionRows, nights: bf.sessionNights) {
            log(summary)
        }
        // #547 RE-POLLUTION: this session's ingest gate dropped bad-clock records, so the strap has a
        // wandering clock and may have banked similar garbage on an OLDER build whose gate was weaker. Arm
        // a heal re-run so the next analyze tick purges any such pollution — not gated behind the one-shot
        // done flag. Pure UserDefaults set (no engine handle here); IntelligenceEngine honours it next tick.
        if (backfiller?.sessionDroppedImplausible ?? 0) > 0 {
            IntelligenceEngine.requestTimestampReheal()
        }
        // #364 auto-continue spin-detector: did THIS session move the strap's trim cursor? Compare the
        // Backfiller's current high-water trim against where it stood when the previous session ended.
        // A frozen cursor (console-only / strap refusing to trim) ⇒ don't re-kick (it would spin forever).
        let currentTrim = backfiller?.lastAckedTrim
        let trimAdvanced = currentTrim != nil && currentTrim != lastSessionEndTrim
        lastSessionEndTrim = currentTrim
        // Honest sync outcome for a cloud-free user (mirrors Android exitBackfilling, ed6a31d):
        // HISTORY_COMPLETE stamps lastSyncedAt + clears any error; the idle-watchdog timeout surfaces
        // a non-silent error. A disconnect mid-sync bypasses this path (didDisconnectPeripheral resets
        // the flags directly) — that's not a sync failure, and the next connect re-offloads.
        if reason == "HISTORY_COMPLETE" {
            state.lastSyncedAt = Date().timeIntervalSince1970
            // HISTORY_COMPLETE already triggers the mirror + refresh + analysis via lastSyncedAt: count it as the
            // newest progress reference so the intermediate signal does not double-fire right after it.
            lastHistoryProgressSignalAt = Date()
            // #77 / #91: a sync that COMPLETED but discarded records must not read as a clean
            // "History synced" — the wording distinguishes bytes saved on this Mac from bytes the
            // full archive could not preserve, so "saved" is never claimed falsely.
            let archived = state.rejectedFramesThisSession
            let unarchived = state.rejectedFramesUnarchived
            // Classify this completed offload (pure, unit-tested in EmptyBankingClassifierTests).
            let banking = BLEManager.classifyCompletedOffload(
                decodedChunks: state.decodedChunksThisSession,
                archivedFrames: archived,
                unarchivedFrames: unarchived,
                consoleChunks: state.consoleChunksThisSession,
                rowsPersisted: backfiller?.sessionRowsPersisted ?? 0)
            let bankedSensorRecords = banking.bankedSensorRecords
            let bankedNothing = banking.bankedNothing
            let sustainedEmpty = emptySyncTracker.recordCompletedSync(
                bankedSensorRecords: bankedSensorRecords, consoleOnly: bankedNothing)
            if unarchived > 0 {
                state.lastSyncError = "Synced, but \(archived + unarchived) record(s) couldn't be decoded (unrecognised strap firmware layout), and the on-device archive is full — the \(unarchived) newest weren't preserved. Please share a strap log so the layout can be mapped."
            } else if archived > 0 {
                state.lastSyncError = "Synced, but \(archived) record(s) couldn't be decoded (unrecognised strap firmware layout). The raw bytes were saved on this Mac — please share a strap log so the layout can be mapped."
            } else if bankedNothing {
                // #77 / #214 family: the offload COMPLETED but the strap handed over no sensor records
                // at all — either console/diagnostic output across many chunks, OR a near-empty
                // metadata-only completion (zero rows persisted) — i.e. it isn't banking history to
                // flash (its RTC has lost sync). Only escalate to the actionable banner once emptiness
                // is SUSTAINED (#126): a single empty cycle on an otherwise-banking strap stays silent.
                let detail = state.consoleChunksThisSession >= 3
                    ? "console-only across \(state.consoleChunksThisSession) chunks"
                    : "metadata-only, 0 sensor rows persisted"
                log("Backfill: completed but the strap banked no sensor history (\(detail)); consecutive empty syncs = \(emptySyncTracker.consecutiveEmptySyncs).")
                state.lastSyncError = sustainedEmpty
                    ? "Synced, but your strap had no stored history to hand over — only its diagnostic output. This usually means its clock has lost sync, so it isn't saving data to flash. Fully charge it to 100%, then reconnect, and it should start banking again."
                    : nil
            } else {
                state.lastSyncError = nil
            }
            // #580: a 5/MG that reaches a real HISTORY_COMPLETE with banked sensor records proves its
            // history offload IS working — clear the experimental note + empty streak so the home state
            // stops saying "history sync experimental".
            if selectedModel.deviceFamily == .whoop5, bankedSensorRecords {
                whoop5EmptyOffload.reset()
                state.historySyncExperimental = false
            }
            UserDefaults.standard.set(state.lastSyncedAt, forKey: "lastSyncedAt")
            // NOTE: the auto-continue streak is NOT reset here. A HISTORY_COMPLETE is no longer assumed to
            // mean "caught up" (#25): a strap whose firmware segments a deep offload into many small
            // HISTORY_COMPLETE slices keeps ONE streak (and one wall-time budget) across the slices. The streak
            // is cleared only when maybeAutoContinueBackfill decides to stop, fired below for BOTH exit reasons.
        } else if reason == "timeout" {
            // #580: distinguish a genuine WHOOP-4 "strap went quiet mid-sync" from a WHOOP 5/MG whose
            // firmware acks SEND_HISTORICAL_DATA but never emits a single type-0x2F offload frame. The
            // 5/MG case isn't a failure — live HR is streaming fine over 0x2A37, the history offload is
            // just experimental/empty on that firmware. "Banked" = this offload made ANY offload progress
            // (chunks acked, rows persisted, or deep packets seen); an empty 5/MG offload has none.
            let bankedThisOffload = state.syncChunksThisSession > 0
                || (backfiller?.sessionRowsPersisted ?? 0) > 0
                || state.deepPacketsThisSession > 0
            if selectedModel.deviceFamily == .whoop5 {
                let crossed = whoop5EmptyOffload.recordOffload(bankedRecords: bankedThisOffload)
                if whoop5EmptyOffload.historyEmpty {
                    // Honest home state (#580): NOT a sync error — connected + live HR, history experimental.
                    state.historySyncExperimental = true
                    state.lastSyncError = nil
                    if crossed {
                        log("Backfill: WHOOP 5/MG offload empty \(whoop5EmptyOffload.consecutiveEmpty)× — history sync is experimental on 5.0; surfacing 'connected, history experimental' (not a sync error) and backing off the bounce loop.")
                    }
                } else {
                    // Either the first empty cycle (could be the strap waking flash — stay quiet, don't
                    // cry failure) OR a banking offload that just cleared the streak (recovery — drop the
                    // experimental note). Both want a clean, error-free state.
                    state.historySyncExperimental = false
                    state.lastSyncError = nil
                }
            } else {
                state.lastSyncError = "Sync interrupted — the strap went quiet. It will retry on the next sync."
            }
        }
        checkStrapLiveness()         // safety-net: strap ahead of us AND our frontier frozen ⇒ stuck?
        // #364 / #25: a session that ended on the 60s IDLE cap OR on a true HISTORY_COMPLETE while still
        // connected, with more backlog to fetch and the trim still advancing, immediately re-kicks another
        // offload instead of tearing down to wait the 15-min floor — so a deep oldest-first backlog drains
        // in back-to-back ~60s passes rather than one-per-15-min. #25: fire on HISTORY_COMPLETE too — some
        // straps segment a deep overnight offload into many small HISTORY_COMPLETE slices and would
        // otherwise stall between slices until the periodic floor. The pure shouldAutoContinue guards make
        // this safe: a genuinely caught-up strap (newest within behindGapSeconds of the frontier and 0 rows)
        // returns false and stops; that else path is also where the consecutive streak is cleared. Bounded
        // by the consecutive-cap and the spin-detector inside the pure predicate either way.
        if reason == "timeout" || reason == "HISTORY_COMPLETE" {
            maybeAutoContinueBackfill(trimAdvanced: trimAdvanced,
                                      rowsPersisted: backfiller?.sessionRowsPersisted ?? 0,
                                      historyFrontierAdvanced: backfiller?.sessionHistoryFrontierAdvanced ?? false)
        }
    }

    /// #364 / #25: evaluate (and, if warranted, fire) an immediate back-to-back backfill after a 60s
    /// idle-cap exit OR a HISTORY_COMPLETE. The "more backlog remains" test needs our HISTORY frontier
    /// (`WhoopStore.latestHistoryTs` — newest gravity / strap-state / … row), which only the Collector can read,
    /// so this hops onto a Task exactly like `checkStrapLiveness`. It is deliberately NOT max HR ts: the live
    /// 0x2A37 / type-40 stream writes `hrSample` and pins that "frontier" at now while the offload is days behind.
    /// The decision itself is the pure `BackfillContinuation.decide` so it stays unit-testable; this method only
    /// gathers the inputs, keeps the streak counter / wall-time budget, logs WHY it continued or stopped, and
    /// re-kicks via the SAME gated requestSync path (so it still respects connected/bonded and can't double-start).
    /// The `.autoContinue` trigger bypasses the BackfillPolicy 15-min floor; the per-session progress
    /// requirement (trim advanced AND real rows AND history frontier moved) plus the cap / time budget are the guard.
    /// `trimAdvanced` is the spin-detector signal computed in exitBackfilling (did this session move the
    /// trim cursor vs the previous one) — passed in because exitBackfilling has already advanced
    /// `lastSessionEndTrim` past the comparison point by the time this Task runs.
    private func maybeAutoContinueBackfill(trimAdvanced: Bool, rowsPersisted: Int, historyFrontierAdvanced: Bool) {
        // Cheap pre-check first (no Task if the link is already gone).
        guard state.connected, state.bonded else { return }
        let newest = strapNewestTs
        let count = consecutiveAutoContinues
        let streakElapsed = autoContinueStreakStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        Task { @MainActor in
            let frontier = await collector?.latestHistoryTs() ?? nil
            if frontier == nil, !loggedHistoryFrontierUnavailable {
                loggedHistoryFrontierUnavailable = true
                log("Backfill: history frontier unavailable (latestHistoryTs returned nil — no concrete store, nothing persisted yet, or the read threw); auto-continue falls back to trim/rows/frontier-progress + the safety bound. Logged once per session.")
            }
            let decision = BackfillContinuation.decide(
                stillConnected: state.connected && state.bonded,
                now: Int(Date().timeIntervalSince1970),
                strapNewestTs: newest,
                ourFrontierTs: frontier,
                rowsPersistedThisSession: rowsPersisted,
                lastTrimAdvanced: trimAdvanced,
                historyFrontierAdvanced: historyFrontierAdvanced,
                consecutiveCount: count,
                streakElapsedSeconds: streakElapsed)
            guard case .proceed = decision else {
                // No re-kick: the drain is finished, stalled, or hit its safety bound. Clear the streak so the
                // next natural trigger starts a fresh one (every continue in it needed demonstrated progress, so
                // a rest after the cap / budget cannot turn into an unbounded spin — natural triggers are floored).
                if case .stop(let reason) = decision {
                    log("Backfill: auto-continue stopped (\(reason.rawValue)) — trim advanced=\(trimAdvanced), \(rowsPersisted) new row(s), history frontier advanced=\(historyFrontierAdvanced), frontier \(frontier.map(String.init) ?? "?"), strap-reported newest \(newest.map(String.init) ?? "?"); \(count) re-kick(s) this streak.")
                }
                consecutiveAutoContinues = 0
                autoContinueStreakStartedAt = nil
                // A streak that ended on its safety bound (cap / budget) rests for the natural floor, counted
                // from NOW (the stamp is otherwise the start of the last re-kick): the next .periodic / .strap
                // trigger starts a new series only after the full 15-min / event floor, never back-to-back.
                if case .stop(let reason) = decision, reason == .capReached || reason == .budgetExhausted {
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: BLEManager.backfillLastAtKey)
                }
                return
            }
            // Guard against a race: a real backfill may already have re-started (periodic/connect) in the
            // gap before this Task ran. requestSync's own gate (!backfilling) handles that, but skip the
            // log/counter churn if so.
            guard !backfilling else { return }
            if consecutiveAutoContinues == 0 { autoContinueStreakStartedAt = Date() }
            consecutiveAutoContinues += 1
            log("Backfill: auto-continuing (#364/#451) — trim advanced, \(rowsPersisted) new row(s), history frontier moved to \(frontier.map(String.init) ?? "?") (strap-reported newest \(newest.map(String.init) ?? "?")); re-kicking offload \(consecutiveAutoContinues) (cap \(BackfillContinuation.defaultMaxAutoContinues), budget \(Int(BackfillContinuation.defaultStreakBudgetSeconds / 60)) min) without waiting the 15-min floor.")
            // .autoContinue bypasses the BackfillPolicy floor (the whole point — don't wait 15 min);
            // requestSync still re-checks connected/bonded/not-backfilling before kicking.
            requestSync(.autoContinue)
        }
    }

    /// After an offload, judge liveness: stuck = strap reports records newer than our frontier AND our
    /// frontier (max persisted HR ts) hasn't advanced for the detector window. Off-wrist / caught up
    /// (strap not ahead) is NOT stuck. On stuck: attempt recovery (defensive EXIT + SET_CLOCK) and raise
    /// the surface. Best-effort; reads the frontier via the Collector (which owns the concrete store).
    private func checkStrapLiveness() {
        let strapNewest = strapNewestTs
        Task { @MainActor in
            let frontier = await collector?.latestHRSampleTs()
            let front: Int? = frontier ?? nil
            let now = Date().timeIntervalSince1970
            let stuck = stuckDetector.observe(strapNewestTs: strapNewest,
                                              ourFrontierTs: front,
                                              now: now)
            state.strapNeedsReboot = stuck
            if stuck {
                log("Watchdog: behind + frontier frozen — recovery (exit high-freq + SET_CLOCK)")
                send(.exitHighFreqSync, payload: [0x00])
                sendSetClockBothForms()
            }
        }
    }

    /// Pure classification of a COMPLETED (HISTORY_COMPLETE) offload, extracted from exitBackfilling so
    /// it's unit-testable without a CoreBluetooth seam (EmptyBankingClassifierTests).
    /// - `bankedSensorRecords`: the strap handed over real sensor records — decoded, or
    ///   undecodable-but-archived (either way its clock is banking to flash).
    /// - `bankedNothing` (#77/#120/#214): the offload completed but banked NO sensor records at all,
    ///   in EITHER shape — console-only across ≥3 diagnostic chunks, OR a near-empty metadata-only
    ///   completion (zero rows persisted) with fewer than 3 console frames. The #214 broadening is the
    ///   `rowsPersisted == 0` arm: before it, a metadata-only completion slipped through silently. The
    ///   sustained-streak gate (EmptySyncTracker) still decides whether the banner fires.
    nonisolated static func classifyCompletedOffload(decodedChunks: Int, archivedFrames: Int,
                                                     unarchivedFrames: Int, consoleChunks: Int,
                                                     rowsPersisted: Int)
        -> (bankedSensorRecords: Bool, bankedNothing: Bool) {
        let bankedSensorRecords = decodedChunks > 0 || archivedFrames > 0 || unarchivedFrames > 0
        let bankedNothing = !bankedSensorRecords && (consoleChunks >= 3 || rowsPersisted == 0)
        return (bankedSensorRecords, bankedNothing)
    }

    /// Inactivity reminder (#419): on each natural offload completion, run the shipped, unit-tested
    /// `SedentaryDetector` over the freshly-arrived gravity window and buzz the wrist if the user has
    /// been seated too long. NO offload-timer change — a read-only hook on an event that already
    /// happens, so the nudge lags the stillness by the offload cadence (~7-15 min). Best-effort.
    ///
    /// All gating + de-dup lives in the engine: we only supply honest inputs (recent gravity, the live
    /// `state.worn` flag, the prefs→`SedentaryConfig`/`SedentaryState`) and persist the engine's
    /// `nextState`. The engine acts only when this offload advanced the newest gravity ts (a replayed /
    /// no-new-rows sync can't re-buzz), only for a bout whose end is still current, only through its
    /// mayBuzz gate (master / quiet hours / worn / active-hours-by-bout-end-time), and either re-nudges a
    /// continuing bout on the user's cadence or alerts a distinct new bout separated by movement.
    ///
    /// Mirrors the async pattern of checkStrapLiveness: the gravity read only the Collector can do (it
    /// owns the concrete store) hops onto a @MainActor Task, then the gated buzz + state save run back on
    /// the main actor. Haptic firing can't be verified in the simulator — test on-device.
    private func maybeBuzzInactivity() {
        guard InactivityPrefs.isEnabled() else { return }   // cheap pre-check before any DB read
        Task { @MainActor in
            let nowSec = Int(Date().timeIntervalSince1970)
            let from = nowSec - BLEManager.inactivityLookbackSeconds
            let gravity = await collector?.recentGravity(from: from, to: nowSec) ?? []
            guard !gravity.isEmpty else { return }

            let decision = SedentaryDetector.evaluate(
                gravity, state: InactivityPrefs.loadState(),
                config: InactivityPrefs.loadConfig(),
                worn: state.worn, nowSec: nowSec,
                tzOffsetSec: InactivityPrefs.tzOffsetSec(nowSec))
            // The engine always advances lastProcessedGravityTs when a window arrived, so persist the
            // de-dup state every run — a replayed window then can't re-buzz across a relaunch.
            InactivityPrefs.saveState(decision.nextState)

            if decision.shouldBuzz {
                send(.runHapticsPattern, payload: [2, UInt8(clamping: decision.buzzLoops), 0, 0, 0])
                let mins = Int((decision.bout?.durationS ?? 0) / 60)
                log("Inactivity: nudged after a \(mins)-min sedentary stretch.")
                AppModel.postInactivity(minutes: mins)   // #577 — local notification (iOS-only, self-gated on notif.masterEnabled)
            }
        }
    }
}

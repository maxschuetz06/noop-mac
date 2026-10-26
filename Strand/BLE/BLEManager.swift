import Foundation
import CoreBluetooth
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// CoreBluetooth engine for the WHOOP 4.0: scan-by-service → connect → discover →
/// BOND (one confirmed write) → subscribe → reassemble char-05 frames → FrameRouter.
/// Cannot run in the simulator; verified manually on-device (Task C6).
@MainActor
public final class BLEManager: NSObject, ObservableObject {

    // MARK: GATT UUIDs (authoritative, from FINDINGS.md)
    static let customService   = CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
    static let whoop5Service   = CBUUID(string: "fd4b0001-cce1-4033-93ce-002d5875f58a") // WHOOP 5.0 / MG
    static let cmdWriteChar    = CBUUID(string: "61080002-8d6d-82b8-614a-1c8cb0f8dcc6") // CMD → strap
    static let cmdNotifyChar   = CBUUID(string: "61080003-8d6d-82b8-614a-1c8cb0f8dcc6") // responses
    static let eventNotifyChar = CBUUID(string: "61080004-8d6d-82b8-614a-1c8cb0f8dcc6") // events
    static let dataNotifyChar  = CBUUID(string: "61080005-8d6d-82b8-614a-1c8cb0f8dcc6") // data (frag)
    // WHOOP 5.0 / MG ("puffin") characteristics under the fd4b service. EXPERIMENTAL — see the
    // whoop5 connect path in didDiscoverCharacteristics. fd4b0002 takes the static CLIENT_HELLO.
    static let whoop5CmdWriteChar = CBUUID(string: "fd4b0002-cce1-4033-93ce-002d5875f58a")
    static let whoop5NotifyChars: [CBUUID] = [
        CBUUID(string: "fd4b0003-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0004-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0005-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0007-cce1-4033-93ce-002d5875f58a"),
    ]
    static let heartRateService = CBUUID(string: "180D")
    static let heartRateChar    = CBUUID(string: "2A37") // HR + R-R (works unbonded)
    static let batteryService   = CBUUID(string: "180F")
    static let batteryChar      = CBUUID(string: "2A19")

    static let restoreID = "com.openwhoop.ble.central"

    // MARK: Published state
    public let state: LiveState
    let router: FrameRouter
    var collector: Collector?
    /// Opt-in raw PPG research capture; fire-and-forget beside the persistence/ack path.
    let rawFrameSink: any RawFrameSink

    // MARK: Upload / server sync — REMOVED for Strand (standalone, fully on-device).

    // MARK: Backfill
    var backfiller: Backfiller?
    /// True while a historical offload session is in progress (frames route to Backfiller).
    var backfilling = false
    /// Wall time of the most recent offload frame OR HISTORY_COMPLETE — drives the #174 deep-packet
    /// cooldown. A type-0x2F frame arriving just after a backfill ends (backfilling already flipped
    /// false) is a TRAILING historical frame, not the live R22 stream; it must not be miscounted as a
    /// "live deep packet". nil until the first offload frame this process.
    var lastOffloadFrameAt: Date?
    /// Window after the last offload frame/HISTORY_COMPLETE during which a type-0x2F frame is treated
    /// as trailing-historical, not live. ~10 s comfortably covers the post-completion drain lull.
    static let deepPacketLiveCooldownSeconds: TimeInterval = 10
    /// How far back the inactivity reminder (#419) reads gravity on each offload completion (4 h
    /// comfortably spans the threshold + re-nudge cadence and a separating Active break for bout
    /// continuity). Mirrors the Android WhoopBleClient.INACTIVITY_LOOKBACK_S.
    static let inactivityLookbackSeconds = 4 * 3600
    /// Safety-net detector: strap reports newer data than us AND our frontier frozen 10 min ⇒ flag for
    /// reboot. behindGapSeconds avoids false positives when off-wrist / caught up. Insurance only.
    var stuckDetector = StuckStrapDetector(stuckAfterSeconds: 600, behindGapSeconds: 300)
    /// Newest record unix the strap reports having (from the GET_DATA_RANGE response); refreshed each
    /// offload. Compared against our frontier to tell "stuck" from "off-wrist/caught-up".
    var strapNewestTs: Int?
    /// Fires if the strap goes silent mid-offload; re-armed on every frame during backfill.
    var backfillTimeout: DispatchWorkItem?
    /// Periodic opportunistic upload while connected. Without it, upload only fires at connect +
    /// backfill-exit, so during a long live session decoded rows pile up locally and the server
    /// (dashboard) lags. Started on bond, cancelled on disconnect.
    var uploadTimer: DispatchSourceTimer?
    static let uploadIntervalSeconds = 30
    /// Periodic re-trigger of the type-47 historical offload. This is the PRIMARY continuous metric
    /// source (mirrors how WHOOP syncs): the strap's 14-day biometric store is re-offloaded every
    /// `backfillIntervalSeconds` while connected+bonded, rather than once per connect. Started on
    /// bond, cancelled on disconnect. Plain SEND_HISTORICAL_DATA returns the type-47 store (no
    /// high-freq-sync), so each periodic tick just routes through requestSync(.periodic) → beginBackfill
    /// (SEND_HISTORICAL_DATA + watchdog), subject to the BackfillPolicy floor.
    var backfillTimer: DispatchSourceTimer?
    // The timer fires this often, but BackfillPolicy.periodicFloorSeconds is the real floor (a recent
    // event-triggered sync defers the next periodic tick). 900s = 15 min, matching WHOOP.
    static let backfillIntervalSeconds = 900
    /// Keep-alive: re-arm realtime, poll battery, and bounce a stalled link so streaming
    /// never silently dies. Started on bond, cancelled on disconnect.
    var keepAliveTimer: DispatchSourceTimer?
    static let keepAliveIntervalSeconds = 30
    var keepAliveTick = 0
    /// If a persisted/missing strap-family preference points at the wrong service, a service-filtered
    /// BLE scan can run forever even though the strap is nearby (the common "won't reconnect after an
    /// update" report). Rotate between WHOOP families after a short miss and persist whichever family
    /// actually advertises. (PR#195)
    var scanFallbackWorkItem: DispatchWorkItem?
    static let scanFallbackDelaySeconds: TimeInterval = 8
    /// One-shot "nothing found yet" timer for the scan feedback UI (`ScanFeedback.timeoutSeconds`).
    /// Deliberately separate from `scanFallbackWorkItem`: the family rotation restarts the scan, but the
    /// user's perceived "searching" window must keep counting from the original request.
    var scanTimeoutWorkItem: DispatchWorkItem?
    /// Last time ANY notification arrived — drives the liveness watchdog.
    var lastDataAt = Date()
    /// True while a Live/Health screen is on-screen and wants the realtime stream. One of the two
    /// inputs to `wantsRealtime`. Driven by `startRealtime()` / `stopRealtime()`.
    var screenWantsRealtime = false
    /// True while the "Continuous HRV capture" preference wants the realtime stream held open even with
    /// no Live screen visible, so the strap banks dense beat-to-beat R-R 24/7 (better overnight
    /// HRV/recovery/sleep). The second input to `wantsRealtime`. Default off; set by
    /// `setKeepRealtimeForData(_:)`. Mirrors the Android `keepStreamForData`.
    var keepRealtimeForData = false
    /// Derived want: the (heavy) realtime stream should be armed while EITHER a screen wants it OR the
    /// continuous-capture preference wants it. Keep-alive re-arms it; the post-bond branch arms it on
    /// connect. Recomputed only inside `reconcileRealtime()`.
    var wantsRealtime = false
    /// What we last told the strap (armed = TOGGLE_REALTIME_HR 1). Lets `reconcileRealtime()` send the
    /// toggle only on the false↔true edge instead of on every input change. Cleared on disconnect — the
    /// strap forgets the toggle across a connection, and the post-bond branch re-arms from `wantsRealtime`.
    var realtimeArmed = false
    /// #80 marginal-radio fallback: tracks consecutive arm-then-quick-timeout cycles. When it trips,
    /// `standardHRFallback` goes true and the next connect skips arming R10/R11 (relies on 0x2A37).
    var marginalRadio = MarginalRadioDetector()
    /// #617 bond-loop detector: tracks consecutive bond-then-quick-timeout cycles on a WHOOP 4. When it
    /// trips, BLEManager surfaces the existing re-pair guide (`state.reconnectGuide`) instead of looping
    /// silently. Reset on a clean session / intentional disconnect / a successful connect.
    var postBondLoop = PostBondTimeoutLoopDetector()
    /// Wall time the encrypted bond was established this connection, to measure how soon a drop follows
    /// the bond (the #617 bond-loop tell). nil until bonded; cleared on disconnect.
    var bondedAt: Date?
    /// #126 false-alarm guard: tracks CONSECUTIVE console-only completed syncs so the "clock has lost
    /// sync" banner only fires on sustained emptiness, not a single transient empty cycle on a healthy strap.
    var emptySyncTracker = EmptySyncTracker()
    /// #580: tracks CONSECUTIVE empty 5/MG offloads so a 5/MG whose firmware serves no history offload (but
    /// streams live HR fine) reads as "history sync experimental on 5.0" instead of a sync error, and the
    /// 120s bounce loop backs off while live HR is flowing. Reset on connect / a banking offload.
    var whoop5EmptyOffload = Whoop5EmptyOffloadTracker()
    /// When true, SKIP arming the R10/R11 raw realtime stream on connect — the radio couldn't sustain
    /// it (see MarginalRadioDetector). Live HR then comes only from the already-subscribed low-bandwidth
    /// 0x2A37 standard-HR profile. Per-session: set by the detector, cleared on a clean reconnect (a
    /// connection that actually carried data) or when the user re-opens Live / taps Start HR.
    var standardHRFallback = false
    /// Wall time we last armed the R10/R11 realtime burst this connection, to measure how soon a drop
    /// follows the arm (the marginal-radio tell). nil until armed; cleared on disconnect.
    var realtimeArmedAt: Date?
    /// Last-offload-attempt time (unix seconds), persisted so the rate limiter survives relaunch
    /// (matches WHOOP's DATA_SYNC_WORKER_LAST_WORK_TIME watermark).
    static let backfillLastAtKey = "backfillLastAt"
    /// Prevents a second backfill from starting on a same-process reconnect to the same strap.
    var backfillStarted = false
    /// #364 auto-continue: how many times we've immediately re-kicked a backfill in the CURRENT back-to-back
    /// streak (after a 60s idle-cap OR HISTORY_COMPLETE exit). Bounded by BackfillContinuation's safety cap and
    /// wall-time budget. Cleared when a session stops the streak (caught up / no progress / bound hit) and on
    /// disconnect — never on a mere HISTORY_COMPLETE, so a strap slicing one offload into many completions
    /// keeps one streak (and one budget) across the slices (#25).
    var consecutiveAutoContinues = 0
    /// When the current back-to-back auto-continue streak began (its first re-kick); nil outside a streak.
    /// Feeds `BackfillContinuation`'s wall-time budget. Cleared with the streak (stop / disconnect).
    var autoContinueStreakStartedAt: Date?
    /// One-shot (per BLEManager lifetime) guard for the "latestHistoryTs read failed / empty" log line.
    var loggedHistoryFrontierUnavailable = false
    /// #364 spin-detector: the trim cursor as of the END of the previous backfill session this
    /// connection. exitBackfilling compares the current Backfiller.lastAckedTrim against this to decide
    /// whether the just-ended session actually advanced the strap's trim (progress) or froze (stop
    /// re-kicking). nil until the first session ends; reset on disconnect.
    var lastSessionEndTrim: UInt32?
    /// Runs the connect handshake EXACTLY ONCE per connection. `didWriteValueFor` re-fires on every
    /// `.withResponse` write (the bond write, every SEND_HISTORICAL, every HISTORY_END ack); without
    /// this guard those re-entries re-blasted hello/SET_CLOCK at the strap mid-offload and stopped it
    /// from streaming type-47 — THE iOS "won't serve" root cause. Reset on disconnect.
    var connectHandshakeDone = false
    /// Re-entrancy guard for captureRawAccel: true while a bounded on-demand window is running.
    /// A second tap is a no-op until the active capture's asyncAfter block fires and clears this.
    var rawCaptureInFlight = false
    /// The single serial drain that feeds offload frames to the Backfiller in arrival order.
    lazy var offloadDrain = OffloadFrameDrain { [weak self] frame in
        await self?.ingestOffloadFrame(frame) ?? false
    }

    /// Reference time for the intermediate history-progress signal (see `HistoryProgressPolicy`): the last
    /// signal, the last HISTORY_COMPLETE, or — seeded at the first offload start — "when this drain began".
    var lastHistoryProgressSignalAt: Date?
    /// Last raw-outbox maintenance run (see `RawPrunePolicy`); nil = never this process.
    var lastRawPruneAt: Date?
    /// Last time the idle watchdog was (re-)armed (see `BackfillWatchdogPolicy`).
    var lastBackfillTimeoutArmAt: Date?
    /// App-Nap guard held for the whole offload streak (see `SyncActivityHold`).
    let syncActivity = SyncActivityHold()
    /// Pending delayed release of `syncActivity` once a streak has really ended.
    var syncActivityReleaseWork: DispatchWorkItem?
    /// How long after a session ends the activity assertion lingers before release. An auto-continue
    /// re-kick starts the next session within milliseconds and cancels the release, so the assertion is held
    /// across the whole streak instead of being taken/dropped per session.
    static let syncActivityLingerSeconds: TimeInterval = 30
    /// Rolling per-window throughput of offload sessions (strap-log line, see `BackfillThroughputTracker`).
    var throughputTracker = BackfillThroughputTracker()

    /// Records WHOOP 5/MG puffin frames to a JSON file for protocol mapping. Passive (read-only on the
    /// strap) and gated by the Settings → Experimental "Record puffin frames" toggle; a no-op for
    /// WHOOP 4.0 and when the toggle is off. Lazy so it shares `state` after init. (Cherry-picked from
    /// @j0b-dev's PR #20.)
    lazy var puffinRecorder = PuffinFrameRecorder(state: state)

    /// Force the puffin capture buffer to disk so the Settings export/reveal targets a current file.
    public func flushPuffinCaptures() { puffinRecorder.flush() }

    // MARK: CoreBluetooth
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    /// Multi-WHOOP: when non-nil, the scan/discover path connects ONLY to the peripheral whose
    /// `identifier == preferredPeripheralUUID` and ignores every other discovered WHOOP. When nil
    /// (the only state a single-WHOOP user is ever in) the discover path is byte-for-byte unchanged —
    /// it connects to the FIRST WHOOP discovered. Set by the app via `setPreferredPeripheral(_:)` to
    /// the active device's persisted `peripheralId`. Purely additive; nothing reads it on the nil path.
    var preferredPeripheralUUID: UUID?
    /// Multi-WHOOP Add-a-WHOOP wizard: while true, `didDiscover` POPULATES `discoveredWhoops` instead
    /// of auto-connecting — an explicit, separate "present the nearby straps" mode the wizard turns on
    /// (`scanForWhoops()`) then off (`stopWhoopScan()`). Default false leaves the auto-connect path
    /// untouched. Must never overlap the normal connect flow (the wizard owns the central while true).
    var isPresentingScan = false
    /// The CBPeripheral.identifier.uuidString of the WHOOP we most recently CONNECTED to (`didConnect`).
    /// Published so the app/AppModel can persist it onto the active registry device
    /// (`registry.setPeripheralId`) — letting "my-whoop" adopt its strap's id on first connect and a
    /// specific WHOOP confirm its identity. BLEManager stays decoupled: it never writes the registry.
    @Published public internal(set) var connectedPeripheralUUID: String?
    /// The WHOOP family PROVEN for the connected strap — never merely the family we asked for. Proven by a
    /// service-filtered discovery (`didDiscover`, `retrieveConnectedPeripherals(withServices:)`) or by the
    /// family's service actually being found during service discovery. Reset to nil on every new connect
    /// (BEFORE `connectedPeripheralUUID` is republished) and set again once proven, so the app records the
    /// exact model on the paired-device row only for the strap it belongs to. nil until proven.
    @Published public internal(set) var connectedModel: WhoopModel?
    /// The family a service-filtered discovery proved for one specific peripheral, kept until that
    /// peripheral's `didConnect` so the proof is attributed to the right strap.
    var familyProof: (peripheral: UUID, model: WhoopModel)?
    /// Multi-WHOOP Add-a-WHOOP wizard surface: straps seen while `isPresentingScan` is true, WITHOUT
    /// auto-connecting. Cleared at the start of each `scanForWhoops()`. Empty/unused on the default path.
    @Published public internal(set) var discoveredWhoops: [(uuid: String, name: String, rssi: Int)] = []
    /// Peripheral captured during `willRestoreState`; cleared in `didConnect`.
    /// Non-nil signals that `centralManagerDidUpdateState` should reconnect this
    /// specific peripheral rather than starting a fresh scan.
    var restoredPeripheral: CBPeripheral?
    var cmdCharacteristic: CBCharacteristic?
    var cmdNotifyCharacteristic: CBCharacteristic?
    var eventNotifyCharacteristic: CBCharacteristic?
    var dataNotifyCharacteristic: CBCharacteristic?
    var heartRateCharacteristic: CBCharacteristic?
    var batteryCharacteristic: CBCharacteristic?
    /// EXPERIMENTAL WHOOP 5.0/MG puffin notify chars (fd4b0003/4/5/7), remembered at discovery so we
    /// can re-subscribe them AFTER bonding — the strap refuses them ("Authentication is insufficient")
    /// until the link is encrypted (issue #17).
    var whoop5NotifyCharacteristics: [CBCharacteristic] = []
    /// One frame reassembler PER notify characteristic (not one shared buffer): a large record fragmented
    /// across notifications on one channel (a 2140-byte v20) must not have a frame from another channel
    /// spliced into it — that corrupts the record, or a HISTORY_END we must ack. Reset per connection.
    let reassemblers = ReassemblerBank()
    /// Frames on the notify channels whose packet type no handler persists (e.g. 5/MG 51…55 IMU /
    /// puffin-event streams, which used to fall through to the live UI parser and vanish). Counted and a
    /// few sampled; logged + stored raw (bounded) when a backfill ends.
    var unmappedTap = UnmappedFrameTap()
    var seq: UInt8 = 0
    var didBond = false
    /// WHOOP 5/MG only: realtime HR has been armed (puffin TOGGLE_REALTIME_HR sent) once for this
    /// connection, so the post-bond callback re-firing on later `.withResponse` writes doesn't re-send it.
    var whoop5RealtimeArmed = false
    /// Once-per-connection guard for the 5/MG offload kick (connectHandshakeDone + requestSync +
    /// startBackfillTimer). Stops the HISTORY_END acks re-entering didWriteValueFor from re-triggering
    /// the offload mid-stream (the 5/MG twin of the WHOOP4 connectHandshakeDone ack-storm guard).
    var whoop5SessionStarted = false
    /// Backfill ACKs can arrive hundreds or thousands of times in one offload. Keep the strap log
    /// readable and avoid forcing SwiftUI to auto-scroll on every ACK row.
    var historicalAckLogCounter = 0
    /// Haptic Clock pulses not yet sent; a stop request or a new readout cancels them.
    let hapticClockPulses = HapticPulseSchedule()
    var clockRequested = false
    var intentionalDisconnect = false
    /// Consecutive `didFailToConnect` count, for the auto-reconnect backoff (#414). Reset to 0 on a
    /// successful connect; grows the reschedule delay so a strap that's genuinely out of range doesn't
    /// hammer Bluetooth (vs the disconnect path's flat 3s, which is fine for an already-bonded drop).
    var failedConnectAttempts = 0
    /// Multi-WHOOP stale-pin recovery (#52). The identifier of the last peripheral that reached a GENUINE
    /// encrypted bond this run. When the pinned strap keeps refusing the bond but THIS one bonds fine, it's
    /// the live working strap the registry pin should point at. nil until any strap genuinely bonds.
    var lastBondedPeripheralUUID: UUID?
    /// #78: consecutive "Encryption/Authentication is insufficient" CLIENT_HELLO refusals with NO genuine
    /// bond in between. When the strap genuinely refuses the encrypted bond (held by the WHOOP app, or a
    /// stale iOS pairing), this climbs and we surface actionable pairing-mode guidance; a single transient
    /// refusal right after a good bond (#74) stays quiet. Reset to 0 on any genuine bond, NOT on disconnect
    /// (so it accumulates across the reconnect loop). Distinct from `pinnedBondRefusals`, which is gated to
    /// the multi-WHOOP pinned peripheral and drives the #52 stale-pin handoff.
    var bondRefusalStreak = 0
    /// Multi-WHOOP stale-pin recovery (#52). Consecutive "Encryption/Authentication is insufficient" bond
    /// refusals on the CURRENTLY PINNED peripheral. A stale registry pin (pointing at a strap that bonds to
    /// the official app / isn't really here) makes `connect()` drop the strap that DOES bond and loop
    /// forever on the dead pin. Counts up here; cleared by any genuine bond (a healthy pin never accrues).
    var pinnedBondRefusals = 0
    /// Refusals on the pinned strap before we hand the pin off to a different, live-bonding strap (#52). 3
    /// (not 1): a single "insufficient" can be a transient just-works race; three in a row on the pin while
    /// ANOTHER strap bonds fine is an unrecoverable stale pin. Mirrors the EmptySync/marginal-radio idiom.
    let pinBondRefusalLimit = 3
    /// The strap we're mid-handoff onto during a #52 re-adoption (set in `readoptWorkingStrap`, cleared
    /// when that strap re-bonds in `noteGenuineBond`). Gates the one-time `connectedPeripheralUUID`
    /// re-publish that confirms the re-adoption to SourceCoordinator. nil whenever no handoff is in flight.
    var readoptingTo: UUID?
    /// The strap family the user chose to pair. Drives which service we scan for
    /// and which service we discover after connecting. Hydrated from the persisted
    /// pick so restoration/reconnect after a relaunch target the right strap.
    var selectedModel: WhoopModel = .persisted
    var lastStandardHRLogAt: Date?

    /// Stable device id; matches the server's existing device for sync parity. Overridable.
    /// Seeded from the init argument, then refined once in bootstrapStore() to the device registry's
    /// active id (still "my-whoop" today) before any store writes use it — see bootstrapStore().
    var deviceId: String
    /// Captured (device↔wall) correlation from GET_CLOCK; nil until the response lands.
    var clockRef: ClockRef?

    /// The strap's OWN clock extrapolated to right now (its RTC at the last GET_CLOCK + elapsed since).
    /// Used to judge live-gesture freshness in the strap's clock domain rather than wall time — so a
    /// real-time gesture is "now" and a replayed historical one is "old" REGARDLESS of how stale the
    /// strap RTC is (fix #72's straps). Falls back to wall-now when GET_CLOCK hasn't landed.
    var strapClockNow: Int {
        let wallNow = Int(Date().timeIntervalSince1970)
        guard let ref = clockRef else { return wallNow }
        return ref.device + (wallNow - ref.wall)
    }

    /// `rawFrameSink` receives offload frames for the opt-in raw PPG capture; the app wires it
    /// (`BLEManager+AppWiring.swift`).
    init(state: LiveState, deviceId: String, rawFrameSink: any RawFrameSink) {
        self.state = state
        self.rawFrameSink = rawFrameSink
        self.deviceId = deviceId
        self.router = FrameRouter(state: state)
        // WhoopStore.init is now async, so it can't run here.
        // bootstrapStore() is called once the CBCentralManager reaches poweredOn
        // (see centralManagerDidUpdateState), which guarantees the store is ready
        // before any BLE data arrives.
        self.collector = nil
        super.init()
        state.lastSyncedAt = UserDefaults.standard.object(forKey: "lastSyncedAt") as? Double
        // Restore identifier + background-capable central (foundation for M3 state restoration).
        #if os(iOS)
        // iOS background state preservation/restoration: the restore identifier is what makes
        // CoreBluetooth relaunch the app into the background and deliver willRestoreState after
        // a suspend-then-jettison. Without it, willRestoreState is never called.
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: BLEManager.restoreID])
        #else
        // Strand (macOS desktop): no state-restoration identifier (iOS background feature).
        central = CBCentralManager(delegate: self, queue: .main)
        #endif
        // Strap-as-clock: an incoming EVENT packet kicks a rate-limited catch-up sync.
        router.onSyncTrigger = { [weak self] in self?.requestSync(.strap) }
    }

    /// Build the WhoopStore + Collector + Backfiller asynchronously. Safe to call multiple
    /// times — bails out early if the collector is already initialised.
    func bootstrapStore() async {
        guard collector == nil else { return }
        // Surface store-open failures instead of swallowing them with `try?` (#222): a silent failure
        // here left `backfiller` nil forever and the only visible symptom was the downstream
        // "store not ready" tick, with no clue why. On iOS a background reconnect that opens the
        // data-protected store while the device is locked throws SQLITE_IOERR/CANTOPEN — logging the
        // code proves it; the periodic tick (see beginBackfill) re-attempts so it self-heals on unlock.
        let path: String
        do {
            path = try StorePaths.defaultDatabasePath()
        } catch {
            log("Backfill: bootstrap FAILED resolving DB path — \(error)")
            return
        }
        let store: WhoopStore
        do {
            store = try await WhoopStore(path: path)
        } catch {
            let ns = error as NSError
            log("Backfill: bootstrap FAILED opening store — \(ns.domain) code=\(ns.code): \(ns.localizedDescription)")
            return
        }
        // Route deviceId through the device registry: use the active device's id (migration v15 seeds
        // a single 'my-whoop' row as active, so this is still "my-whoop" today — zero behaviour change).
        // Guarded + best-effort: if the registry is empty/unreadable, deviceId stays as it was, so no
        // crash and no behaviour change. registryQueue is nonisolated/Sendable (GRDB-serialized).
        if let activeId = try? DeviceRegistryStore(dbQueue: store.registryQueue).activeDeviceId(),
           !activeId.isEmpty {
            self.deviceId = activeId
        }
        try? await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP 4.0")
        // Research toggle — OFF by default. When disabled the app is decoded-only and never
        // persists raw frames. Flip "enableRawCapture" in UserDefaults to capture raw again.
        let enableRawCapture = UserDefaults.standard.bool(forKey: "enableRawCapture")
        collector = Collector(store: store, deviceId: deviceId,
                              enableRawCapture: enableRawCapture)
        // The store can finish bootstrapping AFTER connect(model:) already ran (both wait on
        // poweredOn), so apply the family/clock configuration here too — whichever runs last wins.
        configureCollectorFamily()
        backfiller = Backfiller(store: store, deviceId: deviceId,
                                ackTrim: { [weak self] trim, endData in
                                    self?.ackHistoricalChunk(trim: trim, endData: endData)
                                },
                                enableRawCapture: enableRawCapture,
                                log: { [weak self] s in self?.log(s) },
                                rejectedSink: { [weak self] frames, trim, family in
                                    self?.archiveRejectedFrames(frames, trim: trim, family: family) ?? true
                                },
                                onChunk: { [weak self] decoded, console in
                                    if decoded { self?.state.decodedChunksThisSession += 1 }
                                    if console { self?.state.consoleChunksThisSession += 1 }
                                })
        // Strand: no server uploader/sync — all data stays on-device.

        // Retro-decode the reject archive through the current decoder (#152); see RejectArchiveReplayGate.
        switch await RejectArchiveReplayGate.production()
            .runIfDue(archive: rejectedHistoryArchive, store: store, deviceId: deviceId) {
        case .replayed(let rows) where rows > 0:
            log("Backfill: retro-decoded \(rows) record(s) from the reject archive after an update.")
        case .deferred:
            log("Backfill: reject-archive retro-decode deferred (store insert failed) — will retry next launch.")
        case .notDue, .replayed:
            break
        }
    }

    // MARK: Store maintenance

    /// Apply the raw-outbox retention policy (24h synced window / 50MB unsynced cap).
    /// Called when the app enters the background; no-op without a concrete store.
    public func pruneRaw() {
        Task { @MainActor in await collector?.prune() }
    }

    /// Light storage summary for the UI (decoded rows, raw batches, raw bytes). nil without a store.
    public func storageStats() async -> (decodedRows: Int, rawBatches: Int, rawBytes: Int)? {
        await collector?.storageStats()
    }

    /// Point the Collector's live decode at the selected family. For a 5/MG, also install an identity
    /// clock ref: live puffin REALTIME_DATA timestamps are already real-unix seconds, so device==wall
    /// makes toWall a no-op (the same idiom the Backfiller uses for 5/MG history). For a WHOOP 4.0 the
    /// collector takes the manager's GET_CLOCK correlation (nil until it lands — the normal 4.0 flow);
    /// this also evicts a stale identity ref a prior 5/MG session installed when the user switches
    /// straps, which would otherwise mis-stamp WHOOP4 device-epoch frames as wall-clock. Idempotent;
    /// called from connect() AND after the async store bootstrap builds the collector, so the
    /// configuration lands regardless of which finishes first.
    func configureCollectorFamily() {
        collector?.family = selectedModel.deviceFamily
        if selectedModel.deviceFamily == .whoop5 {
            let now = Int(Date().timeIntervalSince1970)
            collector?.clockRef = ClockRef(device: now, wall: now)
        } else {
            collector?.clockRef = clockRef   // the WHOOP4 correlation, nil until GET_CLOCK lands
        }
    }

    /// On-device archive for HISTORICAL_DATA record frames that failed decode (#77 / #91).
    let rejectedHistoryArchive = RawHistoryArchive()

    // MARK: Logging
    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    func log(_ s: String) {
        state.append(log: "[\(timestamp())] \(s)")
    }
    private func timestamp() -> String {
        BLEManager.logTimeFormatter.string(from: Date())
    }
    func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

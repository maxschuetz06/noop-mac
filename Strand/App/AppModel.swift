import SwiftUI
import Combine
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// Composition root and root app state: builds the live BLE state, the strap engine, the read model and
/// the feature services (imports, manual workouts, moments, health signals, stress, strap inputs), wires
/// them together and publishes the state the screens observe. Feature logic lives in the services; the
/// view-facing forwarders are in `AppModel+ViewAPI.swift`, strap/device control in
/// `AppModel+DeviceSources.swift`.
@MainActor
final class AppModel: ObservableObject {
    /// The live instance, so an AppIntent (Shortcuts) can reach the bonded strap rather than spinning
    /// up a dead second AppModel (which would start a duplicate BLE engine and never buzz). Set in
    /// init(); `weak` so an intent fired while NOOP is closed sees nil and asks the user to open it. (#42)
    static weak var shared: AppModel?

    /// Timestamp formatter for the generic-HR strap-log lines routed through `straplog` into the shared
    /// log (issue #421). Mirrors `BLEManager.logTimeFormatter`'s `HH:mm:ss` so WHOOP and HR-strap lines
    /// read identically in the exported strap log.
    static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// Shared device id for both live capture (BLEManager) and imported history.
    let deviceId = "my-whoop"
    /// Source id for imported Apple Health data (stored beside Whoop for per-source pages + consensus).
    let appleDeviceId = "apple-health"
    /// True inside the XCTest host: no strap engine, no launch work, no background services, and an
    /// in-memory store instead of the user's (see `AppRuntime`).
    let isTestHost: Bool
    /// Observable snapshot driven by the BLE engine (connection, HR, battery, log).
    let live: LiveState
    /// The strap engine AppModel itself drives; nil in the XCTest host so no hosted screen wakes CoreBluetooth.
    let engine: BLEManager?
    /// CoreBluetooth engine — scans, connects, bonds, streams. Screens reach it for strap settings. In the
    /// app this is `engine`; in the XCTest host it is only created if a screen dereferences it.
    private(set) lazy var ble: BLEManager = engine ?? Self.makeEngine(live: live)
    /// Read model over the on-device store (dashboard + detail screens).
    let repo: Repository
    /// User profile (age/sex/body/HR-max) for zones, calories, baselines.
    let profile = ProfileStore()
    /// Behaviour settings: double-tap action, wear automation, zone coaching, illness watch.
    let behavior = BehaviorStore()
    /// On-device WHOOP-style recovery/strain/sleep computation from raw strap streams.
    let intelligence: IntelligenceEngine
    /// The L3 passive-nudge surface (haptic biofeedback "stress check-in"). `stress` fires onto this; both
    /// app roots inject it into the environment so the Breathe screen's card surfaces the pending nudge.
    let stressNudgeCenter = StressNudgeCenter()

    let imports: DataSourceImportService
    let workouts: ManualWorkoutController
    let marks: MomentsStore
    let healthSignals: HealthSignalEngines
    private let stress: StressMonitor
    let strapInputs: StrapInputAutomation
    private let buzzStrap: (UInt8) -> Void

    /// Observable cache over the paired-device registry; `activeDeviceId` drives the source coordinator.
    /// Built lazily once the store opens (see `makeDeviceSources`). nil until then — with no generic
    /// strap paired the active id stays "my-whoop", so this never affects the WHOOP startup path.
    /// `@Published` so the Devices screen re-renders the moment the registry is wired in (it observes
    /// `model.deviceRegistry`); nested `registry.$devices` changes are observed by the screen directly.
    @Published private(set) var deviceRegistry: DeviceRegistry?
    /// Runs exactly one device's live BLE at a time. DORMANT whenever WHOOP is active (the default and
    /// every no-strap case): it only acts when a non-WHOOP generic strap becomes the active device,
    /// pausing WHOOP and running the isolated `StandardHRSource`. nil until wired (post store-open).
    private(set) var sourceCoordinator: SourceCoordinator?

    /// Smoothed, display-ready live heart rate — median over a short window, spike-filtered.
    /// Every screen should show THIS, not the raw per-beat value (which swings with HRV).
    @Published var bpm: Int?
    private var hrWindow: [(t: Date, v: Double)] = []
    private var cancellables = Set<AnyCancellable>()
    /// How many on-screen surfaces currently want the realtime HR stream (see `startRealtimeHR`).
    private var realtimeWanters = 0
    /// Installs the in-memory store in the XCTest host; nil in the app.
    private(set) var testStoreIsolation: Task<Void, Never>?

    init(isTestHost: Bool = AppRuntime.isTestHost) {
        let live = LiveState()
        self.live = live
        self.isTestHost = isTestHost
        // Built first, as before the split: BLEManager.init restores `live.lastSyncedAt`, which the sync
        // sinks below must see as their initial (dropped) value.
        let engine = isTestHost ? nil : Self.makeEngine(live: live)
        self.engine = engine
        let buzz: (UInt8) -> Void = { loops in engine?.send(.runHapticsPattern, payload: [2, loops, 0, 0, 0]) }
        self.buzzStrap = buzz
        let repo = Repository(deviceId: "my-whoop")
        self.repo = repo
        self.intelligence = IntelligenceEngine(repo: repo, profile: profile, deviceId: "my-whoop")
        // Route the engine's per-day scoring diagnostic into the SAME shareable strap log every other
        // subsystem writes to (PII-scrubbed by `live.append(log:)`), so a bug report ships proof of what
        // was computed per day. (Sleep overhaul §2.5.)
        self.intelligence.diagnosticSink = { [live] line in live.append(log: line) }
        self.imports = DataSourceImportService(repo: repo, whoopDeviceId: "my-whoop", appleDeviceId: "apple-health")
        self.workouts = ManualWorkoutController(repo: repo, deviceId: "my-whoop", profile: profile, buzz: buzz)
        let marks = MomentsStore(
            buzz: { buzz(1) },
            log: { [live] line in live.append(log: line) },
            recordSleepMark: { mark in
                Task {
                    guard let store = await repo.storeHandle() else { return }
                    try? await store.upsertMetricSeries([mark.metricPoint], deviceId: repo.deviceId)
                }
            })
        self.marks = marks
        self.healthSignals = HealthSignalEngines(repo: repo, behavior: behavior)
        self.stress = StressMonitor(live: live, behavior: behavior, nudgeCenter: stressNudgeCenter, buzz: buzz)
        self.strapInputs = StrapInputAutomation(
            live: live, behavior: behavior, profile: profile,
            actions: .init(buzz: buzz,
                           markMoment: { marks.markMoment(at: Date()) },
                           markSleep: { marks.markSleep(at: Date()) },
                           buzzTimeNow: { is24h in engine?.buzzTimeNow(is24h: is24h) }))
        wireLiveState()
        relayServiceChanges()
        AppModel.shared = self   // publish for App Intents (Shortcuts) — see the static above (#42)
        if isTestHost { isolateFromUserStore() } else { startLaunchWork() }
    }

    private static func makeEngine(live: LiveState) -> BLEManager {
        BLEManager(state: live, deviceId: "my-whoop", rawFrameSink: RawPPGCapture.shared)
    }

    /// Subscribe the services to the live strap state and the dashboard history.
    private func wireLiveState() {
        // Smooth HR centrally so it's solid everywhere it's shown.
        live.$heartRate.sink { [weak self] _ in self?.ingestHR() }.store(in: &cancellables)
        live.$rr.sink { [weak self] _ in self?.ingestHR() }.store(in: &cancellables)
        // Physical-input + wear hooks (fired live by FrameRouter).
        strapInputs.installHooks()
        // HR-zone haptic coaching watches the smoothed bpm.
        $bpm.sink { [weak self] hr in self?.strapInputs.coachZone(hr) }.store(in: &cancellables)
        // Illness/strain early-warning recomputes when the daily history changes.
        repo.$days.sink { [weak self] days in self?.healthSignals.evaluateIllness(days) }.store(in: &cancellables)
        // The macOS app arms no strap alarm, but an earlier build may have left one on the strap. Clear
        // it on every (re)bond so that alarm can never fire.
        live.$bonded.removeDuplicates().sink { [weak self] bonded in
            guard bonded else { return }
            self?.engine?.disableStrapAlarm()
        }.store(in: &cancellables)
        // Re-apply "Continuous HRV capture" on every (re)bond: if on, the strap should hold the dense
        // realtime stream armed even with no Live screen open, so it banks beat-to-beat R-R 24/7 for
        // better overnight HRV/recovery/sleep. The BLE reconciler arms it on the off→on edge; pushing it
        // here (and at launch) covers a fresh launch and every reconnect. (See PuffinExperiment.)
        live.$bonded.removeDuplicates().sink { [weak self] _ in
            self?.engine?.setKeepRealtimeForData(PuffinExperiment.keepRealtimeForDataEnabled)
        }.store(in: &cancellables)
        wireSyncRefresh()
    }

    /// A completed backfill (`lastSyncedAt`) or, during a LONG multi-day offload that drains for hours
    /// without a HISTORY_COMPLETE, BLEManager's rate-limited (~10 min) history-progress stamp has just
    /// written strap history: refresh the dashboard cache and re-run the analysis. `lastSyncedAt` is NOT
    /// touched by progress (a half-finished drain isn't "synced").
    private func wireSyncRefresh() {
        live.$lastSyncedAt.dropFirst().compactMap { $0 }.removeDuplicates()
            .sink { [weak self] _ in
                Task { [weak self] in await self?.refreshAfterCompletedBackfill() }
            }
            .store(in: &cancellables)
        live.$historyProgressAt.dropFirst().compactMap { $0 }.removeDuplicates()
            .sink { [weak self] _ in
                Task { [weak self] in await self?.refreshAfterCompletedBackfill(reason: "history progress") }
            }
            .store(in: &cancellables)
    }

    /// Screens observe this model; re-publish the services' changes so they keep re-rendering.
    private func relayServiceChanges() {
        let children = [imports.objectWillChange, workouts.objectWillChange,
                        marks.objectWillChange, healthSignals.objectWillChange]
        for child in children {
            child.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }
    }

    /// The app's launch work: arm "Continuous HRV capture", reclaim stranded import temps, surface the
    /// stored data, wire the device sources, run the one-shot heals and then score the strap's offloaded
    /// raw data on launch and every 15 minutes (recovery / strain / sleep populate with no import).
    private func startLaunchWork() {
        // Seed the BLE client with the persisted "Continuous HRV capture" intent so `wantsRealtime`
        // reflects it from launch — the reconciler then arms the dense stream as soon as the strap bonds
        // (and the bond sink re-applies it on every reconnect).
        engine?.setKeepRealtimeForData(PuffinExperiment.keepRealtimeForDataEnabled)
        // One-shot reclaim of any stranded `noop-*` temp scratch (e.g. the multi-GB `noop-health-*`
        // export.xml an interrupted import leaves behind — #590). Off the main actor.
        Task.detached { StorageDiagnostics.purgeImportTemp() }
        Task { [weak self] in
            guard let self else { return }
            #if DEBUG
            // DEBUG-only: when launched with `--demo-seed`, populate a deterministic synthetic
            // dataset so an empty simulator/dev build can walk every screen (verification + marketing
            // screenshots). No-op in Release (whole seeder is #if DEBUG) and once data already exists.
            if AppleDemoSeeder.requested, let store = await self.repo.storeHandle() {
                await AppleDemoSeeder.seedIfRequested(into: store)
                // Give the demo a plausible strap battery so the Today header badge renders (the live
                // battery is runtime-only and nil without a connected strap).
                self.live.batteryPct = 68
            }
            #endif
            await self.repo.refresh()                          // surface any imported data at once
            await self.wireDeviceSources()                     // dormant unless a generic strap is active
            try? await Task.sleep(nanoseconds: 6_000_000_000)  // give the first offload a moment
            await self.runAnalysisLoop()
        }
    }

    /// Build the device registry + source coordinator once the store is open (see `makeDeviceSources`).
    private func wireDeviceSources() async {
        guard sourceCoordinator == nil, let engine, let store = await repo.storeHandle() else { return }
        (deviceRegistry, sourceCoordinator) = makeDeviceSources(engine: engine, store: store)
    }

    private func runAnalysisLoop() async {
        // One-shot on-upgrade heal (#547): purge rows a bad-clock strap dated to scattered garbage
        // (far-past / bogus-2027 / FUTURE) from an older build, then rescore the real days. Runs
        // BEFORE the Effort rescore + analyzeRecent loop so both operate on a cleaned DB. Persisted
        // flag → no-op on every subsequent launch; idempotent on a clean DB.
        await intelligence.runTimestampHealIfNeeded()
        // One-shot on-upgrade Effort rescore (#313): recompute strain from source across the FULL
        // history once, so any deep-history rows an older build left on the 0–21 axis regenerate on
        // the 0–100 axis. Guarded by a persisted flag, so this is a no-op on every subsequent launch.
        await intelligence.runEffortRescoreIfNeeded()
        while !Task.isCancelled {
            // #547 RE-POLLUTION: a sync since the last tick may have armed a re-heal (its ingest gate
            // dropped bad-clock records). `runTimestampHealIfNeeded` honours the pending flag even after
            // the one-shot done flag is set, purges any pollution, and rescores the affected days — so a
            // wandering-clock strap can't keep re-polluting. A no-op when nothing's pending.
            await intelligence.runTimestampHealIfNeeded()
            await intelligence.analyzeRecent()
            // v5: recompute the skin-temp suite snapshots (cycle phase + body clock) from the
            // freshly-scored history so the Health hub cards read a ready result.
            await healthSignals.refreshV5Signals()
            try? await Task.sleep(nanoseconds: 900_000_000_000)  // 15 min, matches the offload cadence
        }
    }

    /// XCTest host: give the read model an in-memory store so nothing a hosted screen asks of this model
    /// can open the user's database. Hosted screens run after the host finished launching.
    private func isolateFromUserStore() {
        #if DEBUG
        testStoreIsolation = Task { [repo] in
            do {
                repo.setStoreForTesting(try await WhoopStore.inMemory())
            } catch {
                preconditionFailure("XCTest host could not open its in-memory store: \(error)")
            }
        }
        #endif
    }

    /// Start the app-lifetime background services: the desktop widget publisher, the daily backup and —
    /// when this build has an external data folder — the Codex mirror and the import inbox. Idempotent;
    /// never inside the XCTest host.
    func startBackgroundServices() {
        guard !isTestHost else { return }
        MacWidgetPublisher.shared.start(repo: repo, live: live, smoothedBpm: { [weak self] in self?.bpm })
        AutoBackupScheduler.shared.start()
        CodexMirrorScheduler.shared?.start(syncs: live.$lastSyncedAt, historyProgress: live.$historyProgressAt)
        ImportInboxScheduler.shared?.start(importer: imports)
    }

    private func refreshAfterCompletedBackfill(reason: String = "completed sync") async {
        live.append(log: "Backfill: refreshing dashboard cache from \(reason)")
        await repo.refresh(days: 120)
        // Score the freshly-offloaded raw data RIGHT NOW rather than waiting for the next 15-minute
        // analyzeRecent tick — otherwise a just-synced night's Charge / Effort / Rest can take up to
        // 15 minutes to appear on a strap-only (no-import) dashboard. analyzeRecent no-ops if a tick is
        // already running and refreshes the dashboard itself once the new scores persist. (PR #218)
        await intelligence.analyzeRecent()
        await healthSignals.refreshV5Signals()
    }

    /// Fold a fresh reading into the smoothing window and republish a stable bpm.
    /// Prefers the strap's reported HR; falls back to 60000/R-R. Clamps to a plausible
    /// 30–220 range (rejects 0 / garbage spikes) and publishes the window MEDIAN.
    private func ingestHR() {
        var inst: Double?
        if let hr = live.heartRate, hr >= 30, hr <= 220 {
            inst = Double(hr)
        } else if let rr = live.rr.last, rr > 0 {
            let v = 60_000.0 / Double(rr)
            if v >= 30, v <= 220 { inst = v }
        }
        guard let inst else {
            // #39: when the live source is gone (disconnect blanks heartRate AND rr), drop the stale
            // median so screens that now prefer `bpm` fall through to "—" instead of freezing on the
            // last value. Mirrors Android (_bpm = null on disconnect). A transient out-of-range sample
            // with the link still up (heartRate or rr still present) keeps the last median.
            if live.heartRate == nil && live.rr.isEmpty { resetSmoothing() }
            return
        }
        let now = Date()
        hrWindow.append((now, inst))
        hrWindow.removeAll { now.timeIntervalSince($0.t) > 10 }   // ~10s window
        if hrWindow.count > 40 { hrWindow.removeFirst(hrWindow.count - 40) }
        let vals = hrWindow.map(\.v).sorted()
        // live perf: only republish when the SMOOTHED value actually changes. ingestHR fires on every
        // heartRate AND rr update (~1–3 Hz), but the median is stable across most of them — an
        // unconditional assign re-renders every bpm observer (Live, menu bar, widgets) for nothing.
        let smoothed = vals.isEmpty ? nil : Int(vals[vals.count / 2].rounded())
        if bpm != smoothed { bpm = smoothed }
        workouts.captureSample(bpm: bpm)
        stress.evaluate(bpm: bpm)
    }

    /// Drop the smoothing window and blank the hero number so a resume / re-attach shows "—"
    /// until a genuinely fresh sample arrives, instead of republishing the stale pre-gap median.
    /// Called on Live-tab entry / manual Start HR (see `startRealtimeHR`), NOT on the 30s keep-alive
    /// re-arm — so steady-state smoothing is untouched. Fixes #46 (HR jumped to a stale ~100 on
    /// reopen, then "slowly came back down" as fresh low samples refilled the window).
    func resetSmoothing() {
        hrWindow.removeAll()
        bpm = nil
    }

    /// A surface that shows live HR appeared (the Live tab and the in-exercise LiveWorkoutView can be
    /// open at the same time). The stream stays armed while ANY of them is visible, so a second surface
    /// arming it never disarms it out from under the first (#681). Arms the realtime stream on the 0→1
    /// edge — and ONLY on that edge blanks the stale smoothing window (#46). The keep-alive re-arm goes
    /// through `ble.startRealtime()` directly, NOT here. Each surface must balance this with exactly one
    /// `stopRealtimeHR()` on disappear. Ref-counted to match Android's `realtimeWanters`.
    func startRealtimeHR() {
        if realtimeWanters == 0 {
            resetSmoothing()
            engine?.startRealtime()
        }
        realtimeWanters += 1
    }
    /// A live-HR surface went away. Stops the realtime stream only when the last one leaves (1→0 edge);
    /// the lightweight 0x2A37 HR keeps recording regardless. Clamped at 0 so an unbalanced extra stop
    /// can't drive the count negative and wedge the stream off.
    func stopRealtimeHR() {
        realtimeWanters = max(0, realtimeWanters - 1)
        if realtimeWanters == 0 { engine?.stopRealtime() }
    }

    /// Re-issue the BLE realtime arm WITHOUT touching the ref-count — used when a fresh
    /// connection/bond lands while a surface is already showing live HR (Apple's `ble.startRealtime()`
    /// must be re-sent on a new connection). A no-op when nothing wants the stream, so a stray
    /// connection event can't arm it behind a closed Live tab.
    func rearmRealtimeIfWanted() {
        guard realtimeWanters > 0 else { return }
        engine?.startRealtime()
    }
    /// Ask the strap for a fresh battery reading.
    func getBattery() { engine?.refreshBattery() }

    /// Fire a haptic buzz on the strap. patternId=2 is the graduated buzz confirmed on-device;
    /// `loops` sets the length. Requires a bonded connection — no-op otherwise (the command
    /// characteristic is gated on bond).
    func buzz(loops: UInt8 = 2) { buzzStrap(loops) }
}

/// The app's BLE engine hands offload frames to the opt-in raw PPG capture, a no-op unless enabled.
extension RawPPGCapture: RawFrameSink {}

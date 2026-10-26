import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// Manually-tracked workouts (requested by users who want to start a session themselves rather than
/// rely on auto-detection): start, live HR capture, durable snapshot across app kills (#529), GPS route
/// for distance sports (#524), and End → scored `WorkoutRow` (source "manual") in the store.
@MainActor
final class ManualWorkoutController: ObservableObject {
    /// A manual workout in progress. `samples` accumulate from the smoothed live `bpm`; `liveStrain`
    /// is recomputed as the window grows so the active card can show strain building in real time.
    struct ActiveWorkout: Equatable {
        let start: Date
        /// The named sport chosen at start (e.g. "Tennis", "Padel") — persisted as the saved row's
        /// `sport` so a live-tracked session keeps its label instead of the old generic "Workout".
        /// Defaults to the catalogue default ("Other") when started without a pick. (#519)
        var sport: String = WorkoutCatalog.defaultSportName
        var samples: [HRSample] = []
        var liveStrain: Double = 0
        var avgHr: Int = 0
        var peakHr: Int = 0
    }

    /// An in-progress manually-tracked workout. Holds the start time + the live HR collected
    /// since; on End the window is scored via `StrainScorer` and saved as a `WorkoutRow` (source
    /// "manual"), which then shows in the Workouts view. The day's strain already counts this HR (it's
    /// the same live stream the store persists), so this is a per-session annotation, not a double-count.
    @Published var activeWorkout: ActiveWorkout?
    /// The just-ended workout, for a brief inline confirmation on Live (cleared on the next start).
    @Published var lastWorkout: WorkoutRow?

    /// Records the GPS route of an in-flight distance-type workout (run / ride / walk / hike) from
    /// CoreLocation (#524) — the Apple analogue of Android's `GpsSession` + foreground `LocationManager`.
    /// Fails safe: on a Mac with no GPS, or when location permission is denied, it records nothing and
    /// the session still banks HR + Effort without a route. Its final route is persisted on End via
    /// `RouteStore`, keyed by the saved row's natural key (the shared `WorkoutRow` has no route column on
    /// Apple). Default behaviour is opt-in by sport: it only arms for a
    /// `WorkoutCatalog.Sport.isDistanceSport`, and only actually captures once the user grants When-In-Use
    /// location.
    private let gpsRecorder = GpsWorkoutRecorder()
    /// True while the active workout is a GPS-type session (drives the End-time route persist). Mirrors
    /// Android's `ActiveWorkout.gpsEnabled`.
    private var activeWorkoutIsGps = false

    private let repo: Repository
    private let deviceId: String
    private let profile: ProfileStore
    /// Confirming strap buzz (`loops` sets the length).
    private let buzz: (UInt8) -> Void

    init(repo: Repository, deviceId: String, profile: ProfileStore, buzz: @escaping (UInt8) -> Void) {
        self.repo = repo
        self.deviceId = deviceId
        self.profile = profile
        self.buzz = buzz
        rehydrateActiveWorkout()
    }

    /// Begin a manually-tracked workout for the named `sport` (the picker passes the chosen catalogue
    /// name; callers that don't pick a sport get the catalogue default "Other", parity with Android's
    /// `startWorkout(sport:)`). The active card on Live then shows elapsed time, live HR and strain
    /// building; End scores + saves it under this sport. Confirms with a single buzz. (#519)
    func startWorkout(sport: String = WorkoutCatalog.defaultSportName) {
        guard activeWorkout == nil else { return }
        lastWorkout = nil
        let name = sport.trimmingCharacters(in: .whitespaces)
        let resolved = name.isEmpty ? WorkoutCatalog.defaultSportName : name
        let started = Date()
        activeWorkout = ActiveWorkout(start: started, sport: resolved)
        // #524: arm GPS route recording for a distance-type sport (run / ride / walk / hike), mirroring
        // Android, which defaults GPS on for `isDistanceSport`. Manual-first / opt-in: only these sports
        // record a route, and the recorder still captures nothing unless the user grants When-In-Use
        // location (and on a Mac with no GPS it stays empty) — the session always banks HR + Effort
        // regardless. A non-distance sport (yoga, strength) never touches location at all.
        activeWorkoutIsGps = WorkoutCatalog.sport(named: resolved)?.isDistanceSport ?? false
        if activeWorkoutIsGps {
            gpsRecorder.start(startMs: Int64(started.timeIntervalSince1970 * 1000))
        }
        // Make the session durable from the first instant (#529): persist it now so an OS kill right
        // after Start — before any HR sample lands — can still be rehydrated + ended on relaunch.
        persistActiveWorkout()
        buzz(1)
    }

    /// Finish the active workout: finalize the GPS route (#524), score the captured HR window, and save it
    /// as a `WorkoutRow`. A session with no HR window AND no real GPS route is discarded quietly (parity
    /// with Android) — but a GPS-only walk with HR not streaming still saves. Double-buzz confirms.
    func endWorkout() {
        guard let w = activeWorkout else { return }
        activeWorkout = nil
        let wasGps = activeWorkoutIsGps
        activeWorkoutIsGps = false
        // Drop the durable snapshot the instant the session ends — whether it saves below or is discarded
        // as too-short — so a relaunch never rehydrates an already-finished session (#529).
        ActiveWorkoutPersistence.clear()
        // #524: finalize the GPS route. Stop the recorder and take its captured route — it kept
        // accumulating from CoreLocation independently of the HR window. `capturedRoute()` is nil unless
        // ≥2 points actually landed (honest: no route, no distance, when nothing was captured — e.g. a
        // Mac with no GPS, or denied permission). A non-GPS session never armed the recorder.
        var route: WorkoutRoute?
        if wasGps {
            gpsRecorder.stop()
            route = gpsRecorder.capturedRoute()
        }
        // Save when there's an HR window OR a real GPS route — a GPS-only walk (HR not streaming) is
        // still a workout (parity with Android's `samples.size < 2 && track.size < 2` discard gate).
        guard w.samples.count >= 2 || route != nil else { lastWorkout = nil; return }
        let row = scoredRow(for: w, end: Date(), route: route)
        // Persist the route polyline under the row's natural key so WorkoutDetailView can draw it. On
        // device only; mirrors the moments / sleepMarks UserDefaults persistence. (#524)
        if let route { RouteStore.store(route, startTs: row.startTs, sport: w.sport) }
        lastWorkout = row
        buzz(2)
        Task { [weak self] in
            guard let self else { return }
            if let store = await self.repo.storeHandle() {
                _ = try? await store.upsertWorkouts([row], deviceId: self.deviceId)
                await self.repo.refresh()
            }
        }
    }

    /// Score the captured HR window of `w` (avg / peak / strain / calories) into the saved row.
    private func scoredRow(for w: ActiveWorkout, end: Date, route: WorkoutRoute?) -> WorkoutRow {
        let samples = w.samples
        let avg = samples.isEmpty ? nil
            : Int((Double(samples.map(\.bpm).reduce(0, +)) / Double(samples.count)).rounded())
        let peak = samples.map(\.bpm).max()
        let strain = samples.count >= 2
            ? StrainScorer.strain(samples, maxHR: Double(profile.hrMax), sex: profile.sex) : nil
        // Estimate calories from the captured HR window (same Keytel/Harris–Benedict model the
        // auto-detector uses) so a manual session shows energy too, not just duration/strain. (#117)
        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex)
        let kcal = samples.count >= 2
            ? Calories.estimateBoutCalories(samples, profile: up, hrmax: Double(profile.hrMax), restingHR: nil).0
            : 0
        return WorkoutRow(
            startTs: Int(w.start.timeIntervalSince1970), endTs: Int(end.timeIntervalSince1970),
            sport: w.sport, source: "manual", durationS: end.timeIntervalSince(w.start),
            energyKcal: kcal > 0 ? kcal : nil, avgHr: avg, maxHr: peak, strain: strain,
            // GPS distance rides the shared row so the Workouts list / detail show it like any other
            // distance workout; the polyline itself is persisted alongside in RouteStore (the shared
            // WorkoutRow has no route column on Apple). Only a real route sets distance — honest "—".
            distanceM: route?.distanceM, zonesJSON: nil, notes: nil)
    }

    /// Append the current smoothed `bpm` to the active workout and recompute its running strain. Called
    /// on every fresh smoothed sample; a no-op when no workout is running. Recomputing strain over the
    /// growing window each sample is cheap at the ~1 Hz live-HR cadence.
    func captureSample(bpm: Int?) {
        guard var w = activeWorkout, let hr = bpm else { return }
        w.samples.append(HRSample(ts: Int(Date().timeIntervalSince1970), bpm: hr))
        w.peakHr = max(w.peakHr, hr)
        w.avgHr = Int((Double(w.samples.map(\.bpm).reduce(0, +)) / Double(w.samples.count)).rounded())
        w.liveStrain = StrainScorer.strain(w.samples, maxHR: Double(profile.hrMax), sex: profile.sex) ?? 0
        activeWorkout = w
        // Re-snapshot the durable session so a kill keeps the latest accumulated HR window (#529).
        persistActiveWorkout()
    }

    /// Persist the in-flight manual workout to `UserDefaults` so it survives the app being killed mid-
    /// session (#529). Called on start + each captured sample. A no-op when nothing is running. Apple has
    /// no GPS-route session, so every manual workout is the "non-GPS" case and gets this durability —
    /// the Apple analogue of Android's `persistNonGpsWorkout`.
    private func persistActiveWorkout() {
        guard let w = activeWorkout else { return }
        ActiveWorkoutPersistence.store(
            ActiveWorkoutPersistence.Snapshot(
                startSec: Int(w.start.timeIntervalSince1970),
                sport: w.sport,
                samples: w.samples,
                avgHr: w.avgHr,
                peakHr: w.peakHr,
                liveStrain: w.liveStrain))
    }

    /// If a manual workout was in flight when the app was killed, rebuild `activeWorkout` from the durable
    /// snapshot so reopening doesn't lose it — the session can still be ended + saved (#529). The Apple
    /// analogue of Android's `rehydrateActiveNonGpsWorkout`. No-op when a workout is already live (a live
    /// session wins over a stale snapshot) or nothing is stored. Called once from `init`.
    private func rehydrateActiveWorkout() {
        guard activeWorkout == nil, let snap = ActiveWorkoutPersistence.load() else { return }
        var w = ActiveWorkout(start: Date(timeIntervalSince1970: TimeInterval(snap.startSec)),
                              sport: snap.sport)
        w.samples = snap.samples
        w.avgHr = snap.avgHr
        w.peakHr = snap.peakHr
        w.liveStrain = snap.liveStrain
        activeWorkout = w
    }
}

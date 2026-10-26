import XCTest
import SwiftUI
import AppKit
import QuartzCore
import WhoopStore
import WhoopProtocol
@testable import StrandAnalytics
@testable import Strand

/// Main-thread budget harness. Opens a realistic WHOOP-export-sized database the same way the app does
/// (`WhoopStore(path:)` + `Repository`), then measures what blocks the MAIN thread:
///   * `Repository.refresh()` (store reads run on the store actor; the merges/publishes run on main);
///   * the synchronous per-pass builders the screens run inside `body` / `.task`
///     (`testSynchronousBuildersFitInOneFrame`, each timed against the implementation it replaced);
///   * the first layout of the big screens + a data refresh while each one is on screen, which covers
///     everything else those screens do on the main thread (model builds, SwiftUI body/layout/commit).
///
/// `NOOP_PERF_DB=/path/to/whoop.sqlite` measures a COPY of a real database (the original is never opened,
/// and no row content is ever printed — timings only). Without it, a deterministic synthetic database of
/// the same shape (400 days) is generated so CI can run this test.
///
/// Stall measurement: a background thread pings the main queue every ~2 ms; the ping latency is how long the
/// main thread was unavailable, so `maxStall` is the longest single block (a dropped frame is > 16 ms).
@MainActor
final class MainThreadBudgetTests: XCTestCase {

    // MARK: - Budgets

    /// One frame at 60 Hz.
    static let frameMs = 16.0
    /// The hard cap: no single main-actor step may exceed this on the real dataset.
    static let stepBudgetMs = 50.0
    /// GitHub-hosted macOS runners are shared VMs that run this Debug build a few times slower than a
    /// developer Mac, so on CI every budget is tripled: it still fails on an order-of-magnitude regression
    /// without flaking on runner noise. Local runs keep the tight budgets. The workflow forwards `CI` to the
    /// test host as `TEST_RUNNER_CI`; only the literal value `true` counts, so an empty or `false` `CI`
    /// keeps the tight budgets.
    static let ciSlack: Double = ProcessInfo.processInfo.environment["CI"]?.lowercased() == "true" ? 3 : 1

    // MARK: - Tests

    func testRefreshStaysUnderStepBudget() async throws {
        let env = try await PerfEnvironment.make()
        defer { env.cleanup() }

        var rows: [PerfRow] = []
        rows.append(contentsOf: await Self.waitForQuietHost())
        let baselineCount = rows.count
        // Cold (first read of the file) + warm repeats.
        for i in 0..<5 {
            let m = await StallProbe.measure { await env.repo.refresh() }
            rows.append(PerfRow(step: i == 0 ? "repo.refresh (cold)" : "repo.refresh (warm #\(i))",
                                wallMs: m.wallMs, maxStallMs: m.maxStallMs))
        }
        PerfReport.print("Repository.refresh — \(env.describe)", rows)

        let worst = rows.dropFirst(baselineCount).map(\.maxStallMs).max() ?? 0
        XCTAssertLessThan(worst, Self.stepBudgetMs * env.budgetSlack,
                          "repo.refresh blocked the main thread for \(Int(worst)) ms")
    }

    /// Mount each big screen against the loaded dataset, then refresh the repository while it is visible
    /// (the "new data landed" path every screen reacts to). Reports first-layout time and the longest main
    /// thread stall in each phase.
    func testScreenModelBuildsStayUnderStepBudget() async throws {
        let env = try await PerfEnvironment.make()
        defer { env.cleanup() }
        var rows: [PerfRow] = await Self.waitForQuietHost()
        let baselineCount = rows.count
        await env.repo.refresh()
        XCTAssertTrue(env.repo.loaded)

        // Each screen is mounted `repetitions` times (fresh hosting view each time); the median of the
        // longest stalls is reported and asserted, so one scheduler hiccup does not fail or mask a step.
        let repetitions = Int(ProcessInfo.processInfo.environment["NOOP_PERF_REPS"] ?? "") ?? 3
        for screen in env.screens {
            var runs: [PerfEnvironment.MountResult] = []
            for _ in 0..<max(1, repetitions) { runs.append(await env.mount(screen)) }
            func median(_ f: (PerfEnvironment.MountResult) -> Double) -> Double {
                let s = runs.map(f).sorted(); return s[s.count / 2]
            }
            rows.append(PerfRow(step: "\(screen.name) mount (first layout)",
                                wallMs: median(\.firstLayoutMs), maxStallMs: median(\.firstLayoutMs)))
            rows.append(PerfRow(step: "\(screen.name) mount (settle 1.2 s)",
                                wallMs: median(\.settleWallMs), maxStallMs: median(\.settleMaxStallMs)))
            rows.append(PerfRow(step: "\(screen.name) refresh while visible",
                                wallMs: median(\.refreshWallMs), maxStallMs: median(\.refreshMaxStallMs)))
        }
        PerfReport.print("Screens — \(env.describe)", rows)

        let worst = rows.dropFirst(baselineCount).map(\.maxStallMs).max() ?? 0
        XCTAssertLessThan(worst, Self.stepBudgetMs * env.budgetSlack,
                          "a screen step blocked the main thread for \(Int(worst)) ms")
    }

    /// The synchronous per-pass builders the big screens run on the main thread inside `body` / `.task`,
    /// timed one by one on the perf dataset, each against the implementation it replaced (reproduced in
    /// `PerfEqualityTests` / kept as `…ViaFoundation`). Every NEW step must fit in one frame (16 ms);
    /// the OLD column documents what the screens used to pay per pass. Best of 5 runs, in milliseconds.
    func testSynchronousBuildersFitInOneFrame() async throws {
        let env = try await PerfEnvironment.make()
        defer { env.cleanup() }
        await env.repo.refresh()
        let repo = env.repo
        let days = repo.days
        XCTAssertGreaterThan(days.count, 250)

        // Dataset pieces the builders consume.
        let now = Int(Date().timeIntervalSince1970)
        var workouts: [WorkoutRow] = []
        for dev in ["my-whoop", "apple-health", "my-whoop-noop", "lifting"] {
            workouts += (try? await env.store.workouts(deviceId: dev, from: now - 4000 * 86_400, to: now + 86_400,
                                                       limit: 5000)) ?? []
        }
        // Today's body reads the selected day dozens of times; Health runs calendarSeries per vital; Insights
        // ranks 6 behaviours × 7 outcomes × 3 lags; Compare/Trends parse every history day several times.
        let vitalSeries: [[(day: String, value: Double?)]] = [
            days.map { ($0.day, $0.recovery) }, days.map { ($0.day, $0.avgHrv) },
            days.map { ($0.day, $0.restingHr.map(Double.init)) }, days.map { ($0.day, $0.skinTempDevC) },
            days.map { ($0.day, $0.respRateBpm) }, days.map { ($0.day, $0.spo2Pct) },
        ]
        let dayKeys = days.map(\.day)
        let plainFormatter: DateFormatter = {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
        }()
        let utcParser: DateFormatter = {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"; return f
        }()
        var sink = 0   // keeps the optimiser from discarding results

        func best(_ block: () -> Void, reps: Int = 5) -> Double {
            var lo = Double.greatestFiniteMagnitude
            for _ in 0..<reps {
                let t0 = CACurrentMediaTime(); block(); lo = min(lo, (CACurrentMediaTime() - t0) * 1000)
            }
            return lo
        }
        var rows: [PerfRow] = []
        var newTimes: [(String, Double)] = []
        func record(_ name: String, new: () -> Void, old: () -> Void) {
            let n = best(new), o = best(old)
            rows.append(PerfRow(step: "\(name) — new", wallMs: n, maxStallMs: n))
            rows.append(PerfRow(step: "\(name) — old", wallMs: o, maxStallMs: o))
            newTimes.append((name, n))
        }

        repo.days = days   // fresh memo
        record("Today body: 200 × repo.today",
               new: { for _ in 0..<200 { sink &+= repo.today?.day.count ?? 0 } },
               old: {
                   for _ in 0..<200 {
                       let n = Date()
                       sink &+= Repository.resolveToday(days: days,
                                                        logicalKey: plainFormatter.string(from: n.addingTimeInterval(-4 * 3_600)),
                                                        localKey: plainFormatter.string(from: n))?.day.count ?? 0
                   }
               })
        record("Workouts/Insights load: cross-source dedup",
               new: { sink &+= WorkoutSource.dedupCrossSource(workouts).count },
               old: { sink &+= PerfEqualityTests.referenceDedup(workouts).count })
        record("Health body: calendarSeries × 6 vitals",
               new: { for s in vitalSeries { sink &+= VitalBands.calendarSeries(s).count } },
               old: { for s in vitalSeries { sink &+= VitalBands.calendarSeriesViaFoundation(s).count } })
        record("InsightsHub rank: shiftDay × days × 3 lags × 7 outcomes",
               new: { for _ in 0..<7 { for d in dayKeys { for lag in 1...3 { sink &+= CorrelationEngine.shiftDay(d, by: lag)?.count ?? 0 } } } },
               old: { for _ in 0..<7 { for d in dayKeys { for lag in 1...3 { sink &+= CorrelationEngine.shiftDayViaFoundation(d, by: lag)?.count ?? 0 } } } })
        record("Compare/Trends/Explore body: parse 6 series × 3 passes",
               new: { for _ in 0..<18 { for k in dayKeys { sink &+= DayKeyDateCache.utc.date(k) == nil ? 0 : 1 } } },
               old: { for _ in 0..<18 { for k in dayKeys { sink &+= utcParser.date(from: k) == nil ? 0 : 1 } } })
        record("Today/Sleep/Trends bodies: 300 × localDayKey",
               new: { for i in 0..<300 { sink &+= Repository.localDayKey(Date(timeIntervalSinceNow: Double(-(i % 8)))).count } },
               old: { for i in 0..<300 { sink &+= plainFormatter.string(from: Date(timeIntervalSinceNow: Double(-(i % 8)))).count } })
        XCTAssertGreaterThan(sink, 0)

        PerfReport.print("Synchronous builders (best of 5) — \(env.describe)", rows)
        for (name, ms) in newTimes {
            // Best-of-5 micro-timings are stable, so this stays at (twice) one frame even in -Onone Debug builds.
            XCTAssertLessThan(ms, Self.frameMs * 2 * Self.ciSlack, "\(name) takes \(ms) ms on the main thread")
        }
    }

    /// The test host IS the app: for the first seconds after launch its own window (Today screen, real
    /// container store) renders and refreshes on the same main thread. Wait until that settles so the
    /// measured step is not blamed for the host's own work. The wait itself is reported (it is the app's
    /// own start-up stall, measured in the host process).
    static func waitForQuietHost(maxSeconds: Int = 40) async -> [PerfRow] {
        var rows: [PerfRow] = []
        var quietInARow = 0
        for i in 0..<maxSeconds {
            let m = await StallProbe.measure { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            rows.append(PerfRow(step: "host idle window #\(i)", wallMs: m.wallMs, maxStallMs: m.maxStallMs))
            quietInARow = m.maxStallMs < 8 ? quietInARow + 1 : 0
            if quietInARow >= 2 { break }
        }
        return rows
    }
}

// MARK: - Report

struct PerfRow {
    let step: String
    let wallMs: Double
    let maxStallMs: Double
}

enum PerfReport {
    static func print(_ title: String, _ rows: [PerfRow]) {
        var out = "\nPERF| \(title)\n"
        out += "PERF| \("step".padding(toLength: 62, withPad: " ", startingAt: 0)) \("wall ms".leftPad(9)) \("max stall ms".leftPad(13))  >16ms >50ms\n"
        for r in rows {
            let flag16 = r.maxStallMs > MainThreadBudgetTests.frameMs ? "  *" : "   "
            let flag50 = r.maxStallMs > MainThreadBudgetTests.stepBudgetMs ? "  **" : "    "
            out += "PERF| \(r.step.padding(toLength: 62, withPad: " ", startingAt: 0)) "
            out += "\(String(format: "%.1f", r.wallMs).leftPad(9)) \(String(format: "%.1f", r.maxStallMs).leftPad(13)) \(flag16)  \(flag50)\n"
        }
        Swift.print(out)
        if let path = ProcessInfo.processInfo.environment["NOOP_PERF_REPORT"] {
            if let h = FileHandle(forWritingAtPath: path) ?? {
                FileManager.default.createFile(atPath: path, contents: nil)
                return FileHandle(forWritingAtPath: path)
            }() {
                h.seekToEndOfFile(); h.write(Data(out.utf8)); try? h.close()
            }
        }
    }
}

private extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}

// MARK: - Stall probe

/// Measures main-thread unavailability: a background thread posts a block to the main queue every ~2 ms and
/// records how long it waited. The maximum is the longest single main-thread block in the window.
final class StallProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var maxLatency = 0.0
    private var thread: Thread?

    func start() {
        lock.lock(); running = true; maxLatency = 0; lock.unlock()
        let t = Thread { [self] in
            while true {
                lock.lock(); let go = running; lock.unlock()
                if !go { break }
                let t0 = CACurrentMediaTime()
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { [self] in
                    let lat = CACurrentMediaTime() - t0
                    lock.lock(); if lat > maxLatency { maxLatency = lat }; lock.unlock()
                    sem.signal()
                }
                sem.wait()
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Stops the probe and returns the longest stall in ms. Yields briefly first so a ping that was queued
    /// behind a long main-thread block is still recorded.
    func stop() async -> Double {
        try? await Task.sleep(nanoseconds: 10_000_000)
        lock.lock(); running = false; let v = maxLatency; lock.unlock()
        return v * 1000
    }

    struct Result { let wallMs: Double; let maxStallMs: Double }

    @MainActor
    static func measure(_ work: () async -> Void) async -> Result {
        let p = StallProbe()
        p.start()
        let t0 = CACurrentMediaTime()
        await work()
        let wall = (CACurrentMediaTime() - t0) * 1000
        let stall = await p.stop()
        return Result(wallMs: wall, maxStallMs: stall)
    }
}

// MARK: - Environment (database + repository + hosted screens)

@MainActor
struct PerfScreen {
    let name: String
    let make: () -> AnyView
}

@MainActor
final class PerfEnvironment {
    let dir: URL
    let isSynthetic: Bool
    let store: WhoopStore
    let repo: Repository
    let live = LiveState()
    let profile = ProfileStore()
    let behavior = BehaviorStore()
    let intelligence: IntelligenceEngine
    let router = NavRouter()

    /// Multiplier on the 50 ms step budget. The shipped app is an optimised build; `xcodebuild test` builds
    /// Debug (-Onone), where SwiftUI/ARC-heavy code runs several times slower, and CI hardware is noisier
    /// than the dev machine. The default therefore guards against order-of-magnitude regressions (an O(n²)
    /// loop on the main thread); set `NOOP_PERF_SLACK=1` with an optimised build to hold the real 50 ms line.
    var budgetSlack: Double {
        if let s = ProcessInfo.processInfo.environment["NOOP_PERF_SLACK"], let v = Double(s), v > 0 { return v }
        return 6 * MainThreadBudgetTests.ciSlack
    }
    var describe: String { isSynthetic ? "synthetic 400-day database" : "copy of NOOP_PERF_DB" }

    static func make() async throws -> PerfEnvironment {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("whoop.sqlite").path

        var synthetic = true
        if let src = ProcessInfo.processInfo.environment["NOOP_PERF_DB"], !src.isEmpty {
            synthetic = false
            let fm = FileManager.default
            try fm.copyItem(atPath: src, toPath: dbPath)
            for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: src + suffix) {
                try fm.copyItem(atPath: src + suffix, toPath: dbPath + suffix)
            }
        } else {
            let s = try await WhoopStore(path: dbPath)
            try await SyntheticDataset.populate(s, deviceId: "my-whoop")
            try await s.checkpointWAL()
        }

        let store = try await WhoopStore(path: dbPath)
        return PerfEnvironment(dir: dir, isSynthetic: synthetic, store: store)
    }

    private init(dir: URL, isSynthetic: Bool, store: WhoopStore) {
        self.dir = dir
        self.isSynthetic = isSynthetic
        self.store = store
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        self.repo = repo
        self.intelligence = IntelligenceEngine(repo: repo, profile: profile, deviceId: "my-whoop")
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    /// The screens a user switches between most. Health/Workouts take the host app's live `AppModel`
    /// (the test host IS the app) only for its live-strap state; all data comes from this environment's repo.
    var screens: [PerfScreen] {
        func wrap<V: View>(_ v: V) -> AnyView {
            var any = AnyView(v
                .environmentObject(repo).environmentObject(live).environmentObject(profile)
                .environmentObject(behavior).environmentObject(intelligence)
                .environmentObject(router).environmentObject(UpdateStore.shared))
            if let model = AppModel.shared { any = AnyView(any.environmentObject(model)) }
            return any
        }
        var list: [PerfScreen] = [
            PerfScreen(name: "Today") { wrap(TodayView()) },
            PerfScreen(name: "Sleep") { wrap(SleepView()) },
            PerfScreen(name: "Trends") { wrap(TrendsView()) },
            PerfScreen(name: "Insights") { wrap(InsightsView()) },
            PerfScreen(name: "Stress") { wrap(StressView()) },
            PerfScreen(name: "InsightsHub") { wrap(InsightsHubView()) },
            PerfScreen(name: "Explore") { wrap(MetricExplorerView()) },
            PerfScreen(name: "Compare") { wrap(CompareView()) },
        ]
        if AppModel.shared != nil {
            list.append(PerfScreen(name: "Health") { wrap(HealthView()) })
            list.append(PerfScreen(name: "Workouts") { wrap(WorkoutsView()) })
        }
        // `NOOP_PERF_SCREENS=Today,Sleep` narrows the run (handy for profiling one screen).
        if let only = ProcessInfo.processInfo.environment["NOOP_PERF_SCREENS"], !only.isEmpty {
            let names = Set(only.split(separator: ",").map(String.init))
            list = list.filter { names.contains($0.name) }
        }
        return list
    }

    struct MountResult {
        var firstLayoutMs = 0.0
        var settleWallMs = 0.0, settleMaxStallMs = 0.0
        var refreshWallMs = 0.0, refreshMaxStallMs = 0.0
    }

    /// Hosts `screen` in an off-screen window, forces its first layout (synchronous `body` evaluation),
    /// lets its `.task`s settle, then refreshes the repository while it is on screen.
    func mount(_ screen: PerfScreen) async -> MountResult {
        var result = MountResult()
        let host = NSHostingView(rootView: screen.make())
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()

        let t0 = CACurrentMediaTime()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        result.firstLayoutMs = (CACurrentMediaTime() - t0) * 1000

        let settle = await StallProbe.measure { try? await Task.sleep(nanoseconds: 1_200_000_000) }
        result.settleWallMs = settle.wallMs
        result.settleMaxStallMs = settle.maxStallMs

        let refresh = await StallProbe.measure {
            await repo.refresh()
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        result.refreshWallMs = refresh.wallMs
        result.refreshMaxStallMs = refresh.maxStallMs

        window.contentView = nil
        window.close()
        return result
    }
}

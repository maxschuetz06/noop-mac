import XCTest
import SwiftUI
import AppKit
import WidgetKit
import StrandDesign
@testable import Strand

/// Offscreen visual QA harness: renders the core screens and the desktop-widget families to PNG files so
/// they can be inspected while the Mac's screen is locked (no screen capture involved: the views are hosted
/// in an offscreen borderless `NSWindow` and drawn with `cacheDisplay`).
///
/// SKIPPED unless `NOOP_SNAPSHOT_DIR` is set (the sandboxed test host usually can't write there; it then
/// falls back to a folder in its temporary directory, see the `SNAPSHOT_DIR` log line).
/// Data comes from `PerfEnvironment` (a COPY of `NOOP_PERF_DB`,
/// or the synthetic dataset when unset); the original database is never opened. Only file names, sizes and
/// pixel statistics are logged — no health values. Images are written into the (0700) snapshot folder only.
///
///     TEST_RUNNER_NOOP_PERF_DB=/tmp/noop-perf-db/whoop.sqlite TEST_RUNNER_NOOP_SNAPSHOT_DIR=/tmp/noop-snapshots \
///       xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
///       CODE_SIGN_IDENTITY=- -only-testing:StrandTests/ScreenSnapshotQATests
///
/// Per screen: `<name>.png` (1280×900 window) and `<name>_tall.png` (1280×2600, shows long screens in full).
/// Widgets: `widget_<family>_<full|sparse>.png` at the native macOS widget sizes.
@MainActor
final class ScreenSnapshotQATests: XCTestCase {

    private static let windowSize = CGSize(width: 1280, height: 900)
    private static let tallSize = CGSize(width: 1280, height: 2600)

    func testRenderScreensAndWidgets() async throws {
        guard let dirPath = ProcessInfo.processInfo.environment["NOOP_SNAPSHOT_DIR"], !dirPath.isEmpty else {
            throw XCTSkip("Set NOOP_SNAPSHOT_DIR to render screen snapshots.")
        }
        // The test host is the sandboxed app and may only write inside its container. Fall back to its
        // temporary directory when the requested folder is not writable (path is printed).
        var outDir = URL(fileURLWithPath: dirPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // The sandbox may allow stat/mkdir-existing but still refuse writes: probe with a real write.
            let probe = outDir.appendingPathComponent(".write-probe")
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
        } catch {
            outDir = FileManager.default.temporaryDirectory.appendingPathComponent("qa-snapshots", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            print("SNAPSHOT_DIR sandbox cannot write \(dirPath); using \(outDir.path)")
        }

        let env = try await PerfEnvironment.make()
        defer { env.cleanup() }
        await env.repo.refresh()
        XCTAssertTrue(env.repo.loaded)

        var written = 0
        // Optional filter, e.g. NOOP_SNAPSHOT_SCREENS=Today,Sleep,Widgets
        let only = ProcessInfo.processInfo.environment["NOOP_SNAPSHOT_SCREENS"]
            .map { Set($0.split(separator: ",").map(String.init)) }

        for screen in env.snapshotScreens where only?.contains(screen.name) ?? true {
            let host = NSHostingView(rootView: screen.make())
            let window = Self.offscreenWindow(host: host, size: Self.windowSize)
            await Self.settle(host, window: window, seconds: 2.0)
            written += try Self.write(Self.render(host), name: screen.name, dir: outDir)

            window.setContentSize(Self.tallSize)
            host.frame = NSRect(origin: .zero, size: Self.tallSize)
            await Self.settle(host, window: window, seconds: 1.2)
            written += try Self.write(Self.render(host), name: screen.name + "_tall", dir: outDir)

            window.contentView = nil
            window.close()
        }

        // Desktop widget (native macOS widget sizes; the system adds ~16 pt content margins).
        let families: [(String, WidgetFamily, CGSize)] = [
            ("small", .systemSmall, CGSize(width: 170, height: 170)),
            ("medium", .systemMedium, CGSize(width: 364, height: 170)),
            ("large", .systemLarge, CGSize(width: 364, height: 382)),
        ]
        let entries: [(String, MacEntry)] = [
            ("full", MacEntry(date: Date(),
                              snapshot: WidgetSnapshot(recovery: 72, bpm: 61, batteryPct: 84, bonded: true,
                                                       updated: Date(), effort: 59, rest: 84, hrv: 64,
                                                       restingHr: 52, lastSync: Date().addingTimeInterval(-12 * 60)),
                              isPlaceholder: false)),
            ("sparse", MacEntry(date: Date(),
                                snapshot: WidgetSnapshot(recovery: 28, bpm: nil, batteryPct: nil, bonded: false,
                                                         updated: Date()),
                                isPlaceholder: false)),
        ]
        if only == nil || only?.contains("Widgets") == true {
            for (famName, family, size) in families {
                for (entryName, entry) in entries {
                    let view = MacWidgetView(entry: entry, familyOverride: family)
                        .padding(16)
                        .frame(width: size.width, height: size.height)
                        .background(StrandPalette.surfaceBase)
                        .environment(\.colorScheme, .dark)
                    let host = NSHostingView(rootView: view)
                    let window = Self.offscreenWindow(host: host, size: size)
                    await Self.settle(host, window: window, seconds: 0.4)
                    written += try Self.write(Self.render(host), name: "widget_\(famName)_\(entryName)", dir: outDir)
                    window.contentView = nil
                    window.close()
                }
            }
        }
        XCTAssertGreaterThan(written, 0)
    }

    // MARK: - Helpers

    private static func offscreenWindow(host: NSView, size: CGSize) -> NSWindow {
        host.frame = NSRect(origin: .zero, size: size)
        // Borderless: no title bar, and AppKit does not clamp it to the screen height (tall captures).
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: snapshotIsLight ? .aqua : .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        return window
    }

    /// Lets `.task`s / data loads / animations finish: a few layout passes spread over `seconds`.
    private static func settle(_ host: NSView, window: NSWindow, seconds: Double) async {
        let steps = max(1, Int(seconds / 0.2))
        for _ in 0..<steps {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private static func render(_ host: NSView) -> NSBitmapImageRep? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Writes the PNG (0600) and logs name / size / pixel stats only. Fails on a missing or uniform image.
    private static func write(_ rep: NSBitmapImageRep?, name: String, dir: URL) throws -> Int {
        let rep = try XCTUnwrap(rep, "\(name): could not render")
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "\(name): PNG encode failed")
        let url = dir.appendingPathComponent("\(name).png")
        try png.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let varied = variedPixelFraction(rep)
        print("SNAPSHOT \(name).png \(rep.pixelsWide)x\(rep.pixelsHigh) \(png.count) bytes, non-background pixels \(String(format: "%.1f", varied * 100)) %")
        XCTAssertGreaterThan(varied, 0.001, "\(name): image looks blank")
        return 1
    }

    /// Fraction of (sampled) pixels that differ from the top-left pixel — a cheap blank-image check.
    private static func variedPixelFraction(_ rep: NSBitmapImageRep) -> Double {
        guard let data = rep.bitmapData else { return 0 }
        let bpp = rep.bitsPerPixel / 8, rowBytes = rep.bytesPerRow
        guard bpp >= 3 else { return 0 }
        let ref = (data[0], data[1], data[2])
        var total = 0, varied = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                let p = data + y * rowBytes + x * bpp
                total += 1
                if p[0] != ref.0 || p[1] != ref.1 || p[2] != ref.2 { varied += 1 }
            }
        }
        return total == 0 ? 0 : Double(varied) / Double(total)
    }
}

/// `NOOP_SNAPSHOT_APPEARANCE=light` renders the screens in light mode (default dark).
private var snapshotIsLight: Bool {
    ProcessInfo.processInfo.environment["NOOP_SNAPSHOT_APPEARANCE"] == "light"
}

/// `NOOP_SNAPSHOT_LOCALE=de_DE` (or `en_US`) renders the screens in that locale (default: the app setting).
private var snapshotLocale: Locale {
    ProcessInfo.processInfo.environment["NOOP_SNAPSHOT_LOCALE"].map(Locale.init(identifier:))
        ?? AppLanguage.currentContentLocale
}

extension PerfEnvironment {
    /// The QA screen list: the perf screens' set plus Smart Alarm, Data Sources and Settings.
    var snapshotScreens: [PerfScreen] {
        func wrap<V: View>(_ v: V) -> AnyView {
            var any = AnyView(v
                .environmentObject(repo).environmentObject(live).environmentObject(profile)
                .environmentObject(behavior).environmentObject(intelligence).environmentObject(coach)
                .environmentObject(router).environmentObject(UpdateStore.shared)
                .environment(\.locale, snapshotLocale)
                .preferredColorScheme(snapshotIsLight ? .light : .dark))
            if let model = AppModel.shared { any = AnyView(any.environmentObject(model)) }
            return any
        }
        var list: [PerfScreen] = [
            PerfScreen(name: "Home") { wrap(HomeView()) },
            PerfScreen(name: "Shell") { wrap(RootView()) },
            PerfScreen(name: "Today") { wrap(TodayView()) },
            PerfScreen(name: "Sleep") { wrap(SleepView()) },
            PerfScreen(name: "Trends") { wrap(TrendsView()) },
            PerfScreen(name: "Stress") { wrap(StressView()) },
            PerfScreen(name: "Explore") { wrap(MetricExplorerView()) },
            PerfScreen(name: "Compare") { wrap(CompareView()) },
        ]
        if AppModel.shared != nil {
            list.append(PerfScreen(name: "Workouts") { wrap(WorkoutsView()) })
            list.append(PerfScreen(name: "Health") { wrap(HealthView()) })
            list.append(PerfScreen(name: "SmartAlarm") { wrap(SmartAlarmView()) })
            list.append(PerfScreen(name: "DataSources") { wrap(DataSourcesView()) })
            list.append(PerfScreen(name: "Settings") { wrap(SettingsView()) })
            list.append(PerfScreen(name: "Live") { wrap(LiveView()) })
            list.append(PerfScreen(name: "Breathe") { wrap(BreathingView()) })
            list.append(PerfScreen(name: "Devices") { wrap(DevicesView()) })
        }
        return list
    }
}

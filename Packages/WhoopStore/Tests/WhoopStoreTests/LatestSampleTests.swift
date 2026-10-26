import XCTest
import WhoopProtocol
@testable import WhoopStore

final class LatestSampleTests: XCTestCase {
    func testLatestHRSampleTs() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "d", mac: nil, name: nil)
        // No rows yet → nil.
        let empty = try await store.latestHRSampleTs(deviceId: "d")
        XCTAssertNil(empty)
        // Insert HR rows at ts 100 and 250; latest = 250.
        let s = Streams(hr: [HRSample(ts: 100, bpm: 60), HRSample(ts: 250, bpm: 61)])
        _ = try await store.insert(s, deviceId: "d")
        let latest = try await store.latestHRSampleTs(deviceId: "d")
        XCTAssertEqual(latest, 250)
    }

    /// The stuck-strap watchdog frontier must advance on a PPG-only offload too (#156): a v26
    /// WHOOP 5 night with no measured HR still has a real data frontier from its PPG rows.
    func testLatestHRSampleTsIncludesPpgFallbackRows() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "d", mac: nil, name: nil)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 100, bpm: 60)]), deviceId: "d")
        _ = try await store.insert(
            Streams(ppgHr: [PpgHrSample(ts: 300, bpm: 62, conf: 0.8)]), deviceId: "d")

        let latest = try await store.latestHRSampleTs(deviceId: "d")
        XCTAssertEqual(latest, 300)
    }

    /// The history frontier must NOT follow realtime HR / R-R / events / battery (the live stream pushes
    /// those to "now"); it advances only with rows the historical offload alone writes.
    func testLatestHistoryTsIgnoresRealtimeOnlyTables() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "d", mac: nil, name: nil)
        let none = try await store.latestHistoryTs(deviceId: "d")
        XCTAssertNil(none)

        // Live-style rows far in the "future": HR, R-R, battery, event.
        _ = try await store.insert(Streams(
            hr: [HRSample(ts: 9_000, bpm: 60)], rr: [RRInterval(ts: 9_000, rrMs: 900)],
            events: [WhoopEvent(ts: 9_000, kind: "DOUBLE_TAP(14)", payload: [:])],
            battery: [BatterySample(ts: 9_000, soc: 50, mv: 3800, charging: false)]), deviceId: "d")
        let stillNone = try await store.latestHistoryTs(deviceId: "d")
        XCTAssertNil(stillNone, "realtime-only rows are not history")

        // History-only rows at older timestamps: the frontier is their max, not the live "now".
        var history = Streams(gravity: [GravitySample(ts: 100, x: 0, y: 0, z: 1)])
        history.strapState = [StrapStateSample(ts: 400, onWrist: 1, sleepState: 1)]
        _ = try await store.insert(history, deviceId: "d")
        let afterHistory = try await store.latestHistoryTs(deviceId: "d")
        XCTAssertEqual(afterHistory, 400)
        let hrFrontier = try await store.latestHRSampleTs(deviceId: "d")
        XCTAssertEqual(hrFrontier, 9_000, "HR frontier is dragged to 'now' by the live stream")

        _ = try await store.insert(Streams(skinTemp: [SkinTempSample(ts: 650, raw: 3200)],
                                           steps: [StepSample(ts: 700, counter: 10)]), deviceId: "d")
        let advanced = try await store.latestHistoryTs(deviceId: "d")
        XCTAssertEqual(advanced, 700)
        // Per-device.
        let other = try await store.latestHistoryTs(deviceId: "other")
        XCTAssertNil(other)
    }
}

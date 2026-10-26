import XCTest
@testable import Strand
import WhoopProtocol
import WhoopStore

/// The retro-decode gate re-runs the reject archive (the only surviving copy of acked-but-undecodable
/// records) through the current decoder: once per gate version, idempotently against a real store,
/// and never closing the gate when an insert fails.
final class RejectArchiveReplayGateTests: XCTestCase {
    /// Real WHOOP 4.0 v25 records (84 B, 1 Hz) that pre-v25 builds archived as undecodable; the
    /// current decoder turns each into one gravity sample.
    private static let v25Frames = [
        "aa50000c2f190013390000140d2b6a4075010068a2010032fdbcfd98fdd3fdccfd47ffb00366064f073e06c103d3016cffa2fc87fa2ffae5fdbe03140675060c0510012dff1bfec0018f3c500500010068dc8f44",
        "aa50000c2f190014390000150d2b6a487001003ab301008dfd6afdaffda9fdaffd68fddbfb0dfc09fd77fe89fe62febffec9fe91ff0bff81ff5fff3e00d600790078ff3dff4bff801d553c5005010000d7c016b3",
        "aa50000c2f190015390000160d2b6a586b01006d8f0100a3ff94ffc4ffbcffbeff22004a009400cb0048005d006b004400d700130115013301f20088001d0031ffd9fe5eff75ff0048933c50050001008bdf2c2c",
    ]
    private static let deviceId = "replay-test"

    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-replay-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "noop-replay-gate-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    private func archiveWithV25Frames() throws -> RawHistoryArchive {
        let archive = RawHistoryArchive(directory: directory)
        guard case .written(3) = archive.archive(Self.v25Frames.map(bytes), trim: 70476, family: .whoop4) else {
            throw XCTSkip("the fixture archive could not be written")
        }
        return archive
    }

    private func tempStore() async throws -> WhoopStore {
        try await WhoopStore(path: directory.appendingPathComponent("store.sqlite").path)
    }

    private func gate(_ version: String) -> RejectArchiveReplayGate {
        RejectArchiveReplayGate(defaults: defaults, key: "testReplayGate", version: version)
    }

    private func gravity(in store: WhoopStore) async throws -> [GravitySample] {
        try await store.gravitySamples(deviceId: Self.deviceId, from: 0, to: Int.max, limit: 10_000)
    }

    func testANewVersionReplaysExactlyOnceAndTheSameVersionNeverAgain() async throws {
        let archive = try archiveWithV25Frames()
        let store = try await tempStore()
        defaults.set("1", forKey: "testReplayGate")

        let first = await gate("2").runIfDue(archive: archive, store: store, deviceId: Self.deviceId)
        let second = await gate("2").runIfDue(archive: archive, store: store, deviceId: Self.deviceId)

        XCTAssertEqual(first, .replayed(rows: 3))
        XCTAssertEqual(second, .notDue, "the same version must not replay again")
        let rows = try await gravity(in: store)
        XCTAssertEqual(rows.count, 3)
    }

    func testReplayingAlreadyDecodedFramesInsertsNothingAndKeepsEveryRow() async throws {
        let archive = try archiveWithV25Frames()
        let store = try await tempStore()
        let liveRow = GravitySample(ts: 1_700_000_123, x: 0.1, y: 0.2, z: 0.9)
        try await store.insert(Streams(gravity: [liveRow]), deviceId: Self.deviceId)

        let first = await gate("1").runIfDue(archive: archive, store: store, deviceId: Self.deviceId)
        let afterFirst = try await gravity(in: store)
        let second = await gate("2").runIfDue(archive: archive, store: store, deviceId: Self.deviceId)
        let afterSecond = try await gravity(in: store)

        XCTAssertEqual(first, .replayed(rows: 3))
        XCTAssertEqual(second, .replayed(rows: 0), "a re-run must not insert duplicates")
        XCTAssertEqual(afterFirst.count, 4)
        XCTAssertEqual(afterSecond, afterFirst, "a re-run must neither duplicate nor drop rows")
        XCTAssertTrue(afterSecond.contains(liveRow), "rows that were not in the archive survive")
    }

    func testAFailedInsertLeavesTheGateOpenForTheNextLaunch() async throws {
        final class FailingStore: BackfillStoreWriting {
            struct Boom: Error {}
            func insert(_ streams: Streams, deviceId: String) async throws
                -> (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
                throw Boom()
            }
            func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
            func setCursor(_ name: String, _ value: Int) async throws {}
            func cursor(_ name: String) async throws -> Int? { nil }
        }
        let archive = try archiveWithV25Frames()

        let outcome = await gate("2").runIfDue(archive: archive, store: FailingStore(), deviceId: Self.deviceId)

        XCTAssertEqual(outcome, .deferred)
        XCTAssertTrue(gate("2").isDue, "the archive is the only copy: a failed replay must retry")
    }
}

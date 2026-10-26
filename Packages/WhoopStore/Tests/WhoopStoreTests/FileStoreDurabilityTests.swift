import XCTest
import GRDB
@testable import WhoopStore

/// The backfill acks each chunk right after its commit and the strap then frees its copy, so a commit
/// must survive a power loss, not only an app crash: the file-backed store runs WAL with synchronous=FULL
/// and fullfsync, so macOS flushes the drive's write cache (F_FULLFSYNC) on every commit.
final class FileStoreDurabilityTests: XCTestCase {

    func testFileBackedStoreCommitsWithFullSynchronousAndFullFsync() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-durability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try await WhoopStore(path: dir.appendingPathComponent("whoop.sqlite").path)
        let (journalMode, synchronous, fullFsync) = try await store.registryQueue.read { db in
            (try String.fetchOne(db, sql: "PRAGMA journal_mode"),
             try Int.fetchOne(db, sql: "PRAGMA synchronous"),
             try Int.fetchOne(db, sql: "PRAGMA fullfsync"))
        }

        XCTAssertEqual(journalMode, "wal")
        XCTAssertEqual(synchronous, 2, "2 = FULL")
        XCTAssertEqual(fullFsync, 1, "1 = F_FULLFSYNC on every commit")
    }
}

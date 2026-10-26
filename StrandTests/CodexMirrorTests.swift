import XCTest
import SQLite3
@testable import Strand

/// Pure policy for the Codex mirror (rate limit) and the engine that publishes the read-only copy.
final class CodexMirrorPolicyTests: XCTestCase {
    func testDelayIsZeroWithoutPreviousRun() {
        XCTAssertEqual(CodexMirrorPolicy.delay(now: Date(), lastRun: nil), 0)
    }

    func testDelayCountsDownToTenMinutes() {
        let last = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(CodexMirrorPolicy.delay(now: last.addingTimeInterval(60), lastRun: last), 540, accuracy: 0.001)
        XCTAssertEqual(CodexMirrorPolicy.delay(now: last.addingTimeInterval(600), lastRun: last), 0)
        XCTAssertEqual(CodexMirrorPolicy.delay(now: last.addingTimeInterval(5_000), lastRun: last), 0)
    }
}

final class CodexMirrorEngineTests: XCTestCase {
    private var dir: URL!
    private var sourceURL: URL!
    private var mirrorDir: URL!
    private var db: OpaquePointer?

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("codexmirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sourceURL = dir.appendingPathComponent("whoop.sqlite")
        mirrorDir = dir.appendingPathComponent("NOOP-Data", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let db { sqlite3_close(db) }
        db = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func exec(_ sql: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql, file: file, line: line)
    }

    private func openLiveWAL(rows: Int) {
        XCTAssertEqual(sqlite3_open(sourceURL.path, &db), SQLITE_OK)
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA wal_autocheckpoint=0")
        exec("CREATE TABLE samples (id INTEGER PRIMARY KEY, v TEXT)")
        for i in 0..<rows { exec("INSERT INTO samples (v) VALUES ('row\(i)')") }
    }

    private func count(at url: URL) -> Int {
        var h: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(h) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(h, "SELECT COUNT(*) FROM samples", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func testMirrorPublishesWALDatabaseReadableAndLeavesOnlyFinalFiles() throws {
        openLiveWAL(rows: 120)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path + "-wal"))

        let url = try AutoBackupEngine.mirror(sourcePath: sourceURL.path, into: mirrorDir)

        XCTAssertEqual(url.lastPathComponent, "whoop-latest.sqlite")
        XCTAssertEqual(count(at: url), 120)
        XCTAssertEqual(try AutoBackupEngine.quickCheck(path: url.path), ["ok"])
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: mirrorDir.path))
        XCTAssertEqual(names, ["whoop-latest.sqlite", "README.txt"])
        // No chmod after the copy: 0600 here means the `.partial` was created owner-only before SQLite
        // wrote the first page (with the default umask it would otherwise be 0644).
        XCTAssertEqual(try mode(url), 0o600)
    }

    private func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue
    }

    func testMirrorTightensAnExistingFolderAndWritesOwnerOnlyFiles() throws {
        try FileManager.default.createDirectory(at: mirrorDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        openLiveWAL(rows: 3)
        let url = try AutoBackupEngine.mirror(sourcePath: sourceURL.path, into: mirrorDir)
        XCTAssertEqual(try mode(mirrorDir), 0o700)
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try mode(mirrorDir.appendingPathComponent("README.txt")), 0o600)
    }

    func testSecondMirrorReplacesContentAndKeepsExistingReadme() throws {
        openLiveWAL(rows: 5)
        let url = try AutoBackupEngine.mirror(sourcePath: sourceURL.path, into: mirrorDir)
        XCTAssertEqual(count(at: url), 5)

        let readme = mirrorDir.appendingPathComponent("README.txt")
        try "eigener Text".write(to: readme, atomically: true, encoding: .utf8)
        exec("INSERT INTO samples (v) VALUES ('more')")

        _ = try AutoBackupEngine.mirror(sourcePath: sourceURL.path, into: mirrorDir)
        XCTAssertEqual(count(at: url), 6)
        XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), "eigener Text")
    }

    func testReadmeIsEnglishThreeLines() {
        let lines = CodexMirrorPolicy.readmeText.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(CodexMirrorPolicy.readmeText.contains("read-only copy"))
    }

    func testMissingSourceFailsWithoutCreatingFiles() {
        XCTAssertThrowsError(try AutoBackupEngine.mirror(sourcePath: dir.appendingPathComponent("nope.sqlite").path,
                                                         into: mirrorDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirrorDir.path))
    }

    func testFailedMirrorKeepsPreviousFileAndLeavesNoPartial() throws {
        openLiveWAL(rows: 4)
        let url = try AutoBackupEngine.mirror(sourcePath: sourceURL.path, into: mirrorDir)
        // A non-database source makes the snapshot fail; the published mirror must survive untouched.
        let bogus = dir.appendingPathComponent("bogus.sqlite")
        try Data(String(repeating: "not a database ", count: 200).utf8).write(to: bogus)
        XCTAssertThrowsError(try AutoBackupEngine.mirror(sourcePath: bogus.path, into: mirrorDir))
        XCTAssertEqual(count(at: url), 4)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: mirrorDir.path).contains { $0.hasSuffix(".partial") })
    }

    @MainActor
    func testSchedulerRunNowPublishesIntoInjectedDirectory() async throws {
        openLiveWAL(rows: 7)
        let path = sourceURL.path
        let scheduler = CodexMirrorScheduler(directory: mirrorDir, sourcePath: { path })
        let result = await scheduler.runNow()
        let url = try result.get()
        XCTAssertEqual(count(at: url), 7)
        XCTAssertNotNil(scheduler.lastMirrorAt)
        XCTAssertNil(scheduler.lastMirrorError)
    }
}

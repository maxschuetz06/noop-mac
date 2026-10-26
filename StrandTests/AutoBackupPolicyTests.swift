import XCTest
import SQLite3
@testable import Strand

/// Pure policy logic for the automatic daily database backup (filename, due-check, retention).
final class AutoBackupPolicyTests: XCTestCase {
    private func calendar(_ tz: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        return cal
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    func testFileNameUsesLocalCalendarDate() {
        // 2026-10-14 23:30 UTC is already 2026-10-15 in Berlin (CEST, UTC+2).
        let d = date("2026-10-14T23:30:00Z")
        XCTAssertEqual(AutoBackupPolicy.fileName(for: d, calendar: calendar("UTC")), "whoop-2026-10-14.sqlite")
        XCTAssertEqual(AutoBackupPolicy.fileName(for: d, calendar: calendar("Europe/Berlin")), "whoop-2026-10-15.sqlite")
    }

    func testFileNameZeroPads() {
        let d = date("2026-01-05T12:00:00Z")
        XCTAssertEqual(AutoBackupPolicy.fileName(for: d, calendar: calendar("UTC")), "whoop-2026-01-05.sqlite")
    }

    func testIsBackupFileNameIsStrict() {
        XCTAssertTrue(AutoBackupPolicy.isBackupFileName("whoop-2026-10-14.sqlite"))
        XCTAssertFalse(AutoBackupPolicy.isBackupFileName("whoop-2026-10-14.sqlite.partial"))
        XCTAssertFalse(AutoBackupPolicy.isBackupFileName("whoop-2026-10-14.sqlite-wal"))
        XCTAssertFalse(AutoBackupPolicy.isBackupFileName("whoop.sqlite"))
        XCTAssertFalse(AutoBackupPolicy.isBackupFileName("whoop-latest.sqlite"))
        XCTAssertFalse(AutoBackupPolicy.isBackupFileName("notes.txt"))
        XCTAssertFalse(AutoBackupPolicy.isBackupFileName("whoop-2026-1-4.sqlite"))
    }

    func testIsDueWhenNoBackupForToday() {
        let cal = calendar("UTC")
        let now = date("2026-10-14T10:00:00Z")
        XCTAssertTrue(AutoBackupPolicy.isDue(now: now, existingFileNames: [], calendar: cal))
        XCTAssertTrue(AutoBackupPolicy.isDue(now: now, existingFileNames: ["whoop-2026-10-13.sqlite"], calendar: cal))
        XCTAssertTrue(AutoBackupPolicy.isDue(now: now, existingFileNames: ["notes.txt"], calendar: cal))
    }

    func testIsNotDueWhenTodayExists() {
        let cal = calendar("UTC")
        let now = date("2026-10-14T10:00:00Z")
        XCTAssertFalse(AutoBackupPolicy.isDue(now: now, existingFileNames: ["whoop-2026-10-14.sqlite", "whoop-2026-10-13.sqlite"], calendar: cal))
    }

    func testIsDueRollsOverAtLocalMidnight() {
        let cal = calendar("Europe/Berlin")
        let existing = ["whoop-2026-10-14.sqlite"]
        XCTAssertFalse(AutoBackupPolicy.isDue(now: date("2026-10-14T21:59:00Z"), existingFileNames: existing, calendar: cal))
        XCTAssertTrue(AutoBackupPolicy.isDue(now: date("2026-10-14T22:00:00Z"), existingFileNames: existing, calendar: cal))
    }

    func testPruneKeepsNewestAndIgnoresOtherFiles() {
        var names = (1...20).map { String(format: "whoop-2026-09-%02d.sqlite", $0) }
        names += ["whoop.sqlite", "notes.txt", "whoop-2026-09-01.sqlite.partial"]
        let pruned = AutoBackupPolicy.filesToPrune(from: names.shuffled(), keep: 14)
        XCTAssertEqual(Set(pruned), Set((1...6).map { String(format: "whoop-2026-09-%02d.sqlite", $0) }))
    }

    func testPruneNothingWhenWithinLimit() {
        let names = (1...14).map { String(format: "whoop-2026-09-%02d.sqlite", $0) }
        XCTAssertTrue(AutoBackupPolicy.filesToPrune(from: names, keep: 14).isEmpty)
        XCTAssertTrue(AutoBackupPolicy.filesToPrune(from: [], keep: 14).isEmpty)
    }

    func testPruneSortsAcrossMonthAndYearBoundaries() {
        let names = ["whoop-2025-12-31.sqlite", "whoop-2026-01-01.sqlite", "whoop-2026-01-02.sqlite"]
        XCTAssertEqual(AutoBackupPolicy.filesToPrune(from: names, keep: 2), ["whoop-2025-12-31.sqlite"])
    }

    func testDefaultKeepCountIsFourteen() {
        XCTAssertEqual(AutoBackupPolicy.keepCount, 14)
    }
}

/// Engine: online-backup of a real (WAL-mode) SQLite file into the AutoBackups folder.
final class AutoBackupEngineTests: XCTestCase {
    private var dir: URL!
    private var sourceURL: URL!
    private var backupDir: URL!
    private var db: OpaquePointer?

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("autobackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sourceURL = dir.appendingPathComponent("whoop.sqlite")
        backupDir = dir.appendingPathComponent("AutoBackups", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let db { sqlite3_close(db) }
        db = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func exec(_ handle: OpaquePointer?, _ sql: String, file: StaticString = #filePath, line: UInt = #line) {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        XCTAssertEqual(rc, SQLITE_OK, "sql failed: \(sql) — \(err.map { String(cString: $0) } ?? "")", file: file, line: line)
        sqlite3_free(err)
    }

    private func openLiveWAL(rows: Int) {
        XCTAssertEqual(sqlite3_open(sourceURL.path, &db), SQLITE_OK)
        exec(db, "PRAGMA journal_mode=WAL")
        // Keep committed pages in the WAL so a raw copy of the main file would miss them.
        exec(db, "PRAGMA wal_autocheckpoint=0")
        exec(db, "CREATE TABLE samples (id INTEGER PRIMARY KEY, v TEXT)")
        for i in 0..<rows { exec(db, "INSERT INTO samples (v) VALUES ('row\(i)')") }
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

    private func now(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testBackupContainsUncheckpointedWALRowsAndPassesQuickCheck() throws {
        openLiveWAL(rows: 250)
        // Precondition: the data really is still in the WAL (main file alone would be incomplete).
        let wal = sourceURL.path + "-wal"
        XCTAssertTrue(FileManager.default.fileExists(atPath: wal))

        let url = try AutoBackupEngine.backup(sourcePath: sourceURL.path, into: backupDir,
                                              now: now("2026-10-14T10:00:00Z"), calendar: utc)
        XCTAssertEqual(url.lastPathComponent, "whoop-2026-10-14.sqlite")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, backupDir.standardizedFileURL)
        XCTAssertEqual(count(at: url), 250)
        XCTAssertEqual(try AutoBackupEngine.quickCheck(path: url.path), ["ok"])
        // Single self-contained file: no sidecars, no leftover temp files.
        let names = try FileManager.default.contentsOfDirectory(atPath: backupDir.path)
        XCTAssertEqual(names, ["whoop-2026-10-14.sqlite"])
    }

    func testBackupLeavesLiveDatabaseUsable() throws {
        openLiveWAL(rows: 10)
        _ = try AutoBackupEngine.backup(sourcePath: sourceURL.path, into: backupDir,
                                        now: now("2026-10-14T10:00:00Z"), calendar: utc)
        exec(db, "INSERT INTO samples (v) VALUES ('after')")
        XCTAssertEqual(count(at: sourceURL), 11)
    }

    func testSameDayBackupReplacesExistingFile() throws {
        openLiveWAL(rows: 5)
        let d = now("2026-10-14T10:00:00Z")
        let first = try AutoBackupEngine.backup(sourcePath: sourceURL.path, into: backupDir, now: d, calendar: utc)
        XCTAssertEqual(count(at: first), 5)
        exec(db, "INSERT INTO samples (v) VALUES ('more')")
        let second = try AutoBackupEngine.backup(sourcePath: sourceURL.path, into: backupDir, now: d, calendar: utc)
        XCTAssertEqual(first, second)
        XCTAssertEqual(count(at: second), 6)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backupDir.path).count, 1)
    }

    func testRetentionPrunesOldBackupsOnlyAfterSuccessAndKeepsOtherFiles() throws {
        openLiveWAL(rows: 3)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        for i in 1...16 {
            let n = String(format: "whoop-2026-09-%02d.sqlite", i)
            try Data("x".utf8).write(to: backupDir.appendingPathComponent(n))
        }
        try Data("keep".utf8).write(to: backupDir.appendingPathComponent("notes.txt"))

        _ = try AutoBackupEngine.backup(sourcePath: sourceURL.path, into: backupDir,
                                        now: now("2026-10-14T10:00:00Z"), calendar: utc, keep: 14)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: backupDir.path))
        let backups = names.filter(AutoBackupPolicy.isBackupFileName)
        XCTAssertEqual(backups.count, 14)
        XCTAssertTrue(backups.contains("whoop-2026-10-14.sqlite"))
        XCTAssertFalse(backups.contains("whoop-2026-09-01.sqlite"))
        XCTAssertFalse(backups.contains("whoop-2026-09-03.sqlite"))
        XCTAssertTrue(backups.contains("whoop-2026-09-04.sqlite"))
        XCTAssertTrue(names.contains("notes.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testFailureDoesNotPruneAndLeavesNoPartialFile() throws {
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        for i in 1...16 {
            let n = String(format: "whoop-2026-09-%02d.sqlite", i)
            try Data("x".utf8).write(to: backupDir.appendingPathComponent(n))
        }
        let missing = dir.appendingPathComponent("does-not-exist.sqlite").path
        XCTAssertThrowsError(try AutoBackupEngine.backup(sourcePath: missing, into: backupDir,
                                                         now: now("2026-10-14T10:00:00Z"), calendar: utc))
        let names = try FileManager.default.contentsOfDirectory(atPath: backupDir.path)
        XCTAssertEqual(names.count, 16)
        XCTAssertFalse(names.contains { $0.hasSuffix(".partial") })
    }

    func testCorruptSourceIsRejectedAndNothingIsPublished() throws {
        try Data(repeating: 0x41, count: 8192).write(to: sourceURL)
        XCTAssertThrowsError(try AutoBackupEngine.backup(sourcePath: sourceURL.path, into: backupDir,
                                                         now: now("2026-10-14T10:00:00Z"), calendar: utc))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: backupDir.path)) ?? []
        XCTAssertTrue(names.isEmpty, "unexpected files: \(names)")
    }
}

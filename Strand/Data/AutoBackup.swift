import Foundation
import Combine
import SQLite3

// MARK: - Policy (pure, testable)

/// Pure rules for the automatic daily database backup: file naming, "is a backup due", retention.
/// Everything is value-in / value-out with injected dates + calendars so it is trivially testable.
enum AutoBackupPolicy {
    /// How many of the newest daily backups to keep.
    static let keepCount = 14
    static let filePrefix = "whoop-"
    static let fileExtension = "sqlite"
    /// Folder (next to the live DB) that holds the backups.
    static let directoryName = "AutoBackups"

    /// `whoop-YYYY-MM-DD.sqlite` for the *local* calendar day of `date`.
    static func fileName(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%@%04d-%02d-%02d.%@", filePrefix, c.year ?? 0, c.month ?? 0, c.day ?? 0, fileExtension)
    }

    /// Strictly `whoop-YYYY-MM-DD.sqlite` — temp (`.partial`) files, sidecars and anything else don't match.
    static func isBackupFileName(_ name: String) -> Bool {
        let pattern = "^whoop-[0-9]{4}-[0-9]{2}-[0-9]{2}\\.sqlite$"
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    /// A backup is due when no backup exists yet for today's local date.
    static func isDue(now: Date, existingFileNames: [String], calendar: Calendar = .current) -> Bool {
        !existingFileNames.contains(fileName(for: now, calendar: calendar))
    }

    /// Backup file names to delete so only the `keep` newest remain. Names sort chronologically
    /// (ISO dates); non-backup names are ignored and never returned.
    static func filesToPrune(from names: [String], keep: Int = keepCount) -> [String] {
        let backups = names.filter(isBackupFileName).sorted(by: >)
        guard backups.count > max(keep, 0) else { return [] }
        return Array(backups.dropFirst(max(keep, 0)))
    }
}

// MARK: - Engine

enum AutoBackupError: LocalizedError {
    case alreadyRunning
    case missingDatabase(String)
    case sqlite(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "A backup is already running."
        case .missingDatabase(let p): return "No database found at \(p)."
        case .sqlite(let m): return "SQLite error: \(m)"
        case .verificationFailed(let m): return "Backup verification failed: \(m)"
        }
    }
}

/// Consistent snapshot of the live SQLite store via SQLite's online backup API. Safe while the app
/// is writing (WAL): the backup runs in one read transaction on its own read-only connection.
enum AutoBackupEngine {

    /// Creates `<directory>/whoop-YYYY-MM-DD.sqlite` from `sourcePath`, verifies it, atomically
    /// publishes it, then prunes old backups (only after success). Blocking — call off the main thread.
    @discardableResult
    static func backup(sourcePath: String, into directory: URL, now: Date = Date(),
                       calendar: Calendar = .current, keep: Int = AutoBackupPolicy.keepCount) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourcePath) else { throw AutoBackupError.missingDatabase(sourcePath) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let finalName = AutoBackupPolicy.fileName(for: now, calendar: calendar)
        let finalURL = directory.appendingPathComponent(finalName)
        try snapshot(sourcePath: sourcePath, to: finalURL)

        prune(directory: directory, keep: keep, protecting: finalName)
        return finalURL
    }

    /// Process-wide lock so a daily backup and a Codex mirror never snapshot at the same time.
    private static let snapshotLock = NSLock()

    /// Consistent copy of `sourcePath` published atomically at `finalURL`: online backup into a sibling
    /// `.partial`, `PRAGMA quick_check`, then `rename(2)`. The `.partial` is removed on any failure.
    /// Blocking and serialized with other snapshots.
    static func snapshot(sourcePath: String, to finalURL: URL, filePermissions: mode_t? = nil) throws {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        // Same directory as the destination so the final rename is atomic (same volume).
        let tempURL = URL(fileURLWithPath: finalURL.path + ".partial")
        removeIfPresent(tempURL)
        removeIfPresent(URL(fileURLWithPath: tempURL.path + "-wal"))
        removeIfPresent(URL(fileURLWithPath: tempURL.path + "-shm"))

        do {
            // With explicit permissions the `.partial` exists with them before SQLite writes a single
            // page (SQLite keeps an existing file's mode and gives its journal the same mode).
            if let filePermissions, try !PrivateFiles.createEmptyFile(at: tempURL, mode: filePermissions) {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: tempURL.path])
            }
            try onlineBackup(from: sourcePath, to: tempURL.path)
            // Switching the copy out of WAL mode can leave an orphan `-shm` behind; the file itself is
            // now a plain rollback-journal database, so the sidecars are meaningless.
            removeIfPresent(URL(fileURLWithPath: tempURL.path + "-wal"))
            removeIfPresent(URL(fileURLWithPath: tempURL.path + "-shm"))
            let result = try quickCheck(path: tempURL.path)
            guard result == ["ok"] else {
                throw AutoBackupError.verificationFailed(result.joined(separator: "; "))
            }
            // rename(2) atomically replaces an existing file at the destination.
            guard rename(tempURL.path, finalURL.path) == 0 else {
                throw AutoBackupError.sqlite("rename failed (errno \(errno))")
            }
        } catch {
            removeIfPresent(tempURL)
            removeIfPresent(URL(fileURLWithPath: tempURL.path + "-wal"))
            removeIfPresent(URL(fileURLWithPath: tempURL.path + "-shm"))
            throw error
        }
    }

    /// `PRAGMA quick_check` rows on a read-only connection (`["ok"]` when healthy).
    static func quickCheck(path: String) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let msg = message(db)
            sqlite3_close(db)
            throw AutoBackupError.sqlite(msg)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &stmt, nil) == SQLITE_OK else {
            throw AutoBackupError.verificationFailed(message(db))
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [String] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                rows.append(sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "")
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw AutoBackupError.verificationFailed(message(db))
            }
        }
        return rows
    }

    // MARK: Internals

    private static func onlineBackup(from sourcePath: String, to destPath: String) throws {
        var src: OpaquePointer?
        guard sqlite3_open_v2(sourcePath, &src, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let msg = message(src)
            sqlite3_close(src)
            throw AutoBackupError.sqlite(msg)
        }
        defer { sqlite3_close(src) }
        sqlite3_busy_timeout(src, 5_000)

        var dst: OpaquePointer?
        guard sqlite3_open_v2(destPath, &dst, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let msg = message(dst)
            sqlite3_close(dst)
            throw AutoBackupError.sqlite(msg)
        }
        defer { sqlite3_close(dst) }

        guard let handle = sqlite3_backup_init(dst, "main", src, "main") else {
            throw AutoBackupError.sqlite(message(dst))
        }
        // Copy everything in a single step = one read transaction = consistent snapshot; in WAL mode
        // this doesn't block the app's writers. Retry transient BUSY/LOCKED a few times.
        var rc: Int32 = SQLITE_OK
        var attempts = 0
        repeat {
            rc = sqlite3_backup_step(handle, -1)
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
                attempts += 1
                sqlite3_sleep(250)
            }
        } while (rc == SQLITE_BUSY || rc == SQLITE_LOCKED) && attempts < 20
        let finishRC = sqlite3_backup_finish(handle)
        guard rc == SQLITE_DONE, finishRC == SQLITE_OK else {
            throw AutoBackupError.sqlite(message(dst))
        }

        // The copied header may carry the WAL flag; make the backup a single self-contained file.
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(dst, "PRAGMA journal_mode=DELETE", -1, &stmt, nil) == SQLITE_OK else {
            throw AutoBackupError.sqlite(message(dst))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let mode = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              mode.lowercased() == "delete" else {
            throw AutoBackupError.sqlite("could not switch backup to rollback-journal mode: \(message(dst))")
        }
    }

    private static func prune(directory: URL, keep: Int, protecting protectedName: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in AutoBackupPolicy.filesToPrune(from: names, keep: keep) where name != protectedName {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static func removeIfPresent(_ url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
    }

    private static func message(_ db: OpaquePointer?) -> String {
        guard let db, let c = sqlite3_errmsg(db) else { return "unknown error" }
        return String(cString: c)
    }
}

// MARK: - Scheduler

/// Runs the daily backup in the background: once ~60 s after launch if today's backup is missing,
/// then re-checks every 6 h while the app is running. Status is persisted in `UserDefaults` so a UI
/// can show it later.
@MainActor
final class AutoBackupScheduler: ObservableObject {
    static let shared = AutoBackupScheduler()

    static let lastBackupAtKey = "lastAutoBackupAt"
    static let lastErrorKey = "lastAutoBackupError"
    private static let initialDelayNanos: UInt64 = 60 * 1_000_000_000
    private static let recheckNanos: UInt64 = 6 * 60 * 60 * 1_000_000_000

    @Published private(set) var lastAutoBackupAt: Date?
    @Published private(set) var lastAutoBackupError: String?
    @Published private(set) var isRunning = false

    private let defaults: UserDefaults
    private var loopTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastAutoBackupAt = defaults.object(forKey: Self.lastBackupAtKey) as? Date
        lastAutoBackupError = defaults.string(forKey: Self.lastErrorKey)
    }

    /// `<AppSupport>/OpenWhoop/AutoBackups`, next to the live database (nil if the path can't be resolved).
    var backupDirectory: URL? {
        guard let dbPath = try? StorePaths.defaultDatabasePath() else { return nil }
        return URL(fileURLWithPath: dbPath).deletingLastPathComponent()
            .appendingPathComponent(AutoBackupPolicy.directoryName, isDirectory: true)
    }

    /// Idempotent: starts the background schedule once.
    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.initialDelayNanos)
            while !Task.isCancelled {
                await self?.runIfDue()
                try? await Task.sleep(nanoseconds: Self.recheckNanos)
            }
        }
    }

    /// Runs a backup immediately (also when one already exists for today). Never overlaps another run.
    func runNow() async -> Result<URL, Error> {
        guard !isRunning else { return .failure(AutoBackupError.alreadyRunning) }
        isRunning = true
        defer { isRunning = false }

        let result = await Task.detached(priority: .utility) { () -> Result<URL, Error> in
            Result {
                let dbPath = try StorePaths.defaultDatabasePath()
                let dir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
                    .appendingPathComponent(AutoBackupPolicy.directoryName, isDirectory: true)
                return try AutoBackupEngine.backup(sourcePath: dbPath, into: dir)
            }
        }.value
        record(result)
        return result
    }

    private func runIfDue() async {
        guard !isRunning, await isBackupDue() else { return }
        _ = await runNow()
    }

    private func isBackupDue() async -> Bool {
        await Task.detached(priority: .utility) { () -> Bool in
            guard let dbPath = try? StorePaths.defaultDatabasePath() else { return false }
            let dir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
                .appendingPathComponent(AutoBackupPolicy.directoryName, isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return AutoBackupPolicy.isDue(now: Date(), existingFileNames: names)
        }.value
    }

    private func record(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            let now = Date()
            lastAutoBackupAt = now
            lastAutoBackupError = nil
            defaults.set(now, forKey: Self.lastBackupAtKey)
            defaults.removeObject(forKey: Self.lastErrorKey)
        case .failure(let error):
            let message = error.localizedDescription
            lastAutoBackupError = message
            defaults.set(message, forKey: Self.lastErrorKey)
        }
    }
}

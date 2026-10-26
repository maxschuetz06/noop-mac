import Foundation
import Combine

// MARK: - Policy (pure, testable)

/// How often and with which README the read-only database mirror for local AI agents (Codex) is published.
enum CodexMirrorPolicy {
    static let fileName = "whoop-latest.sqlite"
    static let readmeName = "README.txt"
    /// At most one mirror run per this interval.
    static let minInterval: TimeInterval = 10 * 60

    static let readmeText = """
    This is a read-only copy of the NOOP database for local AI agents (e.g. Codex).
    NOOP refreshes whoop-latest.sqlite automatically after every strap sync and daily backup.
    Changes to this copy are lost and never reach NOOP: the next refresh overwrites them.
    """

    /// Seconds to wait before the next mirror run may start (0 = right now).
    static func delay(now: Date, lastRun: Date?, minInterval: TimeInterval = minInterval) -> TimeInterval {
        guard let lastRun else { return 0 }
        return max(0, minInterval - now.timeIntervalSince(lastRun))
    }
}

// MARK: - Engine

extension AutoBackupEngine {
    /// Publishes a verified, consistent copy of `sourcePath` as `<directory>/whoop-latest.sqlite`
    /// (`.partial` → quick_check → atomic rename) and writes `README.txt` if it is missing.
    /// Blocking — call off the main thread.
    @discardableResult
    static func mirror(sourcePath: String, into directory: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: sourcePath) else { throw AutoBackupError.missingDatabase(sourcePath) }
        try PrivateFiles.ensureDirectory(directory)
        let finalURL = directory.appendingPathComponent(CodexMirrorPolicy.fileName)
        try snapshot(sourcePath: sourcePath, to: finalURL, filePermissions: PrivateFiles.fileMode)

        try? PrivateFiles.writeIfMissing(CodexMirrorPolicy.readmeText,
                                         to: directory.appendingPathComponent(CodexMirrorPolicy.readmeName))
        return finalURL
    }
}

// MARK: - Scheduler

/// Keeps `<external data folder>/whoop-latest.sqlite` fresh: after every completed strap sync, every intermediate
/// history-progress signal of a long offload (`LiveState.historyProgressAt`) and every successful daily
/// backup (plus once shortly after launch), debounced to one run per 10 minutes.
/// Mirror and backup snapshots are serialized by `AutoBackupEngine`'s snapshot lock.
@MainActor
final class CodexMirrorScheduler: ObservableObject {
    /// nil when this build has no external data folder: then nothing is ever mirrored.
    static let shared: CodexMirrorScheduler? = ExternalDataFolder.current.map { CodexMirrorScheduler(directory: $0.root) }

    @Published private(set) var lastMirrorAt: Date?
    @Published private(set) var lastMirrorError: String?

    private let directory: URL
    private let sourcePath: @Sendable () throws -> String
    private let minInterval: TimeInterval
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var isRunning = false
    private var runScheduled = false
    private var rerunRequested = false
    private var lastRunStart: Date?

    init(directory: URL,
         minInterval: TimeInterval = CodexMirrorPolicy.minInterval,
         sourcePath: @escaping @Sendable () throws -> String = { try StorePaths.defaultDatabasePath() }) {
        self.directory = directory
        self.minInterval = minInterval
        self.sourcePath = sourcePath
    }

    /// Idempotent: subscribes to sync completion and backup success.
    func start(model: AppModel, backups: AutoBackupScheduler = .shared) {
        guard !started else { return }
        started = true

        model.live.$lastSyncedAt
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.request() }
            .store(in: &cancellables)

        attachHistoryProgress(model.live.$historyProgressAt)

        backups.$lastAutoBackupAt
            .dropFirst()
            .sink { [weak self] _ in self?.request() }
            .store(in: &cancellables)

        // Initial mirror shortly after launch so the file exists even without a fresh sync/backup.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
            self?.request()
        }
    }

    /// A long offload (multi-day backlog) can run for hours without a HISTORY_COMPLETE, i.e. without a
    /// `lastSyncedAt` change. BLEManager publishes an intermediate, rate-limited progress stamp instead; each
    /// change requests a mirror run (still coalesced and held to `minInterval` by `request()`). Internal so a
    /// test can drive it with a bare `LiveState` instead of a full `AppModel`.
    func attachHistoryProgress(_ progress: Published<TimeInterval?>.Publisher) {
        progress
            .removeDuplicates()
            .dropFirst()
            .compactMap { $0 }
            .sink { [weak self] _ in self?.request() }
            .store(in: &cancellables)
    }

    /// Requests a mirror run; coalesced and rate-limited to one run per `minInterval`.
    func request() {
        if isRunning { rerunRequested = true; return }
        guard !runScheduled else { return }
        runScheduled = true
        let wait = CodexMirrorPolicy.delay(now: Date(), lastRun: lastRunStart, minInterval: minInterval)
        Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            await self?.runNow()
        }
    }

    /// Runs one mirror immediately (ignores the rate limit). Returns the published file or the error.
    @discardableResult
    func runNow() async -> Result<URL, Error> {
        runScheduled = false
        if isRunning { return .failure(AutoBackupError.alreadyRunning) }
        isRunning = true
        lastRunStart = Date()
        let dir = directory
        let source = sourcePath
        let result = await Task.detached(priority: .utility) { () -> Result<URL, Error> in
            Result { try AutoBackupEngine.mirror(sourcePath: try source(), into: dir) }
        }.value
        switch result {
        case .success:
            lastMirrorAt = Date()
            lastMirrorError = nil
        case .failure(let error):
            lastMirrorError = error.localizedDescription
        }
        isRunning = false
        if rerunRequested {
            rerunRequested = false
            request()
        }
        return result
    }
}

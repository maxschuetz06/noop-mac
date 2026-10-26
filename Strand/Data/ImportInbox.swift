import Foundation
import ZIPFoundation

// MARK: - Outcome (shared with AppModel)

/// Result of one automatic WHOOP import, reported by `AppModel.importWhoopAwaiting(url:)`.
enum ImportInboxOutcome: Equatable, Sendable {
    /// `counts` uses the importer's category keys: `cycles`, `sleeps`, `workouts`, `journal`.
    case success(recordCount: Int, counts: [String: Int], summary: String)
    case failure(String)
}

// MARK: - Policy (pure, testable)

/// Rules for the import inbox `<external data folder>/Import/`: what counts as a WHOOP export, what is ignored,
/// and when a dropped item is considered fully written.
enum ImportInboxPolicy {
    static let doneName = "Done"
    static let failedName = "Failed"
    static let logName = "import-log.txt"
    static let readmeName = "README.txt"
    static let errorNoteSuffix = ".error.txt"
    /// Archive folders created by builds before the English names. They stay on disk untouched and are
    /// never scanned, otherwise the exports archived in them would be imported a second time.
    static let legacyArchiveNames: Set<String> = ["Erledigt", "Fehler"]
    /// An item must be untouched for at least this long before it is imported.
    static let minAge: TimeInterval = 10
    /// How deep a dropped folder is searched for WHOOP CSVs (export folders are flat or one level deep).
    static let maxFolderDepth = 4

    /// Lowercased CSV file names that identify a WHOOP export. English and German names are the primary
    /// ones; Spanish/French sleep+workout names are accepted because `WhoopExportImporter` reads them too.
    static let knownCSVNames: Set<String> = [
        "physiological_cycles.csv", "sleeps.csv", "workouts.csv", "journal_entries.csv",
        "physiologische_zyklen.csv", "schlaf.csv", "trainings.csv", "logbuch_eintraege.csv",
        "sueño.csv", "sueno.csv", "entrenamientos.csv", "sommeil.csv",
        "entrainements.csv", "entraînements.csv",
    ]

    static let readmeText = """
    NOOP import inbox

    Drop a WHOOP export here: the ZIP file from "Export data" or the unpacked folder with the CSV files
    (e.g. physiological_cycles.csv, sleeps.csv, workouts.csv).

    While NOOP is running it imports the export automatically (within a few minutes, once the file has
    been copied completely). You don't need to click anything in the app.

    - Successfully imported exports are moved to "Done".
    - Failed exports are moved to "Failed", together with an .error.txt file that names the reason.
    - Every run is recorded in import-log.txt.
    - Everything else in this folder (unknown files, hidden files) is left alone.
    - NOOP never deletes files here.
    """

    // MARK: Detection

    enum Kind: Equatable, Sendable {
        case whoopZip
        case whoopFolder
    }

    /// Hidden files and the engine's own sub-folders are never candidates.
    static func isIgnored(name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        return name == doneName || name == failedName || legacyArchiveNames.contains(name)
    }

    /// True when any entry path (zip entry or relative file path) ends in a known WHOOP CSV name.
    /// macOS resource-fork entries (`__MACOSX/…`, `._*`) never count.
    static func containsWhoopCSV(entryNames: [String]) -> Bool {
        for path in entryNames {
            let comps = path.split(separator: "/").map(String.init)
            guard let base = comps.last?.lowercased() else { continue }
            if comps.contains("__MACOSX") || base.hasPrefix(".") { continue }
            if knownCSVNames.contains(base) { return true }
        }
        return false
    }

    /// Entry paths of a zip, or nil when `url` is not (yet) a readable zip.
    static func zipEntryNames(at url: URL) -> [String]? {
        guard let archive = try? Archive(url: url, accessMode: .read) else { return nil }
        return archive.compactMap { $0.type == .file ? $0.path : nil }
    }

    /// Relative paths of regular, non-hidden files below `folder` (bounded depth).
    static func folderFileNames(at folder: URL) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        let basePath = folder.standardizedFileURL.path
        var names: [String] = []
        for case let url as URL in enumerator {
            let rel = String(url.standardizedFileURL.path.dropFirst(basePath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if rel.split(separator: "/").count > maxFolderDepth {
                enumerator.skipDescendants()
                continue
            }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                names.append(rel)
            }
        }
        return names
    }

    /// Classifies a top-level inbox item. nil = not a WHOOP export → leave it alone.
    static func classify(_ url: URL) -> Kind? {
        guard !isIgnored(name: url.lastPathComponent) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue {
            return containsWhoopCSV(entryNames: folderFileNames(at: url)) ? .whoopFolder : nil
        }
        guard url.pathExtension.lowercased() == "zip",
              let names = zipEntryNames(at: url) else { return nil }
        return containsWhoopCSV(entryNames: names) ? .whoopZip : nil
    }

    // MARK: Stability

    /// Cheap change detector for a file or folder tree.
    struct Fingerprint: Equatable, Sendable {
        var size: Int64
        var modified: Date
    }

    /// Size and newest modification date of a file, or summed/maximal over all files of a folder.
    static func fingerprint(of url: URL) -> Fingerprint? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        func read(_ u: URL) -> (Int64, Date)? {
            guard let v = try? u.resourceValues(forKeys: keys) else { return nil }
            return (Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        if !isDir.boolValue {
            guard let (s, d) = read(url) else { return nil }
            return Fingerprint(size: s, modified: d)
        }
        var total: Int64 = 0
        var newest = read(url)?.1 ?? .distantPast
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
            for case let f as URL in e {
                guard let v = try? f.resourceValues(forKeys: keys) else { continue }
                newest = max(newest, v.contentModificationDate ?? .distantPast)
                if v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
            }
        }
        return Fingerprint(size: total, modified: newest)
    }

    /// An item is stable once it looked identical on two consecutive scans and was last modified at
    /// least `minAge` seconds ago.
    static func isStable(current: Fingerprint, previous: Fingerprint?, now: Date,
                         minAge: TimeInterval = minAge) -> Bool {
        guard let previous, previous == current else { return false }
        return now.timeIntervalSince(current.modified) >= minAge
    }

    // MARK: Formatting

    static func timestamp(_ date: Date, format: String = "yyyy-MM-dd HHmm") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: date)
    }

    /// One log line: timestamp | file | result | counts.
    static func logLine(now: Date, name: String, outcome: ImportInboxOutcome) -> String {
        let ts = timestamp(now, format: "yyyy-MM-dd HH:mm:ss")
        switch outcome {
        case .success(_, let counts, _):
            let detail = "\(counts["cycles"] ?? 0) days, \(counts["sleeps"] ?? 0) sleeps, "
                + "\(counts["workouts"] ?? 0) workouts, \(counts["journal"] ?? 0) journal"
            return "\(ts) | \(name) | OK | \(detail)"
        case .failure(let message):
            let oneLine = message.replacingOccurrences(of: "\n", with: " ")
            return "\(ts) | \(name) | FAILED | \(oneLine)"
        }
    }
}

// MARK: - Engine

/// One scan of the inbox: detects stable WHOOP exports, imports them one at a time through the injected
/// importer, archives them into `Done/` or `Failed/` and appends to `import-log.txt`. Never deletes.
@MainActor
final class ImportInboxEngine {
    struct ScanReport: Equatable {
        var imported = 0
        var failed = 0
        /// Candidates seen but not yet stable (a follow-up scan is useful).
        var pending = 0
    }

    let directory: URL
    private let importer: (URL) async -> ImportInboxOutcome
    private let minAge: TimeInterval
    private var previous: [String: ImportInboxPolicy.Fingerprint] = [:]
    private var classified: [String: (ImportInboxPolicy.Fingerprint, ImportInboxPolicy.Kind?)] = [:]

    init(directory: URL,
         minAge: TimeInterval = ImportInboxPolicy.minAge,
         importer: @escaping (URL) async -> ImportInboxOutcome) {
        self.directory = directory
        self.minAge = minAge
        self.importer = importer
    }

    /// Creates the inbox (+ `Done`, `Failed`) owner-only and `README.txt` if missing.
    func prepare() throws {
        try PrivateFiles.ensureDirectory(directory)
        for sub in [ImportInboxPolicy.doneName, ImportInboxPolicy.failedName] {
            try PrivateFiles.ensureDirectory(directory.appendingPathComponent(sub, isDirectory: true))
        }
        try? PrivateFiles.writeIfMissing(ImportInboxPolicy.readmeText,
                                         to: directory.appendingPathComponent(ImportInboxPolicy.readmeName))
    }

    /// Scans once. Items are imported sequentially (awaiting each importer call).
    @discardableResult
    func scan(now: Date = Date()) async -> ScanReport {
        var report = ScanReport()
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return report }
        var seen = Set<String>()
        for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            guard !ImportInboxPolicy.isIgnored(name: name) else { continue }
            guard let fp = ImportInboxPolicy.fingerprint(of: url) else { continue }
            seen.insert(url.path)

            // Only items with a plausible extension/type are tracked at all (unknown files are left alone).
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if !isDir.boolValue && url.pathExtension.lowercased() != "zip" { continue }

            let stable = ImportInboxPolicy.isStable(current: fp, previous: previous[url.path],
                                                    now: now, minAge: minAge)
            previous[url.path] = fp

            let kind: ImportInboxPolicy.Kind?
            if let cached = classified[url.path], cached.0 == fp {
                kind = cached.1
            } else if stable {
                kind = ImportInboxPolicy.classify(url)
                classified[url.path] = (fp, kind)
            } else {
                // Not settled yet; classification would read a half-written file.
                report.pending += 1
                continue
            }
            guard kind != nil else { continue }
            guard stable else { report.pending += 1; continue }

            let outcome = await importer(url)
            archive(url, outcome: outcome, now: now)
            previous[url.path] = nil
            classified[url.path] = nil
            if case .success = outcome { report.imported += 1 } else { report.failed += 1 }
        }
        previous = previous.filter { seen.contains($0.key) }
        classified = classified.filter { seen.contains($0.key) }
        return report
    }

    // MARK: Archiving + log

    private func archive(_ url: URL, outcome: ImportInboxOutcome, now: Date) {
        let fm = FileManager.default
        let name = url.lastPathComponent
        let sub: String
        if case .success = outcome { sub = ImportInboxPolicy.doneName } else { sub = ImportInboxPolicy.failedName }
        let targetDir = directory.appendingPathComponent(sub, isDirectory: true)
        try? PrivateFiles.ensureDirectory(targetDir)

        let base = "\(ImportInboxPolicy.timestamp(now)) \(name)"
        var dest = targetDir.appendingPathComponent(base)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = targetDir.appendingPathComponent("\(base) (\(n))")
            n += 1
        }
        do {
            try fm.moveItem(at: url, to: dest)
        } catch {
            appendLog(ImportInboxPolicy.logLine(now: now, name: name,
                                                outcome: .failure("Could not move the file: \(error.localizedDescription)")))
            return
        }
        if case .failure(let message) = outcome {
            let note = dest.deletingLastPathComponent()
                .appendingPathComponent(dest.lastPathComponent + ImportInboxPolicy.errorNoteSuffix)
            try? PrivateFiles.writeIfMissing("Import failed: \(name)\n\(message)\n", to: note)
        }
        appendLog(ImportInboxPolicy.logLine(now: now, name: name, outcome: outcome))
    }

    private func appendLog(_ line: String) {
        let logURL = directory.appendingPathComponent(ImportInboxPolicy.logName)
        _ = try? PrivateFiles.createEmptyFile(at: logURL)
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}

// MARK: - Scheduler

/// Runs the inbox engine inside the app: first scan ~20 s after launch, then every 2 minutes, plus
/// whenever the folder's contents change (file-system watch). Items still settling trigger a quick
/// follow-up scan so a freshly dropped export is picked up within about half a minute.
@MainActor
final class ImportInboxScheduler {
    /// nil when this build has no external data folder: then no inbox is created or watched.
    static let shared: ImportInboxScheduler? = ExternalDataFolder.current.map {
        ImportInboxScheduler(directory: $0.importInboxDirectory)
    }

    static let initialDelay: TimeInterval = 20
    static let interval: TimeInterval = 120
    static let followUpDelay: TimeInterval = 15

    private let directory: URL
    private var engine: ImportInboxEngine?
    private var model: AppModel?
    private var started = false
    private var isScanning = false
    private var rescanRequested = false
    private var followUpScheduled = false
    private var watcher: DispatchSourceFileSystemObject?
    private var loopTask: Task<Void, Never>?

    init(directory: URL) {
        self.directory = directory
    }

    /// Idempotent.
    func start(model: AppModel) {
        guard !started else { return }
        started = true
        self.model = model
        let engine = ImportInboxEngine(directory: directory) { [weak model] url in
            guard let model else { return .failure("NOOP quit.") }
            return await model.importWhoopAwaiting(url: url)
        }
        do { try engine.prepare() } catch { return }   // folder not reachable (e.g. sandbox without exception)
        self.engine = engine
        startWatcher(directory: engine.directory)
        loopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.initialDelay * 1_000_000_000))
            while !Task.isCancelled {
                await self?.scanNow()
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
            }
        }
    }

    private func startWatcher(directory: URL) {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                               eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in await self?.scanNow() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func scanNow() async {
        guard let engine, let model else { return }
        // Don't start while the user's own import is writing to the store; the next scan retries.
        if model.hasActiveImport { scheduleFollowUp(); return }
        if isScanning { rescanRequested = true; return }
        isScanning = true
        let report = await engine.scan()
        isScanning = false
        if report.pending > 0 || rescanRequested {
            rescanRequested = false
            scheduleFollowUp()
        }
    }

    private func scheduleFollowUp() {
        guard !followUpScheduled else { return }
        followUpScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.followUpDelay * 1_000_000_000))
            self?.followUpScheduled = false
            await self?.scanNow()
        }
    }
}

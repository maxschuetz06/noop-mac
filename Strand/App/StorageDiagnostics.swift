import Foundation
import WhoopStore

/// Where the app's on-disk footprint goes, and the Storage screen's clean-up (#590 — StorageView).
enum StorageDiagnostics {
    /// A point-in-time snapshot of where the app's on-disk footprint is going, for the Storage screen.
    /// All sizes in bytes; `db` is nil only for an unopened/in-memory store. `inbox` is the iOS
    /// document-picker drop folder, which the macOS app never writes, so it is always 0 here.
    struct Report: Equatable, Sendable {
        var db: Int64?
        var inbox: Int64 = 0
        var importTemp: Int64
    }

    /// Gather the report: the GRDB file (+ WAL/SHM) from the store plus the import temp files this
    /// app writes.
    static func report(store: WhoopStore?) async -> Report {
        let db = await store?.databaseFileSizeBytes()
        return Report(db: db, importTemp: importTempSizeBytes())
    }

    /// The Storage screen's "Clean up" action: purge stranded import temps, then truncate the WAL so
    /// the freed pages return to the OS. Returns a fresh report so the screen updates. Safe — temp holds
    /// only this app's own temp copies, never user data or live rows.
    static func cleanUp(store: WhoopStore?) async -> Report {
        purgeImportTemp()
        if let store { try? await store.checkpointWAL() }
        return await report(store: store)
    }

    /// True for any scratch file/dir NOOP itself writes into the temp directory — import copies, the
    /// decompressed export.xml, exports, backups, raw captures: every one is prefixed `noop-`. #590: the
    /// import decompresses `export.xml` to a `noop-health-*` temp file (up to 8 GB), but a previous build
    /// only matched `noop-import-*`, so an interrupted import stranded multi-GB extractions the Storage
    /// screen never saw OR reclaimed. Matching the shared `noop-` prefix counts + sweeps them all and is
    /// future-proof. Safe: the temp dir is NOOP's private sandbox and the 60 s in-flight guard in
    /// `purgeImportTemp` protects a live import.
    static func isNoopTempScratch(_ name: String) -> Bool { name.hasPrefix("noop-") }

    /// Total bytes of NOOP's own `noop-*` temp scratch (a crash mid-import can strand a multi-GB one).
    /// Recurses into directories (the Xiaomi importer stages a `noop-xiaomi-*` folder).
    static func importTempSizeBytes() -> Int64 {
        let tmp = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: []) else { return 0 }
        return items.filter { isNoopTempScratch($0.lastPathComponent) }.reduce(0) { $0 + sizeBytes($1) }
    }

    /// Remove NOOP's stranded `noop-*` temp scratch (import copies, the multi-GB `noop-health-*`
    /// export.xml an interrupted import leaves behind — #590, exports, backups, raw captures). A 60 s
    /// in-flight guard keeps a concurrent import/export from being disturbed.
    static func purgeImportTemp() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let items = try? fm.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return }
        let cutoff = Date().addingTimeInterval(-60)
        for item in items where isNoopTempScratch(item.lastPathComponent) {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > cutoff { continue }
            try? fm.removeItem(at: item)
        }
    }

    /// Size of a file, or the sum of every regular file below a directory. Best-effort; missing → 0.
    private static func sizeBytes(_ item: URL) -> Int64 {
        let vals = try? item.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        guard vals?.isDirectory == true else { return Int64(vals?.fileSize ?? 0) }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: item, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: []) else { return 0 }
        return children.reduce(0) { $0 + sizeBytes($1) }
    }
}

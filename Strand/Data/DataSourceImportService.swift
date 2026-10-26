import Foundation
import StrandImport
import WhoopStore

/// Data source currently running an import from the Data Sources screen.
enum DataSourceImportKind {
    case whoop
    case appleHealth
    case xiaomi
}

/// Runs the file imports from the Data Sources screen, onboarding and the import inbox (WHOOP export,
/// Apple Health export, Xiaomi / Mi Band export) into the on-device store, and publishes each source
/// card's progress, summary and typed failure flag. At most one import writes at a time per source.
@MainActor
final class DataSourceImportService: ObservableObject, WhoopImportInboxTarget {
    /// Import source currently writing to the local store, if any.
    @Published private var activeImportSource: DataSourceImportKind?
    /// Last WHOOP export import result surfaced in the WHOOP card.
    @Published var whoopImportSummary: String?
    /// Last Apple Health import result surfaced in the Apple Health card.
    @Published var appleHealthImportSummary: String?
    /// Last Xiaomi / Mi Band import result surfaced in the Mi Band card.
    @Published var xiaomiImportSummary: String?
    /// Typed failure flags per source — the summary's warning styling reads these instead of
    /// substring-matching the human-readable message (which misses errors like "Couldn't open
    /// the local store."). Surfaced on both the Data Sources cards and the onboarding import step.
    @Published var whoopImportFailed = false
    @Published var appleHealthImportFailed = false
    @Published var xiaomiImportFailed = false

    private let repo: Repository
    private let whoopDeviceId: String
    private let appleDeviceId: String

    init(repo: Repository, whoopDeviceId: String, appleDeviceId: String) {
        self.repo = repo
        self.whoopDeviceId = whoopDeviceId
        self.appleDeviceId = appleDeviceId
    }

    /// True while any data-source import is writing to the local store.
    var hasActiveImport: Bool { activeImportSource != nil }

    /// Returns true only for the source currently importing.
    func isImporting(_ source: DataSourceImportKind) -> Bool {
        activeImportSource == source
    }

    /// Whether the last import for a source ended in failure (for warning styling).
    func importFailed(_ source: DataSourceImportKind) -> Bool {
        switch source {
        case .whoop: return whoopImportFailed
        case .appleHealth: return appleHealthImportFailed
        case .xiaomi: return xiaomiImportFailed
        }
    }

    /// Import a WHOOP CSV export (.zip or folder) → on-device store, then refresh the dashboard.
    func importWhoop(url: URL) {
        beginImport(.whoop)
        Task { _ = await runWhoopImport(url: url) }
    }

    /// Same WHOOP import as `importWhoop(url:)` (identical card state), but awaitable: returns once the
    /// import finished, with counts on success or the error text on failure. Used by the import inbox.
    func importWhoopAwaiting(url: URL) async -> ImportInboxOutcome {
        beginImport(.whoop)
        return await runWhoopImport(url: url)
    }

    /// Import a Xiaomi / Mi Band export into its own source, then refresh.
    func importXiaomi(url: URL) {
        beginImport(.xiaomi)
        Task {
            _ = await runImport(.xiaomi, url: url) { store in
                try await XiaomiImporter.importExport(url: url, into: store)
            } describe: { summary in
                let days = summary.countsByCategory["days"] ?? 0
                let sleeps = summary.countsByCategory["sleepSessions"] ?? 0
                return "Imported \(days) days · \(sleeps) sleeps\(Self.span(summary))"
            }
        }
    }

    /// Import an Apple Health export (export.zip) — streams + aggregates per-day into the store
    /// under the `apple-health` source, then refreshes. Large exports take ~1–2 minutes.
    func importAppleHealth(url: URL) {
        beginImport(.appleHealth)
        Task {
            _ = await runImport(.appleHealth, url: url) { [appleDeviceId] store in
                try await AppleHealthImport.importExport(url: url, into: store, deviceId: appleDeviceId)
            } describe: { summary in
                "Imported \(summary.recordCount) records"
            }
        }
    }

    /// Shared body of both WHOOP import entry points. Callers must have called `beginImport(.whoop)`.
    private func runWhoopImport(url: URL) async -> ImportInboxOutcome {
        let result = await runImport(.whoop, url: url) { [whoopDeviceId] store in
            try await WhoopImporter.importExport(url: url, into: store, deviceId: whoopDeviceId)
        } describe: { summary in
            "Imported \(summary.recordCount) records\(Self.span(summary))"
        }
        switch result {
        case .success(let done):
            return .success(recordCount: done.summary.recordCount, counts: done.summary.countsByCategory,
                            summary: done.text)
        case .failure(let failure):
            return .failure(failure.text)
        }
    }

    private struct ImportFailure: Error {
        let text: String
    }

    /// One import from start to card state: hold the security scope, open the store, run the source's
    /// importer, reclaim the WAL a bulk import grew (#590), refresh the dashboard and publish the card
    /// summary from `describe` (or the failure text) on the source's card.
    private func runImport(_ source: DataSourceImportKind, url: URL,
                           importer: (WhoopStore) async throws -> ImportSummary,
                           describe: (ImportSummary) -> String)
    async -> Result<(summary: ImportSummary, text: String), ImportFailure> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let store = await repo.storeHandle() else {
            let message = "Couldn't open the local store."
            finishImport(source, summary: message, failed: true)
            return .failure(ImportFailure(text: message))
        }
        do {
            let summary = try await importer(store)
            try? await store.checkpointWAL()
            await repo.refresh()
            let text = describe(summary)
            finishImport(source, summary: text)
            return .success((summary, text))
        } catch {
            let text = "Import failed: \(error)"
            finishImport(source, summary: text, failed: true)
            return .failure(ImportFailure(text: text))
        }
    }

    /// " · Jan 2024–Mar 2025" for the imported date range, or "" when the export carried no dates.
    private static func span(_ summary: ImportSummary) -> String {
        guard let a = summary.earliest, let b = summary.latest else { return "" }
        let f = DateFormatter(); f.dateFormat = "MMM yyyy"
        return " · \(f.string(from: a))–\(f.string(from: b))"
    }

    /// Marks a source as importing and clears only that source's old status text + failure flag.
    private func beginImport(_ source: DataSourceImportKind) {
        activeImportSource = source
        switch source {
        case .whoop:
            whoopImportSummary = nil
            whoopImportFailed = false
        case .appleHealth:
            appleHealthImportSummary = nil
            appleHealthImportFailed = false
        case .xiaomi:
            xiaomiImportSummary = nil
            xiaomiImportFailed = false
        }
    }

    /// Stores the completed import summary (and typed failure flag) on the matching source card.
    private func finishImport(_ source: DataSourceImportKind, summary: String, failed: Bool = false) {
        switch source {
        case .whoop:
            whoopImportSummary = summary
            whoopImportFailed = failed
        case .appleHealth:
            appleHealthImportSummary = summary
            appleHealthImportFailed = failed
        case .xiaomi:
            xiaomiImportSummary = summary
            xiaomiImportFailed = failed
        }
        activeImportSource = nil
    }
}

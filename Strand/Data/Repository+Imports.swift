import Foundation
import WhoopStore
import StrandImport

/// A store-backed Repository operation could not run because the local store is not open.
enum RepositoryError: Error {
    case storeUnavailable
}

// MARK: - Named writes for imports and manual entries

extension Repository {
    /// Upserts generic daily metric points (nutrition totals, manual HRV readings, sleep marks) under
    /// `source`. Idempotent on (source, day, key). Throws `RepositoryError.storeUnavailable` without a store.
    func saveMetricPoints(_ points: [MetricPoint], source: String) async throws {
        guard let store = await storeHandle() else { throw RepositoryError.storeUnavailable }
        try await store.upsertMetricSeries(points, deviceId: source)
    }

    /// Upserts imported workout rows (lifting logs, activity files) under `source`.
    func saveWorkouts(_ rows: [WorkoutRow], source: String) async throws {
        guard let store = await storeHandle() else { throw RepositoryError.storeUnavailable }
        try await store.upsertWorkouts(rows, deviceId: source)
    }

    /// Imports another brand's wearable export (Garmin, Oura, …) into the store.
    func importWearableExport(url: URL) async throws -> WearableImportResult {
        guard let store = await storeHandle() else { throw RepositoryError.storeUnavailable }
        return try await WearableImporter.importExport(url: url, into: store)
    }

    /// Deletes every row a source device (e.g. the Apple Health import) contributed.
    func deleteAllData(deviceId: String) async throws {
        guard let store = await storeHandle() else { throw RepositoryError.storeUnavailable }
        // `registryQueue` is the nonisolated GRDB handle the synchronous DeviceRegistryStore wraps.
        try DeviceRegistryStore(dbQueue: store.registryQueue).deleteAllData(deviceId: deviceId)
    }
}

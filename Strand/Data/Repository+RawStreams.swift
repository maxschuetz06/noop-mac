import Foundation
import WhoopStore
import WhoopProtocol

// MARK: - Raw sensor streams and per-source sessions

extension Repository {
    /// R-R intervals in [from, to] for `deviceId` (the strap's id by default); empty without a store.
    func rrIntervals(deviceId: String? = nil, from: Int, to: Int, limit: Int) async -> [RRInterval] {
        guard let store = await storeHandle() else { return [] }
        return (try? await store.rrIntervals(deviceId: deviceId ?? self.deviceId, from: from, to: to, limit: limit)) ?? []
    }

    /// Gravity (accelerometer) samples of the strap in [from, to]; empty without a store.
    func gravitySamples(from: Int, to: Int, limit: Int) async -> [GravitySample] {
        guard let store = await storeHandle() else { return [] }
        return (try? await store.gravitySamples(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
    }

    /// Every stored sleep session of one source (e.g. "xiaomi-band"), up to 4000. nil while the store
    /// cannot be opened; empty when the read fails.
    func sleepSessions(source: String) async -> [CachedSleepSession]? {
        guard let store = await storeHandle() else { return nil }
        let farFuture = Int(Date.distantFuture.timeIntervalSince1970)
        return (try? await store.sleepSessions(deviceId: source, from: 0, to: farFuture, limit: 4000)) ?? []
    }

    /// Writes the raw sensor streams since `since` to a CSV file and returns its URL.
    func exportRawSensorCSV(deviceId: String, since: TimeInterval) async throws -> URL {
        guard let store = await storeHandle() else { throw RepositoryError.storeUnavailable }
        return try await store.exportRawCSV(deviceId: deviceId, since: since)
    }
}

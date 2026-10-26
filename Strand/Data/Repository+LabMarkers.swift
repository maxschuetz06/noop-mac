import Foundation
import WhoopStore
import StrandImport

// MARK: - Lab book markers (stored under the strap device id)

extension Repository {
    /// Every lab marker across all categories, oldest first; nil while the store cannot be opened.
    func labMarkers() async -> [LabMarkerRow]? {
        guard let store = await storeHandle() else { return nil }
        var all: [LabMarkerRow] = []
        for category in LabMarkerCategory.allCases {
            all += (try? await store.labMarkers(deviceId: deviceId, category: category.rawValue)) ?? []
        }
        return all.sorted { $0.takenAt < $1.takenAt }
    }

    /// Best-effort upsert of lab markers; a write failure leaves the book unchanged.
    func saveLabMarkers(_ rows: [LabMarkerRow]) async {
        guard !rows.isEmpty, let store = await storeHandle() else { return }
        _ = try? await store.upsertLabMarkers(rows)
    }

    /// Best-effort delete of one lab marker.
    func deleteLabMarker(id: String) async {
        guard let store = await storeHandle() else { return }
        _ = try? await store.deleteLabMarker(id: id)
    }
}

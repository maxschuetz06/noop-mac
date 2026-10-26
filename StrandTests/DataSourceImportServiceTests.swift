import XCTest
import WhoopStore
@testable import Strand

/// Pins the import cards' state machine: a failed import marks only its own source, ends the active
/// import and reports the error text to the awaiting import inbox.
@MainActor
final class DataSourceImportServiceTests: XCTestCase {
    private func makeService() async throws -> DataSourceImportService {
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(try await WhoopStore.inMemory())
        return DataSourceImportService(repo: repo, whoopDeviceId: "my-whoop", appleDeviceId: "apple-health")
    }

    func testFailedWhoopImportMarksOnlyTheWhoopCard() async throws {
        let service = try await makeService()
        service.xiaomiImportSummary = "Imported 3 days · 2 sleeps"
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-test-missing-\(UUID().uuidString).zip")

        let outcome = await service.importWhoopAwaiting(url: missing)

        guard case .failure(let text) = outcome else { return XCTFail("expected a failure, got \(outcome)") }
        XCTAssertTrue(text.hasPrefix("Import failed:"), text)
        XCTAssertEqual(service.whoopImportSummary, text)
        XCTAssertTrue(service.whoopImportFailed)
        XCTAssertTrue(service.importFailed(.whoop))
        XCTAssertFalse(service.hasActiveImport)
        XCTAssertFalse(service.isImporting(.whoop))
        XCTAssertEqual(service.xiaomiImportSummary, "Imported 3 days · 2 sleeps")
        XCTAssertFalse(service.importFailed(.xiaomi))
    }

    func testNewImportClearsThatSourcesPreviousFailure() async throws {
        let service = try await makeService()
        service.whoopImportSummary = "Import failed: old"
        service.whoopImportFailed = true

        service.importWhoop(url: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))

        XCTAssertTrue(service.isImporting(.whoop))
        XCTAssertTrue(service.hasActiveImport)
        XCTAssertNil(service.whoopImportSummary)
        XCTAssertFalse(service.whoopImportFailed)

        let deadline = Date().addingTimeInterval(10)
        while service.hasActiveImport, Date() < deadline { await Task.yield() }
        XCTAssertFalse(service.hasActiveImport, "the import task must finish within the test")
        XCTAssertTrue(service.whoopImportFailed)
    }
}

import XCTest
import WhoopStore
@testable import Strand

/// The XCTest host is NOOP.app itself. Its AppModel must stay off the strap, the user's store and the
/// background schedulers while still serving hosted screens as their environment object.
@MainActor
final class AppTestHostGuardTests: XCTestCase {
    func testHostAppModelRunsWithoutStrapStoreOrSchedulers() async throws {
        XCTAssertTrue(AppRuntime.isTestHost)
        let model = try XCTUnwrap(AppModel.shared, "the test host must still publish its AppModel")
        XCTAssertTrue(model.isTestHost)
        XCTAssertNil(model.engine, "no CoreBluetooth engine in the test host")

        await model.testStoreIsolation?.value
        let store = await model.repo.storeHandle()
        XCTAssertNotNil(store)
        let onDiskBytes = await store?.databaseFileSizeBytes()
        XCTAssertNil(onDiskBytes, "the host's read model must use an in-memory store, never the user's database")

        model.startBackgroundServices()
        XCTAssertFalse(MacWidgetPublisher.shared.isStarted, "background services never start in the test host")
    }

    /// Until the in-memory store is installed, a read model must find no store rather than open the
    /// on-disk default — the test host runs as the app bundle, so that path is a real user's database.
    func testHostNeverResolvesTheOnDiskStore() async {
        XCTAssertThrowsError(try StorePaths.defaultDatabasePath()) { error in
            XCTAssertEqual(error as? StorePaths.PathError, .refusedInTestHost)
        }
        let store = await Repository(deviceId: SourceID.whoop).storeHandle()
        XCTAssertNil(store, "a repository without an injected store must not fall back to the user's database")
    }
}

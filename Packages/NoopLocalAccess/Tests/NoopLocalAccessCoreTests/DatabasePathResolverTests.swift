import XCTest
@testable import NoopLocalAccessCore

final class DatabasePathResolverTests: XCTestCase {
    func testPersonalBundleIsNotADefaultCandidate() {
        let candidates = DatabasePathResolver.candidates(home: "/Users/example")

        XCTAssertTrue(candidates.contains("/Users/example/Library/Containers/com.noopapp.noop/Data/Library/Application Support/OpenWhoop/whoop.sqlite"))
        XCTAssertFalse(candidates.contains { $0.contains("com.noopapp.noop.personal") })
    }

    func testCustomBundleIDIsExplicitOptIn() {
        let candidates = DatabasePathResolver.candidates(bundleID: "com.example.noop", home: "/Users/example")

        XCTAssertEqual(
            candidates.first,
            "/Users/example/Library/Containers/com.example.noop/Data/Library/Application Support/OpenWhoop/whoop.sqlite"
        )
        XCTAssertTrue(candidates.contains("/Users/example/Library/Containers/com.noopapp.noop/Data/Library/Application Support/OpenWhoop/whoop.sqlite"))
    }

    func testExplicitPathMustExist() throws {
        let url = try TemporaryDatabase.emptyFileURL()
        let config = LocalAccessConfiguration(databasePath: url.path)

        XCTAssertEqual(try DatabasePathResolver.resolve(configuration: config), url.path)
    }

    func testExplicitPathFailureDoesNotFallBack() {
        let config = LocalAccessConfiguration(databasePath: "/definitely/not/noop/whoop.sqlite")

        XCTAssertThrowsError(try DatabasePathResolver.resolve(configuration: config)) { error in
            XCTAssertEqual(error as? LocalAccessError, .databaseUnavailable("NOOP database not found at NOOP_DB_PATH."))
        }
    }

    // MARK: - External data folder mirror precedence

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    private func touch(_ path: String) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data()))
    }

    private func resolve(_ config: LocalAccessConfiguration = LocalAccessConfiguration(), home: URL) throws -> String {
        try DatabasePathResolver.resolve(configuration: config, home: home.path)
    }

    func testDefaultMirrorFolderIsUsedWhenPresent() throws {
        let home = try makeHome()
        let mirror = home.path + "/NOOP-Data/whoop-latest.sqlite"
        try touch(mirror)
        try touch(DatabasePathResolver.candidates(home: home.path)[0])

        XCTAssertEqual(try resolve(home: home), mirror)
    }

    func testLegacyGermanMirrorFolderIsStillFound() throws {
        let home = try makeHome()
        let legacy = home.path + "/NOOP-Daten/whoop-latest.sqlite"
        try touch(legacy)
        try touch(DatabasePathResolver.candidates(home: home.path)[0])

        XCTAssertEqual(try resolve(home: home), legacy)
    }

    func testDefaultMirrorFolderBeatsLegacyFolder() throws {
        let home = try makeHome()
        try touch(home.path + "/NOOP-Daten/whoop-latest.sqlite")
        try touch(home.path + "/NOOP-Data/whoop-latest.sqlite")

        XCTAssertEqual(try resolve(home: home), home.path + "/NOOP-Data/whoop-latest.sqlite")
    }

    func testConfiguredDataFolderIsUsedInsteadOfTheDefaults() throws {
        let home = try makeHome()
        try touch(home.path + "/NOOP-Data/whoop-latest.sqlite")
        try touch(home.path + "/Health Mirror/whoop-latest.sqlite")

        let config = LocalAccessConfiguration.environment(["NOOP_DATA_FOLDER": "Health Mirror"])
        XCTAssertEqual(try resolve(config, home: home), home.path + "/Health Mirror/whoop-latest.sqlite")
    }

    func testConfiguredDataFolderWithoutMirrorFallsBackToContainerOnly() throws {
        let home = try makeHome()
        try touch(home.path + "/NOOP-Daten/whoop-latest.sqlite")
        let container = DatabasePathResolver.candidates(home: home.path)[0]
        try touch(container)

        let config = LocalAccessConfiguration(dataFolder: "Elsewhere")
        XCTAssertEqual(try resolve(config, home: home), container)
    }

    func testEmptyDataFolderEnvironmentMeansDefault() {
        XCTAssertNil(LocalAccessConfiguration.environment(["NOOP_DATA_FOLDER": ""]).dataFolder)
        XCTAssertEqual(DatabasePathResolver.mirrorPaths(dataFolder: nil, home: "/Users/example"),
                       ["/Users/example/NOOP-Data/whoop-latest.sqlite", "/Users/example/NOOP-Daten/whoop-latest.sqlite"])
    }

    func testContainerCandidateIsUsedWhenMirrorIsMissing() throws {
        let home = try makeHome()
        let container = DatabasePathResolver.candidates(home: home.path)[0]
        try touch(container)

        XCTAssertEqual(try DatabasePathResolver.resolve(configuration: LocalAccessConfiguration(), home: home.path), container)
    }

    func testExplicitPathBeatsMirror() throws {
        let home = try makeHome()
        try touch(home.path + "/NOOP-Data/whoop-latest.sqlite")
        let explicit = home.path + "/custom/whoop.sqlite"
        try touch(explicit)

        let config = LocalAccessConfiguration(databasePath: explicit)
        XCTAssertEqual(try DatabasePathResolver.resolve(configuration: config, home: home.path), explicit)
    }

    func testMissingExplicitPathDoesNotFallBackToMirror() throws {
        let home = try makeHome()
        try touch(home.path + "/NOOP-Data/whoop-latest.sqlite")

        let config = LocalAccessConfiguration(databasePath: home.path + "/missing.sqlite")
        XCTAssertThrowsError(try DatabasePathResolver.resolve(configuration: config, home: home.path))
    }

    func testTildeInExplicitPathExpandsAgainstInjectedHome() throws {
        let home = try makeHome()
        try touch(home.path + "/db/whoop.sqlite")

        let config = LocalAccessConfiguration(databasePath: "~/db/whoop.sqlite")
        XCTAssertEqual(try DatabasePathResolver.resolve(configuration: config, home: home.path), home.path + "/db/whoop.sqlite")
    }

    func testNoDatabaseAnywhereThrows() throws {
        let home = try makeHome()
        XCTAssertThrowsError(try DatabasePathResolver.resolve(configuration: LocalAccessConfiguration(), home: home.path))
    }
}

import XCTest
import SQLite3
@testable import Strand

/// Build-time opt-in folder outside the sandbox container (Info.plist `NOOPExternalDataFolder`).
final class ExternalDataFolderTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    func testDisabledWhenKeyIsMissingOrEmpty() {
        XCTAssertNil(ExternalDataFolder.resolve(configuredName: nil, realHome: home))
        XCTAssertNil(ExternalDataFolder.resolve(configuredName: "", realHome: home))
        XCTAssertNil(ExternalDataFolder.resolve(configuredName: "   ", realHome: home))
    }

    func testEnabledWithAValidFolderName() throws {
        let folder = try XCTUnwrap(ExternalDataFolder.resolve(configuredName: "NOOP-Data", realHome: home))
        XCTAssertEqual(folder.root.path, "/Users/example/NOOP-Data")
        XCTAssertEqual(folder.importInboxDirectory.path, "/Users/example/NOOP-Data/Import")
        XCTAssertEqual(folder.rawPPGDirectory.path, "/Users/example/NOOP-Data/raw-ppg")
        XCTAssertEqual(folder.displayPath, "~/NOOP-Data")
        XCTAssertEqual(folder.rawPPGDisplayPath, "~/NOOP-Data/raw-ppg/")
    }

    func testExistingGermanFolderNameStaysUsable() throws {
        let folder = try XCTUnwrap(ExternalDataFolder.resolve(configuredName: "NOOP-Daten", realHome: home))
        XCTAssertEqual(folder.root.path, "/Users/example/NOOP-Daten")
    }

    func testInvalidValuesAreRejected() {
        let invalid: [Any] = [
            "/NOOP-Data", "/NOOP-Data/", "NOOP-Data/", "a/b", "~/NOOP-Data", "..", ".", "../NOOP-Data",
            "$(NOOP_EXTERNAL_DATA_FOLDER)", "NOOP\u{0}Data", String(repeating: "x", count: 256), 42, true,
        ]
        for value in invalid {
            XCTAssertNil(ExternalDataFolder.resolve(configuredName: value, realHome: home), "\(value)")
        }
    }

    func testWellKnownHomeFoldersAreRejectedInAnyCase() {
        let wellKnown = ["Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music",
                         "Pictures", "Public", "Sites", "public", "DOCUMENTS", "dEsKtOp", " Public "]
        for name in wellKnown {
            XCTAssertNil(ExternalDataFolder.resolve(configuredName: name, realHome: home), name)
        }
        for name in ["Public-NOOP", "My Documents", "Music2", "NOOP-Library"] {
            XCTAssertNotNil(ExternalDataFolder.resolve(configuredName: name, realHome: home), name)
        }
    }

    func testRealHomeIsNotTheSandboxContainer() {
        XCTAssertFalse(ExternalDataFolder.realHomeDirectory().path.contains("/Library/Containers/"))
    }
}

/// Owner-only directories and files created in the external folder.
final class PrivateFilesTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("privfiles-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue
    }

    func testEnsureDirectoryCreatesMissingComponentsOwnerOnly() throws {
        let leaf = dir.appendingPathComponent("a/b", isDirectory: true)
        try PrivateFiles.ensureDirectory(leaf)
        XCTAssertEqual(try mode(dir), 0o700)
        XCTAssertEqual(try mode(dir.appendingPathComponent("a")), 0o700)
        XCTAssertEqual(try mode(leaf), 0o700)
    }

    func testEnsureDirectoryLeavesAnExistingTargetAloneByDefault() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try PrivateFiles.ensureDirectory(dir)
        XCTAssertEqual(try mode(dir), 0o755)
    }

    func testEnsureDirectoryTightensAnExistingTargetOnlyWhenAsked() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try PrivateFiles.ensureDirectory(dir, tighteningExisting: true)
        XCTAssertEqual(try mode(dir), 0o700)
    }

    func testEnsureDirectoryNeverTightensAnExistingWellKnownFolder() throws {
        let publicFolder = dir.appendingPathComponent("Public", isDirectory: true)
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try PrivateFiles.ensureDirectory(publicFolder, tighteningExisting: true)
        XCTAssertEqual(try mode(publicFolder), 0o755)
    }

    func testEnsureDirectoryFailsWhenAFileIsInTheWay() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blocker = dir.appendingPathComponent("blocker")
        try Data([0]).write(to: blocker)
        XCTAssertThrowsError(try PrivateFiles.ensureDirectory(blocker))
        XCTAssertThrowsError(try PrivateFiles.ensureDirectory(blocker.appendingPathComponent("x")))
    }

    func testCreateEmptyFileIsOwnerOnlyAndNeverReplaces() throws {
        try PrivateFiles.ensureDirectory(dir)
        let file = dir.appendingPathComponent("f")
        XCTAssertTrue(try PrivateFiles.createEmptyFile(at: file))
        XCTAssertEqual(try mode(file), 0o600)
        try Data("keep".utf8).write(to: file)
        XCTAssertFalse(try PrivateFiles.createEmptyFile(at: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep")
    }

    func testWriteIfMissingIsOwnerOnlyAndKeepsExistingContent() throws {
        try PrivateFiles.ensureDirectory(dir)
        let file = dir.appendingPathComponent("README.txt")
        try PrivateFiles.writeIfMissing("first", to: file)
        XCTAssertEqual(try mode(file), 0o600)
        try PrivateFiles.writeIfMissing("second", to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first")
    }
}

/// The three writers only ever touch `<home>/<folder>`, and nothing at all when the folder is disabled.
final class ExternalDataFolderWiringTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("noop-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func makeSourceDatabase() -> URL {
        let source = home.appendingPathComponent("source.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE t(x INTEGER)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        return source
    }

    private var ppgFrame: [UInt8] {
        var f = [UInt8](repeating: 0x11, count: 120)
        f[8] = 47; f[9] = 21
        return f
    }

    func testDisabledByDefaultWritesNothingIntoTheHome() async throws {
        let folder = ExternalDataFolder.resolve(configuredName: nil, realHome: home)
        XCTAssertNil(folder)
        let capture = RawPPGCapture(directory: folder?.rawPPGDirectory, isEnabled: { true })
        capture.submitStreamFrame(ppgFrame, family: .whoop5)
        await capture.append(unix: nil, frame: ppgFrame)
        await capture.flush()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
    }

    @MainActor
    func testEnabledWritesOnlyBelowTheConfiguredFolder() async throws {
        let folder = try XCTUnwrap(ExternalDataFolder.resolve(configuredName: "NOOP-Data", realHome: home))
        let source = makeSourceDatabase()

        try AutoBackupEngine.mirror(sourcePath: source.path, into: folder.root)
        try ImportInboxEngine(directory: folder.importInboxDirectory) { _ in .failure("unused") }.prepare()
        let capture = RawPPGCapture(directory: folder.rawPPGDirectory, isEnabled: { true })
        await capture.append(unix: nil, frame: ppgFrame)
        await capture.close()

        let fm = FileManager.default
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: home.path)), ["source.sqlite", "NOOP-Data"])
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: folder.root.path)),
                       ["whoop-latest.sqlite", "README.txt", "Import", "raw-ppg"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.rawPPGDirectory.path).count, 1)
        let rootMode = try fm.attributesOfItem(atPath: folder.root.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(rootMode?.intValue, 0o700)
    }

    @MainActor
    func testOnlyTheConfiguredFolderItselfIsTightenedWhenItAlreadyExists() throws {
        let folder = try XCTUnwrap(ExternalDataFolder.resolve(configuredName: "NOOP-Data", realHome: home))
        let fm = FileManager.default
        for dir in [folder.root, folder.importInboxDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        let source = makeSourceDatabase()

        try AutoBackupEngine.mirror(sourcePath: source.path, into: folder.root)
        try ImportInboxEngine(directory: folder.importInboxDirectory) { _ in .failure("unused") }.prepare()

        func mode(_ url: URL) throws -> Int? {
            (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        }
        XCTAssertEqual(try mode(folder.root), 0o700)
        XCTAssertEqual(try mode(folder.importInboxDirectory), 0o755, "an existing subfolder keeps its mode")
        XCTAssertEqual(try mode(folder.importInboxDirectory.appendingPathComponent("Done")), 0o700)
    }

    @MainActor
    func testSharedWritersFollowTheBuildConfiguration() {
        let configured = ExternalDataFolder.current
        XCTAssertEqual(CodexMirrorScheduler.shared == nil, configured == nil)
        XCTAssertEqual(ImportInboxScheduler.shared == nil, configured == nil)
        XCTAssertEqual(RawPPGCapture.shared.directory, configured?.rawPPGDirectory)
    }
}

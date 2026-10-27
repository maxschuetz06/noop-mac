import XCTest
@testable import Strand

/// Minimal ZIP writer (stored entries) so the tests need no ZIP dependency.
private enum TestZip {
    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
    private static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }

    static func write(entries: [(String, String)], to url: URL) throws {
        var out = Data()
        var central = Data()
        for (name, text) in entries {
            let nameBytes = Array(name.utf8)
            let data = Data(text.utf8)
            let crc = crc32(data)
            let offset = UInt32(out.count)
            var local: [UInt8] = le32(0x04034b50) + le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0x21)
            local += le32(crc) + le32(UInt32(data.count)) + le32(UInt32(data.count))
            local += le16(nameBytes.count) + le16(0) + nameBytes
            out.append(contentsOf: local); out.append(data)
            var cd: [UInt8] = le32(0x02014b50) + le16(20) + le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0x21)
            cd += le32(crc) + le32(UInt32(data.count)) + le32(UInt32(data.count))
            cd += le16(nameBytes.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + nameBytes
            central.append(contentsOf: cd)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        let end: [UInt8] = le32(0x06054b50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
            + le32(UInt32(central.count)) + le32(cdOffset) + le16(0)
        out.append(contentsOf: end)
        try out.write(to: url)
    }
}

final class ImportInboxPolicyTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("importinbox-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testContainsWhoopCSVEnglishAndGerman() {
        XCTAssertTrue(ImportInboxPolicy.containsWhoopCSV(entryNames: ["my_export/physiological_cycles.csv"]))
        XCTAssertTrue(ImportInboxPolicy.containsWhoopCSV(entryNames: ["Sleeps.CSV"]))
        XCTAssertTrue(ImportInboxPolicy.containsWhoopCSV(entryNames: ["workouts.csv", "x.txt"]))
        XCTAssertTrue(ImportInboxPolicy.containsWhoopCSV(entryNames: ["journal_entries.csv"]))
        XCTAssertTrue(ImportInboxPolicy.containsWhoopCSV(entryNames: ["physiologische_zyklen.csv"]))
        XCTAssertTrue(ImportInboxPolicy.containsWhoopCSV(entryNames: ["a/Schlaf.csv"]))
        XCTAssertTrue(ImportInboxPolicy.containsWhoopCSV(entryNames: ["Trainings.csv"]))
        XCTAssertTrue(ImportInboxPolicy.containsWhoopCSV(entryNames: ["logbuch_eintraege.csv"]))
    }

    func testContainsWhoopCSVRejectsUnrelatedAndResourceForks() {
        XCTAssertFalse(ImportInboxPolicy.containsWhoopCSV(entryNames: ["export.xml", "notes.csv", "readme.txt"]))
        XCTAssertFalse(ImportInboxPolicy.containsWhoopCSV(entryNames: []))
        XCTAssertFalse(ImportInboxPolicy.containsWhoopCSV(entryNames: ["__MACOSX/export/._sleeps.csv"]))
        XCTAssertFalse(ImportInboxPolicy.containsWhoopCSV(entryNames: ["__MACOSX/sleeps.csv", "._workouts.csv"]))
    }

    func testIgnoreRules() {
        XCTAssertTrue(ImportInboxPolicy.isIgnored(name: ".DS_Store"))
        XCTAssertTrue(ImportInboxPolicy.isIgnored(name: ".hidden.zip"))
        XCTAssertTrue(ImportInboxPolicy.isIgnored(name: "Done"))
        XCTAssertTrue(ImportInboxPolicy.isIgnored(name: "Failed"))
        // Archive folders of earlier builds are never scanned.
        XCTAssertTrue(ImportInboxPolicy.isIgnored(name: "Erledigt"))
        XCTAssertTrue(ImportInboxPolicy.isIgnored(name: "Fehler"))
        XCTAssertFalse(ImportInboxPolicy.isIgnored(name: "export.zip"))
    }

    func testClassifyZip() throws {
        let good = dir.appendingPathComponent("whoop.zip")
        try TestZip.write(entries: [("physiological_cycles.csv", "a,b\n1,2\n"), ("sleeps.csv", "a\n")], to: good)
        XCTAssertEqual(ImportInboxPolicy.classify(good), .whoopZip)

        let german = dir.appendingPathComponent("daten.zip")
        try TestZip.write(entries: [("ordner/Schlaf.csv", "a\n")], to: german)
        XCTAssertEqual(ImportInboxPolicy.classify(german), .whoopZip)

        let other = dir.appendingPathComponent("other.zip")
        try TestZip.write(entries: [("export.xml", "<x/>")], to: other)
        XCTAssertNil(ImportInboxPolicy.classify(other))

        let notZip = dir.appendingPathComponent("broken.zip")
        try Data("not a zip".utf8).write(to: notZip)
        XCTAssertNil(ImportInboxPolicy.classify(notZip))

        let wrongExt = dir.appendingPathComponent("whoop.dat")
        try TestZip.write(entries: [("sleeps.csv", "a\n")], to: wrongExt)
        XCTAssertNil(ImportInboxPolicy.classify(wrongExt))
    }

    func testClassifyFolder() throws {
        let good = dir.appendingPathComponent("entpackt", isDirectory: true)
        try FileManager.default.createDirectory(at: good.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: good.appendingPathComponent("inner/workouts.csv"))
        XCTAssertEqual(ImportInboxPolicy.classify(good), .whoopFolder)

        let other = dir.appendingPathComponent("misc", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: other.appendingPathComponent("foo.csv"))
        XCTAssertNil(ImportInboxPolicy.classify(other))

        for archive in ["Done", "Erledigt"] {
            let done = dir.appendingPathComponent(archive, isDirectory: true)
            try FileManager.default.createDirectory(at: done, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: done.appendingPathComponent("sleeps.csv"))
            XCTAssertNil(ImportInboxPolicy.classify(done), archive)
        }
    }

    func testStabilityRule() {
        let now = Date(timeIntervalSince1970: 10_000)
        let old = ImportInboxPolicy.Fingerprint(size: 100, modified: now.addingTimeInterval(-60))
        let fresh = ImportInboxPolicy.Fingerprint(size: 100, modified: now.addingTimeInterval(-3))
        let grown = ImportInboxPolicy.Fingerprint(size: 200, modified: now.addingTimeInterval(-60))

        XCTAssertFalse(ImportInboxPolicy.isStable(current: old, previous: nil, now: now), "first sighting")
        XCTAssertFalse(ImportInboxPolicy.isStable(current: grown, previous: old, now: now), "size changed")
        XCTAssertFalse(ImportInboxPolicy.isStable(current: fresh, previous: fresh, now: now), "mtime too recent")
        XCTAssertTrue(ImportInboxPolicy.isStable(current: old, previous: old, now: now))
        XCTAssertTrue(ImportInboxPolicy.isStable(current: fresh, previous: fresh,
                                                 now: now.addingTimeInterval(10)))
    }

    func testFolderFingerprintChangesWhenFileGrows() throws {
        let folder = dir.appendingPathComponent("f", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("sleeps.csv")
        try Data("abc".utf8).write(to: file)
        let a = try XCTUnwrap(ImportInboxPolicy.fingerprint(of: folder))
        try Data("abcdef".utf8).write(to: file)
        let b = try XCTUnwrap(ImportInboxPolicy.fingerprint(of: folder))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(b.size, 6)
    }

    func testLogLines() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ok = ImportInboxPolicy.logLine(now: now, name: "a.zip", outcome: .success(
            recordCount: 165, counts: ["cycles": 100, "sleeps": 40, "workouts": 20, "journal": 5], summary: "x"))
        XCTAssertTrue(ok.contains("| a.zip | OK | 100 days, 40 sleeps, 20 workouts, 5 journal"), ok)
        let bad = ImportInboxPolicy.logLine(now: now, name: "b.zip", outcome: .failure("kaputt\nzeile 2"))
        XCTAssertTrue(bad.hasSuffix("| b.zip | FAILED | kaputt zeile 2"), bad)
        XCTAssertFalse(bad.contains("\n"))
    }
}

@MainActor
final class ImportInboxEngineTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("importinbox-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func contents(_ sub: String) -> [String] {
        let url = dir.appendingPathComponent(sub)
        return ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    private func logText() -> String {
        (try? String(contentsOf: dir.appendingPathComponent("import-log.txt"), encoding: .utf8)) ?? ""
    }

    private func makeEngine(minAge: TimeInterval = 0,
                            importer: @escaping (URL) async -> ImportInboxOutcome) throws -> ImportInboxEngine {
        let engine = ImportInboxEngine(directory: dir, minAge: minAge, importer: importer)
        try engine.prepare()
        return engine
    }

    private func mode(_ sub: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(sub).path)
        return try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue
    }

    func testPrepareCreatesOwnerOnlyFoldersAndEnglishReadmeOnce() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        let engine = try makeEngine { _ in .failure("unused") }
        XCTAssertEqual(try mode(""), 0o755, "an inbox that already existed keeps its permissions")
        XCTAssertEqual(try mode("Done"), 0o700)
        XCTAssertEqual(try mode("Failed"), 0o700)
        let readmeURL = dir.appendingPathComponent("README.txt")
        XCTAssertTrue(try String(contentsOf: readmeURL, encoding: .utf8).contains("Drop a WHOOP export here"))
        XCTAssertEqual(try mode("README.txt"), 0o600)
        try "own text".write(to: readmeURL, atomically: true, encoding: .utf8)
        try engine.prepare()
        XCTAssertEqual(try String(contentsOf: readmeURL, encoding: .utf8), "own text")
    }

    func testExistingGermanArchiveFoldersAndReadmeAreKeptAndNeverImported() async throws {
        // Earlier builds archived unpacked exports as folders: a WHOOP CSV two levels deep.
        for legacy in ["Erledigt", "Fehler"] {
            let archived = dir.appendingPathComponent("\(legacy)/2026-01-01 1200 export", isDirectory: true)
            try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
            try Data("a\n".utf8).write(to: archived.appendingPathComponent("sleeps.csv"))
        }
        try "alter Text".write(to: dir.appendingPathComponent("LIESMICH.txt"), atomically: true, encoding: .utf8)
        var calls = 0
        let engine = try makeEngine { _ in calls += 1; return .success(recordCount: 0, counts: [:], summary: "") }

        await engine.scan()
        let report = await engine.scan(now: Date().addingTimeInterval(30))
        XCTAssertEqual(report, ImportInboxEngine.ScanReport())
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(contents("Erledigt"), ["2026-01-01 1200 export"])
        XCTAssertEqual(contents("Fehler"), ["2026-01-01 1200 export"])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("LIESMICH.txt"), encoding: .utf8), "alter Text")
        XCTAssertTrue(contents("Done").isEmpty)
    }

    func testSuccessMovesToDoneAndLogs() async throws {
        var imported: [String] = []
        let engine = try makeEngine { url in
            imported.append(url.lastPathComponent)
            return .success(recordCount: 9, counts: ["cycles": 5, "sleeps": 2, "workouts": 1, "journal": 1], summary: "ok")
        }
        let zip = dir.appendingPathComponent("export.zip")
        try TestZip.write(entries: [("physiological_cycles.csv", "a\n1\n")], to: zip)

        // First sighting: not stable yet.
        let first = await engine.scan()
        XCTAssertEqual(first, ImportInboxEngine.ScanReport(imported: 0, failed: 0, pending: 1))
        XCTAssertTrue(imported.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))

        // Second sighting: imported and archived.
        let second = await engine.scan(now: Date().addingTimeInterval(30))
        XCTAssertEqual(second, ImportInboxEngine.ScanReport(imported: 1, failed: 0, pending: 0))
        XCTAssertEqual(imported, ["export.zip"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.path))
        let done = contents("Done")
        XCTAssertEqual(done.count, 1)
        XCTAssertTrue(done[0].hasSuffix(" export.zip"), done[0])
        XCTAssertTrue(contents("Failed").isEmpty)
        XCTAssertTrue(logText().contains("| export.zip | OK | 5 days, 2 sleeps, 1 workouts, 1 journal"), logText())
        XCTAssertEqual(try mode("import-log.txt"), 0o600)

        // Nothing left to do.
        let third = await engine.scan(now: Date().addingTimeInterval(60))
        XCTAssertEqual(third, ImportInboxEngine.ScanReport())
        XCTAssertEqual(imported.count, 1)
    }

    func testFailureMovesToFailedWithNote() async throws {
        let engine = try makeEngine { _ in .failure("Import failed: kaputte Zeile") }
        let folder = dir.appendingPathComponent("entpackt", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("workouts.csv"))

        await engine.scan()
        let report = await engine.scan(now: Date().addingTimeInterval(30))
        XCTAssertEqual(report, ImportInboxEngine.ScanReport(imported: 0, failed: 1, pending: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let failed = contents("Failed")
        XCTAssertEqual(failed.count, 2, "\(failed)")
        let moved = try XCTUnwrap(failed.first { !$0.hasSuffix(".error.txt") })
        let note = try XCTUnwrap(failed.first { $0.hasSuffix(".error.txt") })
        XCTAssertEqual(note, moved + ".error.txt")
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("Failed/\(note)"), encoding: .utf8)
            .contains("kaputte Zeile"))
        XCTAssertEqual(try mode("Failed/\(note)"), 0o600)
        XCTAssertTrue(contents("Done").isEmpty)
        XCTAssertTrue(logText().contains("| entpackt | FAILED | Import failed: kaputte Zeile"), logText())
    }

    func testUnknownAndHiddenFilesAreLeftAlone() async throws {
        var calls = 0
        let engine = try makeEngine { _ in calls += 1; return .failure("nope") }
        try Data("hi".utf8).write(to: dir.appendingPathComponent("notizen.txt"))
        try Data("x".utf8).write(to: dir.appendingPathComponent(".versteckt.zip"))
        try TestZip.write(entries: [("export.xml", "<x/>")], to: dir.appendingPathComponent("apple.zip"))

        await engine.scan()
        await engine.scan(now: Date().addingTimeInterval(30))
        await engine.scan(now: Date().addingTimeInterval(60))
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notizen.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".versteckt.zip").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("apple.zip").path))
        XCTAssertTrue(logText().isEmpty)
    }

    func testItemStillGrowingIsNotImported() async throws {
        var calls = 0
        let engine = try makeEngine { _ in calls += 1; return .success(recordCount: 0, counts: [:], summary: "") }
        let zip = dir.appendingPathComponent("grows.zip")
        try TestZip.write(entries: [("sleeps.csv", "a\n")], to: zip)
        await engine.scan()
        // The file changes between scans (still being written) → still pending.
        try TestZip.write(entries: [("sleeps.csv", "a\n"), ("workouts.csv", "bbbbbbbb\n")], to: zip)
        let report = await engine.scan(now: Date().addingTimeInterval(30))
        XCTAssertEqual(report.imported, 0)
        XCTAssertEqual(report.pending, 1)
        XCTAssertEqual(calls, 0)
        let settled = await engine.scan(now: Date().addingTimeInterval(60))
        XCTAssertEqual(settled.imported, 1)
        XCTAssertEqual(calls, 1)
    }

    func testRecentlyModifiedItemWaitsForMinAge() async throws {
        var calls = 0
        let engine = try makeEngine(minAge: 10) { _ in calls += 1; return .success(recordCount: 0, counts: [:], summary: "") }
        try TestZip.write(entries: [("sleeps.csv", "a\n")], to: dir.appendingPathComponent("neu.zip"))
        await engine.scan()
        let tooSoon = await engine.scan(now: Date())   // unchanged, but mtime is only moments old
        XCTAssertEqual(tooSoon.pending, 1)
        XCTAssertEqual(calls, 0)
        let later = await engine.scan(now: Date().addingTimeInterval(15))
        XCTAssertEqual(later.imported, 1)
        XCTAssertEqual(calls, 1)
    }

    func testNameCollisionInDoneKeepsBoth() async throws {
        let engine = try makeEngine { _ in .success(recordCount: 1, counts: [:], summary: "") }
        let fixedNow = Date().addingTimeInterval(30)
        for _ in 0..<2 {
            try TestZip.write(entries: [("sleeps.csv", "a\n")], to: dir.appendingPathComponent("export.zip"))
            await engine.scan(now: fixedNow)
            await engine.scan(now: fixedNow)
        }
        XCTAssertEqual(contents("Done").count, 2)
    }
}

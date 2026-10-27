import XCTest
import WhoopProtocol
@testable import Strand

/// Opt-in raw PPG night capture (SpO₂ research): binary format, gzip rotation, retention policy and the
/// "capture errors never propagate" contract.
final class RawPPGFormatTests: XCTestCase {
    func testRecordRoundTrip() throws {
        let a = RawPPGFormat.Record(unix: 1_780_000_000, frame: [0xAA, 1, 2, 3])
        let b = RawPPGFormat.Record(unix: 1_780_000_001, frame: Array(repeating: 0x5A, count: 1_900))
        var data = Data()
        for r in [a, b] { data.append(try XCTUnwrap(RawPPGFormat.encode(unix: r.unix, frame: r.frame))) }
        // Layout check: u32 LE unix, u16 LE len, payload.
        XCTAssertEqual(Array(data.prefix(6)),
                       [UInt8(truncatingIfNeeded: a.unix), UInt8(truncatingIfNeeded: a.unix >> 8),
                        UInt8(truncatingIfNeeded: a.unix >> 16), UInt8(truncatingIfNeeded: a.unix >> 24), 4, 0])
        let decoded = RawPPGFormat.decode(data)
        XCTAssertEqual(decoded.records, [a, b])
        XCTAssertFalse(decoded.truncatedTail)
    }

    func testTornTailIsIgnoredAndReported() throws {
        var data = try XCTUnwrap(RawPPGFormat.encode(unix: 1_780_000_000, frame: [1, 2, 3, 4]))
        data.append(try XCTUnwrap(RawPPGFormat.encode(unix: 1_780_000_001, frame: [9, 9, 9, 9, 9])).dropLast(2))
        let decoded = RawPPGFormat.decode(data)
        XCTAssertEqual(decoded.records.count, 1)
        XCTAssertTrue(decoded.truncatedTail)
    }

    func testEmptyAndOversizedFramesAreRejected() {
        XCTAssertNil(RawPPGFormat.encode(unix: 1, frame: []))
        XCTAssertNil(RawPPGFormat.encode(unix: 1, frame: Array(repeating: 0, count: 65_536)))
        XCTAssertNotNil(RawPPGFormat.encode(unix: 1, frame: Array(repeating: 0, count: 65_535)))
    }

    func testMultiMemberGzipRoundTrip() throws {
        // Pseudo-random-ish but compressible payload spanning several gzip members.
        var payload = Data()
        for i in 0..<9_000 { payload.append(contentsOf: [UInt8(i & 0xFF), UInt8((i / 7) & 0xFF), 3, 4]) }
        var gz = Data()
        var offset = 0
        let chunk = 10_000
        while offset < payload.count {
            gz.append(try RawPPGFormat.gzipMember(payload.subdata(in: offset..<min(offset + chunk, payload.count))))
            offset += chunk
        }
        XCTAssertEqual(Array(gz.prefix(3)), [0x1f, 0x8b, 0x08])
        XCTAssertEqual(try RawPPGFormat.gunzip(gz), payload)
    }

    func testGunzipDetectsCorruption() throws {
        var gz = try RawPPGFormat.gzipMember(Data(repeating: 7, count: 500))
        gz[gz.count - 8] ^= 0xFF   // CRC byte
        XCTAssertThrowsError(try RawPPGFormat.gunzip(gz))
    }

    func testCRC32KnownVector() {
        XCTAssertEqual(RawPPGFormat.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }
}

final class RawPPGPolicyTests: XCTestCase {
    private func frame(family: DeviceFamily, version: UInt8, type: UInt8 = 47, unix: UInt32 = 1_780_000_000) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 40)
        f[0] = 0xAA
        let t = family == .whoop5 ? 8 : 4
        f[t] = type
        f[t + 1] = version
        let o = family == .whoop5 ? 15 : 11
        for i in 0..<4 { f[o + i] = UInt8((unix >> (8 * UInt32(i))) & 0xFF) }
        return f
    }

    func testStreamVersionsAreCapturedOnlyForHistoricalRecords() {
        for v: UInt8 in [20, 21, 26] {
            XCTAssertTrue(RawPPGPolicy.isStreamCaptured(frame(family: .whoop5, version: v), family: .whoop5))
        }
        XCTAssertFalse(RawPPGPolicy.isStreamCaptured(frame(family: .whoop5, version: 18), family: .whoop5))
        XCTAssertFalse(RawPPGPolicy.isStreamCaptured(frame(family: .whoop5, version: 21, type: 40), family: .whoop5))
        XCTAssertFalse(RawPPGPolicy.isStreamCaptured([0xAA, 1], family: .whoop5))
    }

    func testVersionAndUnixOffsetsFollowFamily() {
        let f4 = frame(family: .whoop4, version: 19, unix: 1_780_000_123)
        XCTAssertEqual(RawPPGPolicy.historicalVersion(f4, family: .whoop4), 19)
        XCTAssertEqual(RawPPGPolicy.recordUnix(f4, family: .whoop4), 1_780_000_123)
        let f5 = frame(family: .whoop5, version: 21, unix: 1_780_000_456)
        XCTAssertEqual(RawPPGPolicy.historicalVersion(f5, family: .whoop5), 21)
        XCTAssertEqual(RawPPGPolicy.recordUnix(f5, family: .whoop5), 1_780_000_456)
    }

    func testFileNameDay() {
        XCTAssertEqual(RawPPGPolicy.day(fromFileName: "2026-10-13.bin"), "2026-10-13")
        XCTAssertEqual(RawPPGPolicy.day(fromFileName: "2026-10-13.bin.gz"), "2026-10-13")
        XCTAssertNil(RawPPGPolicy.day(fromFileName: "2026-10-13.bin.gz.tmp"))
        XCTAssertNil(RawPPGPolicy.day(fromFileName: "notes.txt"))
        XCTAssertNil(RawPPGPolicy.day(fromFileName: "abcd-ef-gh.bin"))
    }

    // MARK: Retention (pure)

    private let utc = TimeZone(identifier: "UTC")!
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    func testRetentionDeletesFilesOlderThanThirtyDays() {
        let today = date(2026, 10, 14)   // cutoff = 2026-09-14
        let entries: [RawPPGPolicy.FileEntry] = [
            .init(name: "2026-09-13.bin.gz", size: 10),   // older → delete
            .init(name: "2026-09-14.bin.gz", size: 10),   // exactly 30 days → keep
            .init(name: "2026-10-13.bin", size: 10),
            .init(name: "README.txt", size: 10),          // foreign file → untouched
        ]
        XCTAssertEqual(RawPPGPolicy.retentionDeletions(entries: entries, today: today, timeZone: utc), ["2026-09-13.bin.gz"])
    }

    func testRetentionSizeCapDeletesOldestFirstButNeverNewestDay() {
        let today = date(2026, 10, 14)
        let entries: [RawPPGPolicy.FileEntry] = [
            .init(name: "2026-10-10.bin.gz", size: 400),
            .init(name: "2026-10-11.bin.gz", size: 400),
            .init(name: "2026-10-12.bin.gz", size: 400),
            .init(name: "2026-10-13.bin", size: 400),
        ]
        XCTAssertEqual(RawPPGPolicy.retentionDeletions(entries: entries, today: today, timeZone: utc, maxBytes: 1_000),
                       ["2026-10-10.bin.gz", "2026-10-11.bin.gz"])
        // The newest day alone exceeds the cap: it must survive.
        XCTAssertEqual(RawPPGPolicy.retentionDeletions(entries: entries, today: today, timeZone: utc, maxBytes: 100),
                       ["2026-10-10.bin.gz", "2026-10-11.bin.gz", "2026-10-12.bin.gz"])
        XCTAssertEqual(RawPPGPolicy.retentionDeletions(entries: entries, today: today, timeZone: utc), [])
    }

    func testRecentlyWrittenFilesSurviveBothRetentionRules() {
        let today = date(2026, 10, 14)
        let justNow = today.addingTimeInterval(-3_600)
        let entries: [RawPPGPolicy.FileEntry] = [
            .init(name: "2026-08-01.bin", size: 400, modified: justNow),   // backlog night captured just now
            .init(name: "2026-08-02.bin.gz", size: 400),                    // old and written long ago
            .init(name: "2026-10-12.bin.gz", size: 400, modified: justNow),
            .init(name: "2026-10-13.bin", size: 400),
        ]
        XCTAssertEqual(RawPPGPolicy.retentionDeletions(entries: entries, today: today, timeZone: utc, maxBytes: 100),
                       ["2026-08-02.bin.gz"])
    }
}

/// Blocks the writer inside its first `now()` call until the test releases it.
private final class WriterGate: @unchecked Sendable {
    private let lock = NSLock()
    private var first = true
    private var blocked = false
    private let released = DispatchSemaphore(value: 0)

    var writerIsBlocked: Bool { lock.lock(); defer { lock.unlock() }; return blocked }

    func passFirstCall() {
        lock.lock()
        let isFirst = first
        first = false
        blocked = isFirst
        lock.unlock()
        guard isFirst else { return }
        released.wait()
    }

    func release() { released.signal() }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ d: Date) { current = d }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func set(_ d: Date) { lock.lock(); current = d; lock.unlock() }
}

private final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ v: Bool) { value = v }
    var on: Bool { get { lock.lock(); defer { lock.unlock() }; return value }
                   set { lock.lock(); value = newValue; lock.unlock() } }
}

final class RawPPGCaptureWriterTests: XCTestCase {
    private var dir: URL!
    private let utc = TimeZone(identifier: "UTC")!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rawppg-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func frame(version: UInt8, unix: UInt32, fill: UInt8 = 0x11, count: Int = 120) -> [UInt8] {
        var f = [UInt8](repeating: fill, count: count)
        f[0] = 0xAA; f[8] = 47; f[9] = version
        for i in 0..<4 { f[15 + i] = UInt8((unix >> (8 * UInt32(i))) & 0xFF) }
        return f
    }

    private func unix(_ d: Date) -> UInt32 { UInt32(d.timeIntervalSince1970) }

    private func makeCapture(clock: TestClock, enabled: TestFlag = TestFlag(true), directory: URL? = nil) -> RawPPGCapture {
        RawPPGCapture(directory: directory ?? dir, timeZone: utc,
                      now: { clock.now }, isEnabled: { enabled.on })
    }

    private func readRecords(_ name: String) throws -> [RawPPGFormat.Record] {
        let data = try Data(contentsOf: dir.appendingPathComponent(name))
        let raw = name.hasSuffix(".gz") ? try RawPPGFormat.gunzip(data) : data
        let decoded = RawPPGFormat.decode(raw)
        XCTAssertFalse(decoded.truncatedTail)
        return decoded.records
    }

    func testWriteThenReadBack() async throws {
        let day = date(2026, 10, 13)
        let clock = TestClock(date(2026, 10, 13, hour: 23))
        let cap = makeCapture(clock: clock)
        let f1 = frame(version: 21, unix: unix(day))
        let f2 = frame(version: 20, unix: unix(day) + 1, fill: 0x22)
        await cap.append(unix: unix(day), frame: f1)
        await cap.append(unix: unix(day) + 1, frame: f2)
        await cap.close()
        let recs = try readRecords("2026-10-13.bin")
        XCTAssertEqual(recs, [.init(unix: unix(day), frame: f1), .init(unix: unix(day) + 1, frame: f2)])
    }

    func testStreamHookCapturesV20V21V26AndRejectedHookTheRest() async throws {
        let now = date(2026, 10, 13)
        let cap = makeCapture(clock: TestClock(now))
        let u = unix(now)
        cap.submitStreamFrame(frame(version: 21, unix: u), family: .whoop5)
        cap.submitStreamFrame(frame(version: 26, unix: u + 1), family: .whoop5)
        cap.submitStreamFrame(frame(version: 18, unix: u + 2), family: .whoop5)   // not a PPG layout → ignored here
        // Rejected path: v20 was already taken by the stream hook (no duplicate); v24 is new.
        cap.submitRejected([frame(version: 20, unix: u + 3), frame(version: 24, unix: u + 4)], family: .whoop5)
        cap.submitStreamFrame(frame(version: 20, unix: u + 3), family: .whoop5)
        await cap.flush()
        await cap.close()
        let versions = try readRecords("2026-10-13.bin").map { $0.frame[9] }
        XCTAssertEqual(versions, [21, 26, 24, 20])
    }

    func testDisabledCapturesNothingAndCreatesNothing() async throws {
        let now = date(2026, 10, 13)
        let flag = TestFlag(false)
        let cap = makeCapture(clock: TestClock(now), enabled: flag)
        cap.submitStreamFrame(frame(version: 21, unix: unix(now)), family: .whoop5)
        cap.submitRejected([frame(version: 24, unix: unix(now))], family: .whoop5)
        await cap.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        flag.on = true
        cap.submitStreamFrame(frame(version: 21, unix: unix(now)), family: .whoop5)
        await cap.flush()
        await cap.close()
        XCTAssertEqual(try readRecords("2026-10-13.bin").count, 1)
    }

    func testImplausibleRecordTimeFallsBackToCaptureTime() async throws {
        let now = date(2026, 10, 13)
        let cap = makeCapture(clock: TestClock(now))
        await cap.append(unix: 1_000_000, frame: frame(version: 21, unix: 1_000_000))      // 1970 → garbage
        await cap.append(unix: unix(now) + 5 * 86_400, frame: frame(version: 21, unix: 0)) // future → garbage
        await cap.close()
        let recs = try readRecords("2026-10-13.bin")
        XCTAssertEqual(recs.map(\.unix), [unix(now), unix(now)])
    }

    func testRotationCompressesFinishedDaysAndKeepsActiveOneUncompressed() async throws {
        let d1 = date(2026, 10, 10)
        let clock = TestClock(d1)
        let cap = makeCapture(clock: clock)
        let f1 = frame(version: 21, unix: unix(d1))
        let f1b = frame(version: 26, unix: unix(d1) + 1, fill: 0x33)
        await cap.append(unix: unix(d1), frame: f1)
        await cap.append(unix: unix(d1) + 1, frame: f1b)

        // Three days later: day 1 is older than the one-day grace and is not open any more.
        let d4 = date(2026, 10, 13)
        clock.set(d4)
        let f4 = frame(version: 21, unix: unix(d4))
        await cap.append(unix: unix(d4), frame: f4)
        await cap.close()

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("2026-10-10.bin").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("2026-10-10.bin.gz").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("2026-10-13.bin").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("2026-10-13.bin.gz").path))
        XCTAssertEqual(try readRecords("2026-10-10.bin.gz"),
                       [.init(unix: unix(d1), frame: f1), .init(unix: unix(d1) + 1, frame: f1b)])
        XCTAssertEqual(try readRecords("2026-10-13.bin"), [.init(unix: unix(d4), frame: f4)])
    }

    func testLateSegmentForAnAlreadyCompressedDayIsAppendedAsGzipMember() async throws {
        let d1 = date(2026, 10, 10)
        let clock = TestClock(d1)
        let cap = makeCapture(clock: clock)
        let first = frame(version: 21, unix: unix(d1))
        await cap.append(unix: unix(d1), frame: first)
        clock.set(date(2026, 10, 13))
        await cap.append(unix: unix(date(2026, 10, 13)), frame: frame(version: 21, unix: unix(date(2026, 10, 13))))
        // A late sync delivers more of night 1 → new `.bin` segment next to the `.bin.gz`.
        let late = frame(version: 20, unix: unix(d1) + 60, fill: 0x44)
        await cap.append(unix: unix(d1) + 60, frame: late)
        // Next day's first write switches files and compresses the late segment into the same .gz.
        clock.set(date(2026, 10, 14))
        await cap.append(unix: unix(date(2026, 10, 14)), frame: frame(version: 21, unix: unix(date(2026, 10, 14))))
        await cap.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("2026-10-10.bin").path))
        XCTAssertEqual(try readRecords("2026-10-10.bin.gz"),
                       [.init(unix: unix(d1), frame: first), .init(unix: unix(d1) + 60, frame: late)])
    }

    func testRetentionRunsAfterRotation() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("2026-01-01.bin.gz"))   // far older than 30 days
        try FileManager.default.setAttributes([.modificationDate: date(2026, 1, 2)],
                                              ofItemAtPath: dir.appendingPathComponent("2026-01-01.bin.gz").path)
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("keep-me.txt"))
        let now = date(2026, 10, 13)
        let cap = makeCapture(clock: TestClock(now))
        await cap.append(unix: unix(now), frame: frame(version: 21, unix: unix(now)))
        await cap.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("2026-01-01.bin.gz").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("keep-me.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("2026-10-13.bin").path))
    }

    // MARK: Crash safety, retention protection, permissions, bounded queue

    func testCompressAfterCrashBetweenPublishAndRemovalDoesNotDuplicateTheDay() async throws {
        // On-disk state of a run that died after publishing the .gz but before removing the .bin.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let d1 = date(2026, 10, 10)
        let record = try XCTUnwrap(RawPPGFormat.encode(unix: unix(d1), frame: frame(version: 21, unix: unix(d1))))
        try record.write(to: dir.appendingPathComponent("2026-10-10.bin"))
        try RawPPGFormat.gzipMember(record).write(to: dir.appendingPathComponent("2026-10-10.bin.gz"))

        let today = date(2026, 10, 13)
        let cap = makeCapture(clock: TestClock(today))
        await cap.append(unix: unix(today), frame: frame(version: 21, unix: unix(today)))
        await cap.close()

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("2026-10-10.bin").path))
        XCTAssertEqual(try readRecords("2026-10-10.bin.gz").count, 1)
    }

    func testCrashLeftoverOfTheDayBeingWrittenIsNotDuplicated() async throws {
        // Same crash state, but the first record after relaunch belongs to that very day (backlog night).
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let d1 = date(2026, 10, 10)
        let record = try XCTUnwrap(RawPPGFormat.encode(unix: unix(d1), frame: frame(version: 21, unix: unix(d1))))
        try record.write(to: dir.appendingPathComponent("2026-10-10.bin"))
        try RawPPGFormat.gzipMember(record).write(to: dir.appendingPathComponent("2026-10-10.bin.gz"))

        let today = date(2026, 10, 13)
        let cap = makeCapture(clock: TestClock(today))
        await cap.append(unix: unix(d1) + 60, frame: frame(version: 20, unix: unix(d1) + 60))
        await cap.append(unix: unix(today), frame: frame(version: 21, unix: unix(today)))
        await cap.close()

        XCTAssertEqual(try readRecords("2026-10-10.bin.gz").map(\.unix), [unix(d1), unix(d1) + 60])
    }

    func testCompressAfterCrashBeforePublishKeepsEveryRecordExactlyOnce() async throws {
        // A run that died while building the new .gz leaves temporaries behind and the .gz untouched.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let d1 = date(2026, 10, 10)
        let first = try XCTUnwrap(RawPPGFormat.encode(unix: unix(d1), frame: frame(version: 21, unix: unix(d1))))
        let late = try XCTUnwrap(RawPPGFormat.encode(unix: unix(d1) + 60, frame: frame(version: 20, unix: unix(d1) + 60)))
        try RawPPGFormat.gzipMember(first).write(to: dir.appendingPathComponent("2026-10-10.bin.gz"))
        try late.write(to: dir.appendingPathComponent("2026-10-10.bin"))
        try Data([0x1f, 0x8b, 0x08]).write(to: dir.appendingPathComponent("2026-10-10.bin.gz.tmp"))
        try Data([0x1f]).write(to: dir.appendingPathComponent("2026-10-10.bin.members.tmp"))

        let today = date(2026, 10, 13)
        let cap = makeCapture(clock: TestClock(today))
        await cap.append(unix: unix(today), frame: frame(version: 21, unix: unix(today)))
        await cap.close()

        XCTAssertEqual(try readRecords("2026-10-10.bin.gz").map(\.unix), [unix(d1), unix(d1) + 60])
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") }, "\(names)")
        XCTAssertFalse(names.contains("2026-10-10.bin"))
    }

    func testBacklogNightOlderThanRetentionSurvivesTheNextDaySwitch() async throws {
        let today = date(2026, 10, 26)
        let cap = makeCapture(clock: TestClock(today))
        let backlog = date(2026, 9, 15)   // more than 30 days old, written just now
        await cap.append(unix: unix(backlog), frame: frame(version: 21, unix: unix(backlog)))
        await cap.append(unix: unix(today), frame: frame(version: 21, unix: unix(today)))
        await cap.close()
        // Compressed like any finished day, but not deleted although it is older than the retention window.
        XCTAssertEqual(try readRecords("2026-09-15.bin.gz").count, 1)
    }

    func testDayBeingWrittenIsNeverDeletedEvenWhenOldAndUntouched() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = date(2026, 9, 1)
        let earlier = try XCTUnwrap(RawPPGFormat.encode(unix: unix(old), frame: frame(version: 21, unix: unix(old))))
        let url = dir.appendingPathComponent("2026-09-01.bin")
        try earlier.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date(2026, 9, 2)], ofItemAtPath: url.path)

        let cap = makeCapture(clock: TestClock(date(2026, 10, 26)))
        await cap.append(unix: unix(old) + 30, frame: frame(version: 21, unix: unix(old) + 30))
        await cap.close()
        XCTAssertEqual(try readRecords("2026-09-01.bin").map(\.unix), [unix(old), unix(old) + 30])
    }

    func testFolderAndFilesAreOwnerOnly() async throws {
        let clock = TestClock(date(2026, 10, 10))
        let cap = makeCapture(clock: clock)
        await cap.append(unix: unix(date(2026, 10, 10)), frame: frame(version: 21, unix: unix(date(2026, 10, 10))))
        clock.set(date(2026, 10, 13))
        await cap.append(unix: unix(date(2026, 10, 13)), frame: frame(version: 21, unix: unix(date(2026, 10, 13))))
        await cap.close()
        func mode(_ name: String) throws -> Int {
            let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
            return try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue
        }
        XCTAssertEqual(try mode(""), 0o700)
        XCTAssertEqual(try mode("2026-10-10.bin.gz"), 0o600)
        XCTAssertEqual(try mode("2026-10-13.bin"), 0o600)
    }

    func testQueueIsBoundedAndDropsRecordsBeyondCapacity() async throws {
        let now = date(2026, 10, 13)
        let gate = WriterGate()
        var limits = RawPPGCapture.Limits()
        limits.queueCapacity = 3
        let cap = RawPPGCapture(directory: dir, timeZone: utc, now: { gate.passFirstCall(); return now },
                                isEnabled: { true }, limits: limits)
        let f = frame(version: 21, unix: unix(now))
        cap.submitStreamFrame(f, family: .whoop5)
        while !gate.writerIsBlocked { try await Task.sleep(nanoseconds: 1_000_000) }   // record 1 in flight
        for _ in 0..<10 { cap.submitStreamFrame(f, family: .whoop5) }
        XCTAssertEqual(cap.droppedRecordCount, 7)
        gate.release()
        await cap.flush()
        await cap.close()
        XCTAssertEqual(try readRecords("2026-10-13.bin").count, 4)
    }

    func testWithoutExternalFolderNothingIsCaptured() async {
        let cap = RawPPGCapture(directory: nil, timeZone: utc, now: { Date() }, isEnabled: { true })
        let now = date(2026, 10, 13)
        cap.submitStreamFrame(frame(version: 21, unix: unix(now)), family: .whoop5)
        cap.submitRejected([frame(version: 24, unix: unix(now))], family: .whoop5)
        await cap.append(unix: unix(now), frame: frame(version: 21, unix: unix(now)))
        await cap.flush()
        XCTAssertNil(cap.directory)
        XCTAssertEqual(cap.droppedRecordCount, 0)
    }

    // MARK: Errors never propagate

    func testUnwritableDirectoryIsSwallowed() async throws {
        // `directory` lives under a regular FILE, so createDirectory/open must fail.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blocker = dir.appendingPathComponent("blocker")
        try Data([0]).write(to: blocker)
        let now = date(2026, 10, 13)
        let cap = makeCapture(clock: TestClock(now), directory: blocker.appendingPathComponent("raw-ppg"))
        // Neither the direct nor the fire-and-forget path may throw, trap or hang.
        await cap.append(unix: unix(now), frame: frame(version: 21, unix: unix(now)))
        cap.submitStreamFrame(frame(version: 21, unix: unix(now)), family: .whoop5)
        cap.submitRejected([frame(version: 24, unix: unix(now))], family: .whoop5)
        await cap.flush()
        await cap.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: blocker.appendingPathComponent("raw-ppg").path))
    }

    func testSubmitIsSynchronousAndNonThrowing() {
        // The hooks are plain non-async, non-throwing functions: callable from the BLE main-actor path
        // without `await`/`try`, so a capture failure cannot change ack control flow.
        let now = date(2026, 10, 13)
        let cap = makeCapture(clock: TestClock(now))
        cap.submitStreamFrame([], family: .whoop5)
        cap.submitStreamFrame([0xAA], family: .whoop4)
        cap.submitRejected([], family: .whoop5)
    }
}

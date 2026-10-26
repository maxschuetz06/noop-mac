import XCTest
@testable import Strand

/// Pins the strap markers: persistence across relaunch, the 500-entry cap, the confirming buzz, the
/// strap-log line and the typed bedtime sleep-mark row.
@MainActor
final class MomentsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var buzzes = 0
    private var logLines: [String] = []
    private var recorded: [SleepMark] = []

    override func setUp() {
        super.setUp()
        suiteName = "noop-moments-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> MomentsStore {
        MomentsStore(defaults: defaults,
                     buzz: { [unowned self] in self.buzzes += 1 },
                     log: { [unowned self] in self.logLines.append($0) },
                     recordSleepMark: { [unowned self] in self.recorded.append($0) })
    }

    func testMomentPersistsBuzzesAndLogs() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        makeStore().markMoment(at: date)

        XCTAssertEqual(makeStore().moments, [date], "a relaunch reloads persisted moments")
        XCTAssertEqual(buzzes, 1)
        XCTAssertEqual(logLines, ["Moment marked"])
    }

    func testMomentsKeepOnlyTheNewest500() {
        let store = makeStore()
        for i in 0..<502 { store.markMoment(at: Date(timeIntervalSince1970: TimeInterval(i))) }

        XCTAssertEqual(store.moments.count, 500)
        XCTAssertEqual(store.moments.first, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(makeStore().moments.count, 500)
    }

    func testSleepMarkLogsTimeAndRecordsBedtimeRow() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        makeStore().markSleep(at: date)

        XCTAssertEqual(makeStore().sleepMarks, [date])
        XCTAssertEqual(buzzes, 1)
        let hhmm = DateFormatter()
        hhmm.locale = Locale(identifier: "en_US_POSIX")
        hhmm.dateFormat = "HH:mm"
        XCTAssertEqual(logLines, ["Sleep mark @ \(hhmm.string(from: date))"])
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(try XCTUnwrap(recorded.first).type, .bedtime)
    }
}

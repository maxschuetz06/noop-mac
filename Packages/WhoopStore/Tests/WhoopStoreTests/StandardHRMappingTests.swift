import XCTest
import WhoopProtocol
@testable import WhoopStore

final class StandardHRMappingTests: XCTestCase {
    func testStandardHRMapsToStreams() throws {
        let s = StandardHRMapping.samples(fromHR: 72, rr: [820, 815], at: 1_750_000_000)
        XCTAssertEqual(s.hr.map { $0.bpm }, [72])
        XCTAssertEqual(s.hr.map { $0.ts }, [1_750_000_000])
        XCTAssertEqual(s.rr.map { $0.rrMs }, [820, 815])
        XCTAssertEqual(s.rr.map { $0.ts }, [1_750_000_000, 1_750_000_000])
    }

    func testStandardHRWithNoRRLeavesRREmpty() throws {
        let s = StandardHRMapping.samples(fromHR: 60, rr: [], at: 1_000)
        XCTAssertEqual(s.hr.map { $0.bpm }, [60])
        XCTAssertTrue(s.rr.isEmpty)
    }

    func testOnlyHRandRRStreamsArePopulated() throws {
        // A chest strap reports nothing else — every other stream must stay empty.
        let s = StandardHRMapping.samples(fromHR: 88, rr: [700], at: 42)
        XCTAssertTrue(s.spo2.isEmpty)
        XCTAssertTrue(s.skinTemp.isEmpty)
        XCTAssertTrue(s.resp.isEmpty)
        XCTAssertTrue(s.gravity.isEmpty)
        XCTAssertTrue(s.steps.isEmpty)
        XCTAssertTrue(s.ppgHr.isEmpty)
        XCTAssertTrue(s.events.isEmpty)
        XCTAssertTrue(s.battery.isEmpty)
    }
}

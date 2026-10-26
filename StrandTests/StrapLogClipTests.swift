import XCTest
@testable import Strand

@MainActor
final class StrapLogClipTests: XCTestCase {
    func testShortLineUnchanged() {
        XCTAssertEqual(LiveState.clipped("short line"), "short line")
    }

    func testLongLineClippedWithMarker() {
        let long = String(repeating: "a", count: 5_000)
        let out = LiveState.clipped(long)
        XCTAssertTrue(out.hasPrefix(String(repeating: "a", count: LiveState.maxLineLength)))
        XCTAssertTrue(out.hasSuffix("(+\(5_000 - LiveState.maxLineLength) chars)"))
        XCTAssertLessThan(out.count, LiveState.maxLineLength + 40)
    }

    func testAppendClipsLongLines() {
        let state = LiveState()
        state.append(log: String(repeating: "f", count: 4_280))
        XCTAssertLessThan(state.log.last?.count ?? 0, LiveState.maxLineLength + 40)
    }
}

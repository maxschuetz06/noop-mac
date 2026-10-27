import WhoopProtocol
import XCTest
@testable import Strand

/// The reject sink decides whether a chunk with undecodable records may be acked. The ack frees the
/// strap's only copy, so a sink whose BLE manager is gone must refuse (nothing was archived).
@MainActor
final class RejectedFrameSinkTests: XCTestCase {
    private final class Owner {}

    func testSinkRefusesTheAckOnceItsOwnerIsGone() {
        var owner: Owner? = Owner()
        var archiveCalls = 0
        let sink = BLEManager.rejectedFrameSink(owner: owner!) { _, _, _, _ in
            archiveCalls += 1
            return true
        }
        owner = nil

        XCTAssertFalse(sink([[0x01]], 42, .whoop4), "no archive was written, so the chunk must not be acked")
        XCTAssertEqual(archiveCalls, 0)
    }

    func testSinkReportsTheArchiveResultWhileItsOwnerIsAlive() {
        let owner = Owner()
        var archived: [(frames: [[UInt8]], trim: UInt32)] = []
        var result = true
        let sink = BLEManager.rejectedFrameSink(owner: owner) { _, frames, trim, _ in
            archived.append((frames, trim))
            return result
        }

        XCTAssertTrue(sink([[0x01, 0x02]], 7, .whoop5))
        result = false
        XCTAssertFalse(sink([[0x03]], 8, .whoop4))
        XCTAssertEqual(archived.map(\.trim), [7, 8])
        XCTAssertEqual(archived.map(\.frames), [[[0x01, 0x02]], [[0x03]]])
    }
}

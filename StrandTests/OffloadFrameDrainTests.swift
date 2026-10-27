import XCTest
@testable import Strand

/// The offload drain is the one serial path from the BLE delegate to `Backfiller.ingest`: frames must
/// reach it in arrival order and never two at a time, even when more frames arrive while an ingest is
/// suspended (two overlapping `finishChunk`s would interleave chunk state and the ack order).
@MainActor
final class OffloadFrameDrainTests: XCTestCase {
    private final class Recorder {
        var ingested: [UInt8] = []
        var inFlight = 0
        var maxInFlight = 0
    }

    private func drain(_ recorder: Recorder, stopAfter stop: UInt8? = nil) -> OffloadFrameDrain {
        OffloadFrameDrain { frame in
            recorder.inFlight += 1
            recorder.maxInFlight = max(recorder.maxInFlight, recorder.inFlight)
            await Task.yield()
            await Task.yield()
            recorder.ingested.append(frame[0])
            recorder.inFlight -= 1
            return frame[0] != stop
        }
    }

    private func waitUntilIdle(_ drain: OffloadFrameDrain) async {
        for _ in 0..<10_000 where drain.isDraining {
            await Task.yield()
        }
        XCTAssertFalse(drain.isDraining, "the drain loop should finish")
    }

    func testFramesArrivingMidDrainAreIngestedInOrderAndNeverConcurrently() async {
        let recorder = Recorder()
        let drain = drain(recorder)
        for i in 0..<5 { drain.enqueue([UInt8(i)]) }
        await Task.yield()
        for i in 5..<40 {
            drain.enqueue([UInt8(i)])
            if i.isMultiple(of: 3) { await Task.yield() }
        }
        await waitUntilIdle(drain)

        XCTAssertEqual(recorder.ingested, (0..<40).map(UInt8.init))
        XCTAssertEqual(recorder.maxInFlight, 1, "ingest calls must never overlap")
    }

    func testAnEndedSessionDropsTheFramesStillQueued() async {
        let recorder = Recorder()
        let drain = drain(recorder, stopAfter: 3)
        for i in 0..<20 { drain.enqueue([UInt8(i)]) }
        await waitUntilIdle(drain)

        XCTAssertEqual(recorder.ingested, [0, 1, 2, 3])
    }

    func testDiscardPendingDropsFramesNotYetIngested() async {
        let recorder = Recorder()
        let drain = drain(recorder)
        for i in 0..<30 { drain.enqueue([UInt8(i)]) }
        drain.discardPending()
        await waitUntilIdle(drain)

        XCTAssertEqual(recorder.ingested, [], "nothing was ingested before the session ended")
        drain.enqueue([99])
        await waitUntilIdle(drain)
        XCTAssertEqual(recorder.ingested, [99], "a later session drains again")
    }
}

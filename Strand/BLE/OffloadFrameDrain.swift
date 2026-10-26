import Foundation

/// Feeds historical-offload frames to the Backfiller one at a time, in arrival order. Frames are
/// appended synchronously (delegate order) and consumed by a single drain loop in small slices that
/// yield between slices, so START / data / END chunk assembly is never reordered or run concurrently
/// while the UI still gets time to paint. An `enqueue` while the loop runs only appends.
@MainActor
final class OffloadFrameDrain {
    static let batchSize = 12

    private var queue: [[UInt8]] = []
    private(set) var isDraining = false
    /// Ingests one frame; returns false once the session ended, which drops the rest of the queue.
    private let ingest: @MainActor ([UInt8]) async -> Bool

    init(ingest: @escaping @MainActor ([UInt8]) async -> Bool) {
        self.ingest = ingest
    }

    func enqueue(_ frame: [UInt8]) {
        queue.append(frame)
        guard !isDraining else { return }
        isDraining = true
        Task { @MainActor in await drain() }
    }

    /// The session ended: frames not yet ingested are dropped.
    func discardPending() {
        queue.removeAll()
    }

    /// The link dropped: drop pending frames and stop tracking the running loop.
    func reset() {
        queue.removeAll()
        isDraining = false
    }

    private func drain() async {
        while !queue.isEmpty {
            let count = min(Self.batchSize, queue.count)
            let batch = Array(queue.prefix(count))
            queue.removeFirst(count)
            for frame in batch {
                guard await ingest(frame) else {
                    queue.removeAll(keepingCapacity: true)
                    break
                }
            }
            if !queue.isEmpty {
                await Task.yield()
            }
        }
        isDraining = false
    }
}

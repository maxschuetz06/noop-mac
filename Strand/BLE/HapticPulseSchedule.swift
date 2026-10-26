import Foundation

/// Host-driven haptic pulses queued for later, cancellable as a group so a stop request also drops the
/// pulses that have not been sent yet.
final class HapticPulseSchedule {
    private let queue: DispatchQueue
    private var pending: [DispatchWorkItem] = []

    init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    func schedule(afterMs: Int, _ fire: @escaping () -> Void) {
        let item = DispatchWorkItem(block: fire)
        pending.append(item)
        queue.asyncAfter(deadline: .now() + .milliseconds(afterMs), execute: item)
    }

    func cancelAll() {
        pending.forEach { $0.cancel() }
        pending.removeAll()
    }
}

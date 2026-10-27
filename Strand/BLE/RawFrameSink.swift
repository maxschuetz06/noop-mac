import WhoopProtocol

/// Receives historical frames for the opt-in raw PPG research capture. Fire-and-forget: a sink must
/// return immediately and can neither block nor fail a sync, because it sits beside the
/// persistence/ack path, not on it.
protocol RawFrameSink: Sendable {
    /// Every historical frame as it arrives, before the Backfiller sees it.
    func submitStreamFrame(_ frame: [UInt8], family: DeviceFamily)
    /// Frames the decoder could not map, at the moment they are archived.
    func submitRejected(_ frames: [[UInt8]], family: DeviceFamily)
}


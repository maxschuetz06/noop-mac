extension BLEManager {
    /// The app's BLE engine: offload frames also reach the opt-in raw PPG capture, which is a no-op
    /// unless the user enabled it.
    convenience init(state: LiveState, deviceId: String = "my-whoop") {
        self.init(state: state, deviceId: deviceId, rawFrameSink: RawPPGCapture.shared)
    }
}

extension RawPPGCapture: RawFrameSink {}

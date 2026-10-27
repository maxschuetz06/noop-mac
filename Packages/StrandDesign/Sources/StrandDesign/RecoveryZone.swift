/// WHOOP's recovery bands on the 0–100 Charge scale: high ≥ 67, medium 34–66, low < 34.
public enum RecoveryZone: Equatable, Sendable {
    case high, medium, low

    public init(score: Double) {
        if score >= 67 {
            self = .high
        } else if score >= 34 {
            self = .medium
        } else {
            self = .low
        }
    }
}

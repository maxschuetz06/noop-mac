import SwiftUI
import StrandDesign

/// The one-word state under a Home / Sleep metric card.
enum HomeStateLabel {
    static func charge(_ v: Double) -> LocalizedStringKey {
        switch RecoveryZone(score: v) {
        case .high: return "Optimal"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    static func effort(_ v: Double) -> LocalizedStringKey { v >= 66 ? "High" : (v >= 33 ? "Medium" : "Low") }

    /// "Normal" within ±8 % of the baseline, otherwise above/below phrased by whether higher is better.
    static func relative(_ v: Double?, base: Double?, higherIsBetter: Bool) -> LocalizedStringKey {
        guard let v, let base, base > 0 else { return v == nil ? "No value yet" : "Normal" }
        let r = (v - base) / base
        if abs(r) <= 0.08 { return higherIsBetter ? "Optimal" : "Normal" }
        let above = r > 0
        return above == higherIsBetter ? "Above average" : (higherIsBetter ? "Below average" : "Elevated")
    }
}

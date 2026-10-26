import Foundation

/// Pure display helpers for the widget rings. Foundation-only so the logic can be compiled and
/// checked on its own (no SwiftUI / StrandDesign dependency).
enum WidgetRingFormat {
    /// WHOOP's strain scale tops out at 21.
    static let strainScaleMax: Double = 21

    enum Zone: Equatable {
        case green, yellow, red, unknown
    }

    /// Ring fill fraction for a 0–100 value, clamped to 0…1. Missing → 0 (empty track).
    static func fill(_ value: Int?) -> Double {
        guard let value else { return 0 }
        return min(max(Double(value) / 100, 0), 1)
    }

    /// Strain on WHOOP's 0–21 axis from NOOP's 0–100 effort axis (clamped).
    static func strainValue(effort: Int?) -> Double? {
        guard let effort else { return nil }
        return min(max(Double(effort), 0), 100) * strainScaleMax / 100
    }

    /// "12,4" (de) / "12.4" (en); missing → "–".
    static func strainText(effort: Int?, locale: Locale = .current) -> String {
        guard let v = strainValue(effort: effort) else { return "–" }
        return String(format: "%.1f", locale: locale, v)
    }

    /// "67%"; missing → "–". Values are clamped to 0…100 for display.
    static func percentText(_ value: Int?) -> String {
        guard let value else { return "–" }
        return "\(min(max(value, 0), 100))%"
    }

    /// WHOOP recovery zones: green ≥ 67, yellow 34–66, red < 34.
    static func recoveryZone(_ recovery: Int?) -> Zone {
        guard let recovery else { return .unknown }
        if recovery >= 67 { return .green }
        if recovery >= 34 { return .yellow }
        return .red
    }
}

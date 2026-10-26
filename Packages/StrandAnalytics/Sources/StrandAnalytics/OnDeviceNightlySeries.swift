import Foundation
import WhoopStore

/// Nightly values the on-device pipeline already computes but that have no `DailyMetric` column.
/// They are persisted as generic `(day, key, value)` metric-series rows under the computed
/// ("-noop") source, so no schema migration is needed.
public enum OnDeviceNightlySeries {

    /// Metric-series key of the ABSOLUTE nightly skin temperature (°C). The analytics pass stores
    /// only a ±deviation vs the personal baseline on `DailyMetric.skinTempDevC`; this key keeps the
    /// wear-gated nightly mean itself (WHOOP 5.0 `skin_temp_raw / 100`).
    public static let skinTempAbsKey = "skin_temp_abs"

    /// The `skin_temp_abs` point for one night, or nil when the night has no trustworthy mean
    /// (`AnalyticsEngine.wornNightlySkinTempC` returned nil), or it is non-finite / outside the
    /// plausible worn range — a fabricated value must never be persisted. Value is rounded to 0.01 °C
    /// (the strap's centidegree resolution).
    public static func skinTempAbsPoint(day: String, nightlySkinTempC: Double?) -> MetricPoint? {
        guard let c = nightlySkinTempC, c.isFinite,
              c >= AnalyticsEngine.skinTempMinC, c <= AnalyticsEngine.skinTempMaxC else { return nil }
        return MetricPoint(day: day, key: skinTempAbsKey, value: (c * 100).rounded() / 100)
    }
}

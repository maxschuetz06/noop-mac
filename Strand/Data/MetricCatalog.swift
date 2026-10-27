import WhoopStore
import Foundation
import StrandAnalytics

/// One interrogable metric: how to fetch it (key+source), how to label/format it, and whether
/// higher is better (drives delta tinting). The Metric Explorer + Compare are built from this list.
struct MetricDescriptor: Identifiable, Hashable {
    let key: String
    let title: String
    let category: String
    let unit: String
    let source: String       // "my-whoop" or "apple-health"
    let icon: String
    let decimals: Int
    let higherIsBetter: Bool?
    /// A short, plain-English one-liner for the metric (tile subtitle / catalog blurb). Optional —
    /// only the three headline scores (Charge / Effort / Rest) carry one today; everything else is nil.
    var description: String? = nil
    var id: String { source + ":" + key }

    /// Human label for the metric's source partition (catalog row caption / detail subtitle).
    var sourceLabel: String {
        switch source {
        case SourceID.appleHealth: return "Apple Health"
        case "xiaomi-band":  return "Mi Band"
        case "nutrition-csv": return "Nutrition"
        case "noop-mood":    return "Mood"
        default:             return "Whoop"   // "my-whoop" + on-device computed sources
        }
    }

    /// True for the Effort metric (#268). Its stored value is 0–100; the effort-scale toggle converts
    /// the DISPLAYED number + unit onto WHOOP's 0–21 axis. Mirrors the Android `MetricSpec.whoopEffort`
    /// gate (`key == "strain"`) — the only value-converting metric in the catalog.
    private var isEffort: Bool { key == "strain" }

    func format(_ v: Double) -> String {
        let n = decimals == 0 ? String(Int(v.rounded())) : String(format: "%.\(decimals)f", v)
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    /// Effort-aware plain format (#268): the Effort metric's stored 0–100 value is shown on the selected
    /// scale (its number + "/100"→"/21" unit); every other metric is scale-agnostic and falls through to
    /// the unit-less `format` above. Callers that don't carry an effort scale get `.hundred` (no change).
    func format(_ v: Double, effortScale: EffortScale) -> String {
        guard isEffort else { return format(v) }
        let n = UnitFormatter.effortDisplay(v, scale: effortScale)
        return "\(n) \(displayUnit(effortScale: effortScale))"
    }

    /// Unit-aware format: for the three SI-stored metrics that have a non-metric counterpart
    /// (weight/lean_mass in kg, skin_temp in °C) convert + relabel via `UnitFormatter`. The Effort
    /// metric follows its own 0–100↔0–21 scale (#268). Every other metric (%, bpm, ms, min, …) is
    /// scale-agnostic and falls through to the plain `format` above, so each toggle only ever touches
    /// the values that actually have a converted form.
    func format(_ v: Double, system: UnitSystem, temperature: TemperatureUnit,
                effortScale: EffortScale = .hundred) -> String {
        switch unit {
        case "kg":  return UnitFormatter.massFromKilograms(v, system: system)
        case "°C":  return UnitFormatter.temperatureFromCelsius(v, unit: temperature, decimals: decimals)
        default:    return isEffort ? format(v, effortScale: effortScale) : format(v)
        }
    }

    /// Like `format`, but for a DIFFERENCE between two values (e.g. the Δ StatTile). A temperature
    /// delta scales by 9/5 with NO +32 offset; mass/distance deltas scale by their plain factor; an
    /// Effort delta rescales 0–100→0–21 on the WHOOP scale (#268, no offset — it's a magnitude). The
    /// caller supplies the magnitude (sign is rendered separately).
    func formatDelta(_ v: Double, system: UnitSystem, temperature: TemperatureUnit,
                     effortScale: EffortScale = .hundred) -> String {
        switch unit {
        case "kg":  return UnitFormatter.massFromKilograms(v, system: system)
        case "°C":  return UnitFormatter.temperatureDeltaFromCelsius(v, unit: temperature, decimals: decimals)
        default:
            guard isEffort else { return format(v) }
            // A delta on the 0–100 axis rescales by the same ×21/100 factor (the offset-free `effortValue`).
            let n = UnitFormatter.effortDisplay(v, scale: effortScale)
            return "\(n) \(displayUnit(effortScale: effortScale))"
        }
    }

    /// The unit LABEL as displayed (e.g. the trailing chip in the Metric Explorer list), mapped to the
    /// active system. Only the convertible units change; everything else returns its stored label.
    func displayUnit(system: UnitSystem, temperature: TemperatureUnit,
                     effortScale: EffortScale = .hundred) -> String {
        switch unit {
        case "kg":  return UnitFormatter.massUnit(system)
        case "°C":  return UnitFormatter.temperatureUnit(temperature)
        default:    return isEffort ? displayUnit(effortScale: effortScale) : unit
        }
    }

    /// The Effort metric's unit LABEL on the selected scale — "/100" or "/21" (#268). Non-Effort metrics
    /// return their stored label unchanged. Mirrors the Android `MetricSpec.displayUnit` swap.
    func displayUnit(effortScale: EffortScale) -> String {
        guard isEffort else { return unit }
        return "/" + UnitFormatter.effortScaleMax(effortScale)
    }
}

/// Canonical catalog — mirrors the WHOOP "Trend View" plus Apple Health body metrics.
/// Keys match exactly what the importers write into metricSeries.
enum MetricCatalog {
    static let categories = ["Heart", "Charge", "Rest", "Effort", "Health", "Nutrition", "Mind"]

    static let all: [MetricDescriptor] = [
        // ── Heart
        d("avg_hr", "Average Heart Rate", "Heart", "bpm", SourceID.whoop, "heart", 0, nil),
        d("max_hr", "Max Heart Rate", "Heart", "bpm", SourceID.whoop, "bolt.heart", 0, nil),
        d("energy_kcal", "Calories", "Heart", "kcal", SourceID.whoop, "flame", 0, nil),
        d("vo2max", "VO₂ Max", "Heart", "", SourceID.appleHealth, "lungs.fill", 1, true),
        d("fitness_age", "Fitness Age", "Heart", "yrs", SourceID.whoop, "figure.run", 0, false),
        d("vo2max_est", "VO₂ Max (estimated)", "Heart", "", SourceID.whoop, "lungs", 1, true),
        d("vitality", "Vitality", "Heart", "", SourceID.whoop, "sparkles", 0, true),
        d("body_age", "Body Age", "Heart", "yrs", SourceID.whoop, "figure.stand", 0, false),

        // ── Charge (was Recovery)
        d("recovery", "Charge", "Charge", "%", SourceID.whoop, "heart.circle", 0, true,
          "How recovered you are — led by HRV versus your personal baseline."),
        d("hrv", "Heart Rate Variability", "Charge", "ms", SourceID.whoop, "waveform.path.ecg", 0, true),
        d("rhr", "Resting Heart Rate", "Charge", "bpm", SourceID.whoop, "heart", 0, false),
        d("resp_rate", "Respiratory Rate", "Charge", "rpm", SourceID.whoop, "lungs", 1, nil),
        d("spo2", "Blood Oxygen", "Charge", "%", SourceID.whoop, "drop", 0, true),
        d("skin_temp", "Skin Temperature", "Charge", "°C", SourceID.whoop, "thermometer", 1, nil),
        // Absolute nightly mean skin temperature from the on-device pipeline (WHOOP 5.0 skin_temp_raw/100,
        // wear-gated, in-bed). Stored under the computed "-noop" source — the daily row only carries the
        // ±deviation. A wrist sensor reads cooler than core temperature, so compare it to your own
        // baseline, not to a clinical value.
        d(OnDeviceNightlySeries.skinTempAbsKey, "Skin Temperature (nightly)", "Charge", "°C", SourceID.whoop,
          "thermometer.medium", 1, nil,
          "Your nightly average skin temperature from the strap — compare it to your own baseline, not to a clinical value."),

        // ── Rest (was Sleep)
        d("sleep_performance", "Rest", "Rest", "%", SourceID.whoop, "moon.stars", 0, true,
          "How restorative your sleep was — duration, efficiency, deep+REM, timing."),
        d("in_bed_min", "Time in Bed", "Rest", "min", SourceID.whoop, "bed.double", 0, nil),
        d("sleep_total_min", "Asleep Time", "Rest", "min", SourceID.whoop, "moon.zzz", 0, true),
        d("hours_vs_needed_pct", "Hours vs Needed", "Rest", "%", SourceID.whoop, "gauge.medium", 0, true),
        d("sleep_consistency", "Sleep Consistency", "Rest", "%", SourceID.whoop, "calendar", 0, true),
        d("restorative_pct", "Restorative Sleep", "Rest", "%", SourceID.whoop, "sparkles", 0, true),
        d("restorative_min", "Restorative Sleep", "Rest", "min", SourceID.whoop, "sparkles", 0, true),
        d("sleep_efficiency", "Sleep Efficiency", "Rest", "%", SourceID.whoop, "bed.double.fill", 0, true),
        d("sleep_deep_min", "Deep (SWS) Sleep", "Rest", "min", SourceID.whoop, "moon.fill", 0, true),
        d("sleep_rem_min", "REM Sleep", "Rest", "min", SourceID.whoop, "moon.haze", 0, true),
        d("sleep_light_min", "Light Sleep", "Rest", "min", SourceID.whoop, "moon", 0, nil),
        d("awake_min", "Awake Time", "Rest", "min", SourceID.whoop, "eye", 0, false),
        d("sleep_need_min", "Sleep Need", "Rest", "min", SourceID.whoop, "gauge", 0, nil),
        d("sleep_debt_min", "Sleep Debt", "Rest", "min", SourceID.whoop, "exclamationmark.circle", 0, false),

        // ── Effort (was Strain)
        d("strain", "Effort", "Effort", "/100", SourceID.whoop, "flame", 1, nil,
          "Cardiovascular load for the day, on a 0–100 scale (was 0–21)."),
        d("steps", "Steps", "Effort", "", SourceID.appleHealth, "figure.walk", 0, true),
        // On-device steps ESTIMATE for a WHOOP 4.0 (no real step count over BLE): the strap's daily
        // motion volume scaled by a personal calibration. Stored under the computed "-noop" source, so
        // it reads through the same exploreSeries fallback fitness_age/vitality use. Distinct from the
        // real "steps" above — labelled "(estimated)" so it's never mistaken for a measured count.
        d("steps_est", "Steps (estimated)", "Effort", "steps", SourceID.whoop, "figure.walk.motion", 0, true,
          "Estimated from your WHOOP's motion, calibrated to your phone — not a measured step count."),
        d("hr_zone1_min", "HR Zone 1", "Effort", "min", SourceID.whoop, "heart", 0, nil),
        d("hr_zone2_min", "HR Zone 2", "Effort", "min", SourceID.whoop, "heart", 0, nil),
        d("hr_zone3_min", "HR Zone 3", "Effort", "min", SourceID.whoop, "heart", 0, nil),
        d("hr_zone4_min", "HR Zone 4", "Effort", "min", SourceID.whoop, "heart", 0, nil),
        d("hr_zone5_min", "HR Zone 5", "Effort", "min", SourceID.whoop, "heart", 0, nil),
        d("hr_zones13_min", "HR Zones 1–3", "Effort", "min", SourceID.whoop, "heart", 0, nil),
        d("hr_zones45_min", "HR Zones 4–5", "Effort", "min", SourceID.whoop, "heart.fill", 0, nil),
        d("hr_zones_all_min", "HR Zones (All)", "Effort", "min", SourceID.whoop, "heart.text.square", 0, nil),
        d("strength_min", "Strength Activity Time", "Effort", "min", SourceID.whoop, "dumbbell", 0, nil),
        d("active_kcal", "Active Energy", "Effort", "kcal", SourceID.appleHealth, "flame.fill", 0, nil),

        // ── Health / Body
        d("weight", "Weight", "Health", "kg", SourceID.appleHealth, "scalemass", 1, nil),
        d("body_fat", "Body Fat", "Health", "%", SourceID.appleHealth, "percent", 1, false),
        d("lean_mass", "Lean Body Mass", "Health", "kg", SourceID.appleHealth, "figure.arms.open", 1, true),
        d("bmi", "BMI", "Health", "", SourceID.appleHealth, "figure", 1, nil),
        d("stress", "Day Stress", "Health", "/3", SourceID.whoop, "gauge.with.dots.needle.50percent", 1, false),

        // ── Nutrition (imported from a food-tracker CSV: calories-in alongside calories-out)
        d("calories_in", "Calories In", "Nutrition", "kcal", "nutrition-csv", "fork.knife", 0, nil),
        d("protein_g", "Protein", "Nutrition", "g", "nutrition-csv", "p.circle", 0, nil),
        d("carbs_g", "Carbs", "Nutrition", "g", "nutrition-csv", "c.circle", 0, nil),
        d("fat_g", "Fat", "Nutrition", "g", "nutrition-csv", "f.circle", 0, nil),

        // ── Mind (daily mood check-in, 1–5; non-clinical self-tracking)
        d("mood", "Mood", "Mind", "/5", "noop-mood", "face.smiling", 0, true),

        // ── Mi Band (imported from Mi Fitness). Same metricSeries mechanism as Apple Health /
        //    Nutrition, so these light up Explore, Compare and the correlation scan. Distinct
        //    `source` keeps them comparable against the WHOOP/Apple versions rather than colliding.
        d("avg_hr", "Average Heart Rate", "Heart", "bpm", "xiaomi-band", "heart", 0, nil),
        d("max_hr", "Max Heart Rate", "Heart", "bpm", "xiaomi-band", "bolt.heart", 0, nil),
        d("energy_kcal", "Calories", "Heart", "kcal", "xiaomi-band", "flame", 0, nil),
        d("vitality", "Vitality", "Heart", "", "xiaomi-band", "sparkles", 0, true),
        d("rhr", "Resting Heart Rate", "Charge", "bpm", "xiaomi-band", "heart", 0, false),
        d("spo2", "Blood Oxygen", "Charge", "%", "xiaomi-band", "drop", 0, true),
        d("sleep_total_min", "Asleep Time", "Rest", "min", "xiaomi-band", "moon.zzz", 0, true),
        d("sleep_deep_min", "Deep (SWS) Sleep", "Rest", "min", "xiaomi-band", "moon.fill", 0, true),
        d("sleep_rem_min", "REM Sleep", "Rest", "min", "xiaomi-band", "moon.haze", 0, true),
        d("sleep_light_min", "Light Sleep", "Rest", "min", "xiaomi-band", "moon", 0, nil),
        d("sleep_score", "Sleep Score", "Rest", "", "xiaomi-band", "moon.stars", 0, true),
        d("steps", "Steps", "Effort", "", "xiaomi-band", "figure.walk", 0, true),
        d("intensity_min", "Intensity Minutes", "Effort", "min", "xiaomi-band", "figure.run", 0, true),
        d("stress", "Stress", "Health", "/100", "xiaomi-band", "gauge.with.dots.needle.50percent", 0, false),
    ]

    static func inCategory(_ c: String) -> [MetricDescriptor] { all.filter { $0.category == c } }

    private static func d(_ key: String, _ title: String, _ category: String, _ unit: String,
                          _ source: String, _ icon: String, _ decimals: Int,
                          _ higherIsBetter: Bool?, _ description: String? = nil) -> MetricDescriptor {
        MetricDescriptor(key: key, title: title, category: category, unit: unit,
                         source: source, icon: icon, decimals: decimals, higherIsBetter: higherIsBetter,
                         description: description)
    }
}

import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

extension TodayView {
    // MARK: - Derived text

    /// Greeting word used as the section's trailing label (no lone text block).
    var greetingWord: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case ..<12:   return "Good morning"
        case 12..<17: return "Good afternoon"
        default:      return "Good evening"
        }
    }

    var dateLine: String {
        let f = Self.dateLineFmt
        // The selected day's date when navigated; today's banked-row date (or today) at offset 0.
        if selectedDayOffset == 0, let day = repo.today?.day, let date = Self.dayParser.date(from: day) {
            return f.string(from: date)
        }
        return f.string(from: selectedLogicalDay)
    }

    /// Hero title that names the selected day — "Today's"/"Yesterday's"/"Day's" Synthesis.
    var synthesisTitle: LocalizedStringKey {
        switch selectedDayOffset {
        case 0:  return "Today’s Synthesis"
        case 1:  return "Yesterday’s Synthesis"
        default: return "Synthesis"
        }
    }

    /// Section overline naming the selected day — "Today"/"Yesterday"/"EEE d MMM".
    var selectedDayOverline: String {
        switch selectedDayOffset {
        case 0:  return "Today"
        case 1:  return "Yesterday"
        default:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEE d MMM"
            return f.string(from: selectedLogicalDay)
        }
    }

    /// A short recovery state word for the synthesis hero.
    func synthesisWord(_ score: Double?) -> String {
        guard let s = score else { return "No Data" }
        switch s {
        case ..<25:  return "Depleted"
        case ..<50:  return "Low"
        case ..<70:  return "Steady"
        case ..<88:  return "Primed"
        default:     return "Peak"
        }
    }

    /// Plain-English synthesis of recovery + sleep.
    func synthesisDetail(_ d: DailyMetric?) -> String {
        guard let d, let rec = d.recovery else {
            return "No metrics yet. Import your Whoop export or wear the strap to begin."
        }
        let recPart: String
        switch rec {
        case ..<50:  recPart = "Charge is low"
        case ..<70:  recPart = "Charge is steady"
        default:     recPart = "Charge is strong"
        }
        let sleepPart: String
        if let mins = d.totalSleepMin {
            let h = mins / 60.0
            sleepPart = h >= 7 ? " and sleep was consistent" : " but sleep ran short"
        } else {
            sleepPart = ""
        }
        return recPart + sleepPart + "."
    }

    func ringSupporting(_ d: DailyMetric?) -> String {
        let hrv = d?.avgHrv.map { "\(Int($0.rounded())) ms" } ?? "— ms"
        let rhr = d?.restingHr.map { "\($0)" } ?? "—"
        return "HRV \(hrv) · RHR \(rhr)"
    }

    func sleepValue(_ d: DailyMetric?) -> String {
        guard let m = d?.totalSleepMin else { return "—" }
        let h = Int(m) / 60, mm = Int(m) % 60
        return "\(h)h \(mm)m"
    }

    /// The Rest tile's caption — hours-in-bed for the day, the figure that used to be the tile's
    /// VALUE before #248 moved the Rest score there. Falls back to the efficiency read-out when no
    /// duration is banked, and to nil so the tile shows no caption line at all when neither exists.
    func restCaption(_ d: DailyMetric?) -> String? {
        if d?.totalSleepMin != nil { return sleepValue(d) }
        return d?.efficiency.map { String(format: "%.0f%% eff", $0) }
    }

    /// Short "it's coming, not broken" caption for an unscored Effort/Rest tile on TODAY only. The
    /// call sites only reach here when the score is genuinely absent; this adds the today-only gate so
    /// a navigated PAST day with no score honestly stays a bare "—" (missing data, not mid-calibration).
    /// Mirrors the recoveryCalibration today-only rule the Charge tile uses for its "N of 4" treatment.
    func buildingHint(_ metric: KeyMetric) -> String? {
        Self.buildingHintCopy(metric, isToday: selectedDayOffset == 0)
    }

    /// The Component-2 "needs the strap" tile caption — the honest no-data state word a Charge/Rest tile
    /// shows instead of a bare blank when there's no value, no calibration count and nothing to carry.
    /// Matches `MetricTileState.needsStrap.title` verbatim so the tile and the explained note say the same words.
    static let needsStrapCaption = "Needs the strap"

    /// H10 — the honest empty-state caption for a recovery-vital tile (HRV / Resting HR / SpO₂ / Respiratory)
    /// when TODAY has no value yet and there's nothing to carry over. Those vitals are measured overnight, so
    /// "After tonight's sleep" tells the user WHEN the tile fills rather than leaving a bare "—" beside a lone
    /// unit that read as broken. Returns nil off-today (a past day keeps the plain unit — it's missing data the
    /// user can't act on now). Pure copy/gate so it can be unit-tested without a live view. Mirror in Kotlin.
    static func emptyVitalCaption(unit: String, isToday: Bool) -> String? {
        guard isToday else { return nil }
        return "After tonight's sleep"
    }

    /// Pure copy/gate behind `buildingHint` — extracted so it can be unit-tested without a live view.
    /// Rest fills in after a night's sleep; Effort fills in once cardio load is logged. Em-dash-free
    /// house style. Returns nil off-today and for any metric other than Effort/Rest (#527).
    static func buildingHintCopy(_ metric: KeyMetric, isToday: Bool) -> String? {
        guard isToday else { return nil }
        switch metric {
        case .rest:   return "Building, wear it tonight"
        case .effort: return "Building, moves as you do"
        default:      return nil
        }
    }

    /// Active calories (Apple) for the latest day, falling back to the sparkline tail.
    func caloriesValue(_ a: AppleDaily?) -> String {
        if let kcal = a?.activeKcal { return intString(kcal) }
        return latestString("active_kcal", decimals: 0)
    }

    /// The Calories tile: Apple Health active energy wins; when Apple has none, the selected day's imported
    /// WHOOP total energy (`energy_kcal`) fills in, captioned "WHOOP total" so it's never read as active-only.
    func caloriesTile(_ a: AppleDaily?) -> (value: String, caption: String, isWhoop: Bool) {
        let apple = caloriesValue(a)
        let whoop = importedDayValues["energy_kcal"]?[selectedDayKey]
        let r = Self.caloriesResolution(appleDisplay: apple, whoopKcal: whoop)
        return (r.value.map { intString($0) } ?? apple, r.caption, r.isWhoop)
    }

    /// Pure Calories precedence (unit-tested): a real Apple read-out ("—" means none) wins; else the imported
    /// WHOOP kcal; else the empty Apple state. `value` is the WHOOP kcal when `isWhoop`, nil otherwise.
    /// Captions are localized (`locale` only exists so tests can pin a language).
    static func caloriesResolution(appleDisplay: String, whoopKcal: Double?, locale: Locale = .current)
        -> (value: Double?, caption: String, isWhoop: Bool) {
        let active = String(localized: LocalizedStringResource("active", locale: locale))
        if appleDisplay != "—" { return (nil, active, false) }
        if let whoopKcal {
            return (whoopKcal, String(localized: LocalizedStringResource("WHOOP total", locale: locale)), true)
        }
        return (nil, active, false)
    }

    /// Skin temperature read-out for the mixed-semantics `skinTempDevC` field: an imported WHOOP value is
    /// ABSOLUTE °C ("33.8 °C"), an on-device value is a signed ±deviation ("+0.3 °C"). The split is
    /// `VitalBands.isAbsoluteSkinTemp`; °F follows the temperature preference (a deviation scales without
    /// the +32 offset).
    static func skinTempDisplay(_ value: Double, unit: TemperatureUnit) -> String {
        if VitalBands.isAbsoluteSkinTemp(value) {
            return UnitFormatter.temperatureFromCelsius(value, unit: unit)
        }
        // A deviation that rounds to zero at one decimal is neither "+" nor "-": avoids "-0.0 °C".
        let shown = unit == .fahrenheit ? value * 9.0 / 5.0 : value
        if (shown * 10).rounded() == 0 { return UnitFormatter.temperatureDeltaFromCelsius(0, unit: unit) }
        let body = UnitFormatter.temperatureDeltaFromCelsius(value, unit: unit)
        return body.hasPrefix("-") ? body : "+" + body
    }

    /// "Max 153 · Ø 69 bpm" for the day's imported max/average HR; nil when neither is present.
    /// Localized (`locale` only exists so tests can pin a language).
    static func heartRateCaption(max: Double?, avg: Double?, locale: Locale = .current) -> String? {
        switch (max, avg) {
        case let (m?, a?):
            let mi = Int(m.rounded()), ai = Int(a.rounded())
            return String(localized: LocalizedStringResource("Max \(mi) · Ø \(ai) bpm", locale: locale))
        case let (m?, nil):
            let mi = Int(m.rounded())
            return String(localized: LocalizedStringResource("Max \(mi) bpm", locale: locale))
        case let (nil, a?):
            let ai = Int(a.rounded())
            return String(localized: LocalizedStringResource("Ø \(ai) bpm", locale: locale))
        default: return nil
        }
    }

    func workoutDuration(_ w: WorkoutRow) -> String {
        let secs = w.durationS ?? Double(max(w.endTs - w.startTs, 0))
        let mins = Int((secs / 60).rounded())
        if mins >= 60 { return "\(mins / 60)h \(mins % 60)m" }
        return "\(mins)m"
    }

    /// "d MMM · HH:mm–HH:mm", start-only when the row has no real end (#157). The "· N bpm"
    /// segment was dropped: the StatTile caption is lineLimit(1) and date + range + bpm clips —
    /// avg HR remains on the Workouts screen.
    func workoutCaption(_ w: WorkoutRow) -> String {
        let f = Self.workoutDateFmt
        let start = Date(timeIntervalSince1970: TimeInterval(w.startTs))
        let date = f.string(from: start)
        guard w.endTs > w.startTs else { return "\(date) · \(Self.hrTimeFmt.string(from: start))" }
        let end = Date(timeIntervalSince1970: TimeInterval(w.endTs))
        return "\(date) · \(Self.hrTimeFmt.string(from: start))–\(Self.hrTimeFmt.string(from: end))"
    }

    /// Thousands-grouped integer string (steps / calories).
    func intString(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(Int(v.rounded()))"
    }
}

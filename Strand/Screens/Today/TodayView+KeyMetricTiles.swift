import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Key Metric tiles, one per KeyMetric case

extension TodayView {
    @ViewBuilder
    func chargeMetricTile(_ d: DailyMetric?) -> some View {
        // Order of precedence: today's own scored recovery → mid-calibration "N of 4" → the last
        // scored day carried over ("Last night · <date>", #543) so a post-rollover today that
        // isn't scored yet keeps a real Charge instead of a bare "No Data" while live HR ticks →
        // "—" only when there is genuinely nothing banked anywhere. The carry-over shows the PRIOR
        // value labelled as prior — it never fabricates a number for the new day.
        let carried = lastScoredCharge
        StatTile(
            label: "Charge",
            value: d?.recovery.map { "\(Int($0.rounded()))%" }
                ?? recoveryCalibration.map { "\($0)/\(Baselines.minNightsSeed)" }
                ?? carried.map { "\(Int($0.value.rounded()))%" } ?? "—",
            // Component 2: never a bare blank — when there's no number, no calibration count and
            // nothing to carry, the caption states the honest "Needs the strap" rather than nothing.
            caption: d?.recovery.map { StrandPalette.recoveryState($0).capitalized }
                ?? recoveryCalibration.map { _ in "Calibrating" }
                ?? carried.map { $0.caption }
                ?? Self.needsStrapCaption,
            accent: d?.recovery.map { StrandPalette.recoveryColor($0) }
                ?? carried.map { StrandPalette.recoveryColor($0.value) } ?? StrandPalette.textPrimary,
            sparkline: sparks["recovery"],
            sparkColor: StrandPalette.accent
        )
    }

    @ViewBuilder
    func effortMetricTile(_ d: DailyMetric?) -> some View {
        // Unscored TODAY → a short "building" hint instead of the "of N" axis caption, so a
        // fresh user reads "coming" not "broken" (#527); a scored day keeps "of N".
        StatTile(
            label: "Effort",
            value: d?.strain.map { UnitFormatter.effortDisplay($0, scale: effortScale) } ?? "—",
            // A scored day with imported WHOOP Max/Ø HR shows them (WHOOP's Strain screen does too);
            // otherwise the axis caption.
            caption: d?.strain != nil
                ? (Self.heartRateCaption(max: importedDayValues["max_hr"]?[selectedDayKey],
                                         avg: importedDayValues["avg_hr"]?[selectedDayKey])
                   ?? "of \(UnitFormatter.effortScaleMax(effortScale))")
                : (buildingHint(.effort) ?? "of \(UnitFormatter.effortScaleMax(effortScale))"),
            accent: d?.strain.map { StrandPalette.effortTint(fraction: Repository.effortFraction($0)) } ?? StrandPalette.textPrimary,
            sparkline: sparks["strain"],
            sparkColor: StrandPalette.strain066,
            // Inline ⓘ in the tile header (not a corner overlay) so it never sits over the value (#495).
            accessory: { scoreInfoButton(.effort) }
        )
    }

    @ViewBuilder
    func restMetricTile(_ d: DailyMetric?) -> some View {
        // Unscored TODAY → "building, wear it tonight" instead of a lone "—" caption (#527);
        // a scored day keeps its sleep-duration / efficiency caption.
        StatTile(
            label: "Rest",
            value: restScore.map { "\(Int($0.rounded()))%" } ?? "—",
            // Component 2: a scored day shows its duration/efficiency caption; an unscored TODAY shows
            // the "building" hint; a past day with no Rest falls to the honest "Needs the strap" rather
            // than a bare blank, so the tile always carries a state.
            caption: restScore != nil ? restCaption(d)
                : (buildingHint(.rest) ?? restCaption(d) ?? Self.needsStrapCaption),
            accent: restScore.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
            sparkline: sparks["sleep_total_min"],
            sparkColor: StrandPalette.metricPurple,
            // Inline ⓘ in the tile header (not a corner overlay) so it never sits over the value (#495).
            accessory: { scoreInfoButton(.rest) }
        )
    }

    @ViewBuilder
    func hrvMetricTile(_ d: DailyMetric?) -> some View {
        // Carry the last scored night's HRV at the rollover (#543) — today's wins, the carried value
        // is stamped "Last night · <date>", and a never-scored metric still shows "—".
        let hrv = carriedVital(unit: "ms", today: d?.avgHrv,
                               prior: { $0.avgHrv }, format: { "\(Int($0.rounded()))" })
        StatTile(
            label: "HRV",
            value: hrv.value,
            caption: hrv.caption,
            accent: hrv.value == "—" ? StrandPalette.textPrimary : StrandPalette.metricPurple,
            sparkline: sparks["hrv"],
            sparkColor: StrandPalette.metricPurple
        )
    }

    @ViewBuilder
    func restingHrMetricTile(_ d: DailyMetric?) -> some View {
        let rhr = carriedVital(unit: "bpm", today: d?.restingHr.map(Double.init),
                               prior: { $0.restingHr.map(Double.init) }, format: { "\(Int($0.rounded()))" })
        StatTile(
            label: "Resting HR",
            value: rhr.value,
            caption: rhr.caption,
            accent: rhr.value == "—" ? StrandPalette.textPrimary : StrandPalette.metricRose,
            sparkline: sparks["rhr"],
            sparkColor: StrandPalette.metricRose
        )
    }

    @ViewBuilder
    func bloodOxygenMetricTile(_ d: DailyMetric?) -> some View {
        let spo2 = carriedVital(unit: "SpO₂", today: d?.spo2Pct,
                                prior: { $0.spo2Pct }, format: { String(format: "%.0f%%", $0) })
        StatTile(
            label: "Blood Oxygen",
            value: spo2.value,
            caption: spo2.caption,
            accent: spo2.value == "—" ? StrandPalette.textPrimary : StrandPalette.metricCyan,
            sparkline: sparks["spo2"],
            sparkColor: StrandPalette.metricCyan
        )
    }

    @ViewBuilder
    func respiratoryMetricTile(_ d: DailyMetric?) -> some View {
        // Respiratory keeps its sparkline-tail fallback for a NON-carrying today (a sparse-but-recent
        // value still reads); when carrying, the prior scored night's respiratory is shown + stamped.
        let respCarry = carriedVital(unit: "rpm", today: d?.respRateBpm,
                                     prior: { $0.respRateBpm }, format: { String(format: "%.1f", $0) })
        let respValue = respCarry.value == "—" && lastScoredRecoveryDay == nil
            ? latestString("resp_rate", decimals: 1) : respCarry.value
        StatTile(
            label: "Respiratory",
            value: respValue,
            // When the sparkline-tail fallback surfaces a real value (respValue ≠ "—" while respCarry
            // was empty), use the plain "rpm" caption — not carriedVital's empty "After tonight's sleep"
            // state — so the caption matches the shown number (H10 mustn't mislabel a real value).
            caption: (respValue != "—" && respCarry.value == "—") ? "rpm" : respCarry.caption,
            accent: respValue == "—" ? StrandPalette.textPrimary : StrandPalette.accent,
            sparkline: sparks["resp_rate"],
            sparkColor: StrandPalette.accent
        )
    }

    @ViewBuilder
    func stepsMetricTile(_ d: DailyMetric?, latestApple aLatest: AppleDaily?) -> some View {
        // Prefer a REAL step count: the strap's own @57 counter (DailyMetric.steps, WHOOP 5/MG),
        // then Apple Health FOR THE SELECTED DAY (#589 — when the user imported phone steps for this
        // day, show THAT number directly, not the strap estimate), then the loaded Apple-Health steps
        // sparkline tail as a last-resort recent value. Only when a day has NONE of those real sources
        // do we fall back to the on-device ESTIMATE (steps_est) a WHOOP 4.0 user gets — flagged "est."
        // so it's never mistaken for a measured count. Mirrors Android (#276/#150).
        let appleStepsForDay = appleDays.last(where: { $0.day == selectedDayKey })?.steps
            ?? (selectedDayOffset == 0 ? aLatest?.steps : nil)
        let realSteps: String? = (d?.steps).map { intString(Double($0)) }
            ?? appleStepsForDay.map { intString(Double($0)) }
            ?? (sparks["steps"]?.last).map { intString($0) }
        let estSteps = stepsEstByDay[selectedDayKey]
        // H6 — only an ESTIMATED day (no real strap/phone count, so the on-device estimate filled in)
        // gets the calibration entry; a real measured count needs no calibration.
        let isEstimated = realSteps == nil && estSteps != nil
        // #589 — when the tile would be BLANK on a strap that estimates steps (WHOOP 4.0: the steps
        // pipeline has run, so there's calibration state recorded) explain WHY rather than a bare "—",
        // and still expose the ⚙︎ so the user can reach the sheet to set a manual coefficient.
        let needsCalibration = realSteps == nil && estSteps == nil && stepsPipelineActive
        StatTile(
            label: "Steps",
            value: realSteps ?? estSteps.map { intString(Double($0)) } ?? "—",
            // An estimated day reads "est."; a not-yet-calibrated day says how many more phone-counted
            // days are needed (so a blank tile is never silently unexplained).
            caption: realSteps != nil ? "today"
                : (estSteps != nil ? "est."
                   : (needsCalibration ? stepsCalibrationCaption : "today")),
            accent: (realSteps != nil || estSteps != nil) ? StrandPalette.metricCyan : StrandPalette.textPrimary,
            sparkline: sparks["steps"],
            sparkColor: StrandPalette.metricCyan,
            // H6 — an estimated (or awaiting-calibration) steps tile carries a small ⚙︎ that opens the
            // steps-calibration sheet (the SAME one Settings hosts), so a WHOOP 4.0 user can tune or
            // hand-set the estimate from here even before enough auto-fit days exist (#589).
            accessory: { if isEstimated || needsCalibration { stepsCalibrationButton } }
        )
    }

    @ViewBuilder
    func weightMetricTile(latestApple aLatest: AppleDaily?) -> some View {
        StatTile(
            label: "Weight",
            value: weightTile(aLatest?.weightKg).value,
            caption: weightTile(aLatest?.weightKg).caption,
            accent: StrandPalette.accent,
            sparkline: sparks["weight"],
            sparkColor: StrandPalette.accent
        )
    }

    @ViewBuilder
    func caloriesMetricTile(latestApple aLatest: AppleDaily?) -> some View {
        let cal = caloriesTile(aLatest)
        StatTile(
            label: "Calories",
            value: cal.value,
            caption: cal.caption,
            accent: StrandPalette.metricAmber,
            sparkline: cal.isWhoop ? sparks["energy_kcal"] : sparks["active_kcal"],
            sparkColor: StrandPalette.metricAmber
        )
    }
}

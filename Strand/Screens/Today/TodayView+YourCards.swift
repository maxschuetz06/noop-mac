import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

extension TodayView {
    // MARK: - Your cards (#582 / Design Reset)

    /// The user-customisable "Your cards" dashboard (WHOOP "My Dashboard"). Surfaces a persisted, reorderable
    /// selection of metric cards on the home screen as flat WHOOP metric rows — each opens its detail screen,
    /// the original three (Stress / Fitness age / Vitality) keep their destinations. A blue "CUSTOMISE" link on
    /// the header opens a local toggle/reorder sheet. TODAY only. A card with no value yet renders "—" rather
    /// than vanishing, so the section is stable; it's hidden only when the user has no cards selected at all.
    @ViewBuilder
    var yourCardsSection: some View {
        let visibleCards = visibleDashboardCards
        if selectedDayOffset == 0 && !visibleCards.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                // Section header: the "Your cards" label + a right-aligned BLUE "CUSTOMISE" action link (the
                // WHOOP "My Dashboard" ✎ affordance). Opens a local sheet — no new nav destination.
                HStack(alignment: .firstTextBaseline) {
                    Text("Your cards").strandOverline()
                    Spacer(minLength: 8)
                    Button {
                        showingDashboardEditor = true
                    } label: {
                        Label("CUSTOMISE", systemImage: "slider.horizontal.3")
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityLabel("Customise your cards")
                    .help("Choose which cards show and reorder them")
                }
                ForEach(visibleCards) { card in
                    dashboardCardRow(card)
                }
            }
            .sheet(isPresented: $showingDashboardEditor) {
                DashboardCardsEditorSheet(selectionRaw: $dashboardCardsRaw)
            }
        }
    }

    /// One "Your cards" dashboard row: resolves the card's CURRENT value from the values Today already loads
    /// (a card with no value yet shows "—"), then renders it as a WHOOP metric row that navigates to the
    /// card's detail screen. Branching keeps the destination type concrete (no AnyView) so navigation is
    /// exact and the original three cards reach the SAME screens as before.
    @ViewBuilder
    func dashboardCardRow(_ card: DashboardCard) -> some View {
        let tint = dashboardTint(card)
        switch card {
        case .stress:
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card), valueDate: dashboardValueDate(card)) { StressView() }
        case .fitnessAge:
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card), valueDate: dashboardValueDate(card)) { HealthView() }
        case .vitality:
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card), valueDate: dashboardValueDate(card)) { HealthView() }
        case .hrv, .restingHr, .respiratory, .bloodOxygen, .skinTemp:
            // The overnight vitals share the Health detail screen (the vital-signs surface).
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card), valueDate: dashboardValueDate(card)) { HealthView() }
        case .sleep:
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card), valueDate: dashboardValueDate(card)) { SleepView() }
        case .steps:
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card), valueDate: dashboardValueDate(card)) { HealthView() }
        case .calories:
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card), valueDate: dashboardValueDate(card)) { HealthView() }
        case .hydration:
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card), valueDate: dashboardValueDate(card)) { HydrationView() }
        }
    }

    /// A dashboard card's WHOOP-token tint (icon + accent). Score cards take their domain colour; vitals
    /// take their biometric hue; everything else takes the blue accent. No gold (WHOOP), tokens only.
    func dashboardTint(_ card: DashboardCard) -> Color {
        switch card {
        case .stress:      return StrandPalette.effortColor
        case .fitnessAge:  return StrandPalette.chargeColor
        case .vitality:    return StrandPalette.restColor
        case .hrv:         return StrandPalette.metricPurple
        case .restingHr:   return StrandPalette.metricRose
        case .respiratory: return StrandPalette.accent
        case .bloodOxygen: return StrandPalette.metricCyan
        case .skinTemp:    return StrandPalette.metricAmber
        case .sleep:       return StrandPalette.restColor
        case .steps:       return StrandPalette.metricCyan
        case .calories:    return StrandPalette.metricAmber
        case .hydration:   return StrandPalette.metricCyan
        }
    }

    /// Newest value of an overnight vital at or before the shown day — today's own row when it has one,
    /// else the last day that does (the Health "Vital Signs" convention: latest value + its date).
    func latestVital<V: Equatable>(_ pick: (DailyMetric) -> V?) -> TodayDisplayRules.DatedValue<V>? {
        if let own = displayDay, let v = pick(own) { return .init(value: v, day: own.day) }
        return TodayDisplayRules.latest(in: repo.days, upTo: selectedDayKey, pick)
    }

    /// The date caption ("23 Jul") for a card whose value comes from an earlier day; nil for today's own.
    func dashboardValueDate(_ card: DashboardCard) -> String? {
        let found: String?
        switch card {
        case .hrv:         found = latestVital(\.avgHrv)?.day
        case .restingHr:   found = latestVital(\.restingHr)?.day
        case .respiratory: found = latestVital(\.respRateBpm)?.day
        case .bloodOxygen: found = latestVital(\.spo2Pct)?.day
        case .skinTemp:    found = latestVital(\.skinTempDevC)?.day
        default:           found = nil
        }
        return found.flatMap { TodayDisplayRules.dateCaption(valueDay: $0, shownDay: selectedDayKey) }
    }

    /// The "Your cards" rows to render: cards without any value are hidden on the default selection.
    var visibleDashboardCards: [DashboardCard] {
        let customised = !dashboardCardsRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return enabledDashboardCards.filter {
            TodayDisplayRules.showsDashboardCard(hasValue: dashboardValue($0) != "—", userCustomised: customised)
        }
    }

    /// Resolve a dashboard card's CURRENT display value from the values Today already loads, with its unit
    /// suffix appended. Returns "—" when the value isn't available yet — never a fabricated number. Reuses
    /// the same reads the Key-Metrics tiles use (displayDay vitals, restScore / sleep duration, the pinned
    /// Stress / Fitness age / Vitality, steps, calories).
    func dashboardValue(_ card: DashboardCard) -> String {
        let d = displayDay
        func withUnit(_ s: String) -> String {
            guard s != "—" else { return "—" }
            return card.unit.isEmpty ? s : "\(s) \(card.unit)"
        }
        switch card {
        case .hrv:
            return withUnit(latestVital(\.avgHrv).map { "\(Int($0.value.rounded()))" } ?? "—")
        case .restingHr:
            return withUnit(latestVital(\.restingHr).map { "\($0.value)" } ?? "—")
        case .respiratory:
            return withUnit(latestVital(\.respRateBpm).map { String(format: "%.1f", $0.value) }
                            ?? sparks["resp_rate"]?.last.map { String(format: "%.1f", $0) } ?? "—")
        case .bloodOxygen:
            return latestVital(\.spo2Pct).map { String(format: "%.0f%%", $0.value) } ?? "—"
        case .skinTemp:
            // Mixed semantics: an on-device row is a ±°C deviation, an imported WHOOP row is absolute °C.
            return latestVital(\.skinTempDevC).map { Self.skinTempDisplay($0.value, unit: temperatureUnit) } ?? "—"
        case .sleep:
            return sleepValue(d)
        case .steps:
            let appleStepsForDay = appleDays.last(where: { $0.day == selectedDayKey })?.steps
                ?? (selectedDayOffset == 0 ? appleDays.last?.steps : nil)
            let real = (d?.steps).map { intString(Double($0)) }
                ?? appleStepsForDay.map { intString(Double($0)) }
                ?? sparks["steps"]?.last.map { intString($0) }
            let est = stepsEstByDay[selectedDayKey].map { intString(Double($0)) }
            return real ?? est ?? "—"
        case .calories:
            return withUnit(caloriesTile(appleDays.last).value)
        case .stress:
            return stressToday.map { "\(Int($0.rounded()))" } ?? "—"
        case .fitnessAge:
            return withUnit(fitnessAgeToday.map { "\(Int($0.rounded()))" } ?? "—")
        case .vitality:
            return vitalityToday.map { "\(Int($0.rounded()))" } ?? "—"
        case .hydration:
            // "<total> / <goal> L" in litres to 1 dp (the string bakes in the " L" itself). Always shows a
            // value (a fresh day reads "0.0 / 3.2 L"); the goal is always derivable from the profile.
            guard let goal = hydrationGoalML else { return "—" }
            return HydrationGoal.cardValueString(totalML: hydrationTotalML ?? 0, goalML: goal)
        }
    }

    /// One WHOOP "My Dashboard" metric row: a thin-line tinted icon, an UPPERCASE tracked label over a grey
    /// baseline caption, the big white value, and a chevron — the whole row navigates to `destination`. Flat
    /// WHOOP styling (FrostedCardSurface, no glow), tokens only.
    @ViewBuilder
    func pinnedCardRow<Dest: View>(icon: String, tint: Color, title: String, subtitle: String,
                                           value: String, valueDate: String? = nil,
                                           @ViewBuilder destination: @escaping () -> Dest) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased())
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(value).font(StrandFont.rounded(18, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                    if let valueDate {
                        Text(valueDate).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FrostedCardSurface(cornerRadius: NoopMetrics.cardRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

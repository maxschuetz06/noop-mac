import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Hydration detail (MVP, opt-in, local-only)
//
// Design-Reset compliant: a clean progress ring (GlowRing, blue accent, no bloom), the three quick-log
// buttons (Sip / Cup / Bottle) in the secondary NoopButton style, today's logged total as a single
// read-out, and a 7-day mini bar history. Flat cards (NoopCard), NoopMetrics spacing, tokens only, no
// gold. BYTE-PARITY twin of the Android `HydrationScreen`: the day total + history come from the
// local-only `HydrationStore` series (additive day total), and the goal is the pure `HydrationGoal`
// engine (profile sex + today's Effort bump). Per-tap rows aren't separately persisted on either
// platform — the day total is the source of truth, so the screen shows the honest day figure.
struct HydrationView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    /// Today's running total (ml) + the 7-day history (oldest→newest), loaded off the gesture path and
    /// refreshed after each log. A reload key the taps bump so the `.task` re-reads the store.
    @State private var totalML: Double = 0
    @State private var history: [(day: String, value: Double)] = []
    @State private var reloadTick = 0

    private var goalML: Int { repo.hydrationGoalML(profileSex: profile.sex) }
    private var fraction: Double { HydrationGoal.fraction(totalML: totalML, goalML: goalML) }
    private var percent: Int { min(100, Int((fraction * 100).rounded(.towardZero))) }

    var body: some View {
        ScreenScaffold(title: "Hydration",
                       subtitle: "Your fluid intake today, on \(Platform.deviceNounPhrase) only.",
                       onRefresh: { await reload() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                ringSection
                logSection
                historySection
                todayTotalSection
                Text("A simple goal that adjusts to your effort. General wellness guidance, not medical advice.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: reloadTick) { await reload() }
    }

    // MARK: - Ring (total vs goal, in litres)

    private var ringSection: some View {
        NoopCard(padding: 20) {
            VStack(spacing: NoopMetrics.cardInnerSpacing) {
                ZStack {
                    GlowRing(fraction: fraction,
                             value: HydrationGoal.litres(fromML: totalML),
                             format: { _ in "" },   // centre text is the overlay below
                             color: StrandPalette.accent,
                             diameter: 184,
                             lineWidth: 14)
                    VStack(spacing: 2) {
                        Text(String(format: "%.1f", HydrationGoal.litres(fromML: totalML)))
                            .font(StrandFont.rounded(40, weight: .bold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .monospacedDigit()
                        Text(String(format: "of %.1f L", HydrationGoal.litres(fromML: Double(goalML))))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Hydration today")
                .accessibilityValue("\(String(format: "%.1f", HydrationGoal.litres(fromML: totalML))) of \(String(format: "%.1f", HydrationGoal.litres(fromML: Double(goalML)))) litres")

                Text("\(percent)% of today's goal")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Quick log (Sip / Cup / Bottle, secondary style)

    private var logSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(spacing: NoopMetrics.gap) {
                logButton("Sip", systemImage: "drop", ml: HydrationGoal.sipML)
                logButton("Cup", systemImage: "cup.and.saucer.fill", ml: HydrationGoal.cupML)
                logButton("Bottle", systemImage: "drop.fill", ml: HydrationGoal.bottleML)
            }
            Text("Sip \(HydrationGoal.sipML) ml · Cup \(HydrationGoal.cupML) ml · Bottle \(HydrationGoal.bottleML) ml")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    /// One quick-add button using the secondary (no-gold) NoopButton style. Logs the amount and refreshes.
    private func logButton(_ title: LocalizedStringKey, systemImage: String, ml: Int) -> some View {
        NoopButton(title, systemImage: systemImage, kind: .secondary, fullWidth: true) {
            Task { await add(ml: ml) }
        }
        .accessibilityLabel("Log \(title)")
    }

    // MARK: - 7-day mini history (flat bars, today on the right)

    private var historySection: some View {
        NoopCard(padding: 18) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("Last 7 days").strandOverline()
                historyBars
            }
        }
    }

    @ViewBuilder private var historyBars: some View {
        if history.isEmpty {
            Text("No history yet.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        } else {
            // Scale the bars to the LARGER of the goal and the biggest day, so an over-goal day doesn't clip.
            let ceiling = max(Double(max(goalML, 1)), history.map(\.value).max() ?? 0, 1)
            let lastIndex = history.count - 1
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(history.enumerated()), id: \.element.day) { idx, bar in
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(StrandPalette.textPrimary.opacity(0.10))
                                .frame(height: 96)
                            let frac = min(1.0, max(0.0, bar.value / ceiling))
                            if frac > 0 {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(idx == lastIndex ? StrandPalette.accent
                                                           : StrandPalette.accent.opacity(0.45))
                                    .frame(height: max(3, 96 * CGFloat(frac)))
                            }
                        }
                        Text(weekdayInitial(bar.day))
                            .font(StrandFont.overline)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(weekdayInitial(bar.day)): \(String(format: "%.1f", HydrationGoal.litres(fromML: bar.value))) litres")
                }
            }
        }
    }

    // MARK: - Today's total (the honest day figure; per-tap rows aren't persisted)

    private var todayTotalSection: some View {
        NoopCard(padding: 18) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Today").strandOverline()
                if totalML <= 0 {
                    Text("No drinks logged yet. Tap Sip, Cup or Bottle to start.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "drop.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text("Logged today")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: 8)
                        Text("\(Int(totalML)) ml")
                            .font(StrandFont.headline.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: - Data

    /// The single-letter weekday for a yyyy-MM-dd key (M T W T F S S), or "·" when unparseable. Mirrors
    /// the Android `weekdayInitial` (EEE → first letter, US locale).
    private func weekdayInitial(_ dayKey: String) -> String {
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd"
        guard let date = parse.date(from: dayKey) else { return "·" }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US")
        out.dateFormat = "EEE"
        return String(out.string(from: date).prefix(1))
    }

    /// Log `ml` (additive day total) and refresh.
    private func add(ml: Int) async {
        _ = await repo.logHydration(amountMl: ml)
        reloadTick &+= 1
    }

    /// Load today's total + the 7-day history from the store.
    private func reload() async {
        totalML = await repo.hydrationTotal(day: Repository.localDayKey(Date()))
        history = await repo.hydrationHistory(days: 7)
    }
}

import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Control Center (the home dashboard) — HomeDensity rewrite
//
// The owner's complaint was "cards then random space". This rebuild is a tight,
// GAPLESS dashboard grid: one column of uniform sections, every gap == NoopMetrics.gap,
// every section break == NoopMetrics.sectionGap, equal margins from ScreenScaffold.
//
// Composition (top → bottom):
//   (a) HERO  — full-width HStack that fills the width EQUALLY: RecoveryRing (left card)
//               + InsightCard "Today's Synthesis" (right card). No lone card, no gap.
//   (b) METRICS — one adaptive LazyVGrid of fixed-104pt StatTiles (Recovery, Strain,
//               Sleep, HRV, RHR, SpO2, Respiratory, Steps, Weight, Calories) each with
//               a 14-day sparkline so the grid tiles perfectly with no empty cells.
//   (c) LAST WORKOUTS — the SAME adaptive grid of fixed-104pt workout StatTiles.
//   (d) DATA SOURCES — one full-width NoopCard footer of SourceBadges + counts.
//
// Sparse series (weight) fall back to ALL history so a tile never shows an empty
// state when data exists. Only locked StrandDesign components are used.

struct TodayView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var router: NavRouter
    /// The "update ringer" — the bell in the top bar opens this inbox; dismissed Today cards post into it.
    @EnvironmentObject var updateStore: UpdateStore

    // Imperial/Metric display preference (D#103). Only the Weight tile carries a convertible unit here.
    @AppStorage(UnitPrefs.systemKey) var unitSystemRaw = UnitSystem.metric.rawValue
    var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    @AppStorage(UnitPrefs.temperatureKey) var temperatureRaw = ""
    var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw)
    }
    // Effort display scale (#268) — drives the Effort tile's value + caption. Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) var effortScaleRaw = EffortScale.hundred.rawValue
    var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    // Editable Key-Metrics layout (#251) — an ordered list of the enabled tiles, persisted display-only.
    // Empty/unset shows the full default order. The "Edit" affordance on the section opens a local sheet.
    @AppStorage(KeyMetricPrefs.layoutKey) var keyMetricsRaw = ""
    @State var showingMetricsEditor = false
    var enabledKeyMetrics: [KeyMetric] { KeyMetricPrefs.decodeEnabled(keyMetricsRaw) }

    // "Your cards" customisable dashboard (WHOOP "My Dashboard") — a persisted, reorderable selection of
    // metric cards. Empty/unset shows the sensible default set (Stress / Fitness age / Vitality + HRV +
    // Resting HR). The "CUSTOMISE" link on the section header opens a local sheet (no new nav destination).
    // Persistence is display-only — these cards read the SAME values the rest of Today already loads.
    @AppStorage(DashboardCardPrefs.selectionKey) var dashboardCardsRaw = ""
    @State var showingDashboardEditor = false
    // Hydration tracker (opt-in, default OFF). When off the hydration dashboard card is hidden even if a
    // user had it in their saved selection — the feature owns its own gate.
    @AppStorage(HydrationStore.enabledKey) var hydrationEnabled = false
    /// Today's hydration total + goal (ml), loaded in loadAll when the feature is on. nil hides the value.
    @State var hydrationTotalML: Double?
    @State var hydrationGoalML: Int?
    var enabledDashboardCards: [DashboardCard] {
        // Opt-in gate (mirrors the Android TodayScreen filter `it != HYDRATION || hydrationEnabled`):
        // the hydration card only renders when the feature is on AND the user has added it via CUSTOMISE.
        // It's not in the default selection, so a fresh install never shows it until both are true.
        DashboardCardPrefs.decodeEnabled(dashboardCardsRaw)
            .filter { hydrationEnabled || $0 != .hydration }
    }

    // 14-day sparkline series, keyed by metric key. Loaded once in .task.
    @State var sparks: [String: [Double]] = [:]
    @State var workouts: [WorkoutRow] = []
    @State var appleDays: [AppleDaily] = []
    // Design Reset / #582 — the pinned "Your cards" values (Stress / Fitness age / Vitality), surfaced
    // on Today so the buried Explore features sit on the home screen. Loaded in loadAll; nil hides the row.
    @State var stressToday: Double?
    @State var fitnessAgeToday: Double?
    @State var vitalityToday: Double?
    /// Distinct days + sleep sessions imported from a Mi Band (Mi Fitness), for the Data Sources row.
    @State var xiaomiDays = 0
    @State var xiaomiSleeps = 0

    // The Rest SCORE (0–100) for the logical day — IntelligenceEngine's Rest composite, written to the
    // `sleep_performance` metric series (imported export wins, computed strap fills). The Key-Metrics
    // "Rest" tile shows THIS, formatted like Charge/Effort, with hours-in-bed kept as the caption — the
    // tile previously showed hours where the score belonged (#248). nil until loaded / no night yet.
    @State var restScore: Double?

    // Component 4 — the REAL per-day merge winner (provenance) for the selected day's derived scores,
    // keyed by metric key ("recovery" / "sleep_performance"); the value is the raw source id the resolver
    // returned (e.g. "my-whoop", "my-whoop-noop", "apple-health"). Resolved once per load via
    // `resolvedSeries` (the same imported-WHOOP > NOOP-computed > Apple-Health precedence the dashboard
    // merge uses), so a provenance badge reflects which source actually supplied that day's number rather
    // than a blanket "on-device" claim. Absent until loaded / when a day has no value. (spec 2026-06-20)
    @State var provenanceByMetric: [String: String] = [:]

    // On-device steps ESTIMATE per day (key "steps_est", computed "-noop" source). The Steps tile
    // prefers a REAL step count (strap @57 counter / Apple Health); only when a day has neither does it
    // fall back to this estimate, shown with an "est." caption so it's never read as a measured count.
    // Loaded once via exploreSeries (same merged read fitness_age/vitality use), keyed by day. (#150)
    @State var stepsEstByDay: [String: Int] = [:]

    // Imported-WHOOP per-day values that only exist as metric series (the export has no daily column for
    // them): total energy ("energy_kcal"), max HR ("max_hr") and average HR ("avg_hr"). key → day → value.
    // Loaded once via exploreSeries; read for the selected day by the Calories and Effort tiles.
    @State var importedDayValues: [String: [String: Double]] = [:]

    // Today's heart rate as 5-minute bucket means (midnight → now), for the 24h trend chart.
    @State var hrPoints: [TrendPoint] = []

    // The night's sleep session overlapping the HR window — shaded as a band on the HR chart and
    // used to anchor the recovery marker at wake time (WHOOP-style Overview HR annotations).
    @State var sleepToday: CachedSleepSession?

    // TODAY's in-progress Effort (NOOP 0–100 axis), recomputed over the day's HR (local-midnight→now)
    // each load so the gauge tracks today as it accumulates rather than waiting on the heavy daily pass
    // to persist — which early in the day would otherwise surface yesterday's completed Effort or a stale
    // 0.0 (#402). nil below StrainScorer.minReadings (we then fall back to the stored daily row) and on
    // any navigated past day (those use the stored value).
    @State var liveTodayStrain: Double?

    // The HR chart's x-axis window. Today → midnight…now; a navigated PAST day → the full calendar
    // day (midnight…next midnight) so a morning with no banked data reads as empty space rather than
    // the axis silently starting at the first sample (#overview-hr gap clarity).
    @State var hrAxis: ClosedRange<Date>?

    // Day navigation — 0 = today (the logical day), 1 = yesterday, … The DayNavBar chevrons and date
    // jump drive this, and every day-scoped read-out (hero synthesis, the Key-Metrics tiles, the HR
    // trend and Rest score) resolves to the selected day instead of always showing today. Mirrors the
    // Android TodayScreen.selectedDayOffset. Loads re-run when this changes (see .task(id:)).
    @State var selectedDayOffset = 0
    // #605: one-shot guard so the dashboard auto-lands on the most recent day WITH data the first time it
    // opens to an empty today (fresh install, or a strap mid-backfill whose newest banked day is older than
    // today). After the single auto-land the user can chevron freely without it snapping forward again.
    @State var didAutoLandLatest = false
    // iOS top-bar state: the date-jump popover and the profile/settings sheet.
    @State var showDayPicker = false
    @State var showSettings = false
    /// The Updates inbox sheet (opened by the header bell). Shared across both platforms.
    @State var showUpdatesInbox = false

    /// The NEWEST day-key (max yyyy-MM-dd in `repo.days`) announced to the inbox. Persisted (not @State)
    /// so a relaunch over the same history never re-announces (#521). We trigger on a strictly-newer KEY,
    /// not a count: a recompute that deletes-then-reinserts the window dips/recovers the count but keeps
    /// the same max key, so churn can't masquerade as new history. Empty = no baseline yet (first load
    /// just records the key silently — we only announce genuine forward growth).
    @AppStorage("today.lastAnnouncedDayKey") var lastAnnouncedDayKey = ""

    // Per-card "dismissed into the inbox" flags for the two Today info-cards. A small × on each card
    // sets these (and posts a `.dismissedCard` update); "Restore to Today" in the inbox flips them back
    // (via the shared `TodayCardDismissal.flagKey`). @AppStorage matches the file's existing prefs style.
    @AppStorage(TodayCardDismissal.flagKey("scoresBuilding")) var scoresBuildingDismissed = false
    @AppStorage(TodayCardDismissal.flagKey("newHere")) var newHereDismissed = false

    // Memoized repo-derived values that are expensive (a full-history sort + per-call
    // `repo.days.map`) yet INDEPENDENT of the ~1 Hz live-HR ticks that re-evaluate `body`
    // while a strap streams. `LiveState` publishes R-R every second, so `body` (and every
    // section it renders) re-runs ~1 Hz; recomputing Readiness and the recovery calibration
    // over the whole history on each of those passes is pure waste. Cache them keyed on a
    // cheap repo fingerprint and rebuild only when that changes — the same memoization
    // SleepView and StressView already use to absorb the live-HR re-render flood.
    @State var derived: TodayDerived?
    @State var derivedKey: TodayInputKey?

    // "How your scores work" guide — presented at a specific score's section when the ⓘ on that
    // score (or the first-run card) is tapped. nil = not shown. ScoreSection is Identifiable, so
    // .sheet(item:) drives both presentation and the deep-link target in one binding.
    @State var guideSection: ScoreSection?
    /// `nil` means the user tapped the generic first-run card / a non-section entry: open at the top.
    @State var showGuideTop = false

    // One-time, dismissible first-run card pointing at the guide. Set true by either the primary tap
    // or the ✕, so it never shows again. @AppStorage matches the file's existing prefs style (#103).
    @AppStorage(Self.guideCardSeenKey) var scoringGuideCardSeen = false
    static let guideCardSeenKey = "scoringGuideCardSeen"

    // H6 — the steps-calibration sheet, opened from the Steps tile when it's showing an ESTIMATE (a WHOOP
    // 4.0 user, whose strap doesn't transmit steps). Presents the SAME StepsCalibrationSheet Settings uses,
    // so a 4.0 user can reach calibration from where they actually notice the "est." caption.
    @State var showStepsCalibration = false

    // THE single grid definition — every tile group reuses it so margins line up. minimum 150 (not
    // 168) so two tiles reliably fit a phone's ~345pt content width; at 168 the grid sat on the
    // single-vs-two-column boundary and could collapse to one full-width column on a narrow phone.
    let grid = [GridItem(.adaptive(minimum: 150), spacing: NoopMetrics.gap)]
    var body: some View {
        ScreenScaffold(title: scaffoldTitle, subtitle: scaffoldSubtitle, onRefresh: { await repo.refresh() },
                       topBackground: sceneBackground) {
            dashboard
        }
        // Reload when the data refreshes OR the selected day changes — the HR trend and Rest score are
        // day-scoped, so navigating must re-fetch them for the newly selected window.
        .task(id: TodayLoadKey(seq: repo.refreshSeq, offset: selectedDayOffset)) { await loadAll() }
        // Persist the freshly-built derivations so subsequent (1 Hz) renders with the same
        // inputs hit the cache instead of recomputing. Writing @State during `body` is not
        // allowed, so commit it after layout — the memoized accessors already return the
        // correct value for the change frame, so there is no flash and no missed update.
        // macOS-13-safe single-param onChange.
        .onChangeCompat(of: todayInputKey) { newKey in
            derived = buildDerived()
            derivedKey = newKey
        }
        .onAppear {
            if derivedKey != todayInputKey {
                derived = buildDerived()
                derivedKey = todayInputKey
            }
        }
        #if os(macOS)
        // The Updates "ringer" on the trailing (top-right) edge of the window toolbar (iOS hosts it in
        // the compact top bar instead).
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                updateBell.help("Updates")
            }
        }
        #else
        // Profile/settings from the top-bar button.
        .sheet(isPresented: $showSettings) { settingsSheet }
        #endif
        // The scoring guide, opened at a specific score from its ⓘ.
        .sheet(item: $guideSection) { section in
            ScoringGuideView(initialSection: section, onClose: { guideSection = nil })
        }
        // The scoring guide opened at the top (the first-run card's primary action).
        .sheet(isPresented: $showGuideTop) {
            ScoringGuideView(onClose: { showGuideTop = false })
        }
        // The Updates inbox (the header bell). Both platforms.
        .sheet(isPresented: $showUpdatesInbox) {
            UpdatesInboxView(onClose: { showUpdatesInbox = false })
        }
        // H6 — the steps-calibration sheet, opened from an estimated Steps tile (the same sheet Settings
        // hosts). Presented from Today so a WHOOP 4.0 user can calibrate from where the "est." caption shows.
        .sheet(isPresented: $showStepsCalibration) {
            StepsCalibrationSheet(repo: repo, onClose: { showStepsCalibration = false })
        }
        // Honour a "Restore to Today" tap from the inbox: flip the matching dismissed flag back so the
        // card reappears (the inbox also clears the @AppStorage key directly, but this covers an
        // already-mounted Today). Cleared once handled.
        .onChangeCompat(of: updateStore.restoreRequest) { payload in
            guard let payload else { return }
            withAnimation(StrandMotion.interactive) { restoreTodayCard(payload) }
            updateStore.restoreRequest = nil
        }
    }

    /// The Day Details column: day navigation, prompts, the score hero and every section in order.
    var dashboard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            #if os(iOS)
            // Compact top bar: profile/settings (left) · ‹ Today › day-nav (centre, bold) · strap
            // battery (right). Replaces the big title + the full-width day-nav pill (WHOOP-style).
            todayTopBar
            HealthAlertBanner()
            #else
            HealthAlertBanner()
            // Browse past days — chevrons + a date jump capped at today (no future days).
            DayNavBar(selectedOffset: selectedDayOffset) { selectedDayOffset = $0 }
            #endif
            scoresBuildingPrompts
            // Design Reset: the "New here?" first-run card is off the dashboard for the clean WHOOP
            // look. The scoring guide stays reachable from the i on each score and in Settings.
            heroCard
            heartRateTrendSection.staggeredAppear(index: 1)
            // Design Reset: rings -> Heart rate -> Your cards (the flat mockup order); the greeting +
            // Synthesis read-out + vitals now sit below the pinned cards instead of crowding the hero.
            yourCardsSection.staggeredAppear(index: 2)
            synthesisSection.staggeredAppear(index: 3)
            if TodayDisplayRules.coachingCardsVisible {
                readinessSection.staggeredAppear(index: 4)
            }
            metricsSection.staggeredAppear(index: 5)
            workoutsSection.staggeredAppear(index: 6)
            // Opt-in "looks like a workout?" suggestion (default OFF). Renders only when the
            // Settings toggle is on AND the detector finds a recent unsaved, un-dismissed window.
            AutoWorkoutCard()
            sourcesSection
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Control Center") {
    let repo = Repository(deviceId: "preview")
    let cal = Calendar(identifier: .gregorian)
    let today = cal.startOfDay(for: Date())
    var sample: [DailyMetric] = []
    for i in stride(from: 39, through: 0, by: -1) {
        let date = cal.date(byAdding: .day, value: -i, to: today)!
        let day = Repository.dayString(date)
        let phase = Double(i)
        let rec = 48 + 34 * sin(phase / 5.0) + Double((i * 7) % 11)
        let strain = 8 + 7 * abs(sin(phase / 4.0))
        let total = 380 + 70 * sin(phase / 6.0)
        sample.append(DailyMetric(
            day: day, totalSleepMin: total, efficiency: 88 + 6 * sin(phase / 3.0),
            deepMin: 95, remMin: 110, lightMin: total - 200, disturbances: 4,
            restingHr: 50 + (i % 6), avgHrv: 58 + 16 * sin(phase / 4.0),
            recovery: min(max(rec, 8), 99), strain: strain, exerciseCount: i % 3,
            spo2Pct: 96, skinTempDevC: 33.4, respRateBpm: 14.6
        ))
    }
    repo.days = sample
    repo.loaded = true

    return TodayView()
        .environmentObject(repo)
        .frame(width: 920, height: 940)
        .preferredColorScheme(.dark)
}
#endif

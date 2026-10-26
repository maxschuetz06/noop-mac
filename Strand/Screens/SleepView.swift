import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - SleepView
//
// Whoop-sleep clarity on the locked Noop component system. Scannable in two seconds:
//   1. HERO ChartCard "Last night" — the stage breakdown (Hypnogram if intervals
//      reconstruct from stagesJSON, else a clean proportional stacked stage bar),
//      trailing = total asleep, footer = REM/Deep/Light/Awake each "Xh Ym · NN%".
//   2. A uniform grid of fixed StatTiles, each with a sparkline and a "vs typical"
//      caption: Performance, Efficiency, Consistency, Hours vs Needed, Restorative,
//      Respiratory, Sleep Debt.
//   2b. The sleep-debt LEDGER card — a rolling 14-night running balance of (slept −
//      personal need) with a plain-English read and a diverging per-night delta bar.
//   3. "Stages vs typical" NoopCard — Deep/REM/Light as horizontal bars, last-night
//      minutes with a marker at the personal typical (mean) so highs/lows pop.
//   4. A 30-day asleep-hours ChartCard trend.
//
// Every surface is a NoopCard / StatTile / ChartCard — no hand-sized cards, one grid,
// equal margins. Data wiring is preserved from the previous screen (stagesJSON =
// minutes for light/deep/rem/awake; typical = mean of repo.days).

struct SleepView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var intelligence: IntelligenceEngine

    // The standard tile grid: ONE adaptive column set, used for every tile group.
    let tileColumns = [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)]

    /// Memoized snapshot of every expensive derivation (latest Night with its intervals
    /// resolved once, the seven metric series, the trend points, the typical means). Rebuilt
    /// only when the underlying repo data actually changes — NOT on hover/animation/1Hz HR
    /// ticks that merely re-evaluate `body`. `nil` until first build or when there's no night.
    @State var model: SleepModel?
    /// The repo signature the cached `model` was built from. Cheap to compute every render;
    /// when it differs from the current inputs we rebuild the model.
    @State var modelKey: SleepInputKey?

    /// Which night the hero hypnogram shows: 0 = last night, N = N sleep-sessions back.
    /// Snaps back to 0 whenever the data key changes — a stale offset would silently point
    /// at a different session after a sync. The memoized trend `model` stays cached since
    /// the trends are night-independent. (#160)
    @State var nightOffset = 0
    /// Memoized decode of the NAVIGATED night (nil when `nightOffset == 0` — the hero reads
    /// `model.night` then). Rebuilt only in the `nightOffset` / data-key onChange handlers;
    /// `decodedNight` JSON-decodes, which must never run per body pass (1Hz HR ticks). (#160)
    @State var navNight: Night?

    /// Every sleep BLOCK across both sources, UN-deduplicated (`repo.allSleepSessions`) — `repo.sleeps`
    /// keeps one winner per night for the dashboard, collapsing split-sleep days (a nap + a main
    /// sleep on the same day) into a single block. The hero groups these by day (`navDays`) and
    /// merges each day into one Night, so a split day reads as one correctly-totalled night with the
    /// gaps preserved. Oldest→newest. Falls back to `repo.sleeps` until loaded. (#170)
    @State var allSessions: [CachedSleepSession] = []

    /// Naps imported from a WHOOP export (`isNap`). Kept OUT of `allSessions` on purpose — that list feeds
    /// the main-night pick, the hero and every nightly aggregate, which must never see a nap. They are
    /// read separately and only listed (read-only) in the Naps card for the day they fall on.
    @State var importedNaps: [CachedSleepSession] = []

    /// The user's LEARNED habitual midsleep (local time-of-day seconds), or nil under the cold-start
    /// threshold. Loaded from `repo.habitualMidsleepSec()` — the SAME value `AnalyticsEngine.analyzeDay`
    /// threads into the daily total — and fed into the main-night selector so the hero, the naps split,
    /// and the edit target pick the SAME block the analytics rollup did, for a shift/late sleeper too. nil
    /// keeps the existing cold-start overnight-band fallback. (#547) Refreshed with `allSessions`.
    @State var habitualMidsleepSec: Int? = nil

    /// Persisted per-epoch MOTION series keyed by each session's detected `startTs` (#407). Loaded in the
    /// same `.task` as `allSessions` from `repo.sessionMotions(starts:)`, then laid along the hypnogram for
    /// the SAME main-night GROUP blocks the hero resolved (mergeDay's group) — we do NOT re-resolve the
    /// night, only read the already-chosen group's stored motion. A block with no stored series stays absent
    /// (honest empty state for older rows whose `motionJSON` is NULL). Refreshed with `allSessions`.
    @State var motionByStart: [Int: [Double]] = [:]

    /// Memo for `navDays`: the per-day grouping walks every stored session (a `Calendar.startOfDay` each) and
    /// the body asks for it from the hero, the nav header, the model build and the nap card on every pass.
    /// A reference-type holder, so filling it during `body` publishes no state.
    @State var navDaysCache = NavDaysCache()

    /// Draw-in fraction for the Rest hero gauge — owned here so the gauge animates the arc on appear /
    /// when the sleep-performance score changes, exactly as TodayView drives its rings. Presentation-only.
    @State var heroFraction: Double = 0

    /// Non-nil while the wake-time editor sheet is open. Carries the night's stable key (`startTs`) and
    /// current wake time so the editor seeds its picker; saving routes through `repo.editSleepWakeTime`,
    /// which marks the session `userEdited` so a later strap sync can't revert the correction. (#318)
    @State var wakeEdit: WakeEdit?

    /// Non-nil while the "Add nap" picker sheet is open (#508). Carries a seed bed/wake for the picker;
    /// saving routes through `repo.addManualNap`, which stages the chosen window from raw and writes it as
    /// its OWN separate session row (`userEdited = 1`) — never folded into the night's main sleep.
    @State var addNap: AddNapSeed?

    /// The most recent sleep-mark the user tapped, shown as a transient confirmation line under the
    /// two buttons and cleared after a moment. Drives the SwiftUI haptic landing too. LOGGING-ONLY:
    /// a mark never feeds the sleep detector — it's persisted to the metric series + strap log. (#461)
    @State var lastMark: SleepMark?

    /// True while the hero's "why this is your main sleep" popover is open. The reason text comes
    /// straight from the foundation `MainNightReason` for the displayed night's blocks — never
    /// re-derived here — so the explainer says exactly what the selector decided. (spec 2026-06-20 C1)
    @State var showMainSleepWhy = false
    /// The stable detected key of the nap whose "why this is a nap" popover is open, or nil. Keyed by
    /// the nap's own `startTs` so one popover shows at a time even with several nap rows. (C1)
    @State var napWhyStartTs: Int?

    var body: some View {
        // Resolve the memoized model for THIS render. `dataKey` is O(1)-ish (counts + last-row
        // identity), so comparing it every render is cheap. When it matches the cached key we
        // reuse the cached model untouched — the many body re-evaluations from hover/animation/
        // 1Hz HR ticks pay nothing. When it differs (or on first render) we build once, here,
        // synchronously, so the very first frame already shows content (no empty-state flash).
        let key = dataKey
        let resolved: SleepModel? = (key == modelKey) ? model : buildModel()
        ScreenScaffold(title: "Sleep", subtitle: "Understand and improve your rest.",
                       onRefresh: { await repo.refresh() }) {
            Group {
                if let resolved {
                    // Each top-level section fades + rises in sequence on first appear (Reduce-Motion safe).
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                        #if os(macOS)
                        softOverview(resolved).staggeredAppear(index: 0)
                        #else
                        restHero(resolved).staggeredAppear(index: 0)
                        #endif
                        sleepMarkCard.staggeredAppear(index: 1)
                        hero(resolved).staggeredAppear(index: 2)
                        metricGrid(resolved).staggeredAppear(index: 3)
                        sleepDebtLedger(resolved).staggeredAppear(index: 4)
                        stagesVsTypical(resolved).staggeredAppear(index: 5)
                        durationTrend(resolved).staggeredAppear(index: 6)
                        // Imported naps on days that have no night of their own. `napOnlyDaysCard`
                        // already excludes every day with a night, so this never duplicates the
                        // per-night naps list above.
                        napOnlyDaysCard.staggeredAppear(index: 7)
                    }
                } else {
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                        emptyState
                        napOnlyDaysCard
                    }
                }
            }
            // Animate the Rest hero gauge in once content resolves, and re-draw when the
            // sleep-performance score changes (a sync / re-import). macOS-13-safe single-param onChange.
            .onChangeCompat(of: heroScoreFraction(resolved)) { newFraction in
                withAnimation(.easeOut(duration: 0.9)) { heroFraction = newFraction }
            }
            .onAppear {
                withAnimation(.easeOut(duration: 0.9)) { heroFraction = heroScoreFraction(resolved) }
            }
            // Persist the freshly-built model so subsequent renders with the same inputs hit
            // the cache. Writing State during body is not allowed, so commit it after layout;
            // `resolved` already drives THIS frame, so there is no flash and no extra rebuild.
            .onChangeCompat(of: key) { newKey in
                modelKey = newKey
                model = buildModel()
                // New data invalidates a navigated offset — the same offset would silently
                // point at a different session. Snap back to last night. (#160)
                nightOffset = 0
                navNight = nil
            }
            // The navigated night is decoded once per ◀/▶ press, never per body pass —
            // `decodedNight` JSON-decodes and body re-evaluates at 1Hz while HR streams. (#160)
            .onChangeCompat(of: nightOffset) { newOffset in
                navNight = newOffset == 0 ? nil : decodedNight(at: newOffset)
            }
            .onAppear {
                if modelKey != key {
                    modelKey = key
                    model = resolved
                    nightOffset = 0
                    navNight = nil
                }
            }
            // Load EVERY sleep block across BOTH sources (un-deduplicated) so the hero's ◀/▶ can
            // browse split-sleep days the dashboard collapses — including Bluetooth-only nights,
            // whose blocks live under the computed source. Re-runs whenever a sync/import bumps
            // refreshSeq; snaps back to the newest day and rebuilds the model so offset 0 reflects
            // the freshly-loaded blocks. (#170)
            .task(id: repo.refreshSeq) {
                allSessions = await repo.allSleepSessions()
                importedNaps = await repo.napSessions()
                // Load the learned habitual midsleep the engine used, so the main-night pick aligns to it
                // (a shift/late sleeper) instead of only the cold-start band. nil under threshold. (#547)
                habitualMidsleepSec = await repo.habitualMidsleepSec()
                // Per-epoch motion for every block (#407), keyed by detected start. mergeDay reads only the
                // already-resolved group's entries — this just pre-fetches them all so the model build is sync.
                motionByStart = await repo.sessionMotions(starts: allSessions.map { $0.startTs })
                nightOffset = 0
                navNight = nil
                modelKey = dataKey
                model = buildModel()
            }
            .sheet(item: $wakeEdit) { edit in
                SleepTimeEditor(bedTs: edit.bedTs, wakeTs: edit.wakeTs,
                                onSave: { newBedTs, newWakeTs in
                    await repo.editSleepTimes(detectedStartTs: edit.detectedStartTs, oldEndTs: edit.wakeTs,
                                              storedStagesJSON: edit.stagesJSON,
                                              newStartTs: newBedTs, newEndTs: newWakeTs)
                    // Re-score the day so the dashboard aggregates (Rest / recovery) honor the corrected
                    // sleep window, not just the Sleep tab's session view; then refresh the read cache.
                    await intelligence.analyzeRecent()
                    await repo.refresh()
                }, onDelete: {
                    // Delete = the edit path minus the re-insert: drop this session so every metric
                    // recomputes immediately as if the night were never recorded, durably tombstoned so a
                    // re-detect doesn't bring it back, then re-score + refresh exactly like an edit. (#68)
                    await repo.deleteSleepSession(detectedStartTs: edit.detectedStartTs, endTs: edit.wakeTs)
                    await intelligence.analyzeRecent()
                    await repo.refresh()
                })
            }
            // Manually add a missed nap (#508): same picker, but the chosen window is staged from raw and
            // stored as its OWN separate session — never folded into main sleep (which would mislabel the
            // awake daytime gap as light sleep).
            .sheet(item: $addNap) { seed in
                SleepTimeEditor(bedTs: seed.bedTs, wakeTs: seed.wakeTs,
                                title: "Add a nap",
                                blurb: "Pick when the nap started and ended. NOOP stages it from your data as its own session, separate from the night's sleep.",
                                bedLabel: "Nap started", wakeLabel: "Nap ended") { startTs, endTs in
                    await repo.addManualNap(startTs: startTs, endTs: endTs)
                    // Re-score so the day's aggregates pick up the new session, exactly like an edit.
                    await intelligence.analyzeRecent()
                    await repo.refresh()
                }
            }
        }
    }

    // MARK: - 0. REST HERO — scenic backdrop + sleep-performance gauge (Bevel)

    /// The fill fraction (0…1) the Rest hero gauge animates to — the night's sleep-performance
    /// score over 100. 0 when no score exists (the headline-hours hero shows instead). Cheap, so
    /// it's read every render to drive the draw-in animation.
    func heroScoreFraction(_ model: SleepModel?) -> Double {
        guard let p = model?.performance.latest else { return 0 }
        return min(max(p / 100.0, 0), 1)
    }

    /// The Rest world's opening: a scenic indigo backdrop with — when the night carries a 0–100
    /// sleep-performance score — a layered `BevelGauge` in the Rest gradient; otherwise a big
    /// SF-Rounded hours-slept headline over the same backdrop. A `SourceBadge` states whether the
    /// score is WHOOP's own imported figure or NOOP's on-device estimate. Presentation-only — the
    /// number comes straight from the existing `model.performance.latest` / hours computation. (Bevel)
    @ViewBuilder
    func restHero(_ model: SleepModel) -> some View {
        let score = model.performance.latest
        let frac = heroScoreFraction(model)
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep performance", overline: "Last night", trailing: "Rest")
            // A subtle night atmosphere sits behind the sleep hero ONLY (the Rest world's whisper:
            // faint indigo wash + crescent moon over the near-black canvas, no glow), clipped to the
            // card. Replaces the now-flat ScenicHeroBackground here.
            VStack(spacing: NoopMetrics.space4) {
                if let score {
                    BevelGauge(
                        fraction: frac,
                        stops: StrandPalette.restGradient.stops,
                        tipColor: StrandPalette.restColor,
                        numberText: "\(Int(score.rounded()))",
                        captionText: "of 100",
                        stateText: sleepScoreWord(score),
                        diameter: 184,
                        lineWidth: 15,
                        animatedFraction: heroFraction
                    )
                    .padding(.top, NoopMetrics.space1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Sleep performance \(Int(score.rounded())) of 100")
                } else {
                    // No 0–100 score for the night — lead with hours slept as a big rounded headline
                    // whose minutes tick up on appear (the same count-up the scored hero gets).
                    VStack(spacing: NoopMetrics.space1) {
                        CountUpText(
                            value: model.night.stages.asleep,
                            format: { durationText($0) },
                            font: StrandFont.number(46),
                            color: StrandPalette.restBright
                        )
                        Text("asleep last night")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .padding(.vertical, NoopMetrics.space5)
                    .accessibilityElement(children: .combine)
                }
                SourceBadge("\(score != nil ? model.performanceSource.badge : SleepPerformanceSource.onDevice.badge)",
                            tint: StrandPalette.restColor)
            }
            .padding(NoopMetrics.cardInnerPadding + NoopMetrics.space1)
            .frame(maxWidth: .infinity)
            .timeOfDayBackground(.night)
            .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        }
    }

    /// A short Rest state word for the hero gauge — same banding the synthesis hero uses.
    func sleepScoreWord(_ score: Double) -> String {
        switch score {
        case ..<50:  return "Poor"
        case ..<70:  return "Fair"
        case ..<85:  return "Good"
        default:     return "Optimal"
        }
    }

    // The hero badge reads `model.performanceSource`, resolved by `SleepPerformanceResolver` from the SAME
    // day the displayed score comes from (the newest day that HAS a score), not from `repo.days.last`.

    // MARK: - Provenance for the displayed night (COMPONENT 4, spec 2026-06-20)

    /// The REAL per-day merge winner for the DISPLAYED night's sleep numbers, as the same brand wording the
    /// By-Day badge / Today / Intelligence use ("On-device" / "Whoop"). A WHOOP export covering the night's
    /// wake-day wins the dashboard merge (imports win field-by-field, Repository.mergeDaily), so the badge
    /// says "Whoop"; otherwise the night was scored on-device by NOOP. Keyed by the night's LOCAL wake-day
    /// (the `mergeSleep` / importer convention, sleep is filed under the day you woke), so a navigated past
    /// night reads its OWN provenance, not last night's. Honest: never a blanket "on-device". Apple Health
    /// carries no sleep into `importedSleep`, so the sleep merge winner is only ever Whoop vs on-device. (C4)
    func nightSource(_ night: Night) -> String {
        let wakeDay = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(night.session.endTs)))
        return SleepPerformanceResolver.nightSource(wakeDay: wakeDay, imported: repo.importedSleep).badge
    }

    // MARK: - 0b. SLEEP MARKS — tap to log "going to sleep" / "I'm awake" (#461, Phase 1)

    /// A compact additive card with two buttons. Tapping logs a timestamped sleep-mark — persisted to
    /// the `sleep_mark` metric series AND appended to the shareable strap log — then confirms with a
    /// haptic and a transient line. LOGGING ONLY: a mark never touches the sleep detector or the night
    /// boundaries on this screen; it's a record for later tap-driven sleep bounds + calibration.
    @ViewBuilder
    var sleepMarkCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep marks", overline: "Tap to log", trailing: "Phase 1")
            NoopCard(tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    Text("Tap when you're heading to bed or when you wake. Each tap is logged with the time — it doesn't change tonight's detected sleep.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: NoopMetrics.gap) {
                        // Routed through the unified NoopButton system so the two marks sit identically
                        // (sentence-case label, leading icon at 8pt, controlHeight=48, no glow).
                        NoopButton("Going to sleep", systemImage: "moon.zzz.fill",
                                   kind: .secondary, fullWidth: true) { logMark(.bedtime) }
                            .accessibilityLabel("Log going to sleep")

                        NoopButton("I'm awake", systemImage: "sun.max.fill",
                                   kind: .secondary, fullWidth: true) { logMark(.wake) }
                            .accessibilityLabel("Log waking up")
                    }
                    if let lastMark {
                        Text(lastMark.confirmation)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.restColor)
                            .transition(.opacity)
                            .accessibilityLabel(lastMark.confirmation)
                    }
                }
            }
        }
        // A success haptic lands when a new mark is captured (value-driven, not per-tap), matching the
        // app's sparse tactile vocabulary. No-op on macOS.
        .strandHaptic(.success, trigger: lastMark?.tsMs ?? 0)
    }

    /// Persist + log a tapped mark. Optimistically shows the confirmation immediately, fires the
    /// haptic via `lastMark`, appends the human-readable strap-log line, then writes the metric-series
    /// row through the repo's live store handle (no new Repository API, no schema change). The write is
    /// idempotent by (deviceId, day, key). (#461)
    func logMark(_ type: SleepMarkType) {
        let mark = SleepMark(type: type)
        withAnimation(.easeOut(duration: 0.2)) { lastMark = mark }
        // The shareable strap log is the human-readable surface that lands in a debug export.
        live.append(log: mark.logLine)
        Task {
            guard let store = await repo.storeHandle() else { return }
            try? await store.upsertMetricSeries([mark.metricPoint], deviceId: repo.deviceId)
        }
    }

    // MARK: - 1. HERO — stage breakdown

    @ViewBuilder
    func hero(_ model: SleepModel) -> some View {
        // Offset 0 reads the memoized latest night; navigated offsets read the cached
        // `navNight` — never a fresh decode here (this runs on every 1Hz HR tick). When a
        // navigated session decoded to no usable stages, the header stays on that REAL
        // session's date/times with an honest placeholder in the chart slot — never the
        // latest night silently rendered under a navigated label. (#160)
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            if nightOffset == 0 {
                nightNavHeader(trailing: model.night.spanLabel)
                sleepWindowRow(model.night)
                stageCard(model.night, intervals: model.intervals)
                napSection(model.night)
            } else if let night = navNight {
                nightNavHeader(trailing: night.spanLabel)
                sleepWindowRow(night)
                stageCard(night, intervals: night.intervals)
                napSection(night)
            } else if let session = sessionRow(at: nightOffset) {
                // Stage-less stub purely to reuse Night's date/time formatting.
                let stub = Night(session: session, stages: Stages(awake: 0, light: 0, deep: 0, rem: 0),
                                 sourceBlocks: dayBlocks(at: nightOffset),
                                 habitualMidsleepSec: habitualMidsleepSec)
                nightNavHeader(trailing: stub.spanLabel)
                sleepWindowRow(stub)
                ChartCard(
                    title: "Stage breakdown",
                    subtitle: "\(durationText(Double(session.endTs - session.startTs) / 60.0)) in bed",
                    height: NoopMetrics.chartHeight,
                    tint: StrandPalette.restColor,
                    chart: { noStagePlaceholder }
                )
                napSection(stub)
            }
        }
    }

    /// Naps card (#508): each of the day's sleep blocks OTHER than the night's main block, individually
    /// editable + deletable with the SAME durable mechanism main sleep uses, plus an "Add nap" affordance.
    /// A nap is always its own session row (never folded into main sleep), so editing or adding one here
    /// never touches the night's main hypnogram and the awake daytime is never mislabelled as light sleep.
    @ViewBuilder
    func napSection(_ night: Night) -> some View {
        // The day's main sleep is the bridged main-night GROUP (#561): a briefly-interrupted / biphasic
        // night's sibling fragments are part of the night, NOT naps. Only blocks OUTSIDE that group are
        // naps. This matches the hero and AnalyticsEngine.analyzeDay; the old `!= editTarget.startTs` split
        // labelled the bridged siblings as phantom naps (#555). The summary stays explainable: Main X /
        // Nap(s) Y / Total Z, with Main = the whole bridged night. (#508, #518, #555)
        let groupStarts = night.mainGroupStarts
        let naps = night.sourceBlocks
            .filter { !groupStarts.contains($0.startTs) }
            .sorted { $0.effectiveStartTs < $1.effectiveStartTs }
        let mainMin = night.stages.total
        let napMin = naps.reduce(0.0) { $0 + Double($1.endTs - $1.effectiveStartTs) / 60.0 }
        // Imported naps of this calendar day (keyed by the nap's LOCAL start day), de-duplicated against
        // the strap-detected naps: an overlap of ≥ 50 % of the shorter one is ONE nap, the imported row wins.
        let entries = NapMerge.merge(imported: importedNapsOnDay(of: night), detected: naps)
        NoopCard(padding: NoopMetrics.cardInnerPadding, tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack {
                    SectionHeader("Naps", overline: "Daytime sleep", trailing: nil)
                    Spacer(minLength: 8)
                    Button { addNap = AddNapSeed(forNight: night) } label: {
                        Label("Add nap", systemImage: "plus.circle.fill")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.restColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add a nap")
                }
                // Daily split (#518): only meaningful once the day has a nap; a single-night day reads
                // exactly as before. Total = main + naps, the time that drives the day's Rest.
                if !naps.isEmpty {
                    napSummaryRow(mainMin: mainMin, napMin: napMin)
                    Divider().overlay(StrandPalette.hairline)
                }
                if entries.isEmpty {
                    Text("No naps recorded for this day.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        switch entry.source {
                        case .detected: napRow(entry.session)
                        case .imported: importedNapRow(entry.session, mergedWithDetected: entry.mergedWithDetected)
                        }
                        if index < entries.count - 1 {
                            Divider().overlay(StrandPalette.hairline)
                        }
                    }
                }
            }
        }
    }

    /// Imported (WHOOP-export) naps that START on the same local calendar day as `night`, oldest first.
    /// They are listed for completeness only: they never enter the Main / Nap(s) / Total split above,
    /// which is the day's Rest, and `isNap` rows are excluded from every nightly computation by the
    /// store's default read.
    func importedNapsOnDay(of night: Night) -> [CachedSleepSession] {
        let anchor = Date(timeIntervalSince1970: TimeInterval(night.sourceBlocks.last?.endTs ?? night.session.endTs))
        return NapMerge.naps(startingOn: anchor, in: importedNaps)
    }

    /// Naps on calendar days that have NO night block (so no per-night Naps card), newest day first.
    /// Without this, a day with only an imported nap would never be visible on the screen.
    @ViewBuilder
    var napOnlyDaysCard: some View {
        let cal = Calendar.current
        let nightDays = Set(navSessions.map { cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.endTs))) })
        let days = NapMerge.napOnlyDays(naps: importedNaps, nightDays: nightDays)
        if !days.isEmpty {
            NoopCard(padding: NoopMetrics.cardInnerPadding, tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    SectionHeader("Naps on other days", overline: "Daytime sleep", trailing: nil)
                    ForEach(Array(days.enumerated()), id: \.offset) { index, entry in
                        Text(entry.day, format: .dateTime.weekday(.wide).day().month(.wide))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                        ForEach(entry.naps, id: \.startTs) { nap in
                            importedNapRow(nap, mergedWithDetected: false)
                        }
                        if index < days.count - 1 {
                            Divider().overlay(StrandPalette.hairline)
                        }
                    }
                }
            }
        }
    }

    /// One read-only imported-nap row: clock window + duration + a caption that it is not part of the
    /// night (or that it stands for the matching strap-detected nap too). No edit/why affordances — an
    /// imported row has no raw stream to re-stage from.
    @ViewBuilder
    func importedNapRow(_ nap: CachedSleepSession, mergedWithDetected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "powersleep")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.restColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(napWindowText(nap)).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text(durationText(Double(nap.endTs - nap.effectiveStartTs) / 60.0))
                    .strandOverline()
                Group {
                    if mergedWithDetected {
                        Text("Imported nap · merged with the nap detected from your strap")
                    } else {
                        Text("Imported nap · not counted in nightly sleep")
                    }
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 8)
        }
        .accessibilityElement(children: .combine)
    }

    /// The Main / Naps / Total split for a day that has at least one nap, so what drives the day's Rest
    /// total is explainable at a glance. Minutes formatted with the shared `durationText`. (#518)
    @ViewBuilder
    func napSummaryRow(mainMin: Double, napMin: Double) -> some View {
        HStack(spacing: 0) {
            napSummaryCell(label: "Main sleep", value: durationText(mainMin))
            Spacer(minLength: 8)
            napSummaryCell(label: "Nap(s)", value: durationText(napMin))
            Spacer(minLength: 8)
            napSummaryCell(label: "Total", value: durationText(mainMin + napMin))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    func napSummaryCell(label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).strandOverline()
            Text(value).font(StrandFont.number(18)).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    /// One nap row: its clock window + an edit affordance opening the SAME `SleepTimeEditor` main sleep
    /// uses. Editing a nap re-stages it from raw over the corrected window and sticks (`userEdited`), and
    /// can never spawn a duplicate (the detected `startTs` PK is immutable) — exactly the #318/#395 path,
    /// here keyed on the nap's own row. (#508)
    @ViewBuilder
    func napRow(_ nap: CachedSleepSession) -> some View {
        let isEdited = nap.userEdited
        HStack(spacing: 10) {
            Image(systemName: "powersleep")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.restColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(napWindowText(nap)).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text(durationText(Double(nap.endTs - nap.effectiveStartTs) / 60.0))
                    .strandOverline()
            }
            Spacer(minLength: 8)
            // C1 — "why this is a nap" explainer: the nap-row nudge that everything other than the chosen
            // main block is logged as a nap, with the Edit next-step. Keyed by the nap's stable startTs so
            // one popover shows at a time across several nap rows. (spec 2026-06-20)
            Button { napWhyStartTs = (napWhyStartTs == nap.startTs) ? nil : nap.startTs } label: {
                Image(systemName: "info.circle")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.restColor)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Why this is logged as a nap")
            .accessibilityLabel("Why this is logged as a nap")
            .popover(isPresented: Binding(
                get: { napWhyStartTs == nap.startTs },
                set: { if !$0 { napWhyStartTs = nil } }), arrowEdge: .bottom) {
                whyPopover(text: "", napSuffix: true)
            }
            Button {
                wakeEdit = WakeEdit(detectedStartTs: nap.startTs,
                                    bedTs: nap.effectiveStartTs,
                                    wakeTs: nap.endTs,
                                    stagesJSON: nap.stagesJSON)
            } label: {
                Image(systemName: isEdited ? "pencil.circle.fill" : "pencil.circle")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.restColor)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit nap times")
            .accessibilityLabel(isEdited ? "Edit nap times (edited)" : "Edit nap times")
        }
    }

    /// "HH:mm–HH:mm" clock window for a nap row (device 12-/24-h setting via the shared Night formatter).
    func napWindowText(_ nap: CachedSleepSession) -> String {
        let start = Night.clockString(nap.effectiveStartTs)
        let end = Night.clockString(nap.endTs)
        return "\(start)–\(end)"
    }

    /// The stage-breakdown ChartCard for a decoded night: hypnogram when intervals
    /// reconstruct, else the proportional stage bar. Intervals are passed in so offset 0
    /// uses the memoized `model.intervals` rather than re-deriving them. (#160)
    @ViewBuilder
    func stageCard(_ night: Night, intervals: [SleepInterval]) -> some View {
        let s = night.stages
        let isPersisted = (night.realSegments?.count ?? 0) >= 2
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            ChartCard(
                title: "Stage breakdown",
                subtitle: "\(durationText(night.timeInBed)) in bed · \(efficiencyText(night)) efficiency"
                    + (isPersisted ? " · stages approximate (on-device)" : ""),
                trailing: durationText(s.asleep),
                height: NoopMetrics.chartHeight,
                tint: StrandPalette.restColor,
                chart: {
                    if intervals.count >= 2 {
                        Hypnogram(intervals: intervals,
                                  height: NoopMetrics.chartHeight,
                                  showsStageAxis: true,
                                  nightStart: night.onsetDate,
                                  showsTimeAxis: true)
                    } else {
                        stageBar(s)
                    }
                },
                footer: {
                    // WHOOP sleep-detail stage rows: swatch + UPPERCASE stage + coloured % + bar +
                    // right-aligned duration. Same minutes/percentages the old footer grid carried.
                    stageBreakdownRows(s)
                }
            )
            // #407 — subordinate movement/restlessness trace UNDER the hypnogram, on the SAME timeline, for
            // the SAME main-night GROUP blocks the hero resolved (mergeDay's group). Shown only for a real
            // (≥2-segment) hypnogram so the strip aligns with a genuine timeline; the proportional stage-bar
            // fallback has no timeline to anchor to. Placed OUTSIDE the fixed-height ChartCard so it doesn't
            // clip the hypnogram. Honest empty state inside `motionStrip` when no group fragment has motion.
            if intervals.count >= 2 {
                motionStrip(night)
            }
            // H9 — when the engine's Rest confidence flags this night's staging as low-confidence (a
            // high-efficiency night whose deep+REM share is implausibly low → a likely staging miss, not
            // a real night with no restorative sleep), say so honestly under the breakdown rather than
            // presenting the suspect split as fact. Read straight from `ScoreConfidence.rest(...)` — the
            // SAME engine call the daily pass uses — so the badge can never disagree with the score.
            if stageStagingIsLowConfidence(night) {
                stageLowConfidenceNote
            }
        }
    }

    /// #407 — the per-epoch movement/restlessness strip drawn UNDER the hypnogram, on the SAME timeline.
    /// Reads the already-resolved main-night GROUP's persisted motion off `night.motionEpochs` (laid
    /// fragment-by-fragment in `mergeDay`, NO re-resolution of the night). The left inset (44pt axis + 12pt
    /// spacing) matches the Hypnogram's `HStack` so the strip's plot lines up under the stage bands above.
    /// When the night has no persisted motion (older rows whose `motionJSON` is NULL) it shows an HONEST
    /// empty note rather than a fabricated flat zero trace.
    @ViewBuilder
    func motionStrip(_ night: Night) -> some View {
        HStack(alignment: .center, spacing: 0) {
            // 44 = Hypnogram axis width; 12 = its HStack spacing — keep the strip's plot under the bands.
            Text("Move")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 44, alignment: .trailing)
            Spacer().frame(width: 12)
            if night.motionEpochs.count >= 2 {
                MotionTrace(epochs: night.motionEpochs, height: 40, tint: StrandPalette.restColor)
            } else {
                Text("No movement detail for this night")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .accessibilityLabel(Text("No movement detail recorded for this night"))
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// H9 — true when this night's staging is LOW-CONFIDENCE: a high-efficiency night (lots of measured
    /// sleep) whose restorative (deep+REM) share is implausibly low, which the EEG-free classifier is far
    /// more likely to have mis-staged than a genuine night with no deep or REM. Delegates to the engine's
    /// pure `ScoreConfidence.rest(...)` H9 overload (efficiency in [0,1], seconds for the totals) so the UI
    /// and the persisted Rest confidence agree by construction. Needs staged sleep + a real efficiency
    /// reading; a pooled/no-stage or unknown-efficiency night is never flagged (its base tier already
    /// reads honestly). (#H9)
    func stageStagingIsLowConfidence(_ night: Night) -> Bool {
        let s = night.stages
        guard let effPct = efficiencyPct(night) else { return false }
        return SleepView.isStagingLowConfidence(
            asleepMin: s.asleep, deepMin: s.deep, remMin: s.rem, efficiency: effPct / 100.0)
    }

    /// Pure H9 gate (unit-testable without a live view) — true when a night's staging is low-confidence:
    /// a high-efficiency night whose deep+REM share is below the restorative floor. Built on the engine's
    /// own `ScoreConfidence.rest(...)` so the UI flag and the persisted Rest confidence agree. `asleepMin`,
    /// `deepMin`, `remMin` are minutes; `efficiency` is asleep/in-bed in [0,1]. Returns false for an unstaged
    /// or zero-asleep night (no staging to doubt). Mirror EXACTLY in Kotlin. (#H9)
    static func isStagingLowConfidence(asleepMin: Double, deepMin: Double, remMin: Double,
                                       efficiency: Double) -> Bool {
        guard asleepMin > 0 else { return false }
        let restorativeMin = max(0, deepMin) + max(0, remMin)
        // An UNSTAGED night (no deep+REM at all) has no staging split to doubt — its base Rest
        // confidence already reads honestly as `.building` (NOT a downgrade), so it must never be
        // flagged. Only a night that DID stage some sleep can be a suspicious "high efficiency yet
        // implausibly little restorative" staging miss.
        guard restorativeMin > 0 else { return false }
        let tier = ScoreConfidence.rest(
            hasSession: true,
            hasStagedSleep: true,
            asleepSeconds: asleepMin * 60.0,
            restorativeSeconds: restorativeMin * 60.0,
            efficiency: efficiency)
        // The H9 overload only DOWNGRADES solid → building on the suspicious case; a genuinely
        // low-restorative-AND-low-efficiency night keeps its honest base tier and isn't flagged here.
        return tier == .building
            && (restorativeMin / asleepMin) < ScoreConfidence.restorativeLowConfidenceShare
            && efficiency >= ScoreConfidence.highEfficiencyThreshold
    }

    /// The H9 low-confidence note shown beneath the stage breakdown — a warning-tinted badge plus a
    /// one-line honest explanation. No faked stages, no tanked score; just a clear "treat this split with
    /// care" so a user doesn't read a likely staging miss as a real deep/REM drought. (#H9)
    var stageLowConfidenceNote: some View {
        HStack(alignment: .top, spacing: 8) {
            SourceBadge("Low confidence", tint: StrandPalette.statusWarning)
            Text("This night scored high efficiency but very little deep or REM — more likely a staging estimate miss than a real restorative shortfall. The totals are kept as-is; read the split with care.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Low confidence staging. This night scored high efficiency but very little deep or REM, more likely an estimate miss than a real restorative shortfall.")
    }

    /// The night's clock window — when you fell asleep and when you woke — as its own clearly
    /// labelled row. These were previously only in the nav-header's trailing caption, which
    /// truncates between the two chevrons on a phone, so in practice the two times people look for
    /// first were effectively hidden. The header now carries just the date span.
    @ViewBuilder
    func sleepWindowRow(_ night: Night) -> some View {
        // A frosted Rest-tinted card (was a flat surfaceRaised block) so the window row sits in the
        // same colour world as the rest of the screen. Bevel treatment — content unchanged.
        NoopCard(padding: NoopMetrics.cardInnerPadding, tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                HStack(spacing: 0) {
                    sleepTime(icon: "moon.zzz.fill", label: "Asleep", value: night.onsetText)
                    Spacer(minLength: 12)
                    Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 30)
                    Spacer(minLength: 12)
                    sleepTime(icon: "sun.max.fill", label: "Woke", value: night.wakeText)
                    Spacer(minLength: 8)
                    wakeEditButton(night)
                }
                .frame(maxWidth: .infinity)
                // Provenance (C4) + the "why this is your main sleep" explainer (C1). The badge names the
                // REAL per-day merge winner; the info button reveals the foundation reason for the pick.
                Divider().overlay(StrandPalette.hairline)
                mainSleepFooter(night)
            }
        }
    }

    /// The hero's footer: the night's provenance badge (the real merge winner) next to a tappable "why
    /// this is your main sleep" affordance. Tapping reveals the foundation `MainNightReason` copy in a
    /// popover, so the pick is explainable on the spot without leaving the hero. (spec 2026-06-20 C1/C4)
    @ViewBuilder
    func mainSleepFooter(_ night: Night) -> some View {
        HStack(spacing: 10) {
            // C4 — provenance. Dynamic String into the badge slot, so wrap in "\()" (the
            // String vs LocalizedStringKey SwiftUI footgun) to show it verbatim, not as a lookup key.
            SourceBadge("\(nightSource(night))", tint: StrandPalette.restColor)
            Spacer(minLength: 8)
            if mainSleepReasonText(night) != nil {
                Button { showMainSleepWhy.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "info.circle")
                        Text("Why this sleep?")
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.restColor)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Why this is your main sleep")
                .accessibilityLabel("Why this is your main sleep")
                .popover(isPresented: $showMainSleepWhy, arrowEdge: .bottom) {
                    whyPopover(text: mainSleepReasonText(night) ?? "", napSuffix: false)
                }
            }
        }
    }

    /// A compact explainer popover: the verbatim foundation reason text, with the nap suffix appended for a
    /// nap row. Plain English, no jargon, no em-dashes (the words come straight from `mainSleepReasonText`
    /// and the spec's nap-row suffix). Sized for both macOS and iOS. (spec 2026-06-20 C1)
    @ViewBuilder
    func whyPopover(text: String, napSuffix: Bool) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(spacing: NoopMetrics.space2) {
                Image(systemName: "moon.stars.fill")
                    .foregroundStyle(StrandPalette.restColor)
                    .accessibilityHidden(true)
                Text(napSuffix ? "About this nap" : "About your main sleep")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            if !text.isEmpty {
                Text(text)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if napSuffix {
                Text("Logged as a nap. Wrong? Tap Edit to adjust your sleep and wake times.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(NoopMetrics.cardInnerPadding)
        .frame(width: 260)
        .background(StrandPalette.surfaceOverlay)
        .accessibilityElement(children: .combine)
    }

    func sleepTime(icon: String, label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.restColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).strandOverline()
                Text(value).font(StrandFont.number(22)).foregroundStyle(StrandPalette.textPrimary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Pencil affordance that opens the wake-time editor for `night`. Auto-detection misreads the wake
    /// time most often (a late lie-in, or a morning stir read as still-asleep), so a one-tap correction
    /// lives right next to the "Woke" value. A filled pencil marks a night already hand-corrected. (#318)
    ///
    /// The hero shows a MERGED/synthetic Night — its `session` carries no `stagesJSON` and a reset
    /// `userEdited` (mergeDay), with the real stage data in `night.stages`. So resolve the actual stored
    /// block we're editing — the one whose wake time IS the night's wake — and edit against its detected
    /// startTs key, current effective bed/wake (to seed the pickers), stagesJSON, and edited state.
    @ViewBuilder
    func wakeEditButton(_ night: Night) -> some View {
        // Resolve the real stored block by identity (the night's main block), never by re-scanning
        // `allSessions` for a wake-time match — that guess could pick the wrong source/night and, when
        // it missed, fall back to the synthetic effective onset (not a real key) so the edit no-oped.
        if let target = night.editTarget {
            let isEdited = target.userEdited
            Button {
                wakeEdit = WakeEdit(detectedStartTs: target.startTs,
                                    bedTs: target.effectiveStartTs,
                                    wakeTs: target.endTs,
                                    stagesJSON: target.stagesJSON)
            } label: {
                Image(systemName: isEdited ? "pencil.circle.fill" : "pencil.circle")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.restColor)
            }
            .buttonStyle(.plain)
            .help("Edit sleep times")
            .accessibilityLabel(isEdited ? "Edit sleep times (edited)" : "Edit sleep times")
        }
    }

    /// Full-width proportional stacked stage bar (fallback when no intervals).
    @ViewBuilder
    func stageBar(_ s: Stages) -> some View {
        let total = max(1, s.total)
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    segment(.deep, s.deep, total, geo.size.width)
                    segment(.light, s.light, total, geo.size.width)
                    segment(.rem, s.rem, total, geo.size.width)
                    segment(.awake, s.awake, total, geo.size.width)
                }
            }
            .frame(height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sleep stage breakdown: deep \(pct(s.deep, s.total)) percent, light \(pct(s.light, s.total)) percent, REM \(pct(s.rem, s.total)) percent, awake \(pct(s.awake, s.total)) percent")
            HStack(spacing: 16) {
                legend(.deep, "Deep")
                legend(.light, "Light")
                legend(.rem, "REM")
                legend(.awake, "Awake")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    func segment(_ stage: SleepStage, _ minutes: Double, _ total: Double, _ width: CGFloat) -> some View {
        let w = CGFloat(minutes / total) * width
        Rectangle()
            .fill(StrandPalette.sleepStageColor(stage))
            .frame(width: max(0, w))
    }

    @ViewBuilder
    func legend(_ stage: SleepStage, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(StrandPalette.sleepStageColor(stage))
                .frame(width: 9, height: 9)
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: - WHOOP stage rows (swatch + UPPERCASE stage + coloured % + bar + duration)

    /// The four stage rows that replace the old footer "label · value" grid, read like WHOOP's sleep
    /// detail: a colour swatch, the UPPERCASE stage name, the share-of-night % in the stage colour, a
    /// proportional bar in the stage colour over a faint track, and the right-aligned duration. Same data
    /// as the prior footer (`s.rem` / `s.deep` / `s.light` / `s.awake` over `s.total`) — no new numbers.
    @ViewBuilder
    func stageBreakdownRows(_ s: Stages) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
            stageBreakdownRow(.rem,   minutes: s.rem,   total: s.total)
            stageBreakdownRow(.deep,  minutes: s.deep,  total: s.total)
            stageBreakdownRow(.light, minutes: s.light, total: s.total)
            stageBreakdownRow(.awake, minutes: s.awake, total: s.total)
        }
    }

    /// One WHOOP-style stage row. `fraction = minutes / total` sets both the % and the bar fill.
    @ViewBuilder
    func stageBreakdownRow(_ stage: SleepStage, minutes: Double, total: Double) -> some View {
        let color = StrandPalette.sleepStageColor(stage)
        let fraction = total > 0 ? min(1, max(0, minutes / total)) : 0
        let percent = Int((fraction * 100).rounded())
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(stage.label.uppercased())
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 56, alignment: .leading)
            Text("\(percent)%")
                .font(StrandFont.captionNumber)
                .foregroundStyle(color)
                .frame(width: 38, alignment: .leading)
            // The NOOP signature: a segmented PipBar that counts up to the share-of-night fraction,
            // tinted in the stage colour over the canonical inset track. Flat, crisp, no glow.
            PipBar(value: fraction * 100, segments: 20, tint: color, height: 8)
            Text(durationText(minutes))
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 60, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stage.label): \(durationText(minutes)), \(percent) percent of the night")
    }

    // MARK: - 2. Metric grid (UNIFORM fixed-height StatTiles, each with sparkline)

    @ViewBuilder
    func metricGrid(_ model: SleepModel) -> some View {
        // Per-tile latest value + history series (for the sparkline) + typical mean.
        // All seven series are computed ONCE in the model build (each is a full pass over
        // repo.days/repo.sleeps) — here we only read the memoized results.
        let perf  = model.performance
        let eff   = model.efficiency
        let cons  = model.consistency
        let need  = model.hoursVsNeeded
        let rest  = model.restorative
        let resp  = model.respiratory
        let debt  = model.sleepDebt

        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Night detail", overline: "Metrics", trailing: "vs typical")
            LazyVGrid(columns: tileColumns, alignment: .leading, spacing: NoopMetrics.gap) {

                StatTile(
                    label: "Rest",
                    value: pctValue(perf.latest),
                    caption: vsTypical(perf.latest, perf.typical, suffix: "%"),
                    accent: perf.latest.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
                    sparkline: spark(perf.series),
                    sparkColor: StrandPalette.restColor)

                StatTile(
                    label: "Efficiency",
                    value: pctValue(eff.latest),
                    caption: vsTypical(eff.latest, eff.typical, suffix: "%"),
                    accent: StrandPalette.statusPositive,
                    sparkline: spark(eff.series),
                    sparkColor: StrandPalette.statusPositive)

                StatTile(
                    label: "Consistency",
                    value: pctValue(cons.latest),
                    caption: vsTypical(cons.latest, cons.typical, suffix: "%"),
                    accent: cons.latest.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
                    sparkline: spark(cons.series),
                    sparkColor: StrandPalette.metricCyan)

                StatTile(
                    label: "Hours vs Needed",
                    value: pctValue(need.latest),
                    caption: vsTypical(need.latest, need.typical, suffix: "%"),
                    accent: need.latest.map { StrandPalette.recoveryColor(min(100, $0)) } ?? StrandPalette.textPrimary,
                    sparkline: spark(need.series),
                    sparkColor: StrandPalette.restColor)

                StatTile(
                    label: "Restorative",
                    value: pctValue(rest.latest),
                    caption: vsTypical(rest.latest, rest.typical, suffix: "%"),
                    accent: StrandPalette.sleepREM,
                    sparkline: spark(rest.series),
                    sparkColor: StrandPalette.sleepREM)

                StatTile(
                    label: "Respiratory",
                    value: rrValue(resp.latest),
                    caption: vsTypical(resp.latest, resp.typical, suffix: " rpm", decimals: 1),
                    accent: StrandPalette.metricPurple,
                    sparkline: spark(resp.series),
                    sparkColor: StrandPalette.metricPurple)

                StatTile(
                    label: "Sleep Debt",
                    value: debt.latest.map { durationText($0) } ?? "—",
                    caption: debtCaption(debt.latest),
                    accent: debtColor(debt.latest),
                    sparkline: spark(debt.series),
                    sparkColor: StrandPalette.metricRose)
            }
        }
    }

    // MARK: - 2b. Sleep-debt ledger (rolling 14-night running balance)

    /// A running balance of (slept − personal need) across the recent fortnight, surfaced
    /// as one card: the net debt/surplus headline, a plain-English read, and a diverging
    /// bar of each night's delta (surplus above the line, deficit below). Honest: a simple
    /// accumulator — a surplus night offsets a deficit one — capped at 14 nights, no-data
    /// nights skipped. (#242)
    @ViewBuilder
    func sleepDebtLedger(_ model: SleepModel) -> some View {
        let ledger = model.sleepDebtLedger
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep-debt ledger", overline: "Last 14 nights",
                          trailing: "running balance")
            NoopCard(tint: StrandPalette.restColor) {
                if ledger.nightCount == 0 {
                    Text("No nights with sleep data yet — your ledger fills in as you wear the strap to bed.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                        // Headline: net balance (count-up on appear) + the short tag (DEBT / SURPLUS / ON
                        // TARGET). The number ticks from the accumulated magnitude via the same formatter.
                        HStack(alignment: .firstTextBaseline) {
                            CountUpText(
                                value: ledger.magnitudeMin,
                                format: { debtHeadline(forMagnitudeMin: $0, ledger: ledger) },
                                font: StrandFont.number(26),
                                color: debtBalanceColor(ledger)
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            Spacer(minLength: NoopMetrics.space2)
                            Text(debtTag(ledger))
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(debtBalanceColor(ledger))
                        }
                        // Plain-English read.
                        Text(debtRead(ledger))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // Per-night diverging delta bars (surplus up, deficit down).
                        debtDeltaBars(ledger)
                        Divider().overlay(StrandPalette.hairline)
                        ChartFooter([
                            ("Balance", debtSigned(ledger.balanceMin)),
                            ("Per-night need", durationText(ledger.needMin)),
                            ("Nights", "\(ledger.nightCount)"),
                        ])
                    }
                }
            }
        }
    }

    /// The diverging per-night delta strip: each night a bar from the centre line — up
    /// (accent) for a surplus, down (rose) for a deficit — scaled to the largest |delta|.
    @ViewBuilder
    func debtDeltaBars(_ ledger: SleepDebtLedger) -> some View {
        let deltas = ledger.nights.map { $0.deltaMin }
        let scale = max(deltas.map { abs($0) }.max() ?? 1, 1)
        GeometryReader { geo in
            let n = max(deltas.count, 1)
            let slot = geo.size.width / CGFloat(n)
            let barW = max(2, slot * 0.6)
            let midY = geo.size.height / 2
            ZStack(alignment: .topLeading) {
                // Centre (zero) line.
                Rectangle()
                    .fill(StrandPalette.hairline)
                    .frame(height: 1)
                    .position(x: geo.size.width / 2, y: midY)
                ForEach(Array(deltas.enumerated()), id: \.offset) { i, d in
                    let frac = CGFloat(abs(d) / scale)
                    let h = max(2, frac * (midY - 2))
                    let x = slot * CGFloat(i) + slot / 2
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(d >= 0 ? StrandPalette.accent : StrandPalette.metricRose)
                        .frame(width: barW, height: h)
                        // Surplus grows upward from the centre, deficit downward.
                        .position(x: x, y: d >= 0 ? midY - h / 2 : midY + h / 2)
                }
            }
        }
        .frame(height: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Per-night sleep balance: \(ledger.nightCount) nights, net \(debtSigned(ledger.balanceMin))")
    }

    // MARK: - 3. Stages vs typical

    @ViewBuilder
    func stagesVsTypical(_ model: SleepModel) -> some View {
        let s = model.night.stages
        // Per-stage typical means are computed ONCE in the model build (each a full pass
        // over repo.days) and read here.
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Stages vs typical", overline: "Last night",
                          trailing: "hatch = typical")
            NoopCard(tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    stageRow(stage: "Deep",  last: s.deep,  typical: model.typicalDeepMin,  nightTotal: s.total, color: StrandPalette.sleepDeep)
                    Divider().overlay(StrandPalette.hairline)
                    stageRow(stage: "REM",   last: s.rem,   typical: model.typicalRemMin,   nightTotal: s.total, color: StrandPalette.sleepREM)
                    Divider().overlay(StrandPalette.hairline)
                    stageRow(stage: "Light", last: s.light, typical: model.typicalLightMin, nightTotal: s.total, color: StrandPalette.sleepLight)
                }
            }
        }
    }

    /// One stage row, WHOOP sleep-detail style: a colour swatch + UPPERCASE stage + the share-of-night %
    /// (in the stage colour), then a bar that reads "solid = you, hatch = the context" — a diagonal-hatch
    /// track spanning the TYPICAL (the personal mean for this stage) with the user's last-night value as a
    /// solid coloured fill on top, plus a thin marker at the typical mean and the right-aligned duration.
    /// Same data as before (`last` minutes, `typical` personal mean) — the hatch just renders the typical
    /// context the prior vertical-only marker implied.
    @ViewBuilder
    func stageRow(stage label: String, last: Double, typical: Double?, nightTotal: Double, color: Color) -> some View {
        // Scale both values against a shared per-row max so the typical hatch + marker are meaningful.
        let scaleMax = max(last, typical ?? 0) * 1.18
        let max = scaleMax > 0 ? scaleMax : 1
        // Share of the night this stage took (drives the WHOOP coloured %); over time-in-bed, matching the
        // stage-breakdown rows above.
        let sharePct = nightTotal > 0 ? Int((last / nightTotal * 100).rounded()) : 0
        let deltaText: String = {
            guard let typical, typical > 0 else { return "" }
            let diff = last - typical
            let sign = diff >= 0 ? "+" : "−"
            return "\(sign)\(durationText(abs(diff))) vs typ"
        }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text(label.uppercased())
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("\(sharePct)%")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(color)
                Spacer()
                Text(durationText(last)).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                if !deltaText.isEmpty {
                    Text(deltaText)
                        .font(StrandFont.footnote)
                        .foregroundStyle(last >= (typical ?? last) ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                }
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    // Track.
                    Capsule(style: .continuous)
                        .fill(StrandPalette.surfaceInset)
                    // Typical-range CONTEXT: a diagonal-hatch track spanning the personal mean for this
                    // stage. "Hatch = the context" — the user's solid value sits over it.
                    if let typical, typical > 0 {
                        DiagonalHatch(spacing: 5, lineWidth: 1)
                            .stroke(color.opacity(0.5), lineWidth: 1)
                            .frame(width: w * CGFloat(min(1, typical / max)))
                            .clipShape(Capsule(style: .continuous))
                    }
                    // Last-night SOLID value fill — "solid = you".
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: w * CGFloat(min(1, last / max)))
                    // Crisp typical-mean marker so the exact mean still reads at a glance.
                    if let typical, typical > 0 {
                        Rectangle()
                            .fill(StrandPalette.textPrimary)
                            .frame(width: 2, height: 16)
                            .position(x: w * CGFloat(min(1, typical / max)), y: 5)
                    }
                }
            }
            .frame(height: 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label): \(durationText(last)) last night, \(sharePct) percent of the night\(typical.map { ", typical \(durationText($0))" } ?? "")")
        }
    }

    // MARK: - 4. 30-day asleep-hours trend

    @ViewBuilder
    func durationTrend(_ model: SleepModel) -> some View {
        // Trailing-30 trend points and the typical total are precomputed in the model build
        // (full passes over repo.days) — read here, not recomputed per render.
        let pts = model.trendPoints
        let avg = model.typicalTotalMin.map { $0 / 60.0 }
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Asleep duration", overline: "Trend", trailing: "Last 30 days")
            ChartCard(
                title: "Hours asleep",
                subtitle: "Per night, trailing 30 days",
                trailing: avg.map { String(format: "%.1f h avg", $0) },
                height: NoopMetrics.chartHeight,
                tint: StrandPalette.restColor,
                chart: {
                    if pts.count >= 2 {
                        TrendChart(points: pts,
                                   gradient: StrandPalette.restGradient,
                                   valueRange: trendRange(pts),
                                   showsArea: true,
                                   height: NoopMetrics.chartHeight,
                                   valueFormat: { String(format: "%.1f h", $0) },
                                   accessibilityLabel: "Hours asleep trend")
                    } else {
                        sparsePlaceholder
                    }
                },
                footer: {
                    ChartFooter([
                        ("Avg",    avg.map { String(format: "%.1f h", $0) } ?? "—"),
                        ("Min",    pts.map(\.value).min().map { String(format: "%.1f h", $0) } ?? "—"),
                        ("Max",    pts.map(\.value).max().map { String(format: "%.1f h", $0) } ?? "—"),
                        ("Nights", "\(pts.count)"),
                    ])
                }
            )
        }
    }

    // MARK: - Memoization plumbing

    /// A cheap fingerprint of the repo inputs this screen derives from. Recomputed every
    /// render but only contains counts + the identity of the newest/oldest rows, so equality
    /// is fast. When it changes we know `repo.days`/`repo.sleeps` actually changed and the
    /// memoized `model` must be rebuilt; otherwise hover/animation/1Hz HR re-renders are free.
    var dataKey: SleepInputKey {
        SleepInputKey(
            loaded: repo.loaded,
            daysCount: repo.days.count,
            sleepsCount: repo.sleeps.count,
            firstDay: repo.days.first?.day,
            lastDay: repo.days.last?.day,
            lastDayUpdated: repo.days.last,
            lastSleep: repo.sleeps.last,
            refreshSeq: repo.refreshSeq)
    }

    /// Build every expensive derivation exactly once. Called only when `dataKey` changes,
    /// so each full pass over repo.days / repo.sleeps runs once per data change rather than
    /// once per render. Returns nil when there is no usable latest night (renders empty state).
    func buildModel() -> SleepModel? {
        guard let night = latestNight else { return nil }
        return SleepModel(
            night: night,
            intervals: night.intervals,
            isPersistedHypnogram: (night.realSegments?.count ?? 0) >= 2,
            performance: performanceSeries,
            performanceSource: SleepPerformanceResolver.source(of: performancePoints),
            efficiency: efficiencySeries,
            consistency: consistencySeries,
            hoursVsNeeded: hoursVsNeededSeries,
            restorative: restorativeSeries,
            respiratory: respiratorySeries,
            sleepDebt: sleepDebtSeries,
            typicalTotalMin: typicalTotalMin,
            typicalDeepMin: typicalStageMin(\.deepMin),
            typicalRemMin: typicalStageMin(\.remMin),
            typicalLightMin: typicalStageMin(\.lightMin),
            trendPoints: durationTrendPoints,
            sleepDebtLedger: debtLedger)
    }

    /// The rolling 14-night sleep-debt ledger from the cached daily metrics. Uses the
    /// SAME personal sleep need the tiles use (`sleepNeedMin`, ≥ 7.5 h, the per-user
    /// override over the 8 h default), measured against each night's `totalSleepMin`.
    /// Skips nights with no sleep (the analytics function does the skip). (#242)
    var debtLedger: SleepDebtLedger {
        SleepDebt.ledger(
            series: repo.days.map { (day: $0.day, totalSleepMin: $0.totalSleepMin) },
            needHours: sleepNeedMin / 60.0)
    }

    // MARK: - Derived model

    /// The most recent sleep, decoded into stage durations. TWO stagesJSON formats exist:
    /// imported nights store a dict of MINUTES {"light","deep","rem","awake"}; on-device computed
    /// nights store a SEGMENT ARRAY [{start,end,stage}] (AnalyticsEngine.encodeStages). Only the
    /// dict was decoded before, so a Bluetooth-only user's night vanished from this tab entirely
    /// while Intelligence showed it (#77). Computed nights also carry their REAL timeline now —
    /// the hypnogram draws genuine segments instead of the synthetic reconstruction.
    var latestNight: Night? { decodedNight(at: 0) }

    /// The browsable block list: every sleep session un-deduplicated (incl. same-day naps / split
    /// sleep). Falls back to `repo.sleeps` (one-per-night) until the fuller list loads, so the hero
    /// is never empty during the first frame. (#170)
    var navSessions: [CachedSleepSession] {
        allSessions.isEmpty ? repo.sleeps : allSessions
    }

    /// The browsable DAY list: every block grouped by the calendar day it ENDS on (matching the
    /// dashboard's per-night merge), newest day first, blocks within a day oldest→newest. Each day
    /// is ONE ◀/▶ stop, so a split-sleep day reads as a single night and the "N nights ago" label
    /// stays truthful — two blocks of the same day are never "1 night ago" AND "2 nights ago". (#170)
    var navDays: [[CachedSleepSession]] {
        navDaysCache.days(for: navSessions)
    }

    /// The day's MAIN sleep block — the night people mean by "last night" — and the rest (naps). (#518)
    /// A day can hold an overnight AND an afternoon nap (both end on the same calendar day, so both
    /// bucket here). The pick is the SINGLE shared selector (`SleepStageTotals.mainNightIndex`) the
    /// analytics rollup uses — the LEARNED-TIMING score (asleep span + alignment bonus), NOT a re-derived
    /// overnight gate — so the hero, the edit affordance, the analytics total, and the Sleep tab ALL
    /// resolve to the identical block (the whole point of #525/#547). Delegates to `mainNightSession`,
    /// passing the LEARNED habitual midsleep (the same value the engine threaded into the daily total) so
    /// a shift/late sleeper's hero and analytics total agree — not just at cold-start. (#547)
    func mainBlock(_ sessions: [CachedSleepSession]) -> CachedSleepSession? {
        SleepView.mainNightSession(sessions, habitualMidsleepSec: habitualMidsleepSec)
    }

    /// The device's current UTC offset (seconds east), evaluated once per pick. Feeds the selector's
    /// `offsetSec` so the timing test reads the user's clock via the SAME `offsetSec` math the engine
    /// uses (`SleepStageTotals.localSecOfDay`), instead of `Calendar.current.component(.hour:)` which was
    /// the duplicated, DST-fragile gate the audit flagged. (#547)
    static var tzOffsetSec: Int { TimeZone.current.secondsFromGMT() }

    /// The day's single WINNING main block — the durable-edit anchor (`editTarget`) and the one block whose
    /// learned-timing score won. Scores by learned timing on each block's EFFECTIVE onset (what the user
    /// sees) and returns the owning session. This is the BARE single-block pick (no gap-bridge), because the
    /// edit affordance writes against ONE real row so it must resolve to one block. The HERO display and the
    /// nap split do NOT use this alone: they use `mainNightGroup`, which bridges the winner's adjacent
    /// fragments (a wake gap shorter than `gapBridgeMaxMin`) into ONE night the way `AnalyticsEngine`
    /// does (#561), so a biphasic / briefly-interrupted night is shown as one continuous sleep instead of
    /// phantom naps (#555). `habitualMidsleepSec` is the SAME learned value the engine threads into the
    /// persisted totals (loaded via `repo.habitualMidsleepSec()`), so a shift/late sleeper's pick matches
    /// the analytics rollup; nil keeps the cold-start overnight-band bonus. (#525 / #547 / #561)
    static func mainNightSession(_ sessions: [CachedSleepSession],
                                 habitualMidsleepSec: Int? = nil) -> CachedSleepSession? {
        SleepStageTotals.mainNightIndex(
            sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec).map { sessions[$0] }
    }

    /// The day's MAIN-night GROUP — the winning block PLUS any adjacent fragments bridged into it (a wake
    /// gap shorter than `gapBridgeMaxMin`), so a briefly-interrupted / biphasic night reads as ONE
    /// continuous sleep exactly the way `AnalyticsEngine.analyzeDay` rolls it up for the daily total (#561).
    /// The hero aggregates this whole group and ONLY blocks outside it are naps. Without it the tab used the
    /// un-bridged single-block pick and rendered the bridged siblings as phantom naps (#555). A night with
    /// no bridgeable gap collapses to the single block `mainNightSession` picks, so the common case is byte-
    /// identical. Returns ascending by effective onset. (#561 / #555)
    static func mainNightGroup(_ sessions: [CachedSleepSession],
                               habitualMidsleepSec: Int? = nil) -> [CachedSleepSession] {
        guard let idx = SleepStageTotals.mainNightGroupIndices(
            sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec) else { return [] }
        return idx.map { sessions[$0] }.sorted { $0.effectiveStartTs < $1.effectiveStartTs }
    }

    /// Soft nap-duration hint retained for callers/tests; the nap CLASSIFICATION is now purely "not the
    /// chosen main block" (see `isNap`), never an independent duration/onset test. (#518/#547)
    static let napMaxHours: Double = 3.0
    /// Classify a block as a nap: it's a nap exactly when it is NOT the day's chosen main block. Derived
    /// from the pick (never an independent onset/duration gate), so the label can't contradict the
    /// selection — the contradiction the audit flagged. The main block is never a nap. (#518/#547)
    static func isNap(_ s: CachedSleepSession, main: CachedSleepSession?) -> Bool {
        guard let main else { return false }
        return s.startTs != main.startTs
    }

    // MARK: - Why-this-is-your-main-sleep explainer (COMPONENT 1, spec 2026-06-20)

    /// The verbatim reason copy for the displayed night, with {DUR} filled as "Xh Ym" from the chosen
    /// block's asleep duration — driven entirely by the foundation `MainNightReason`, so the explainer
    /// states exactly what the selector decided (never a re-derived guess). Resolved over the day's blocks
    /// via the same `mainNightSelection` API the analytics pick uses, with the SAME learned habitual the
    /// hero used, so the words match the block the hero shows. nil only when the day has no blocks. (C1)
    func mainSleepReasonText(_ night: Night) -> String? {
        guard let sel = SleepStageTotals.mainNightSelection(
            night.sourceBlocks.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: SleepView.tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec) else { return nil }
        let dur = durationText(sel.asleepMinutes)
        switch sel.reason {
        case .onlyBlock:
            return "This is your only sleep block today."
        case .longest:
            return "Picked as your main sleep because it was your longest block (\(dur))."
        case .longestNearUsual:
            return "Picked as your main sleep because it was your longest block (\(dur)), near your usual bedtime."
        case .alignedToUsual:
            return "Picked as your main sleep because it started near your usual sleep time."
        }
    }

    /// Build the hero `Night` for a day around its MAIN-night GROUP — the winning block PLUS any fragments
    /// a brief wake split it into, bridged the way `AnalyticsEngine.analyzeDay` bridges them (#561), so a
    /// biphasic / interrupted night shows as ONE continuous sleep whose total matches the day's headline.
    /// It does NOT merge the whole day: an afternoon nap sits OUTSIDE the bridged group (its gap exceeds
    /// `gapBridgeMaxMin`), so it never folds in and stays a nap (the impossible 1 AM→5 PM merge #518 guarded
    /// against). Stage minutes are SUMMED over the group (the inter-fragment wake gap belongs to no
    /// fragment, so it is excluded from the minutes exactly as the engine excludes it), the hypnogram lays
    /// each fragment's real timeline end-to-end, and `sourceBlocks` keeps every block so the naps card and
    /// the daily Main/Nap/Total summary can read them. A single-block day is byte-identical to the prior
    /// behaviour. Returns nil if the group decodes to no usable stages. (#170, #318, #518, #555, #561)
    func mergeDay(_ sessions: [CachedSleepSession]) -> Night? {
        let group = SleepView.mainNightGroup(sessions, habitualMidsleepSec: habitualMidsleepSec)
        // Earliest fragment's EFFECTIVE onset (corrected bedtime when present) to the latest wake. (#318)
        guard let first = group.first, let last = group.last else { return nil }
        let onset = first.effectiveStartTs, wake = last.endTs
        var stages = Stages(awake: 0, light: 0, deep: 0, rem: 0)
        var segs: [SleepInterval] = []
        // #407: lay the GROUP's per-epoch motion fragment-by-fragment in the SAME order the stage timeline
        // is laid, reading the already-chosen group's stored series (NOT a re-resolution). The detected key
        // (`startTs`, not `effectiveStartTs`) is the motion store's key. A fragment with no persisted series
        // contributes nothing; if NO fragment has one, `motionEpochs` stays empty → honest empty state.
        var motion: [Double] = []
        for frag in group {
            if let seg = decodeSegments(frag.stagesJSON, sessionStart: frag.effectiveStartTs), seg.stages.total > 0 {
                stages.awake += seg.stages.awake; stages.light += seg.stages.light
                stages.deep  += seg.stages.deep;  stages.rem   += seg.stages.rem
                for iv in seg.intervals {
                    segs.append(SleepInterval(stage: iv.stage, start: iv.start, end: iv.end))
                }
            } else if let st = decodeStages(frag.stagesJSON), st.total > 0 {
                stages.awake += st.awake; stages.light += st.light
                stages.deep  += st.deep;  stages.rem   += st.rem
            }
            if let m = motionByStart[frag.startTs] { motion.append(contentsOf: m) }
        }
        guard stages.asleep > 0 else { return nil }
        let eff = stages.total > 0 ? stages.asleep / stages.total : nil
        let synth = CachedSleepSession(startTs: onset, endTs: wake, efficiency: eff,
                                       restingHr: nil, avgHrv: nil, stagesJSON: nil)
        let realSegs = segs.count >= 2 ? segs.sorted { $0.start < $1.start } : nil
        return Night(session: synth, stages: stages, realSegments: realSegs, sourceBlocks: sessions,
                     motionEpochs: motion, habitualMidsleepSec: habitualMidsleepSec)
    }

    /// The real stored blocks composing the day at `offset` (for the stage-less stub Night, so its edit
    /// affordance still targets a real row). Empty when out of range.
    func dayBlocks(at offset: Int) -> [CachedSleepSession] {
        let days = navDays
        return offset >= 0 && offset < days.count ? days[offset] : []
    }

    /// The merged Night for the DAY `offset` stops back from the most recent (0 = last night).
    /// Backs the hero's ◀/▶ navigation via the `navNight` cache — JSON-decodes, so it only runs
    /// from `buildModel()` and the onChange handlers, never per render. (#160, #170)
    func decodedNight(at offset: Int) -> Night? {
        let days = navDays
        guard offset >= 0, offset < days.count else { return nil }
        return mergeDay(days[offset])
    }

    /// A synthetic session for the DAY `offset` stops back, spanning the MAIN block's window (not the
    /// whole day), for the honest no-stage-data header when the day's blocks don't decode to usable
    /// stages. Using the main block (#518) keeps the stub header on the real night rather than a
    /// 1 AM→5 PM overnight+nap span. (#160, #170)
    func sessionRow(at offset: Int) -> CachedSleepSession? {
        let days = navDays
        guard offset >= 0, offset < days.count, let main = mainBlock(days[offset]) else { return nil }
        return CachedSleepSession(startTs: main.effectiveStartTs, endTs: main.endTs,
                                  efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
    }

    /// Header above the hypnogram with ◀/▶ to browse past nights. ◀ goes older (increasing offset),
    /// ▶ goes newer; each is disabled at its bound. The canonical SectionHeader carries the
    /// hierarchy so the hero reads like every other section. (#160)
    @ViewBuilder
    func nightNavHeader(trailing: String) -> some View {
        let lastIndex = max(navDays.count - 1, 0)
        let title: LocalizedStringKey = nightOffset == 0 ? "Last night"
            : (nightOffset == 1 ? "1 night ago" : "\(nightOffset) nights ago")
        HStack(spacing: NoopMetrics.cardInnerSpacing) {
            Button { if nightOffset < lastIndex { nightOffset += 1 } } label: {
                Image(systemName: "chevron.left")
                    .font(StrandFont.headline)
                    .foregroundStyle(nightOffset >= lastIndex ? StrandPalette.textTertiary : StrandPalette.accent)
            }
            .buttonStyle(.plain)
            .disabled(nightOffset >= lastIndex)
            .accessibilityLabel("Previous night")

            SectionHeader(title, overline: "Sleep", trailing: trailing)

            Button { if nightOffset > 0 { nightOffset -= 1 } } label: {
                Image(systemName: "chevron.right")
                    .font(StrandFont.headline)
                    .foregroundStyle(nightOffset == 0 ? StrandPalette.textTertiary : StrandPalette.accent)
            }
            .buttonStyle(.plain)
            .disabled(nightOffset == 0)
            .accessibilityLabel("Next night")
        }
    }

    /// Mean total sleep duration (minutes) across nights with data — the "typical".
    var typicalTotalMin: Double? {
        mean(repo.days.compactMap { $0.totalSleepMin }.filter { $0 > 0 })
    }

    /// Mean of a per-stage minutes column across days with data.
    func typicalStageMin(_ key: KeyPath<DailyMetric, Double?>) -> Double? {
        mean(repo.days.compactMap { $0[keyPath: key] }.filter { $0 > 0 })
    }

    // MARK: - Per-tile series (latest, typical mean, sparkline history)

    typealias Metric = (latest: Double?, typical: Double?, series: [Double])

    /// Build a metric from a per-day transform, keeping only finite positive-ish values.
    func metric(_ transform: (DailyMetric) -> Double?) -> Metric {
        let series = repo.days.compactMap(transform).filter { $0.isFinite }
        return (series.last, mean(series), series)
    }

    /// Sleep performance %: the imported WHOOP figure (sleep_performance, 0–100) when the
    /// export carried one for that day; else the APPROXIMATE fallback (asleep / personal
    /// need, capped 100) so strap-only days after the import horizon stay populated.
    var performancePoints: [SleepPerformanceResolver.Point] {
        SleepPerformanceResolver.points(days: repo.days, imported: repo.importedSleep, needMin: sleepNeedMin)
    }

    var performanceSeries: Metric {
        let series = performancePoints.map(\.value)
        return (series.last, mean(series), series)
    }

    var efficiencySeries: Metric {
        metric { d in
            guard let e = d.efficiency else { return nil }
            return e <= 1.0 ? e * 100 : e
        }
    }

    /// Consistency, resolved PER DAY by `SleepConsistencyResolver`: the imported sleep_consistency
    /// wins for each day that has it; the APPROXIMATE rolling bedtime-spread score fills the days
    /// without one. A trailing day with no import (today, strap-only) therefore no longer discards
    /// the import-era series.
    var consistencySeries: Metric {
        let series = SleepConsistencyResolver.points(
            days: repo.days, imported: repo.importedSleep, sessions: repo.sleeps,
            dayKey: { Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) }
        ).map(\.value)
        guard !series.isEmpty else { return (nil, nil, []) }
        return (series.last, mean(series), series)
    }

    /// Hours vs needed % = asleep / need (can exceed 100 on a long night). The imported
    /// sleep_need_min wins per day; else the APPROXIMATE personal-mean need.
    var hoursVsNeededSeries: Metric {
        let imported = repo.importedSleep
        let fallbackNeed = sleepNeedMin
        return metric { d in
            guard let asleep = d.totalSleepMin, asleep > 0 else { return nil }
            let need = imported[d.day]?.needMin ?? fallbackNeed
            guard need > 0 else { return nil }
            return asleep / need * 100
        }
    }

    /// Restorative % = (deep + REM) / asleep — the share of the night that does the work.
    var restorativeSeries: Metric {
        metric { d in
            guard let deep = d.deepMin, let rem = d.remMin,
                  let asleep = d.totalSleepMin, asleep > 0 else { return nil }
            return (deep + rem) / asleep * 100
        }
    }

    var respiratorySeries: Metric {
        metric { $0.respRateBpm }
    }

    /// Sleep debt (minutes): the imported sleep_debt_min when the export carried it; else
    /// the APPROXIMATE per-night need − asleep, floored at 0 (no "credit").
    var sleepDebtSeries: Metric {
        let imported = repo.importedSleep
        let need = sleepNeedMin
        let series = repo.days.compactMap { d -> Double? in
            if let debt = imported[d.day]?.debtMin { return debt }   // minutes, export-verbatim
            guard let asleep = d.totalSleepMin, asleep > 0, need > 0 else { return nil }
            return Swift.max(0, need - asleep)   // APPROXIMATE fallback
        }
        return (series.last, mean(series), series)
    }

    /// The personal sleep need (minutes): mean asleep, but never below a 7.5h floor so
    /// debt/performance read sensibly even for a chronically short sleeper.
    var sleepNeedMin: Double {
        Swift.max(450, typicalTotalMin ?? 450)   // 450 min = 7.5h
    }

    // MARK: - Trend points

    /// Trailing 30 days of total sleep, plotted in HOURS. Falls back to all nights with
    /// data if the trailing window is too sparse.
    var durationTrendPoints: [TrendPoint] {
        let fmt = SleepView.dayParser
        func build(_ slice: ArraySlice<DailyMetric>) -> [TrendPoint] {
            slice.compactMap { d -> TrendPoint? in
                guard let mins = d.totalSleepMin, mins > 0,
                      let date = fmt.date(from: d.day) else { return nil }
                return TrendPoint(date: date, value: mins / 60.0)
            }
        }
        let recent = build(repo.days.suffix(30))
        if recent.count >= 2 { return recent }
        return build(repo.days[...])
    }

    func trendRange(_ pts: [TrendPoint]) -> ClosedRange<Double> {
        let vals = pts.map(\.value)
        let lo = Swift.max(0, (vals.min() ?? 0) - 1)
        let hi = (vals.max() ?? 9) + 1
        return lo...Swift.max(hi, lo + 1)
    }

    // MARK: - Empty / sparse states

    @ViewBuilder
    var emptyState: some View {
        // While the strap is mid-offload, say so — "No nights" reads as final otherwise (#77).
        if live.backfilling { SyncingHistoryNote(chunks: live.syncChunksThisSession) }
        if repo.loaded {
            ComingSoon(what: "No nights here yet. Import your WHOOP export in Data Sources to see every night, your sleep stages and trends straight away. Or wear your strap overnight. It syncs automatically and your first night shows up here.")
        } else {
            ComingSoon(what: "Loading your sleep history…")
        }
    }

    var sparsePlaceholder: some View {
        Text("Not enough nights yet.")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Hero chart slot for a NAVIGATED session with no decodable stages — honest about the
    /// gap instead of rendering the latest night under a navigated label. (#160)
    var noStagePlaceholder: some View {
        Text("No stage data recorded for this night.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Formatting helpers

    func pct(_ minutes: Double, _ total: Double) -> Int {
        total > 0 ? Int((minutes / total * 100).rounded()) : 0
    }

    func pctValue(_ v: Double?) -> String {
        v.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    func rrValue(_ v: Double?) -> String {
        v.map { String(format: "%.1f", $0) } ?? "—"
    }

    /// "+12% vs typical" / "−0.4 rpm vs typical" — the latest-vs-mean caption every tile carries.
    func vsTypical(_ latest: Double?, _ typical: Double?, suffix: String, decimals: Int = 0) -> String {
        guard let latest, let typical, typical != 0 else { return "vs typical —" }
        let diff = latest - typical
        let sign = diff >= 0 ? "+" : "−"
        let mag = abs(diff)
        let num = decimals == 0 ? "\(Int(mag.rounded()))" : String(format: "%.\(decimals)f", mag)
        return "\(sign)\(num)\(suffix) vs typical"
    }

    func debtCaption(_ debt: Double?) -> String {
        guard let debt else { return "vs need" }
        return debt < 15 ? "On target" : "Below need"
    }

    func debtColor(_ debt: Double?) -> Color {
        guard let debt else { return StrandPalette.textPrimary }
        switch debt {
        case ..<15:  return StrandPalette.statusPositive
        case ..<60:  return StrandPalette.statusWarning
        default:     return StrandPalette.statusCritical
        }
    }

    // MARK: - Sleep-debt ledger formatting

    /// "≈2h 10m" magnitude headline — leading "≈" because it's an accumulated estimate.
    /// Reads "On target" inside the deadband so a few stray minutes don't show as debt.
    func debtHeadline(_ ledger: SleepDebtLedger) -> String {
        debtHeadline(forMagnitudeMin: ledger.magnitudeMin, ledger: ledger)
    }

    /// The same headline formatter, but for an arbitrary (interpolated) magnitude so `CountUpText` can
    /// render a coherent string on every frame as the number ticks up. The on-target deadband check
    /// uses the LIVE magnitude `m` so the headline crosses from "On target" to "≈…" mid-count exactly
    /// once, matching the final reading. Final-value identical to `debtHeadline(_:)`.
    func debtHeadline(forMagnitudeMin m: Double, ledger: SleepDebtLedger) -> String {
        if m < SleepDebt.onTargetBandMin { return "On target" }
        return "≈\(durationText(m))"
    }

    /// Short tag under/beside the headline: DEBT / SURPLUS / ON TARGET.
    func debtTag(_ ledger: SleepDebtLedger) -> String {
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin { return "balanced" }
        return ledger.isDebt ? "sleep debt" : "surplus"
    }

    /// Plain-English read of the running balance over the window.
    func debtRead(_ ledger: SleepDebtLedger) -> String {
        let nights = ledger.nightCount
        let span = "the last \(nights) night\(nights == 1 ? "" : "s")"
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin {
            return "You're roughly on top of your sleep across \(span) — slept minutes balance out against your need."
        }
        let mag = durationText(ledger.magnitudeMin)
        if ledger.isDebt {
            return "You've banked about \(mag) of sleep debt over \(span). Surplus nights count back against it — an earlier night or two would clear it."
        }
        return "You're carrying about \(mag) of surplus over \(span) — you've slept past your need on balance. Nicely ahead."
    }

    /// Color the balance by sign + size: surplus/within-band → positive green, modest
    /// debt → warning, heavier debt → critical.
    func debtBalanceColor(_ ledger: SleepDebtLedger) -> Color {
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin || !ledger.isDebt {
            return StrandPalette.statusPositive
        }
        // A debt: amber up to ~3 h accumulated, red beyond.
        return ledger.magnitudeMin < 180 ? StrandPalette.statusWarning : StrandPalette.statusCritical
    }

    /// Signed "+1h 20m" / "−2h 10m" / "0m" balance string.
    func debtSigned(_ minutes: Double) -> String {
        if abs(minutes) < 1 { return "0m" }
        let sign = minutes >= 0 ? "+" : "−"
        return "\(sign)\(durationText(abs(minutes)))"
    }

    func efficiencyText(_ night: Night) -> String {
        let e = efficiencyPct(night)
        return e.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    /// Efficiency in percent. Prefer the stored session value, else asleep / time-in-bed.
    func efficiencyPct(_ night: Night) -> Double? {
        if let stored = night.session.efficiency ?? repo.today?.efficiency {
            return stored <= 1.0 ? stored * 100 : stored
        }
        let bed = night.timeInBed
        guard bed > 0 else { return nil }
        return Swift.min(100, night.stages.asleep / bed * 100)
    }

    func durationText(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    /// A sparkline needs at least two points; otherwise return nil so the tile stays clean.
    func spark(_ series: [Double]) -> [Double]? {
        let tail = Array(series.suffix(30))
        return tail.count > 1 ? tail : nil
    }

    func mean(_ vals: [Double]) -> Double? {
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    // MARK: - Stage decoding

    /// Decode the imported stagesJSON dict of MINUTES {"light","deep","rem","awake"}.
    func decodeStages(_ json: String?) -> Stages? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        func val(_ key: String) -> Double {
            if let n = dict[key] as? NSNumber { return n.doubleValue }
            if let d = dict[key] as? Double { return d }
            if let i = dict[key] as? Int { return Double(i) }
            return 0
        }
        let s = Stages(awake: val("awake"), light: val("light"),
                       deep: val("deep"), rem: val("rem"))
        return s.total > 0 ? s : nil
    }

    /// Decode the COMPUTED stagesJSON segment array [{"start":epoch,"end":epoch,"stage":"wake"|
    /// "light"|"deep"|"rem"}] into stage totals plus the real timeline (seconds relative to the
    /// session start, the Hypnogram's domain). The on-device SleepStager calls awake "wake". (#77)
    func decodeSegments(
        _ json: String?, sessionStart: Int
    ) -> (stages: Stages, intervals: [SleepInterval])? {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !arr.isEmpty else { return nil }
        var stages = Stages(awake: 0, light: 0, deep: 0, rem: 0)
        var intervals: [SleepInterval] = []
        for seg in arr {
            guard let start = (seg["start"] as? NSNumber)?.intValue,
                  let end = (seg["end"] as? NSNumber)?.intValue, end > start,
                  let name = seg["stage"] as? String else { continue }
            let minutes = Double(end - start) / 60.0
            let stage: SleepStage
            switch name {
            case "wake", "awake": stage = .awake; stages.awake += minutes
            case "light": stage = .light; stages.light += minutes
            case "deep": stage = .deep; stages.deep += minutes
            case "rem": stage = .rem; stages.rem += minutes
            default: continue
            }
            intervals.append(SleepInterval(
                stage: stage,
                start: TimeInterval(start - sessionStart),
                end: TimeInterval(end - sessionStart)))
        }
        return stages.total > 0 ? (stages, intervals) : nil
    }

    /// yyyy-MM-dd → Date (en_US_POSIX, UTC), per task spec.
    static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Diagonal-hatch track (WHOOP "typical range" context)

/// A repeating set of 45° diagonal lines for the "typical range" context track behind a stage bar
/// ("solid = you, hatch = the context"). Pure geometry — stroke it in the stage colour and clip it to a
/// capsule. `spacing` is the gap between lines; the lines run further than the bounds so the clip edges
/// stay clean. Presentation-only; no data of its own.
struct DiagonalHatch: Shape {
    var spacing: CGFloat = 5
    var lineWidth: CGFloat = 1
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Start well before the left edge so the 45° lines fully cover the rect after the diagonal shear.
        var x = -rect.height
        while x < rect.width {
            p.move(to: CGPoint(x: x, y: rect.height))
            p.addLine(to: CGPoint(x: x + rect.height, y: 0))
            x += spacing
        }
        return p
    }
}

// MARK: - Local value types

/// Cheap, Equatable fingerprint of the repo inputs SleepView derives from. Two snapshots are
/// equal iff the data the screen reads is unchanged, so the heavy `SleepModel` rebuild is
/// skipped on the many `body` re-evaluations that don't touch sleep data.
struct SleepInputKey: Equatable {
    let loaded: Bool
    let daysCount: Int
    let sleepsCount: Int
    let firstDay: String?
    let lastDay: String?
    /// Newest day row (Equatable) — catches in-place edits to the latest day's values.
    let lastDayUpdated: DailyMetric?
    /// Newest sleep session (Equatable) — catches a re-import of the latest night.
    let lastSleep: CachedSleepSession?
    /// Bumped on every Repository.refresh — catches a re-import that changes only the
    /// imported metricSeries figures (importedSleep) without touching days/sleeps.
    let refreshSeq: Int
}

/// Memoized result of every expensive SleepView derivation. Built once per data change in
/// `buildModel()` and read by the subviews, so full passes over repo.days / repo.sleeps and
/// the Night.intervals reconstruction no longer run on every render.
struct SleepModel {
    /// (latest, typical mean, full history) per metric — mirrors SleepView.Metric.
    typealias Metric = (latest: Double?, typical: Double?, series: [Double])

    let night: Night
    /// Stage intervals for the hypnogram — computed once (Night.intervals is a computed
    /// property; it was previously re-derived on each access during render).
    let intervals: [SleepInterval]
    /// True when `intervals` are the stager's persisted per-epoch segments (on-device
    /// APPROXIMATE staging), not the synthesized architecture.
    let isPersistedHypnogram: Bool

    let performance: Metric
    /// Provenance of `performance.latest` — the day that figure was actually taken from.
    let performanceSource: SleepPerformanceSource
    let efficiency: Metric
    let consistency: Metric
    let hoursVsNeeded: Metric
    let restorative: Metric
    let respiratory: Metric
    let sleepDebt: Metric

    let typicalTotalMin: Double?
    let typicalDeepMin: Double?
    let typicalRemMin: Double?
    let typicalLightMin: Double?

    let trendPoints: [TrendPoint]

    /// Rolling 14-night sleep-debt ledger: Σ(slept − personal need) across the recent
    /// fortnight, with the per-night deltas behind it. Computed once per data change.
    let sleepDebtLedger: SleepDebtLedger
}

// MARK: - Sleep-performance provenance (pure, unit-tested)

/// Where a displayed sleep-performance score comes from. Badge wording matches Today / Intelligence.
enum SleepPerformanceSource: Equatable {
    case whoop, onDevice
    var badge: String { self == .whoop ? "Whoop" : "On-device" }
}

/// Resolves the sleep-performance series together with the provenance of each point, so the hero badge
/// describes the day the number was taken from. `latest` is the newest day that HAS a score, which is not
/// necessarily `days.last` (e.g. today's row exists but carries no sleep yet): looking the source up by
/// `days.last` mislabelled an imported night as "On-device".
enum SleepPerformanceResolver {
    struct Point: Equatable {
        let day: String
        let value: Double
        let source: SleepPerformanceSource
    }

    /// Imported WHOOP figure when the export carried one for the day; else the APPROXIMATE
    /// asleep / need fallback (capped 100). Days with neither are skipped.
    static func points(days: [DailyMetric], imported: [String: ImportedSleepFigures],
                       needMin: Double) -> [Point] {
        days.compactMap { d -> Point? in
            if let p = imported[d.day]?.performancePct, p.isFinite {
                return Point(day: d.day, value: p, source: .whoop)
            }
            guard let asleep = d.totalSleepMin, asleep > 0, needMin > 0 else { return nil }
            let v = min(100, asleep / needMin * 100)
            return v.isFinite ? Point(day: d.day, value: v, source: .onDevice) : nil
        }
    }

    /// Provenance of the latest point (the displayed score); on-device when there is none.
    static func source(of points: [Point]) -> SleepPerformanceSource {
        points.last?.source ?? .onDevice
    }

    /// Provenance of a night's figures, keyed by its LOCAL wake-day (sleep is filed under the day you woke).
    static func nightSource(wakeDay: String, imported: [String: ImportedSleepFigures]) -> SleepPerformanceSource {
        imported[wakeDay] != nil ? .whoop : .onDevice
    }
}

/// Resolves the sleep-consistency series per day with the SAME precedence as `SleepPerformanceResolver`:
/// the imported WHOOP figure (sleep_consistency, 0–100) when the export carried one for that day, else
/// the APPROXIMATE rolling bedtime-spread score of the session that ended that day. `latest` is therefore
/// the newest day that HAS a value, not necessarily `days.last` (a trailing day without sleep data).
enum SleepConsistencyResolver {
    struct Point: Equatable {
        let day: String
        let value: Double
        let source: SleepPerformanceSource
    }

    /// Rolling (14-session) bedtime-spread score per local wake-day (lower spread → higher score).
    /// Needs ≥ 3 sessions overall and ≥ 3 in the window; the last session of a day wins.
    /// `dayKey` maps a session to its local wake-day key (the caller passes `Repository.localDayKey`).
    static func approximateByDay(sessions: [CachedSleepSession], calendar: Calendar = .current,
                                 dayKey: (CachedSleepSession) -> String) -> [String: Double] {
        func bedMinutes(_ s: CachedSleepSession) -> Double {
            let d = Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs))
            let comps = calendar.dateComponents([.hour, .minute], from: d)
            var m = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
            if m < 12 * 60 { m += 24 * 60 }   // wrap evening onsets into one continuous scale
            return m
        }
        let mins = sessions.map(bedMinutes)
        guard mins.count >= 3 else { return [:] }
        var out: [String: Double] = [:]
        for i in mins.indices {
            let window = Array(mins[Swift.max(0, i - 13)...i])
            guard window.count >= 3 else { continue }
            let m = window.reduce(0, +) / Double(window.count)
            let variance = window.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(window.count)
            let score = Swift.max(0, Swift.min(100, 100 * (1 - variance.squareRoot() / 120)))
            if score.isFinite { out[dayKey(sessions[i])] = score }
        }
        return out
    }

    /// Per day of `days`: imported consistency wins, else the approximation; days with neither are skipped.
    static func points(days: [DailyMetric], imported: [String: ImportedSleepFigures],
                       sessions: [CachedSleepSession], calendar: Calendar = .current,
                       dayKey: (CachedSleepSession) -> String) -> [Point] {
        let approx = approximateByDay(sessions: sessions, calendar: calendar, dayKey: dayKey)
        return days.compactMap { d -> Point? in
            if let p = imported[d.day]?.consistencyPct, p.isFinite {
                return Point(day: d.day, value: p, source: .whoop)
            }
            if let v = approx[d.day] { return Point(day: d.day, value: v, source: .onDevice) }
            return nil
        }
    }
}

struct Stages {
    var awake: Double
    var light: Double
    var deep: Double
    var rem: Double
    /// All stages (includes awake) — total time-in-bed minutes.
    var total: Double { awake + light + deep + rem }
    /// Asleep time = total minus awake.
    var asleep: Double { light + deep + rem }
}

struct Night {
    let session: CachedSleepSession
    let stages: Stages
    /// The REAL per-segment timeline for on-device computed nights (nil for imported nights,
    /// whose export carries totals only — those keep the synthetic reconstruction below). (#77)
    var realSegments: [SleepInterval]? = nil
    /// The actual stored block(s) this merged Night was built from. `session` above is a SYNTHETIC
    /// merge for display; an edit must target a real row, so it resolves it from here by identity
    /// rather than re-scanning by wake time. (#318)
    var sourceBlocks: [CachedSleepSession] = []

    /// Per-epoch MOTION for the MAIN-night GROUP, laid fragment-by-fragment in the SAME order `intervals`
    /// lays the group's stage timeline (#407). Empty when no group fragment has a persisted `motionJSON`
    /// (older rows) — the Sleep tab then shows an honest empty state instead of a fabricated zero trace.
    /// This is read off the already-resolved group, NOT a re-resolution of the night.
    var motionEpochs: [Double] = []

    /// The LEARNED habitual midsleep (local time-of-day seconds) the owning view loaded for the user — the
    /// SAME value the engine threaded into the daily total — so `editTarget` resolves the SAME main block
    /// the hero and the analytics rollup did, for a shift/late sleeper too. nil = cold-start band. (#547)
    var habitualMidsleepSec: Int? = nil

    /// The real stored block a sleep-time edit writes against — the day's MAIN block, resolved by the
    /// SAME shared selector (`SleepView.mainNightSession` → `SleepStageTotals.mainNightIndex`) the hero,
    /// the naps card, and `AnalyticsEngine.analyzeDay` use, so all of them and the edit affordance agree
    /// (no re-derived overnight gate). Passes the same learned habitual the hero used, so the edit target
    /// matches the hero block even for a shift/late sleeper. Its `startTs` is a genuine detected key, so
    /// `applySleepEdit` matches. nil when there's no underlying block (a synthetic stub) — the edit
    /// affordance is then hidden. (#318, #518, #547)
    var editTarget: CachedSleepSession? {
        SleepView.mainNightSession(sourceBlocks, habitualMidsleepSec: habitualMidsleepSec)
    }

    /// The `startTs` of every block in the day's bridged MAIN-night GROUP (the winning block plus the
    /// fragments bridged into it, #561), so the naps card excludes ALL of them — only blocks OUTSIDE the
    /// group are naps. Without this the tab treated every block except the single winner as a nap and a
    /// biphasic night rendered as phantom naps. (#555)
    var mainGroupStarts: Set<Int> {
        Set(SleepView.mainNightGroup(sourceBlocks, habitualMidsleepSec: habitualMidsleepSec).map { $0.startTs })
    }

    /// Total time in bed in minutes (from reconstructed stages).
    var timeInBed: Double { stages.total }

    /// The wall-clock start of the night (for the Hypnogram's clock labels).
    var onsetDate: Date { Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs)) }

    /// Stage intervals laid end-to-end across the night, in seconds from start.
    /// On-device computed nights use their REAL timeline; imported nights are reconstructed
    /// from durations only (the export has no per-epoch timeline).
    var intervals: [SleepInterval] {
        if let real = realSegments, real.count >= 2 { return real }
        var t: TimeInterval = 0
        var out: [SleepInterval] = []
        func add(_ stage: SleepStage, _ minutes: Double) {
            guard minutes > 0 else { return }
            let secs = minutes * 60
            out.append(SleepInterval(stage: stage, start: t, end: t + secs))
            t += secs
        }
        // A plausible architecture: deep early, REM later, awake last.
        add(.light, stages.light * 0.4)
        add(.deep, stages.deep)
        add(.light, stages.light * 0.3)
        add(.rem, stages.rem)
        add(.light, stages.light * 0.3)
        add(.awake, stages.awake)
        return out
    }

    var onsetText: String { Night.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs))) }
    var wakeText: String { Night.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.endTs))) }
    var dateLabel: String { Night.dateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs))) }

    /// Date label that becomes a span when the night crosses midnight (onset on a different
    /// calendar day from wake) — e.g. "Fri 13 → Sat 14 Jun" — otherwise a single date. Lets an
    /// aggregated day that started the previous evening read honestly. (#170)
    var spanLabel: String {
        let onsetDay = Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs))
        let wakeDay  = Date(timeIntervalSince1970: TimeInterval(session.endTs))
        let cal = Calendar.current
        if cal.isDate(onsetDay, inSameDayAs: wakeDay) { return Night.dateFmt.string(from: onsetDay) }
        return "\(Night.spanFmt.string(from: onsetDay)) → \(Night.dateFmt.string(from: wakeDay))"
    }

    /// A unix-second timestamp as a device-locale clock string ("11:42 PM" / "23:42"). Shared so the nap
    /// rows format their windows identically to the Asleep/Woke row. (#508)
    static func clockString(_ ts: Int) -> String {
        timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    // Clock for the Asleep/Woke row — the times people read at a glance. The "jmm" skeleton
    // follows the device's 12-/24-hour setting ("11:42 PM" or "23:42") instead of forcing one
    // on everyone, matching the HR-tooltip / workout times (#337).
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()
    /// Onset side of a cross-midnight span — no month (the wake side carries it): "Fri 13".
    private static let spanFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d"; return f
    }()
}

// MARK: - Wake-time editor

/// Identifies the night being edited for `.sheet(item:)`. A night's `startTs` is its stable natural
/// key (wake-time edits never move it), so it doubles as the sheet identity.
struct WakeEdit: Identifiable {
    let detectedStartTs: Int   // immutable detected key the edit writes against
    let bedTs: Int             // current effective onset (seeds the bed picker)
    let wakeTs: Int            // current wake (seeds the wake picker)
    let stagesJSON: String?
    var id: Int { detectedStartTs }
}

/// Seeds the "Add nap" picker (#508). A nap is short, so seed a 30-minute window anchored to the night's
/// wake (a natural place to look for a missed afternoon nap), clamped to never start before the night's
/// onset. The identity is the seed start so `.sheet(item:)` presents once per request.
struct AddNapSeed: Identifiable {
    let bedTs: Int
    let wakeTs: Int
    var id: Int { bedTs }
    init(forNight night: Night) {
        // Anchor an hour after the night's wake; a 30-min default window the user adjusts.
        let anchor = night.session.endTs + 3_600
        self.bedTs = anchor
        self.wakeTs = anchor + 30 * 60
    }
}

/// A small sheet to hand-correct a night's bed (onset) and wake (end) times. Seeds both pickers with the
/// current values; the wake picker is bounded to after the chosen bedtime. Hands the chosen unix-second
/// (bed, wake) back via `onSave`. Pure presentation + a single async save — persistence lives in the repo.
struct SleepTimeEditor: View {
    let onSave: (Int, Int) async -> Void
    /// Optional destructive delete (#68). Non-nil for an existing main-sleep / nap edit (the editor then
    /// shows a "Delete this sleep" button gated behind a confirmation); nil for the "Add a nap" sheet,
    /// which has nothing to delete yet.
    let onDelete: (() async -> Void)?
    private let title: LocalizedStringKey
    private let blurb: LocalizedStringKey
    private let bedLabel: LocalizedStringKey
    private let wakeLabel: LocalizedStringKey
    private let deleteLabel: LocalizedStringKey

    @Environment(\.dismiss) private var dismiss
    @State private var bed: Date
    @State private var wake: Date
    @State private var saving = false
    @State private var confirmingDelete = false

    /// `title`/`blurb`/`bedLabel`/`wakeLabel` default to the edit-an-existing-night wording; the
    /// "Add a nap" caller (#508) overrides them. The save logic + day-derived wake are identical either
    /// way — adding a nap is just an edit whose "existing" window is a seed. `onDelete` (#68) is the
    /// optional destructive action; `deleteLabel` lets the nap editor say "Delete this nap".
    init(bedTs: Int, wakeTs: Int,
         title: LocalizedStringKey = "Edit sleep times",
         blurb: LocalizedStringKey = "Correct when you went to bed and woke. Stages are re-derived from your data; the edit is kept through the next strap sync.",
         bedLabel: LocalizedStringKey = "Asleep",
         wakeLabel: LocalizedStringKey = "Woke",
         deleteLabel: LocalizedStringKey = "Delete this sleep",
         onSave: @escaping (Int, Int) async -> Void,
         onDelete: (() async -> Void)? = nil) {
        self.onSave = onSave
        self.onDelete = onDelete
        self.title = title; self.blurb = blurb
        self.bedLabel = bedLabel; self.wakeLabel = wakeLabel
        self.deleteLabel = deleteLabel
        _bed = State(initialValue: Date(timeIntervalSince1970: TimeInterval(bedTs)))
        _wake = State(initialValue: Date(timeIntervalSince1970: TimeInterval(wakeTs)))
    }

    /// The wake instant to save: the picked wake TIME-OF-DAY landed on the FIRST occurrence strictly after
    /// bedtime (within 24h). The Woke picker is time-only — its calendar day is always DERIVED from bed
    /// here — so a wake can never be dragged onto an unrelated day. That independent wake-date drag was
    /// what silently re-bucketed a night onto the wrong day and split its stages/totals across two days
    /// (the edit-scramble half of #406). For a normal 23:00→07:00 night this resolves 07:00 to the next
    /// morning; for a short evening nap it resolves to the same evening.
    private func resolvedWake() -> Date {
        let cal = Calendar.current
        let hm = cal.dateComponents([.hour, .minute], from: wake)
        // `nextDate(after:matching:)` returns the first instant with that hour:minute within 24h after the
        // anchor, so starting one minute past bed keeps wake strictly after bedtime and inside (bed, bed+24h].
        return cal.nextDate(after: bed.addingTimeInterval(60), matching: hm, matchingPolicy: .nextTime)
            ?? bed.addingTimeInterval(8 * 3600)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text(title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text(blurb)
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            NoopCard(padding: NoopMetrics.cardPadding, tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: 10) {
                    DatePicker(bedLabel, selection: $bed,
                               displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.compact)
                        .font(StrandFont.body)
                        .tint(StrandPalette.restColor)
                    Divider().overlay(StrandPalette.hairline)
                    // Time-only on purpose — the wake's calendar day is derived from bed (see resolvedWake),
                    // so an edit can't move the night to a different day and scramble its stages/totals (#406).
                    DatePicker(wakeLabel, selection: $wake,
                               displayedComponents: [.hourAndMinute])
                        .datePickerStyle(.compact)
                        .font(StrandFont.body)
                        .tint(StrandPalette.restColor)
                }
            }

            // Destructive delete for an existing night/nap (#68). Confirmation-gated so a tap can't clear
            // a night by accident; nil for the "Add a nap" sheet (nothing to delete). Sits below the
            // pickers, visually separated from the primary Save action.
            if onDelete != nil {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label(deleteLabel, systemImage: "trash")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.statusCritical)
                }
                .buttonStyle(.plain)
                .disabled(saving)
                .accessibilityLabel(deleteLabel)
            }

            HStack(spacing: NoopMetrics.gap) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.noopGhost)
                    .disabled(saving)
                Spacer()
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        await onSave(Int(bed.timeIntervalSince1970), Int(resolvedWake().timeIntervalSince1970))
                        dismiss()
                    }
                }
                .buttonStyle(.noopPrimary)
                .disabled(saving)
            }
        }
        .padding(NoopMetrics.screenPadding)
        .frame(minWidth: 360)
        .background(StrandPalette.surfaceOverlay)
        // On-brand destructive confirm — the same role-tagged .alert DevicesView uses for "Remove this
        // device?", not a bare default. (#68 — Android parity: "Delete this sleep session?")
        .alert("Delete this sleep session?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                saving = true
                Task {
                    await onDelete?()
                    dismiss()
                }
            }
        } message: {
            Text("Removes this recorded sleep and recomputes the day without it. This can't be undone.")
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Sleep") {
    SleepView()
        .environmentObject(Repository.previewSleep())
        .environmentObject(LiveState())
        .frame(width: 980, height: 1180)
        .preferredColorScheme(.dark)
}

@MainActor
private extension Repository {
    /// Sample repository populated with imported-style nights for previews.
    static func previewSleep() -> Repository {
        let repo = Repository(deviceId: "preview")
        let cal = Calendar.current
        let now = Date()

        var days: [DailyMetric] = []
        var sleeps: [CachedSleepSession] = []
        let fmt: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()

        for i in (0..<30).reversed() {
            let date = cal.date(byAdding: .day, value: -i, to: now)!
            let jitter = Double((i * 23) % 11) - 5
            let light = 210.0 + jitter
            let deep = 80.0 + jitter * 0.5
            let rem = 95.0 + jitter * 0.7
            let awake = 25.0 + Double((i * 7) % 9)
            let asleep = light + deep + rem
            let stagesJSON = "{\"light\":\(light),\"deep\":\(deep),\"rem\":\(rem),\"awake\":\(awake)}"

            days.append(DailyMetric(
                day: fmt.string(from: date),
                totalSleepMin: asleep,
                efficiency: 88 + jitter * 0.3,
                deepMin: deep, remMin: rem, lightMin: light,
                disturbances: Int(awake / 6), restingHr: 50 + (i % 4),
                avgHrv: 65 - Double(i % 5), recovery: 60 + jitter,
                strain: 10 + Double(i % 6), exerciseCount: i % 2,
                spo2Pct: 96, skinTempDevC: 33.4, respRateBpm: 14.6 + jitter * 0.1))

            var onset = cal.date(bySettingHour: 22, minute: 50 + Int(jitter), second: 0, of: date) ?? date
            onset = cal.date(byAdding: .day, value: -1, to: onset) ?? onset
            let end = onset.addingTimeInterval((asleep + awake) * 60)
            sleeps.append(CachedSleepSession(
                startTs: Int(onset.timeIntervalSince1970),
                endTs: Int(end.timeIntervalSince1970),
                efficiency: 88 + jitter * 0.3,
                restingHr: 50 + (i % 4),
                avgHrv: 65 - Double(i % 5),
                stagesJSON: stagesJSON))
        }

        repo.days = days
        repo.sleeps = sleeps
        repo.loaded = true
        return repo
    }
}
#endif

// MARK: - navDays memo

/// Caches the "sessions grouped by the calendar day they end on" list. The input is compared by VALUE
/// (array equality, which short-circuits on an identical buffer) and the grouping depends on the current
/// time zone, so the cached list is returned only when the very same sessions are asked for in the same
/// zone — otherwise it is rebuilt with the original grouping, newest day first, blocks oldest→newest.
final class NavDaysCache {
    private var input: [CachedSleepSession]?
    private var zone = ""
    private var output: [[CachedSleepSession]] = []

    func days(for sessions: [CachedSleepSession]) -> [[CachedSleepSession]] {
        let cal = Calendar.current
        let zoneID = cal.timeZone.identifier
        if let input, zone == zoneID, input == sessions { return output }
        func endDay(_ s: CachedSleepSession) -> Date {
            cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
        }
        let groups = Dictionary(grouping: sessions, by: endDay)
        let built = groups.keys.sorted(by: >).map { key in
            (groups[key] ?? []).sorted { $0.effectiveStartTs < $1.effectiveStartTs }
        }
        input = sessions; zone = zoneID; output = built
        return built
    }
}

#if os(macOS)
// MARK: - Soft overview (macOS redesign)
//
// The calm top of the Sleep screen in the style of the home dashboard: score with gradient scale,
// total sleep with recent nights, resting HR, a four-lane stage chart, data-backed insights and the
// night as a timeline. Reads only the memoized `SleepModel` plus stored daily rows; the detailed
// sections (night navigation, editing, naps, debt, trends) follow below unchanged.

extension SleepView {
    func softOverview(_ model: SleepModel) -> some View {
        let night = model.night
        return VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    softScoreCard(model).frame(minWidth: 300)
                    softTotalCard(model).frame(minWidth: 240)
                    softRestingCard(night).frame(minWidth: 220)
                }
                .frame(height: 236)
                VStack(spacing: 16) {
                    softScoreCard(model).frame(height: 236)
                    HStack(spacing: 16) {
                        softTotalCard(model)
                        softRestingCard(night)
                    }
                    .frame(height: 236)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    softStagesCard(model).frame(minWidth: 520)
                    softInsightsCard(model).frame(minWidth: 300, maxWidth: 420)
                }
                .frame(height: 360)
                VStack(spacing: 16) {
                    softStagesCard(model).frame(height: 360)
                    softInsightsCard(model).frame(height: 340)
                }
            }
            softTimelineCard(night).frame(height: 196)
        }
    }

    // MARK: Score

    func softScoreCard(_ model: SleepModel) -> some View {
        let score = model.performance.latest
        return StrandCard(padding: 20, cornerRadius: NoopMetrics.cardRadius) {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: "Sleep Score")
                HStack(alignment: .center, spacing: 12) {
                    Text(score.map { "\(Int($0.rounded()))" } ?? "—")
                        .font(StrandFont.number(46)).tracking(-1).foregroundStyle(StrandPalette.textPrimary)
                    if let score {
                        Text(Self.softScoreWord(score))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(StrandPalette.hueBlue, in: Capsule())
                    }
                }
                .padding(.top, 10)
                Text(model.performanceSource == .whoop ? "Value from the WHOOP export" : "Calculated on this Mac")
                    .font(.system(size: 12)).foregroundStyle(StrandPalette.textTertiary)
                Spacer(minLength: 10)
                SleepScoreScale(fraction: (score ?? 0) / 100, active: score != nil)
                    .frame(height: 44).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(score.map { Text("Sleep Score \(Int($0.rounded())) of 100, \(Text(Self.softScoreWord($0)))") } ?? Text("Sleep Score: no value"))
    }

    static func softScoreWord(_ s: Double) -> LocalizedStringKey {
        switch s {
        case ..<50: return "Weak"
        case ..<70: return "Medium"
        case ..<85: return "Good"
        default: return "Optimal"
        }
    }

    // MARK: Total sleep

    func softTotalCard(_ model: SleepModel) -> some View {
        let asleep = model.night.stages.asleep
        let nights = Array(repo.days.compactMap(\.totalSleepMin).suffix(16))
        let typical = model.typicalTotalMin
        let change = typical.flatMap { $0 > 0 && asleep > 0 ? (asleep - $0) / $0 * 100 : nil }
        return StrandCard(padding: 20, cornerRadius: NoopMetrics.cardRadius) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Total Sleep").font(.system(size: 14, weight: .medium)).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    if let change {
                        DeltaChip(text: "\(change >= 0 ? "↑" : "↓") \(Int(abs(change).rounded())) %",
                                  tint: change >= 0 ? StrandPalette.hueGreen : StrandPalette.hueRose)
                    }
                }
                (asleep > 0 ? Text(asleep / 60, format: .number.precision(.fractionLength(1))) : Text(verbatim: "—"))
                    .font(StrandFont.number(42)).tracking(-1).foregroundStyle(StrandPalette.textPrimary).padding(.top, 10)
                Text("hours").font(.system(size: 14)).foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 8)
                MiniBars(values: nights, colors: [StrandPalette.hueBlue.opacity(0.5), StrandPalette.hueBlue])
                    .frame(height: 54)
                    .accessibilityElement()
                    .accessibilityLabel(HomeFormat.seriesSummary(Text("Sleep duration over the last \(nights.count) nights"),
                                                                 nights.map { $0 / 60 }, unit: Text("hours")))
                HStack {
                    Text("\(nights.count) nights").font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                    Text("Last night").font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
                }
                .padding(.top, 6)
            }
        }
    }

    // MARK: Resting HR

    func softRestingCard(_ night: Night) -> some View {
        let rhrDays = repo.days.compactMap { $0.restingHr.map(Double.init) }
        let value = night.session.restingHr.map(Double.init) ?? rhrDays.last
        let line = Array(rhrDays.suffix(14))
        let base = rhrDays.count >= 5 ? Array(rhrDays.suffix(30)).reduce(0, +) / Double(min(30, rhrDays.count)) : nil
        let change = (value != nil && base != nil && base! > 0) ? (value! - base!) / base! * 100 : nil
        return StrandCard(padding: 20, cornerRadius: NoopMetrics.cardRadius,
                          wash: CardWash(color: StrandPalette.washPeach, center: UnitPoint(x: 0.7, y: 0.8))) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Resting Pulse").font(.system(size: 14, weight: .medium)).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    if let change {
                        DeltaChip(text: "\(change >= 0 ? "↑" : "↓") \(Int(abs(change).rounded())) %",
                                  tint: change <= 0 ? StrandPalette.hueGreen : StrandPalette.hueRose)
                    }
                }
                Text(value.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(StrandFont.number(42)).tracking(-1).foregroundStyle(StrandPalette.textPrimary).padding(.top, 10)
                Text("bpm").font(.system(size: 14)).foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 8)
                Sparkline.smooth(line, color: StrandPalette.huePeach)
                    .frame(height: 44).accessibilityElement()
                    .accessibilityLabel(HomeFormat.seriesSummary(Text("Resting pulse over the last \(line.count) nights"), line, unit: Text(verbatim: "bpm")))
                HStack {
                    Text(HomeView.relativeState(value, base: base, higherIsBetter: false))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    (base.map { Text("Ø 30 d  \(Int($0.rounded()))") } ?? Text(verbatim: ""))
                        .font(.system(size: 13).monospacedDigit()).foregroundStyle(StrandPalette.textSecondary)
                }
                .padding(.top, 10)
            }
        }
    }

    // MARK: Stages

    func softStagesCard(_ model: SleepModel) -> some View {
        let st = model.night.stages
        let total = max(st.total, 1)
        let items: [(SleepStage, LocalizedStringKey, Double)] = [
            (.awake, "Awake", st.awake), (.rem, "REM", st.rem), (.light, "Light", st.light), (.deep, "Deep", st.deep),
        ]
        return StrandCard(padding: 22, cornerRadius: NoopMetrics.cardRadius) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Sleep Stages").font(.system(size: 17, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    if !model.isPersistedHypnogram {
                        Text("Timeline estimated from the stage totals")
                            .font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                SleepStageLanes(intervals: model.intervals, onset: model.night.onsetDate)
                    .padding(.top, 14).accessibilityHidden(true)
                HStack(alignment: .top, spacing: 0) {
                    ForEach(items, id: \.0) { stage, name, minutes in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                Circle().fill(SleepStageLanes.color(stage)).frame(width: 11, height: 11)
                                Text(name).font(.system(size: 13)).foregroundStyle(StrandPalette.textPrimary)
                            }
                            Text(Self.softDuration(minutes))
                                .font(.system(size: 20, weight: .semibold).monospacedDigit()).foregroundStyle(StrandPalette.textPrimary)
                            Text("\(Int((minutes / total * 100).rounded())) %")
                                .font(.system(size: 12)).foregroundStyle(StrandPalette.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 16)
                Spacer(minLength: 0)
            }
        }
    }

    static func softDuration(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    // MARK: Insights

    func softInsightsCard(_ model: SleepModel) -> some View {
        var rows: [(String, Color, LocalizedStringResource, LocalizedStringResource)] = []
        let dayKey = repo.days.last?.day ?? Repository.localDayKey(Date())
        for i in HomeModel.insights(days: repo.days, sleeps: navSessions, dayKey: dayKey)
        where i.topic == .sleep || i.topic == .bedtime {
            let style = HomeView.insightStyle(i)
            rows.append((style.0, style.1, i.title, i.detail))
        }
        if let typ = model.typicalDeepMin, typ > 0, model.night.stages.deep > 0 {
            let diff = Int((model.night.stages.deep - typ).rounded())
            let lastNight: LocalizedStringResource = "Last night \(Self.softDuration(model.night.stages.deep))"
            if abs(diff) >= 5 {
                rows.append(("waveform.path", diff > 0 ? StrandPalette.hueBlue : StrandPalette.hueAmber, diff > 0
                             ? "Deep sleep \(diff) min above your average" : "Deep sleep \(-diff) min below your average", lastNight))
            } else {
                rows.append(("waveform.path", StrandPalette.hueBlue, "Deep sleep in your usual range", lastNight))
            }
        }
        if let eff = model.efficiency.latest {
            let pct = Int((eff <= 1 ? eff * 100 : eff).rounded())
            rows.append(("bed.double", pct >= 85 ? StrandPalette.hueGreen : StrandPalette.hueAmber,
                         "Sleep efficiency \(pct) %",
                         pct >= 85 ? "You're asleep for most of your time in bed" : "A lot of awake time in bed"))
        }
        return StrandCard(padding: 22, cornerRadius: NoopMetrics.cardRadius) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Findings").font(.system(size: 17, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if rows.isEmpty {
                    Text("Findings appear after a week of sleep data.")
                        .font(.system(size: 13)).foregroundStyle(StrandPalette.textTertiary)
                }
                ForEach(Array(rows.prefix(4).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 14) {
                        Image(systemName: row.0)
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(row.1)
                            .frame(width: 42, height: 42)
                            .background(row.1.opacity(0.13), in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.2).font(.system(size: 13, weight: .medium)).foregroundStyle(StrandPalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(row.3).font(.system(size: 12)).foregroundStyle(StrandPalette.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Timeline

    func softTimelineCard(_ night: Night) -> some View {
        let onset = night.session.effectiveStartTs, wake = night.session.endTs
        let deepPeak = night.intervals.filter { $0.stage == .deep }.max(by: { $0.duration < $1.duration })
        let peakTs = deepPeak.map { onset + Int(($0.start + $0.end) / 2) }
        let clock = { (ts: Int) in Text(Date(timeIntervalSince1970: TimeInterval(ts)), format: .dateTime.hour().minute()) }
        return StrandCard(padding: 22, cornerRadius: NoopMetrics.cardRadius) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Sleep Timeline").font(.system(size: 17, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                SleepNightBar(intervals: night.intervals, span: TimeInterval(max(wake - onset, 1)),
                              onset: Date(timeIntervalSince1970: TimeInterval(onset)),
                              marker: peakTs.map { TimeInterval($0 - onset) })
                    .frame(height: 64).padding(.top, 18).accessibilityHidden(true)
                HStack(alignment: .top) {
                    legend(color: SleepStageLanes.color(.awake), title: "Fell asleep", value: clock(onset))
                    Spacer()
                    if let peakTs { legend(color: SleepStageLanes.color(.deep), title: "Deep sleep peak", value: clock(peakTs)) }
                    Spacer()
                    legend(color: SleepStageLanes.color(.rem), title: "Woke up", value: clock(wake))
                    Spacer()
                    HStack(spacing: 10) {
                        Image(systemName: "bed.double").font(.system(size: 14)).foregroundStyle(StrandPalette.textSecondary)
                            .frame(width: 34, height: 34).background(StrandPalette.surfaceInset, in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("In bed").font(.system(size: 12)).foregroundStyle(StrandPalette.textTertiary)
                            Text(Self.softDuration(Double(wake - onset) / 60))
                                .font(.system(size: 16, weight: .semibold).monospacedDigit()).foregroundStyle(StrandPalette.textPrimary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                .padding(.top, 12)
                Spacer(minLength: 0)
            }
        }
    }

    private func legend(color: Color, title: LocalizedStringKey, value: Text) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(color).frame(width: 12, height: 12).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(StrandPalette.textPrimary)
                value.font(.system(size: 13).monospacedDigit()).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Gradient scale 0…100 with a knob at the score and tick labels.
private struct SleepScoreScale: View {
    let fraction: Double
    let active: Bool
    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let f = CGFloat(min(max(fraction, 0), 1))
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.surfaceInset).frame(height: 12)
                    Capsule()
                        .fill(LinearGradient(colors: [StrandPalette.hueBlue.opacity(0.55), StrandPalette.hueViolet, StrandPalette.hueGreen],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(12, geo.size.width * f), height: 12)
                        .opacity(active ? 1 : 0)
                    if active {
                        Circle().fill(StrandPalette.hueGreen).frame(width: 22, height: 22)
                            .overlay(Circle().stroke(Color.white, lineWidth: 3))
                            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                            .offset(x: geo.size.width * f - 11)
                    }
                }
                .frame(height: 22)
            }
            .frame(height: 22)
            HStack {
                ForEach([0, 20, 40, 60, 80, 100], id: \.self) { t in
                    Text("\(t)").font(.system(size: 11).monospacedDigit()).foregroundStyle(StrandPalette.textTertiary)
                    if t != 100 { Spacer() }
                }
            }
        }
    }
}

/// Four-lane hypnogram: Awake / REM / Light / Deep as soft rounded blocks.
private struct SleepStageLanes: View {
    let intervals: [SleepInterval]
    let onset: Date

    static func color(_ stage: SleepStage) -> Color {
        switch stage {
        case .awake: return StrandPalette.hueRose
        case .rem: return StrandPalette.hueViolet.opacity(0.55)
        case .light: return StrandPalette.hueBlue.opacity(0.45)
        case .deep: return StrandPalette.hueBlue
        }
    }
    private static let lanes: [(SleepStage, LocalizedStringKey)] = [(.awake, "Awake"), (.rem, "REM"), (.light, "Light"), (.deep, "Deep")]

    var body: some View {
        let span = max(intervals.map(\.end).max() ?? 1, 1)
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(Self.lanes, id: \.0) { _, name in
                        Text(name).font(.system(size: 12)).foregroundStyle(StrandPalette.textSecondary)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(width: 44)
                GeometryReader { geo in
                    let laneH = geo.size.height / 4
                    ZStack(alignment: .topLeading) {
                        ForEach(0..<4, id: \.self) { i in
                            Rectangle().fill(StrandPalette.surfaceInset.opacity(0.6)).frame(height: 1)
                                .offset(y: laneH * (CGFloat(i) + 0.5))
                        }
                        Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: geo.size.height)
                        ForEach(Array(intervals.enumerated()), id: \.offset) { _, iv in
                            let lane = Self.lanes.firstIndex { $0.0 == iv.stage } ?? 2
                            let x0 = geo.size.width * CGFloat(iv.start / span)
                            let w = max(2, geo.size.width * CGFloat(iv.duration / span))
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Self.color(iv.stage))
                                .frame(width: w, height: laneH * 0.62)
                                .offset(x: x0, y: laneH * CGFloat(lane) + laneH * 0.19)
                        }
                    }
                }
            }
            .frame(height: 168)
            HStack {
                ForEach(0..<5, id: \.self) { i in
                    Text(onset.addingTimeInterval(span * Double(i) / 4), format: .dateTime.hour().minute())
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(StrandPalette.textTertiary)
                    if i < 4 { Spacer() }
                }
            }
            .padding(.leading, 54)
        }
    }
}

/// The night as one capsule coloured by stage, with a clock marker (deep-sleep peak).
private struct SleepNightBar: View {
    let intervals: [SleepInterval]
    let span: TimeInterval
    let onset: Date
    let marker: TimeInterval?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let barY: CGFloat = 28
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .leading) {
                    StrandPalette.surfaceInset
                    ForEach(Array(intervals.enumerated()), id: \.offset) { _, iv in
                        Rectangle().fill(SleepStageLanes.color(iv.stage))
                            .frame(width: max(1, w * CGFloat(iv.duration / span)), height: 14)
                            .offset(x: w * CGFloat(iv.start / span))
                    }
                }
                .frame(width: w, height: 14, alignment: .leading)
                .clipShape(Capsule())
                .offset(y: barY)
                ForEach(0..<7, id: \.self) { i in
                    Text(onset.addingTimeInterval(span * Double(i) / 6), format: .dateTime.hour().minute())
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize()
                        .position(x: min(max(w * CGFloat(i) / 6, 16), w - 16), y: barY + 32)
                }
                if let marker {
                    let mx = w * CGFloat(marker / span)
                    Rectangle().fill(StrandPalette.textPrimary).frame(width: 1.5, height: 30).offset(x: mx - 0.75, y: barY - 8)
                    Text(onset.addingTimeInterval(marker), format: .dateTime.hour().minute())
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(StrandPalette.surfaceRaised)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(StrandPalette.textPrimary, in: Capsule())
                        .fixedSize()
                        .position(x: min(max(mx, 26), w - 26), y: barY - 18)
                }
            }
        }
    }
}
#endif

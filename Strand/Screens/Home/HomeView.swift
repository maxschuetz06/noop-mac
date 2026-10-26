#if os(macOS)
import SwiftUI
import AppKit
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Overview (home)
//
// The redesigned macOS home: greeting header, the abstract aura hero with anchored vitals, six soft
// metric cards, today's timeline, generated insights and today's heart rate. Reads the same stored
// rows as the Control Center (which stays reachable as "Day Details"); nothing here invents values —
// a metric without data shows "—".

struct HomeView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var updateStore: UpdateStore
    @Environment(\.locale) private var locale

    /// Opens another sidebar section (the ↗ buttons and insight rows).
    var navigate: (NavItem) -> Void = { _ in }

    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    @State private var offset = 0
    @State private var restByDay: [String: Double] = [:]
    @State private var stepsEstByDay: [String: Int] = [:]
    @State private var sleeps: [CachedSleepSession] = []
    @State private var workouts: [WorkoutRow] = []
    @State private var hrPoints: [TrendPoint] = []
    @State private var liveStrain: Double?
    @State private var insights: [HomeInsight] = []
    @State private var showInbox = false

    private static let stepGoal = 10_000.0

    private var format: HomeFormat { HomeFormat(locale: locale) }

    // MARK: Day selection

    private var selectedDay: Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -offset, to: base) ?? base
    }
    private var dayKey: String {
        if offset == 0, let k = repo.today?.day { return k }
        return Repository.localDayKey(selectedDay)
    }
    private var day: DailyMetric? {
        offset == 0 ? (repo.today ?? repo.days.last { $0.day == dayKey }) : repo.days.last { $0.day == dayKey }
    }
    /// The last scored night, carried while today isn't scored yet (same rule as the Control Center).
    private var carried: DailyMetric? {
        TodayView.lastScoredRecoveryDay(days: repo.days, selectedDayKey: dayKey, isToday: offset == 0,
                                        todayScored: day?.recovery != nil, isCalibrating: false)
    }
    /// Today's row, or the carried prior row for the recovery-side vitals.
    private var vitalsDay: DailyMetric? { day?.recovery != nil ? day : (carried ?? day) }
    private var priorDays: [DailyMetric] { repo.days.filter { $0.day <= dayKey } }

    var body: some View {
        GeometryReader { geo in
            let content = geo.size.width - 64
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    top(width: content)
                    bottom(width: content)
                    heartRateCard
                }
                .padding(.horizontal, 32).padding(.top, 34).padding(.bottom, 32)
            }
        }
        .background(Soft.canvas.ignoresSafeArea())
        .task(id: HomeLoadKey(seq: repo.refreshSeq, offset: offset)) { await load() }
        .sheet(isPresented: $showInbox) { UpdatesInboxView(onClose: { showInbox = false }) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Hello,").font(.system(size: 28, weight: .light)).foregroundStyle(Soft.ink2)
                (Self.firstName.map { Text(verbatim: "\($0).") } ?? Text("you."))
                    .font(.system(size: 50, weight: .semibold)).tracking(-1.2)
                    .foregroundStyle(Soft.ink)
                Text(offset == 0 ? "Here's how your body is doing today." : "Looking back at this day.")
                    .font(.system(size: 17)).foregroundStyle(Soft.ink2)
                    .padding(.top, 4)
            }
            Spacer(minLength: 16)
            HStack(spacing: 10) {
                Text(verbatim: format.headerDate(selectedDay))
                    .font(.system(size: 14)).foregroundStyle(Soft.ink2)
                    .padding(.trailing, 6)
                SoftCircleButton(symbol: "chevron.left", label: "Previous day") { offset += 1 }
                SoftCircleButton(symbol: "chevron.right", label: "Next day", enabled: offset > 0) {
                    offset = max(0, offset - 1)
                }
                Button { showInbox = true } label: {
                    Image(systemName: "bell")
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(Soft.ink)
                        .frame(width: 40, height: 40)
                        .overlay(alignment: .topTrailing) {
                            if updateStore.unreadCount > 0 {
                                Circle().fill(Soft.rose).frame(width: 8, height: 8).offset(x: -9, y: 9)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(SoftPressStyle())
                .help("Notifications")
                .accessibilityLabel(updateStore.unreadCount > 0
                                    ? "Notifications, \(updateStore.unreadCount) unread" : "Notifications")
                .padding(.leading, 6)
                HomeAvatar(imageData: profile.avatarImageData)
            }
        }
    }

    // MARK: Hero + cards

    @ViewBuilder
    private func top(width: CGFloat) -> some View {
        let cardH: CGFloat = 236
        if width >= 820 {
            let heroW = min(400, max(250, width * 0.31))
            HStack(alignment: .top, spacing: 18) {
                HomeHero(day: vitalsDay, caption: "Real-time readings from your WHOOP.")
                    .frame(width: heroW, height: cardH * 2 + 16)
                cardGrid(columns: 3, height: cardH)
            }
        } else {
            VStack(spacing: 18) {
                HomeHero(day: vitalsDay, caption: "Real-time readings from your WHOOP.")
                    .frame(height: 380)
                cardGrid(columns: width >= 560 ? 3 : 2, height: cardH)
            }
        }
    }

    private func cardGrid(columns: Int, height: CGFloat) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: columns), spacing: 16) {
            chargeCard.frame(height: height)
            hrvCard.frame(height: height)
            restingCard.frame(height: height)
            sleepCard.frame(height: height)
            effortCard.frame(height: height)
            activityCard.frame(height: height)
        }
    }

    /// Big value + unit (+ optional chip) block shared by every metric card.
    private func valueBlock(_ value: String, unit: Text, chip: SoftChip? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(Soft.number(42)).tracking(-1).foregroundStyle(Soft.ink)
                .lineLimit(1).fixedSize()
            unit.font(.system(size: 14)).foregroundStyle(Soft.ink2)
            if let chip { chip.padding(.top, 6) }
        }
    }

    private func footer(_ left: Text, _ right: Text) -> some View {
        HStack {
            left.font(.system(size: 13, weight: .medium)).foregroundStyle(Soft.ink)
            Spacer()
            right.font(.system(size: 13).monospacedDigit()).foregroundStyle(Soft.ink2)
        }
    }

    private var chargeCard: some View {
        let value = day?.recovery ?? carried?.recovery
        let avg = HomeModel.windowMean(repo.days, dayKey: dayKey, fromDaysBack: 8, toDaysBack: 1, minCount: 3) { $0.recovery }
        let chip: SoftChip? = (value != nil && avg != nil) ? delta(value! - avg!, unit: " %", invert: false) : nil
        return SoftCard(wash: SoftWash(color: Soft.greenWash, center: UnitPoint(x: 0.75, y: 0.45))) {
            VStack(alignment: .leading, spacing: 0) {
                SoftCardHeader(title: "Charge") { navigate(.health) }
                HStack(alignment: .top, spacing: 0) {
                    valueBlock(value.map { "\(Int($0.rounded()))" } ?? "—", unit: Text(verbatim: "%"), chip: chip)
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    SoftRings(fraction: (value ?? 0) / 100, color: Soft.green)
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                        .padding(.top, 16)
                        .opacity(value == nil ? 0.4 : 1)
                }
                .padding(.top, 8)
                Spacer(minLength: 6)
                footer(Text(value.map(Self.chargeState) ?? "No value yet"),
                       day?.recovery == nil && carried != nil ? Text("Last night")
                           : (avg.map { Text("Ø 7 d  \(Int($0.rounded())) %") } ?? Text(verbatim: "")))
            }
        }
    }

    private var hrvCard: some View {
        let value = vitalsDay?.avgHrv
        let bars = HomeModel.recentValues(repo.days, upTo: dayKey, count: 16) { $0.avgHrv }
        let base = HomeModel.windowMean(repo.days, dayKey: dayKey, fromDaysBack: 30, toDaysBack: 0, minCount: 5) { $0.avgHrv }
        return SoftCard {
            VStack(alignment: .leading, spacing: 0) {
                SoftCardHeader(title: "HRV") { navigate(.trends) }
                valueBlock(value.map { "\(Int($0.rounded()))" } ?? "—", unit: Text(verbatim: "ms")).padding(.top, 8)
                Spacer(minLength: 8)
                SoftBars(values: bars, colors: [Soft.blue.opacity(0.55), Soft.violet])
                    .frame(height: 56)
                    .accessibilityElement()
                    .accessibilityLabel(HomeFormat.seriesSummary(Text("HRV over the last \(bars.count) nights"), bars,
                                                                  unit: Text(verbatim: "ms")))
                    .padding(.bottom, 12)
                footer(Text(Self.relativeState(value, base: base, higherIsBetter: true)),
                       base.map { Text("Ø 30 d  \(Int($0.rounded()))") } ?? Text(verbatim: ""))
            }
        }
    }

    private var restingCard: some View {
        let value = vitalsDay?.restingHr.map(Double.init)
        let line = HomeModel.recentValues(repo.days, upTo: dayKey, count: 14) { $0.restingHr.map(Double.init) }
        let base = HomeModel.windowMean(repo.days, dayKey: dayKey, fromDaysBack: 30, toDaysBack: 0, minCount: 5) { $0.restingHr.map(Double.init) }
        return SoftCard(wash: SoftWash(color: Soft.peachWash, center: UnitPoint(x: 0.6, y: 0.75), secondary: Soft.roseWash)) {
            VStack(alignment: .leading, spacing: 0) {
                SoftCardHeader(title: "Resting Pulse") { navigate(.health) }
                valueBlock(value.map { "\(Int($0.rounded()))" } ?? "—", unit: Text(verbatim: "bpm")).padding(.top, 8)
                Spacer(minLength: 8)
                SoftLine(values: line, color: Soft.peach, lineWidth: 2).frame(height: 50).padding(.bottom, 12)
                    .accessibilityElement()
                    .accessibilityLabel(HomeFormat.seriesSummary(Text("Resting pulse over the last \(line.count) nights"), line,
                                                                  unit: Text(verbatim: "bpm")))
                footer(Text(Self.relativeState(value, base: base, higherIsBetter: false)),
                       base.map { Text("Ø 30 d  \(Int($0.rounded()))") } ?? Text(verbatim: ""))
            }
        }
    }

    private var sleepCard: some View {
        let minutes = day?.totalSleepMin
        let line = HomeModel.recentValues(repo.days, upTo: dayKey, count: 14) { $0.totalSleepMin }
        let avg = HomeModel.windowMean(repo.days, dayKey: dayKey, fromDaysBack: 8, toDaysBack: 1, minCount: 3) { $0.totalSleepMin }
        let rest = restByDay[dayKey]
        let change = (minutes != nil && avg != nil && avg! > 0) ? (minutes! - avg!) / avg! * 100 : nil
        return SoftCard {
            VStack(alignment: .leading, spacing: 0) {
                SoftCardHeader(title: "Sleep") { navigate(.sleep) }
                valueBlock(minutes.map { format.decimal($0 / 60, digits: 1) } ?? "—", unit: Text("hours")).padding(.top, 8)
                Spacer(minLength: 8)
                SoftLine(values: line, color: Soft.blue, lineWidth: 2, showsHead: false).frame(height: 46).padding(.bottom, 12)
                    .accessibilityElement()
                    .accessibilityLabel(HomeFormat.seriesSummary(Text("Sleep duration over the last \(line.count) nights"),
                                                                  line.map { $0 / 60 }, unit: Text("hours")))
                footer(rest.map { Text("Rest \(Int($0.rounded())) %") } ?? Text(minutes == nil ? "No night" : "Recorded"),
                       Text(verbatim: change.map { Self.signedPercent($0) } ?? ""))
            }
        }
    }

    private var effortCard: some View {
        let stored = day?.strain
        let value: Double? = offset == 0 ? (liveStrain.map { max($0, stored ?? 0) } ?? stored) : stored
        let avg = HomeModel.windowMean(repo.days, dayKey: dayKey, fromDaysBack: 8, toDaysBack: 1, minCount: 3) { $0.strain }
        let change = (value != nil && avg != nil && avg! > 0) ? (value! - avg!) / avg! * 100 : nil
        return SoftCard(wash: SoftWash(color: Soft.roseWash, center: UnitPoint(x: 0.5, y: 0.85))) {
            VStack(alignment: .leading, spacing: 0) {
                SoftCardHeader(title: "Effort") { navigate(.workouts) }
                valueBlock(value.map { format.decimal(UnitFormatter.effortValue($0, scale: effortScale), digits: 1) } ?? "—",
                           unit: Text("of \(UnitFormatter.effortScaleMax(effortScale))")).padding(.top, 8)
                Spacer(minLength: 4)
                SoftArcGauge(fraction: (value ?? 0) / 100, color: Soft.rose)
                    .accessibilityHidden(true)
                    .frame(height: 58).padding(.horizontal, 18).padding(.bottom, 10)
                    .opacity(value == nil ? 0.4 : 1)
                footer(Text(value.map(Self.effortState) ?? "No value yet"),
                       Text(verbatim: change.map { Self.signedPercent($0) } ?? ""))
            }
        }
    }

    private var activityCard: some View {
        let steps = day?.steps.map(Double.init) ?? stepsEstByDay[dayKey].map(Double.init)
        let estimated = day?.steps == nil && stepsEstByDay[dayKey] != nil
        let bars = HomeModel.recentValues(repo.days, upTo: dayKey, count: 7) { $0.steps.map(Double.init) }
        let progress = min(1, (steps ?? 0) / Self.stepGoal)
        return SoftCard {
            VStack(alignment: .leading, spacing: 0) {
                SoftCardHeader(title: "Activity") { navigate(.trends) }
                valueBlock(steps.map { format.grouped($0) } ?? "—", unit: Text(estimated ? "steps (estimated)" : "steps")).padding(.top, 8)
                Spacer(minLength: 6)
                if bars.count > 1 {
                    SoftBars(values: bars, colors: [Soft.ink3, Soft.ink2]).frame(height: 40).padding(.horizontal, 30)
                        .accessibilityElement()
                        .accessibilityLabel(HomeFormat.seriesSummary(Text("Steps over the last \(bars.count) days"), bars,
                                                                      unit: Text("steps")))
                }
                Spacer(minLength: 8)
                (steps == nil ? Text("Goal \(format.grouped(Self.stepGoal))") : Text("\(Int((progress * 100).rounded())) % of goal"))
                    .font(.system(size: 12)).foregroundStyle(Soft.ink2)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Soft.fill)
                        Capsule().fill(Soft.green).frame(width: g.size.width * progress)
                    }
                }
                .frame(height: 7).padding(.top, 6)
            }
        }
    }

    // MARK: Timeline + insights

    @ViewBuilder
    private func bottom(width: CGFloat) -> some View {
        if width >= 820 {
            HStack(alignment: .top, spacing: 18) {
                timelineCard.frame(maxWidth: .infinity)
                insightsCard.frame(width: (width - 18) * 0.44)
            }
            .frame(height: 312)
        } else {
            VStack(spacing: 18) {
                timelineCard.frame(height: 312)
                insightsCard.frame(height: 312)
            }
        }
    }

    private var timelineItems: [HomeTimelineItem] {
        HomeModel.timeline(dayStart: Calendar.current.startOfDay(for: selectedDay), sleeps: sleeps,
                           workouts: workouts, now: Date())
    }

    private var timelineCard: some View {
        let items = timelineItems
        let dayStart = Calendar.current.startOfDay(for: selectedDay)
        return SoftCard(padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                Text(offset == 0 ? "Your day" : "Day timeline")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Soft.ink)
                HomeTimelineBar(items: items, dayStart: dayStart, now: offset == 0 ? Date() : nil)
                    .frame(height: 70).padding(.top, 26)
                    .accessibilityHidden(true)
                if items.isEmpty {
                    Text("No sleep or training recorded for this day yet.")
                        .font(.system(size: 13)).foregroundStyle(Soft.ink3).padding(.top, 22)
                } else {
                    VStack(spacing: 12) {
                        ForEach(items.suffix(3)) { item in timelineRow(item) }
                    }
                    .padding(.top, 18)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func timelineRow(_ item: HomeTimelineItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Circle().fill(HomeTimelineBar.color(item.kind)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Soft.ink)
                Text(verbatim: "\(format.clock(item.start)) – \(format.clock(item.end))")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Soft.ink3)
            }
            Spacer()
            Text(item.status == .running ? "In progress" : "Completed")
                .font(.system(size: 13))
                .foregroundStyle(item.status == .running ? Soft.blue : Soft.ink3)
        }
    }

    private var insightsCard: some View {
        SoftCard(padding: 22) {
            VStack(alignment: .leading, spacing: 14) {
                SoftCardHeader(title: "Findings") { navigate(.trends) }
                    .font(.system(size: 17, weight: .semibold))
                if insights.isEmpty {
                    Text("Findings appear once there's a week of data.")
                        .font(.system(size: 13)).foregroundStyle(Soft.ink3)
                }
                ForEach(insights.prefix(4)) { insight in
                    Button { navigate(Self.destination(insight.topic)) } label: { insightRow(insight) }
                        .buttonStyle(SoftPressStyle())
                        .accessibilityLabel(Text(insight.title) + Text(verbatim: ". ") + Text(insight.detail))
                        .accessibilityHint("Opens the matching section")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func insightRow(_ i: HomeInsight) -> some View {
        let (symbol, tint) = Self.insightStyle(i)
        return HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.13), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(i.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Soft.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(i.detail).font(.system(size: 12)).foregroundStyle(Soft.ink3)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Soft.ink3)
        }
        .contentShape(Rectangle())
    }

    // MARK: Heart rate

    @ViewBuilder
    private var heartRateCard: some View {
        if hrPoints.count > 1 {
            let v = hrPoints.map(\.value)
            SoftCard(padding: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Heart rate").font(.system(size: 17, weight: .semibold)).foregroundStyle(Soft.ink)
                        Text(offset == 0 ? "since midnight · 5-minute average" : "whole day · 5-minute average")
                            .font(.system(size: 12)).foregroundStyle(Soft.ink3)
                        Spacer()
                        stat("Min", v.min()); stat("Ø", v.reduce(0, +) / Double(v.count)); stat("Max", v.max())
                    }
                    SoftLine(values: v, color: Soft.rose, lineWidth: 1.6, showsHead: offset == 0, fill: true)
                        .frame(height: 130)
                        .accessibilityElement()
                        .accessibilityLabel(HomeFormat.seriesSummary(Text("Heart rate"), v, unit: Text(verbatim: "bpm")))
                    HStack {
                        ForEach(Array(format.axisLabels(hrPoints).enumerated()), id: \.offset) { i, t in
                            if i > 0 { Spacer() }
                            Text(t).font(.system(size: 11).monospacedDigit()).foregroundStyle(Soft.ink3)
                        }
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: Double?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Soft.ink3)
            Text(value.map { "\(Int($0.rounded()))" } ?? "—").font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(Soft.ink)
        }
        .padding(.leading, 14)
    }

    // MARK: Loading

    private func load() async {
        let rest = await repo.exploreSeries(key: "sleep_performance", source: Repository.whoopSource)
        restByDay = Dictionary(rest.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        let est = await repo.exploreSeries(key: "steps_est", source: Repository.whoopSource)
        stepsEstByDay = Dictionary(est.map { ($0.day, Int($0.value.rounded())) }, uniquingKeysWith: { _, last in last })
        sleeps = await repo.allSleepSessions(days: offset + 40)
        workouts = await repo.workoutRows(days: offset + 3)

        let dayStart = Calendar.current.startOfDay(for: selectedDay)
        let from = Int(dayStart.timeIntervalSince1970)
        let to = offset == 0 ? Int(Date().timeIntervalSince1970) : from + 86_400
        hrPoints = await repo.hrBuckets(from: from, to: to, bucketSeconds: 300)
            .map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm) }
        if offset == 0 {
            let samples = await repo.hrSamples(from: from, to: to)
            let maxHR = profile.age > 0 ? StrainScorer.tanakaHRmax(age: Double(profile.age)) : nil
            let restHR = day?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
            liveStrain = StrainScorer.strain(samples, maxHR: maxHR, restingHR: restHR, sex: profile.sex)
        } else {
            liveStrain = nil
        }
        insights = HomeModel.insights(days: repo.days, sleeps: sleeps, dayKey: dayKey)
    }

    // MARK: Helpers

    private func delta(_ d: Double, unit: String, invert: Bool) -> SoftChip {
        let up = d >= 0
        let good = invert ? !up : up
        return SoftChip(text: "\(up ? "↑" : "↓") \(Int(abs(d).rounded()))\(unit)", tint: good ? Soft.green : Soft.rose)
    }

    static func chargeState(_ v: Double) -> LocalizedStringKey { v >= 67 ? "Optimal" : (v >= 34 ? "Medium" : "Low") }
    static func effortState(_ v: Double) -> LocalizedStringKey { v >= 66 ? "High" : (v >= 33 ? "Medium" : "Low") }

    /// "Normal" within ±8 % of the baseline, otherwise above/below phrased by whether higher is better.
    static func relativeState(_ v: Double?, base: Double?, higherIsBetter: Bool) -> LocalizedStringKey {
        guard let v, let base, base > 0 else { return v == nil ? "No value yet" : "Normal" }
        let r = (v - base) / base
        if abs(r) <= 0.08 { return higherIsBetter ? "Optimal" : "Normal" }
        let above = r > 0
        return above == higherIsBetter ? "Above average" : (higherIsBetter ? "Below average" : "Elevated")
    }

    static func destination(_ topic: HomeInsight.Topic) -> NavItem {
        switch topic {
        case .hrv: return .trends
        case .sleep, .bedtime: return .sleep
        case .restingHr: return .health
        }
    }

    static func insightStyle(_ i: HomeInsight) -> (String, Color) {
        switch (i.topic, i.tone) {
        case (.hrv, .caution): return ("chart.line.downtrend.xyaxis", Soft.rose)
        case (.hrv, _): return ("chart.line.uptrend.xyaxis", Soft.green)
        case (.sleep, _): return ("moon", Soft.blue)
        case (.restingHr, .caution): return ("heart", Soft.rose)
        case (.restingHr, _): return ("checkmark.shield", Soft.green)
        case (.bedtime, .caution): return ("sun.max", Soft.amber)
        case (.bedtime, _): return ("bed.double", Soft.violet)
        }
    }

    /// The user's first name, or nil when macOS has no full name for the account.
    static var firstName: String? {
        NSFullUserName().split(separator: " ").first.map(String.init)
    }

    static func signedPercent(_ v: Double) -> String {
        let r = Int(v.rounded())
        return r > 0 ? "+\(r) %" : (r < 0 ? "−\(-r) %" : "±0 %")
    }
}

private struct HomeLoadKey: Equatable { let seq: Int; let offset: Int }

// MARK: - Live-observing pieces (isolated so ~1 Hz HR ticks don't re-render the whole screen)

private struct HomeHero: View {
    @EnvironmentObject var live: LiveState
    let day: DailyMetric?
    let caption: LocalizedStringResource
    @Environment(\.locale) private var locale

    var body: some View {
        AuraHero(callouts: callouts, heartRate: live.heartRate, caption: caption)
    }

    private var callouts: [AuraCallout] {
        let format = HomeFormat(locale: locale)
        var raw: [(id: String, title: LocalizedStringResource, value: String, unit: String,
                   status: LocalizedStringResource)] = []
        if live.connected, let hr = live.heartRate {
            raw.append(("pulse", "Pulse", "\(hr)", "bpm", "Live"))
        } else if let rhr = day?.restingHr {
            raw.append(("restingPulse", "Resting Pulse", "\(rhr)", "bpm", "Last night"))
        }
        if let r = day?.respRateBpm {
            raw.append(("breathing", "Breathing", format.decimal(r, digits: 1), "rpm",
                        (12...20).contains(r) ? "Normal" : "Unusual"))
        }
        if let t = day?.skinTempDevC {
            let s = (t >= 0 ? "+" : "−") + format.decimal(abs(t), digits: 1)
            raw.append(("skinTemp", "Skin Temp", s, "°C", abs(t) < 0.5 ? "Normal" : "Deviation"))
        }
        if let o = day?.spo2Pct {
            raw.append(("oxygen", "Oxygen", "\(Int(o.rounded()))", "%", o >= 95 ? "Normal" : "Low"))
        }
        if let h = day?.avgHrv {
            raw.append(("hrv", "HRV", "\(Int(h.rounded()))", "ms", "Last night"))
        }
        let slots: [(AuraCallout.Side, CGFloat, Double)] = [(.leading, 0.14, 300), (.trailing, 0.82, 140), (.leading, 0.66, 240)]
        return zip(raw.prefix(3), slots).map { r, s in
            AuraCallout(id: r.id, title: r.title, value: r.value, unit: r.unit, status: r.status,
                        side: s.0, labelY: s.1, markerAngle: s.2)
        }
    }
}

private struct HomeAvatar: View {
    @EnvironmentObject var live: LiveState
    let imageData: Data?

    var body: some View {
        ProfileAvatarView(imageData: imageData, size: 44)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(live.connected ? Soft.green : Soft.ink3)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(Soft.canvas, lineWidth: 2))
            }
            .help(live.connected ? "WHOOP connected" : "WHOOP not connected")
    }
}

// MARK: - Timeline bar

struct HomeTimelineBar: View {
    let items: [HomeTimelineItem]
    let dayStart: Date
    let now: Date?

    static func color(_ kind: HomeTimelineItem.Kind) -> Color {
        switch kind {
        case .sleep: return Soft.blue
        case .nap: return Soft.violet
        case .workout: return Soft.green
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let barY: CGFloat = 26
            let x: (Date) -> CGFloat = { d in
                CGFloat(min(max(d.timeIntervalSince(dayStart) / 86_400, 0), 1)) * w
            }
            ZStack(alignment: .topLeading) {
                Capsule().fill(Soft.fill).frame(width: w, height: 16).offset(y: barY)
                ForEach(items) { item in
                    let x0 = x(item.start), x1 = max(x(item.end), x0 + 6)
                    Capsule().fill(Self.color(item.kind).opacity(item.kind == .sleep ? 0.75 : 0.9))
                        .frame(width: x1 - x0, height: 16)
                        .offset(x: x0, y: barY)
                }
                ForEach(Array(stride(from: 0, through: 24, by: 3)), id: \.self) { h in
                    Text(String(format: "%02d:00", h))
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(Soft.ink3)
                        .fixedSize()
                        .position(x: min(max(w * CGFloat(h) / 24, 16), w - 16), y: barY + 36)
                }
                if let now {
                    let nx = x(now)
                    Rectangle().fill(Soft.ink).frame(width: 1.5, height: 32).offset(x: nx - 0.75, y: barY - 8)
                    Text(now, format: .dateTime.hour().minute())
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Soft.card)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Soft.ink, in: Capsule())
                        .fixedSize()
                        .position(x: min(max(nx, 26), w - 26), y: barY - 18)
                }
            }
        }
    }
}
#endif

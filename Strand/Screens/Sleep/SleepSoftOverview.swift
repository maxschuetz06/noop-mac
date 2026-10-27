import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

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
                    Text(HomeStateLabel.relative(value, base: base, higherIsBetter: false))
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

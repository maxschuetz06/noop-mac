import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

extension SleepView {
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
}

extension SleepView {
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
    /// or zero-asleep night (no staging to doubt). (#H9)
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
}

extension SleepView {
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
}

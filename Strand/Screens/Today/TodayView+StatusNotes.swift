import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

extension TodayView {
    // MARK: Component 3 — recording-status chip

    /// The honest recording chip on TODAY: a status word (Recording / Last synced Xm ago / Not recording),
    /// its detail line, and — when not recording — a tap that opens Devices to connect. A connected,
    /// recording strap shows a live pulse dot; otherwise a steady dot in the state's hue. Rendered only at
    /// offset 0 (a past day isn't "recording"); `recordingState` is nil otherwise, so this is empty.
    @ViewBuilder
    var recordingStatusChip: some View {
        if let state = recordingState {
            let isLive = state == .recording
            let hue: Color = {
                switch state {
                case .recording:           return StrandPalette.statusPositive
                case .lastSynced:          return StrandPalette.statusWarning
                case .notRecording:        return StrandPalette.textTertiary
                case .historyExperimental: return StrandPalette.accent
                }
            }()
            // "Not recording" is the only actionable state (tap to connect) — wrap it in a Button; the
            // other two are read-outs. A Group keeps one body shape either way.
            Group {
                if case .notRecording = state {
                    Button {
                        StrandHaptic.selection.play()
                        router.openDevices()
                    } label: { recordingChipBody(state: state, hue: hue, isLive: isLive) }
                    .buttonStyle(StrandPressableButtonStyle())
                } else {
                    recordingChipBody(state: state, hue: hue, isLive: isLive)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.accessibilityText)
            .accessibilityAddTraits(state == .notRecording ? .isButton : [])
        }
    }

    /// The recording chip's visual body: a status dot, the bold status word, and the detail line. Shared
    /// by the read-out and the tappable "Not recording" variant so they read identically.
    @ViewBuilder
    func recordingChipBody(state: RecordingState, hue: Color, isLive: Bool) -> some View {
        HStack(spacing: 10) {
            // A pulsing dot when live, a steady one otherwise — colour AND motion, not hue alone.
            RecordingDot(color: hue, pulsing: isLive)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.label)
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Text(state.detail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            if case .notRecording = state {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StrandPalette.surfaceInset))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hue.opacity(0.28), lineWidth: 1))
    }

    // MARK: Component 2 — explained score note (calibrating / carried / needs-strap)

    /// A small explained-state note for a score whose value isn't a real today number: the state title
    /// (Calibrating / Last night · <date> / Needs the strap), its detail line, and the implicit next step
    /// the detail copy carries. Renders NOTHING for `.scored` (the ring/tile shows the number itself), so
    /// a score never shows a bare blank without a state, a reason and a next step.
    @ViewBuilder
    func explainedScoreNote(_ state: MetricTileState) -> some View {
        if let title = state.title, let detail = state.detail {
            let symbol: String = {
                switch state {
                case .calibrating:      return "gauge.with.dots.needle.bottom.50percent"
                case .carriedLastNight: return "clock.arrow.circlepath"
                case .needsStrap:       return "exclamationmark.circle"
                case .scored:           return "info.circle"
                }
            }()
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text(detail)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            // Inset to the card's content margin so the "Last night · <date>" clock-icon footnote sits a
            // proper distance from the hero's left edge rather than hugging it (it previously used a bare
            // 2pt). Matches NoopMetrics.cardPadding, the standard card content inset.
            .padding(.horizontal, NoopMetrics.cardPadding)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.accessibilityText ?? "")
        }
    }

    // MARK: Screen-4 — data-confidence pill, vitals metric card, HRV-baseline insight

    /// The SOLID / CALIBRATING data-confidence chip beside the hero title (README screen 4).
    /// SOLID (gold) once today carries a settled recovery score; CALIBRATING (slate) while the
    /// HRV baseline is still forming (it shows the running "N of 4" count); for a navigated past
    /// day with no score it falls back to CALIBRATING without a count. Drives off the SAME
    /// recovery / calibration bindings the rings use — presentation only.
    @ViewBuilder
    func recoveryStatePill(score: Double?) -> some View {
        switch TodayDisplayRules.statePill(score: score, calibrationNights: recoveryCalibration) {
        case .solid:
            ScoreStatePill(.solid)
        case .calibrating(let n):
            ScoreStatePill(.calibrating, text: "Calibrating, \(n) of \(Baselines.minNightsSeed)")
        case .hidden:
            EmptyView()
        }
    }

    /// Screen-4 "metric card": HRV / Resting HR / Respiratory as a stack of labelled metric rows
    /// inside one frosted card — the three vitals that feed recovery. HRV reads teal (its biometric
    /// hue), Resting HR burnt-orange, Respiratory gold. Values come straight from the selected day's
    /// `DailyMetric` (respiratory falls back to the loaded sparkline tail, as the tile does).
    ///
    /// When today isn't scored yet (the post-rollover state, #543), the recovery side carries over the
    /// last scored day's vitals — labelled with ONE card-level "Last night · <date>" footnote so the
    /// whole recovery side reads consistently with the carried Charge ring, never blanking to "—" while
    /// live HR ticks. Each row still falls through to "—" for a metric the carried row genuinely lacks
    /// (e.g. a BLE-only night with no SpO₂), and today's own value always wins the instant it lands.
    @ViewBuilder
    func recoveryVitalsCard(_ d: DailyMetric?) -> some View {
        // The row the vitals read from: today's own row when it carries recovery, else the carried-over
        // prior scored day (only when we're carrying — `lastScoredRecoveryDay` is gated to that case).
        let carried = lastScoredRecoveryDay
        let vd = carried ?? d
        NoopCard(tint: StrandPalette.chargeColor) {
            VStack(spacing: 0) {
                metricRow(icon: "waveform.path.ecg", label: "HRV",
                          value: vd?.avgHrv.map { "\(Int($0.rounded()))" } ?? "—", unit: "ms",
                          tint: StrandPalette.metricCyan)
                Divider().overlay(StrandPalette.hairline)
                metricRow(icon: "heart.fill", label: "Resting HR",
                          value: vd?.restingHr.map { "\($0)" } ?? "—", unit: "bpm",
                          tint: StrandPalette.metricRose)
                Divider().overlay(StrandPalette.hairline)
                metricRow(icon: "lungs.fill", label: "Respiratory",
                          // Carried day uses its OWN respiratory; a non-carrying today keeps the
                          // sparkline-tail fallback the tile uses so a sparse-but-recent value still reads.
                          value: vd?.respRateBpm.map { String(format: "%.1f", $0) }
                              ?? (carried == nil ? latestString("resp_rate", decimals: 1) : "—"),
                          unit: "rpm",
                          tint: StrandPalette.accent)
                // ONE provenance footnote when these are carried prior-day vitals (not today's), matching
                // the carried Charge ring's "Last night · <date>" stamp — so the whole recovery side is
                // consistently labelled as a prior read rather than silently passing yesterday off as today.
                if let prior = carried {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                        Text(carriedCaption(prior))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 10)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("These vitals are from \(carriedCaption(prior))")
                }
            }
        }
    }

    /// One README "metric row": a metric-hue line icon, a secondary label, and a right-aligned bold
    /// value with a small unit. Rows are divided by a hairline. Shared by the Today vitals card.
    @ViewBuilder
    func metricRow(icon: String, label: String, value: String, unit: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(label)
                .font(StrandFont.footnote.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(StrandFont.number(24))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(unit)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value) \(unit)")
    }
}

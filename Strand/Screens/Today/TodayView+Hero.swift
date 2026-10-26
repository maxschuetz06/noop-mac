import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

extension TodayView {
    // MARK: (a) HERO — three ring scores (Charge / Effort / Rest) over a scenic backdrop,
    // then the green-tinted Synthesis coaching card. Bevel layout.

    @ViewBuilder
    var heroSection: some View {
        let d = displayDay
        let score = d?.recovery
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // Recording status now lives as a colour-coded light in the header icon row, not a full-width
            // banner sandwiched above the rings. The three clean rings lead the screen directly.
            scoreHeroRow(d: d, score: score)

            // Component 2 — when Charge has no real today value, an explained state with its detail +
            // next step replaces a bare blank, sitting directly under the rings. The CALIBRATING case is
            // already richly explained by the data-confidence pill + calibration Synthesis card + the ring
            // overlay below, so the note shows for the two states the existing UI doesn't spell out a next
            // step for — "Last night · <date>" (carry-over) and "Needs the strap" — keeping the hero from
            // saying "calibrating" twice in two phrasings. `.scored` renders nothing (the ring has the
            // value). TODAY-only: the "No data for today" copy would be wrong on a navigated past day, and
            // a past day with no score is missing data the user can't act on now, so it keeps a bare ring.
            if selectedDayOffset == 0 && !chargeScoreState.isCalibrating {
                explainedScoreNote(chargeScoreState)
            }

        }
    }
}

extension TodayView {
    /// The three score rings over a scenic hero background — WHOOP-style, with the Charge (recovery)
    /// ring centred and enlarged as the hero and smaller Rest / Effort rings flanking it. Each ring
    /// floats cleanly on the scenic field (no per-ring card); a tappable label + chevron sits beneath
    /// each and opens that score's section in the scoring guide. Rings are sized off the available
    /// width so the trio never crushes on a narrow phone nor bloats on iPad.
    @ViewBuilder
    func scoreHeroRow(d: DailyMetric?, score: Double?) -> some View {
        GeometryReader { geo in
            // Design Reset: three EQUAL clean rings (no glow, faint track) in Charge / Effort / Rest order
            // with generous spacing — mirrors the flat mockup. Sized off width so they stay equal on any phone.
            let ring = min(98, max(82, (geo.size.width - 56) / 3.4))
            HStack(alignment: .top, spacing: 22) {
                // Component 4 — Charge/Rest badge their real per-day merge winner; Effort has no badge.
                heroRingColumn(section: .charge, domain: .charge, provenanceKey: "recovery") { chargeRing(score: score, d: d, diameter: ring) }
                heroRingColumn(section: .effort, domain: .effort) { effortRing(d: d, diameter: ring) }
                heroRingColumn(section: .rest, domain: .rest, provenanceKey: "sleep_performance") { restRing(diameter: ring) }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        .frame(height: 150)
    }

    /// One hero ring column: the ring centred, with a tappable UPPERCASE domain label + chevron
    /// beneath it (the WHOOP affordance) that opens the matching scoring-guide section. The ring is
    /// intrinsically diameter×diameter, so the column just centres it and stretches to an equal share
    /// of the row width.
    @ViewBuilder
    func heroRingColumn<RingBody: View>(
        section: ScoreSection, domain: DomainTheme, provenanceKey: String? = nil,
        @ViewBuilder ring: () -> RingBody
    ) -> some View {
        VStack(spacing: 8) {
            ring()
            Button { guideSection = section } label: {
                HStack(spacing: 3) {
                    Text(domain.rawValue.uppercased())
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.6)
                }
                .foregroundStyle(StrandPalette.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("How \(domain.rawValue.capitalized) is calculated")
            // Component 4 — the real per-day source under the ring (only when this score has a value for
            // the day AND we resolved its winner; a calibrating / empty ring shows no provenance badge).
            if let key = provenanceKey, ringHasValue(key), let label = provenanceLabel(key) {
                SourceBadge("\(label)", tint: provenanceTint(key))
                    .accessibilityLabel("Source: \(label)")
            }
        }
    }

    /// Whether the score behind a provenance key has a real value for the selected day — gates the ring's
    /// provenance badge so it only appears alongside an actual number (Charge = recovery, Rest = restScore).
    func ringHasValue(_ metricKey: String) -> Bool {
        switch metricKey {
        case "recovery":          return displayDay?.recovery != nil
        case "sleep_performance": return restScore != nil
        default:                  return false
        }
    }

    /// Charge (recovery 0–100) hero ring — the premium animated GlowRing, with a calibrating / no-data
    /// track when nil.
    @ViewBuilder
    func chargeRing(score: Double?, d: DailyMetric?, diameter: CGFloat) -> some View {
        if let s = score {
            GlowRing(fraction: s / 100, value: s, format: { "\(Int($0.rounded()))" },
                     color: StrandPalette.chargeColor, diameter: diameter, lineWidth: diameter * 0.10)
        } else {
            emptyHeroRing(diameter: diameter) { ringEmptyOverlay(d: d, diameter: diameter) }
        }
    }

    /// Effort (strain) hero ring, honouring the 0–100 / WHOOP-0–21 toggle (#313). Integer on the 0–100
    /// axis so it matches Charge/Rest; one decimal on the WHOOP 0–21 axis where the tenth matters.
    @ViewBuilder
    func effortRing(d: DailyMetric?, diameter: CGFloat) -> some View {
        if effortStrain(d) != nil, let gv = effortGaugeValue(d) {
            GlowRing(fraction: gv / effortGaugeMax, value: gv,
                     format: { effortScale == .whoop ? String(format: "%.1f", $0) : "\(Int($0.rounded()))" },
                     color: StrandPalette.effortColor, diameter: diameter, lineWidth: diameter * 0.10)
        } else {
            emptyHeroRing(diameter: diameter) { ringNoData(diameter: diameter) }
        }
    }

    /// Rest (sleep composite 0–100) hero ring.
    @ViewBuilder
    func restRing(diameter: CGFloat) -> some View {
        if let s = restScore {
            GlowRing(fraction: s / 100, value: s, format: { "\(Int($0.rounded()))" },
                     color: StrandPalette.restColor, diameter: diameter, lineWidth: diameter * 0.10)
        } else {
            emptyHeroRing(diameter: diameter) { ringNoData(diameter: diameter) }
        }
    }

    /// The faint full-circle track with a centred overlay, shown when a score is still calibrating/absent.
    @ViewBuilder
    func emptyHeroRing<Overlay: View>(diameter: CGFloat, @ViewBuilder overlay: () -> Overlay) -> some View {
        ZStack {
            Circle().stroke(StrandPalette.textPrimary.opacity(0.10),
                            style: StrokeStyle(lineWidth: diameter * 0.10, lineCap: .round))
            overlay()
        }
        .frame(width: diameter, height: diameter)
    }

    /// The effective Effort strain (NOOP 0–100 axis) the gauge shows. For TODAY this prefers the live
    /// in-progress value computed over the day's HR (midnight→now) in `loadAll`, so the gauge reflects
    /// the accumulating day rather than the last persisted daily row — which only refreshes when the
    /// heavy daily pass runs, so early in the day the stored row is yesterday's Effort or a stale 0.0
    /// (#402). Falls back to the stored `strain` when there isn't yet enough of today's HR to score
    /// (StrainScorer.minReadings). Navigated past days always use the stored row.
    func effortStrain(_ d: DailyMetric?) -> Double? {
        if selectedDayOffset == 0, let live = liveTodayStrain {
            // Effort accrues over a day and must never visibly DROP. The in-progress recompute (raw day
            // HR, midnight→now) can UNDER-read when today's HR is sparse or a logged workout's load isn't
            // in the raw stream — e.g. a 5/MG user who trained this morning saw today's real 38.3 get
            // replaced by a live 0 (#489/#506). Floor at the day's already-earned Effort. `d` (displayDay)
            // for today is ALWAYS today's row or nil — never a prior day — so this can't resurrect a stale
            // day; it only stops the gauge dropping below what's already been counted today.
            if let stored = d?.strain { return Swift.max(live, stored) }
            return live
        }
        return d?.strain
    }

    /// When TODAY's Effort scores a genuine near-zero — there's enough HR to score, but it never
    /// crossed the cardiovascular "effort zone" (~50% of heart-rate reserve) — explain the 0 instead
    /// of leaving a bare number that reads as a fault (#482/#480). A low-HR day honestly earns ~0, the
    /// same as a WHOOP low-strain day; the 5/MG just hits it more often (sparser HR, lower daytime
    /// peaks). Only for today, only when the score is ~0 and a score exists (a no-data ring shows its
    /// own overlay, a past day isn't annotated).
    var effortZeroNote: String? {
        guard selectedDayOffset == 0, let s = effortStrain(displayDay), s < 1.0 else { return nil }
        return "No cardio load yet — Effort builds once your heart rate climbs into your effort zone (around 50% of your heart-rate reserve). A calm day honestly reads near zero."
    }

    /// Strain value to feed the Effort gauge, on the SELECTED display scale (#313). The effective
    /// `strain` is on NOOP's 0–100 Effort axis; `UnitFormatter.effortValue` converts it to the
    /// user's chosen scale (0–100 native, or ×21/100 down to WHOOP's 0–21) so the arc + number
    /// match the rest of the app's Effort read-outs. Pairs with `effortGaugeMax` for the "of N".
    func effortGaugeValue(_ d: DailyMetric?) -> Double? {
        effortStrain(d).map { UnitFormatter.effortValue($0, scale: effortScale) }
    }

    /// The Effort gauge's scale maximum — 100 on NOOP's native axis, 21 on the WHOOP axis. Drives
    /// the arc fraction and the gauge's "of N" caption so both follow the toggle (#313).
    var effortGaugeMax: Double { effortScale == .whoop ? 21 : 100 }

    /// Honest overlay shown over the Charge ring when today's recovery is nil: calibrating count, the
    /// last scored Charge carried over, or No data. After the logical-day rollover the new day has no
    /// recovery until tonight is scored; rather than a bare "No data" on the hero ring while live HR
    /// ticks (which reads as broken, #543), show the most recent scored Charge as a centred read-out
    /// clearly stamped "Last night · <date>". The ring TRACK stays empty (today genuinely isn't scored,
    /// so we never fill the GlowRing as if it were today's number) — the carried value sits inside it as
    /// a labelled prior reading, the way WHOOP keeps last recovery visible until the new one lands.
    @ViewBuilder
    func ringEmptyOverlay(d: DailyMetric?, diameter: CGFloat) -> some View {
        VStack(spacing: 3) {
            if let n = recoveryCalibration {
                // "Calibrating" is a long word for the ring's interior — it reads as the centre label, with
                // the same lineLimit/scaleFactor guard so it never wraps, then its "N of 4" subtitle below.
                Text("Calibrating").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7).fixedSize()
                Text("\(n) of \(Baselines.minNightsSeed)").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
            } else if let carried = lastScoredCharge {
                // Ring text consistency (#hero): the carried "49%" centre number renders in the SAME size +
                // weight as a filled ring's number (GlowRing.centerFont), so a carried Charge, a clean "93"
                // and a "No data" ring all share one centre-number style. Its "Last night" subtitle stays a
                // footnote, matching the calibrating subtitle.
                Text("\(Int(carried.value.rounded()))%")
                    .font(GlowRing.centerFont(diameter: diameter))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.recoveryColor(carried.value))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(carried.caption)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                ringNoData(diameter: diameter)
            }
        }
    }

    @ViewBuilder
    func ringNoData(diameter: CGFloat) -> some View {
        // "No data" reads as the centre label at the same weight family as the ring numbers. lineLimit +
        // fixedSize so a small flanking ring (Rest/Effort) never wraps it mid-word inside the ring's narrow
        // interior (#495/#549).
        Text("No data").font(StrandFont.headline).foregroundStyle(StrandPalette.textSecondary)
            .lineLimit(1).minimumScaleFactor(0.7).fixedSize()
    }
}

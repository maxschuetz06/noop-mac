import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

extension SleepView {
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
            // one popover shows at a time across several nap rows.
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
}

import SwiftUI
import WidgetKit
import StrandDesign

struct MacEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let isPlaceholder: Bool
}

struct MacProvider: TimelineProvider {
    func placeholder(in context: Context) -> MacEntry {
        MacEntry(date: Date(), snapshot: .placeholder, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (MacEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MacEntry>) -> Void) {
        // The app reloads timelines whenever it publishes; this is only the fallback refresh.
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [current()], policy: .after(next)))
    }

    private func current() -> MacEntry {
        if let snap = WidgetSnapshot.load() {
            return MacEntry(date: Date(), snapshot: snap, isPlaceholder: false)
        }
        return MacEntry(date: Date(), snapshot: .placeholder, isPlaceholder: true)
    }
}

struct MacWidgetView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    let entry: MacEntry
    /// QA seam: `widgetFamily` is read-only, so offscreen snapshot tests pick the layout through this.
    var familyOverride: WidgetFamily? = nil

    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    private var snap: WidgetSnapshot { entry.snapshot }

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemLarge: large
            default: medium
            }
        }
        .redacted(reason: entry.isPlaceholder ? .placeholder : [])
    }

    // MARK: Layouts

    private var small: some View {
        VStack(spacing: 6) {
            header
            recoveryRing
            HStack {
                Label(snap.hrv.map { "\($0) ms" } ?? "–", systemImage: "waveform.path.ecg")
                Spacer(minLength: 4)
                Label(snap.restingHr.map(String.init) ?? "–", systemImage: "heart")
            }
            .font(.caption2)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var medium: some View {
        VStack(spacing: 8) {
            header(showsSync: true)
            rings
        }
    }

    private var large: some View {
        VStack(spacing: 12) {
            header
            rings
                .aspectRatio(2.45, contentMode: .fit)
            Divider()
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    stat("HRV", snap.hrv.map(String.init), unit: "ms")
                    stat("Resting Pulse", snap.restingHr.map(String.init), unit: "bpm")
                }
                GridRow {
                    stat("Pulse", snap.bpm.map(String.init), unit: "bpm")
                    stat("Battery", snap.batteryPct.map { "\($0)%" })
                }
            }
            Spacer(minLength: 0)
            HStack { syncLine; Spacer(minLength: 0) }
        }
    }

    // MARK: Pieces

    /// The three WHOOP home-screen rings in WHOOP order: effort · recovery · sleep.
    private var rings: some View {
        HStack(spacing: 8) {
            MetricRingColumn(
                label: "Effort",
                fill: WidgetRingFormat.fill(snap.effort),
                color: StrandPalette.accent,
                valueText: WidgetRingFormat.strainText(effort: snap.effort),
                isEmpty: snap.effort == nil
            )
            recoveryRingColumn
            MetricRingColumn(
                label: "Sleep",
                fill: WidgetRingFormat.fill(snap.rest),
                color: StrandPalette.sleepAwake,
                valueText: WidgetRingFormat.percentText(snap.rest),
                isEmpty: snap.rest == nil
            )
        }
    }

    private var recoveryRingColumn: some View {
        MetricRingColumn(
            label: "Recovery",
            fill: WidgetRingFormat.fill(snap.recovery),
            color: recoveryColor,
            valueText: WidgetRingFormat.percentText(snap.recovery),
            isEmpty: snap.recovery == nil
        )
    }

    /// Small family: the recovery ring alone, large, with its caption below.
    private var recoveryRing: some View {
        MetricRingColumn(
            label: "Recovery",
            fill: WidgetRingFormat.fill(snap.recovery),
            color: recoveryColor,
            valueText: WidgetRingFormat.percentText(snap.recovery),
            isEmpty: snap.recovery == nil,
            valueScale: 0.29
        )
    }

    private var header: some View { header(showsSync: false) }

    private func header(showsSync: Bool) -> some View {
        HStack(spacing: 6) {
            Text("WHOOP").font(.system(size: 12, weight: .bold)).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 4)
            if showsSync {
                syncLine.minimumScaleFactor(0.7)
            }
            if let battery = snap.batteryPct, family != .systemLarge {
                Text("\(battery)%").font(.caption2).foregroundStyle(StrandPalette.textTertiary)
            }
            Circle()
                .fill(snap.bonded ? StrandPalette.statusPositive : StrandPalette.textTertiary)
                .frame(width: 7, height: 7)
                .accessibilityLabel(snap.bonded ? "Connected" : "Not connected")
        }
    }

    @ViewBuilder private var syncLine: some View {
        if let sync = snap.lastSync {
            Text("Sync \(sync, style: .relative)")
                .font(.caption2).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
        } else {
            Text("No sync yet").font(.caption2).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
        }
    }

    private func stat(_ label: LocalizedStringKey, _ value: String?, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "–")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit, value != nil {
                    Text(unit).font(.caption2).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Text(label).font(.caption2).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recoveryColor: Color {
        switch WidgetRingFormat.recoveryZone(snap.recovery) {
        case .green: return StrandPalette.statusPositive
        case .yellow: return StrandPalette.statusWarning
        case .red: return StrandPalette.statusCritical
        case .unknown: return StrandPalette.textTertiary
        }
    }
}

struct NOOPMacWidget: Widget {
    let kind = "NOOPMacWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MacProvider()) { entry in
            MacWidgetView(entry: entry)
                .containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("WHOOP Metrics")
        .description("Recovery, effort, sleep, HRV and resting pulse at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct NOOPMacWidgetBundle: WidgetBundle {
    var body: some Widget {
        NOOPMacWidget()
    }
}

// MARK: - Previews

#if DEBUG
private extension WidgetSnapshot {
    static var previewFull: WidgetSnapshot {
        WidgetSnapshot(recovery: 72, bpm: 61, batteryPct: 84, bonded: true, updated: Date(),
                       effort: 59, rest: 84, hrv: 64, restingHr: 52,
                       lastSync: Date().addingTimeInterval(-12 * 60))
    }
    /// Mostly empty: only a low recovery, no strain/sleep/vitals, no sync yet.
    static var previewSparse: WidgetSnapshot {
        WidgetSnapshot(recovery: 28, bpm: nil, batteryPct: nil, bonded: false, updated: Date())
    }
}

#Preview("Small", as: .systemSmall) {
    NOOPMacWidget()
} timeline: {
    MacEntry(date: Date(), snapshot: .previewFull, isPlaceholder: false)
    MacEntry(date: Date(), snapshot: .previewSparse, isPlaceholder: false)
    MacEntry(date: Date(), snapshot: .placeholder, isPlaceholder: true)
}

#Preview("Medium", as: .systemMedium) {
    NOOPMacWidget()
} timeline: {
    MacEntry(date: Date(), snapshot: .previewFull, isPlaceholder: false)
    MacEntry(date: Date(), snapshot: .previewSparse, isPlaceholder: false)
    MacEntry(date: Date(), snapshot: .placeholder, isPlaceholder: true)
}

#Preview("Large", as: .systemLarge) {
    NOOPMacWidget()
} timeline: {
    MacEntry(date: Date(), snapshot: .previewFull, isPlaceholder: false)
    MacEntry(date: Date(), snapshot: .previewSparse, isPlaceholder: false)
    MacEntry(date: Date(), snapshot: .placeholder, isPlaceholder: true)
}
#endif

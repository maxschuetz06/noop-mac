import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

extension TodayView {
    // MARK: (c) LAST WORKOUTS — SAME grid, uniform 104pt workout tiles.

    @ViewBuilder
    var workoutsSection: some View {
        if !workouts.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Last Workouts", overline: "Activity",
                              trailing: "\(workouts.count) total")
                LazyVGrid(columns: grid, alignment: .leading, spacing: NoopMetrics.gap) {
                    ForEach(Array(workouts.prefix(6).enumerated()), id: \.offset) { _, w in
                        StatTile(
                            label: "\(WorkoutSource.displaySport(w.sport))",
                            value: workoutDuration(w),
                            caption: workoutCaption(w),
                            accent: StrandPalette.effortTint(fraction: (w.strain ?? 0) / StrainScorer.maxStrain),
                            delta: w.energyKcal.map { "\(Int($0.rounded())) kcal" },
                            deltaColor: StrandPalette.metricAmber
                        )
                    }
                }
            }
        }
    }

    // MARK: (d) DATA SOURCES — one full-width footer card.

    @ViewBuilder
    var sourcesSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Data Sources", overline: "Provenance")
            NoopCard {
                VStack(alignment: .leading, spacing: 12) {
                    sourceRow(
                        badge: "Whoop",
                        tint: StrandPalette.accent,
                        present: !repo.days.isEmpty,
                        detail: "\(repo.days.count) days · \(repo.sleeps.count) sleeps"
                    )
                    Divider().overlay(StrandPalette.hairline)
                    sourceRow(
                        badge: "Apple Health",
                        tint: StrandPalette.metricCyan,
                        present: !appleDays.isEmpty,
                        detail: "\(appleDays.count) days · \(workouts.filter { WorkoutSource.isAppleHealth($0.source) }.count) workouts"
                    )
                    if xiaomiDays > 0 {
                        Divider().overlay(StrandPalette.hairline)
                        sourceRow(
                            badge: "Mi Band",
                            tint: StrandPalette.metricAmber,
                            present: true,
                            detail: "\(xiaomiDays) days · \(xiaomiSleeps) sleeps"
                        )
                    }
                    strapBatteryRow
                    Divider().overlay(StrandPalette.hairline)
                    strapSyncRow
                }
            }
        }
    }

    @ViewBuilder
    func sourceRow(badge: String, tint: Color, present: Bool, detail: String) -> some View {
        HStack(spacing: 10) {
            SourceBadge("\(badge)", tint: present ? tint : StrandPalette.textTertiary)
            Spacer()
            Text(present ? detail : "Not connected")
                .font(StrandFont.captionNumber)
                .foregroundStyle(present ? StrandPalette.textSecondary : StrandPalette.textTertiary)
        }
    }

    /// Honest strap-sync outcome for a cloud-free app (ports the Android Live line, ed6a31d): the
    /// stalled-offload error when the last one died, else "History synced N ago". Hidden while an
    /// offload runs — SyncingHistoryNote already says so. TimelineView re-renders the relative label
    /// each minute so "5 min ago" can't go stale while the window sits open with no strap connected
    /// (LiveState publishes nothing then).
    @ViewBuilder
    var strapSyncRow: some View {
        if !live.backfilling {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(alignment: .top, spacing: 10) {
                    SourceBadge("Strap sync",
                                tint: live.lastSyncError != nil ? StrandPalette.statusWarning
                                    : live.lastSyncedAt != nil ? StrandPalette.accent
                                    : StrandPalette.textTertiary)
                    Spacer()
                    if let error = live.lastSyncError {
                        Text(error)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let at = live.lastSyncedAt {
                        Text("History synced \(relativeAgo(at, now: context.date.timeIntervalSince1970))")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        Text("Not synced yet")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    /// Strap battery on the dashboard (#159) — the live reading the keep-alive refreshes, so a glance
    /// covers charge without opening Live. Rendered ONLY while a strap is connected AND a reading
    /// exists; otherwise the row (and its divider) isn't there at all — no empty state.
    @ViewBuilder
    var strapBatteryRow: some View {
        if live.connected, let pct = live.batteryPct {
            Divider().overlay(StrandPalette.hairline)
            HStack(spacing: 10) {
                SourceBadge("Strap battery", tint: batteryTint(pct))
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: batterySymbol(pct))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(batteryTint(pct))
                    Text("\(Int(pct.rounded()))%")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Strap battery \(Int(pct.rounded())) percent\(live.charging == true ? ", charging" : "")")
            }
        }
    }

    /// Battery tint — same thresholds as the menu-bar stat (MenuBarContent.batteryTone).
    func batteryTint(_ pct: Double) -> Color {
        switch pct {
        case ..<15: return StrandPalette.statusCritical
        case ..<35: return StrandPalette.statusWarning
        default:    return StrandPalette.statusPositive
        }
    }

    /// Level-banded battery glyph; the bolt variant when the strap reports charging.
    func batterySymbol(_ pct: Double) -> String {
        if live.charging == true { return "battery.100.bolt" }
        switch pct {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default:    return "battery.100"
        }
    }
}

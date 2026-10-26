import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotosUI
import StrandDesign
import StrandAnalytics
import WhoopStore

extension SettingsView {
    // MARK: - Features (opt-in trackers)

    /// Opt-in, manual-first feature toggles (default OFF). Hydration tracking gates the water-log card on
    /// the Today dashboard and its detail screen — nothing is shown or stored until it's enabled.
    var featuresCard: some View {
        SettingsSection(
            icon: "drop.fill",
            title: "Features",
            blurb: "Optional trackers, off by default. Turn them on to add their cards. Everything stays on \(Platform.deviceNounPhrase)."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2 + 2) {
                Toggle(isOn: $hydrationEnabled) {
                    Text("Hydration tracking")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .accessibilityHint("Adds a water-log card to your dashboard")

                Text("Adds a simple fluid log with a daily goal that adjusts to your effort. Tap to add a sip, cup or bottle and watch a progress ring fill. On \(Platform.deviceNounPhrase) only — nothing is synced.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(StrandPalette.hairline)

                Toggle(isOn: $autoDetectWorkoutsEnabled) {
                    Text("Auto-detect workouts")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .accessibilityHint("Offers to save a workout when it spots sustained elevated heart rate")

                Text("After a sync, NOOP looks over your recent heart rate for a sustained, raised stretch that looks like exercise and offers to save it. It only ever suggests — nothing is saved until you tap Save, and you can dismiss any suggestion. Deliberately conservative, so the odd workout may be missed. On \(Platform.deviceNounPhrase) only.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

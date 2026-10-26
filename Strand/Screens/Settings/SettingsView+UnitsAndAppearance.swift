import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotosUI
import StrandDesign
import StrandAnalytics
import WhoopStore

extension SettingsView {
    // MARK: - Units

    /// Imperial/Metric display toggle + a separate temperature override. Display-only — nothing stored
    /// changes, NOOP keeps everything in SI and converts at the point of display.
    var unitsCard: some View {
        SettingsSection(
            icon: "ruler",
            title: "Units",
            blurb: "Choose how distances, weights, heights, temperatures and Effort are shown. Your data is always stored the same way — this only changes the display."
        ) {
            VStack(spacing: 0) {
                FormRow(label: "Measurement system") {
                    Picker("Measurement system", selection: $unitSystemRaw) {
                        Text("Metric").tag(UnitSystem.metric.rawValue)
                        Text("Imperial").tag(UnitSystem.imperial.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityLabel("Measurement system")
                }
                rowDivider
                FormRow(label: "Temperature") {
                    // Three-way: "Match" follows the system above; °C / °F pin it explicitly. Stored as
                    // an empty string ("match") or the TemperatureUnit raw value.
                    Picker("Temperature", selection: $temperatureRaw) {
                        Text("Match").tag("")
                        Text("°C").tag(TemperatureUnit.celsius.rawValue)
                        Text("°F").tag(TemperatureUnit.fahrenheit.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityLabel("Temperature unit")
                }
                rowDivider
                // Effort scale (#268) — show NOOP's native 0–100 Effort or WHOOP's 0–21 Day Strain axis.
                // Display-only; the stored value never changes, so a flip just re-labels every Effort read-out.
                FormRow(label: "Effort scale") {
                    Picker("Effort scale", selection: $effortScaleRaw) {
                        Text("0–100").tag(EffortScale.hundred.rawValue)
                        Text("0–21").tag(EffortScale.whoop.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityLabel("Effort scale")
                }
            }
        }
    }

    // MARK: - Appearance (Theme everywhere; alternate app icon iOS-only)

    /// Theme (System / Light / Dark) on every platform, plus the iOS app-icon choice. The Theme picker
    /// writes `AppearanceMode.storageKey`, which both app roots read via `.preferredColorScheme`; because
    /// every palette token is a dynamic `Color(light:dark:)`, the whole UI re-resolves on change.
    var appearanceCard: some View {
        SettingsSection(
            icon: "circle.lefthalf.filled",
            title: "Appearance",
            blurb: "Choose Light, Dark, or follow your system. Dark is the signature near-black; Light keeps the same clean look on a bright canvas."
        ) {
            VStack(spacing: 0) {
                FormRow(label: "Theme") {
                    Picker("Theme", selection: $appearanceRaw) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityLabel("Theme")
                }
                FormRow(label: "Chart colours") {
                    // Default = NOOP's clean metric ramps; Classic = the throwback red→amber→green
                    // readiness scale (cool→hot zones, green→red stress). Both schemes.
                    Picker("Chart colours", selection: $chartStyleRaw) {
                        ForEach(ChartStyle.allCases) { style in
                            Text(style.label).tag(style.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityLabel("Chart colours")
                }
            }
        }
    }
}

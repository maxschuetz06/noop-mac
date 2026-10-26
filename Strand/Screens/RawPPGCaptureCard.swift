import SwiftUI
import StrandDesign

/// Opt-in toggle for `RawPPGCapture` (default OFF). Self-contained so it owns its own `@AppStorage`
/// and does not touch the other Experimental rows. Hidden in builds without an external data folder,
/// where the capture has nowhere to write.
struct RawPPGCaptureCard: View {
    @AppStorage(RawPPGCapture.enabledKey) private var enabled = false
    private let folder = ExternalDataFolder.current

    var body: some View {
        if let folder {
            SettingsSection(
                icon: "waveform.path.ecg",
                title: "Experimental · Raw PPG",
                blurb: "Keeps the raw optical (PPG) history frames of your WHOOP 5/MG on this Mac so SpO₂ can be reverse-engineered offline. Off by default; nothing is uploaded."
            ) {
                VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                    Toggle(isOn: $enabled) {
                        Text("Record raw PPG for SpO₂ research")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .toggleStyle(.switch)
                    .tint(StrandPalette.accent)
                    Text("Appends the raw history frames (layouts v20/v21/v26) of every sync to \(folder.rawPPGDisplayPath) — roughly 100 MB per night. Finished days are compressed; files are kept for 30 days, at most 2 GB in total (oldest deleted first).")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

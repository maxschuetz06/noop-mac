import SwiftUI
import StrandDesign

/// Strain/illness early-warning banner. Observes AppModel in isolation so the ~1 Hz HR stream
/// re-renders only this small view, not the whole screen. Renders nothing when there's no alert.
struct HealthAlertBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let alert = model.healthAlert {
            // A frosted, warning-tinted alert card (not a flat coloured bar) — prominent but on-brand.
            // The amber wash + a glyph in a soft amber chip read as an early-warning without a hard rule.
            NoopCard(padding: 14, tint: StrandPalette.statusWarning) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.statusWarning)
                        .frame(width: 30, height: 30)
                        .background(StrandPalette.statusWarning.opacity(0.16), in: Circle())
                        .accessibilityHidden(true)
                    Text(alert)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

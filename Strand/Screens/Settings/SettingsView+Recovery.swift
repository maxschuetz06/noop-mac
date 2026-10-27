import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotosUI
import StrandDesign
import StrandAnalytics
import WhoopStore

extension SettingsView {
    // MARK: - Recovery (Charge baseline)

    /// Advanced recovery controls. The Recalibrate button re-anchors the whole Charge (recovery)
    /// baseline from tonight onward — the cure for a baseline poisoned by a bad first week (worn sick,
    /// or an early reading that anchored too high). It writes now (epoch SECONDS) to BOTH the
    /// `noop.hrvBaselineEpoch` and `noop.recoveryBaselineEpoch` settings the recovery engine reads, then
    /// kicks a recompute the same way the sleep-edit path does (analyzeRecent → refresh). History stays.
    var recoveryCard: some View {
        SettingsSection(
            icon: "heart.text.square",
            title: "Recovery",
            blurb: "Your Charge score learns a personal baseline from your heart-rate variability, resting heart rate and more over time. If a bad first week set it off, you can re-learn it from tonight. Your history stays."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                NoopButton("Recalibrate Charge baseline", systemImage: "arrow.triangle.2.circlepath", kind: .secondary) {
                    showRecalibrateConfirm = true
                }

                Text("Restarts the roughly 4-night build-up for Charge and your HRV baseline from tonight. Use it if a bad first week set your baseline off. Your history stays.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Write the recalibration anchor and trigger a recompute. Re-anchors EVERY baseline that feeds
    /// Charge — HRV plus resting HR / respiration / skin temp — by writing now (epoch SECONDS) to both
    /// `noop.hrvBaselineEpoch` and `noop.recoveryBaselineEpoch` via the single cross-platform source of
    /// truth (`Baselines.recalibrateRecoveryBaselines`). No stored day is deleted; only the day the
    /// baselines re-learn from moves. Then re-score + refresh so the change is reflected without a
    /// relaunch (same path as a sleep edit), and Today honestly shows the building/calibrating state.
    func recalibrateHrvBaseline() {
        Baselines.recalibrateRecoveryBaselines()
        Task {
            await model.intelligence.analyzeRecent()
            await model.repo.refresh()
        }
        backupAlertTitle = "Charge baseline recalibrating"
        backupAlertMessage = "NOOP will re-learn your baseline from tonight's data onward. Your history is kept, and it takes a few nights to settle."
        showBackupAlert = true
    }
}

import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

extension TodayView {
    // MARK: - Scoring-guide info affordance

    /// A small ⓘ that opens the scoring guide at the given score's section. Sized + tinted as
    /// unobtrusive chrome so it sits in a tile/card corner without competing with the value.
    func scoreInfoButton(_ section: ScoreSection) -> some View {
        Button {
            guideSection = section
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("How \(section.rawValue.capitalized) is calculated")
        .help("How this score is calculated")
    }

    /// H6 — the small ⚙︎ on an ESTIMATED Steps tile that opens the steps-calibration sheet. A WHOOP 4.0
    /// strap doesn't transmit steps, so NOOP estimates them from motion calibrated to the phone's count;
    /// this puts the "tune that estimate" entry right where the user reads the "est." caption.
    var stepsCalibrationButton: some View {
        Button {
            showStepsCalibration = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Calibrate steps estimate")
        .help("Calibrate the steps estimate")
    }

    /// #589 — true once the WHOOP-4.0 steps-ESTIMATE pipeline has run for this user, i.e. the
    /// IntelligenceEngine has mirrored some calibration state into the profile (a fitted/manual
    /// coefficient, OR a recorded count of overlapping phone-counted days while still gathering).
    /// Gates the "needs calibration" affordance so a user whose strap reports real steps (5/MG) or who
    /// has no strap at all never sees a steps-calibration prompt on a blank tile.
    var stepsPipelineActive: Bool {
        profile.stepsCalibrationCoefficient > 0
            || profile.stepsManualCoefficient > 0
            || profile.stepsCalibrationSampleDays > 0
    }

    /// #589 — the honest one-liner for a blank, not-yet-calibrated Steps tile: how many more days the
    /// phone also has to count steps before an estimate appears. Built from the SAME engine descriptor
    /// Settings uses (`StepsEstimateEngine.CalibrationStatus`) so the wording matches across surfaces.
    var stepsCalibrationCaption: String {
        let status = StepsEstimateEngine.CalibrationStatus.needsMoreDays(
            have: profile.stepsCalibrationSampleDays,
            need: StepsEstimateEngine.minCalibrationDays)
        return status.headline
    }
}

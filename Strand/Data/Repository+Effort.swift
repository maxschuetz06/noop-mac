import Foundation
import WhoopStore
import StrandAnalytics

// MARK: - Live Effort (in-progress strain) shared by Home and Day Details

extension Repository {
    /// Running Effort over the strap's HR samples in [from, to], scored with the daily pass's parameters
    /// (Tanaka HRmax from age when known, the day's resting HR else the default, sex), so the live number
    /// matches what the engine later persists. nil below `StrainScorer.minReadings`.
    func liveStrain(from: Int, to: Int, restingHr: Int?, age: Int, sex: String) async -> Double? {
        let samples = await hrSamples(from: from, to: to)
        let maxHR = age > 0 ? StrainScorer.tanakaHRmax(age: Double(age)) : nil
        let restHR = restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
        return StrainScorer.strain(samples, maxHR: maxHR, restingHR: restHR, sex: sex)
    }

    /// Position of an Effort value on the full Effort scale (0…1 for 0…`StrainScorer.maxStrain`).
    nonisolated static func effortFraction(_ strain: Double) -> Double {
        strain / StrainScorer.maxStrain
    }
}

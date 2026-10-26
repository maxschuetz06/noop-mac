import Foundation
import WhoopStore

/// The user's profile as the recompute reads it: a value snapshot, so the pipeline never touches app state.
public struct RecomputeProfile: Sendable {
    public var user: UserProfile
    /// Waist circumference (cm); 0 = not set, which drops the VO₂max estimate from Fitness Age.
    public var waistCm: Double
    /// Manual HR-max (bpm); 0 = use the engine's own estimate when scoring a day.
    public var hrMaxOverride: Int
    /// Effective HR-max (override or age estimate) used to re-score manual workouts.
    public var hrMax: Int
    /// Manual steps-per-motion coefficient; nil = calibrate against phone steps.
    public var stepsManualOverride: Double?

    public init(user: UserProfile, waistCm: Double, hrMaxOverride: Int, hrMax: Int, stepsManualOverride: Double?) {
        self.user = user; self.waistCm = waistCm; self.hrMaxOverride = hrMaxOverride
        self.hrMax = hrMax; self.stepsManualOverride = stepsManualOverride
    }
}

/// Everything one recompute run depends on besides the store.
public struct RecomputeRequest: Sendable {
    /// The imported strap id; computed rows are written under `computedId` (`deviceId + "-noop"`).
    public var deviceId: String
    /// Unix seconds the run treats as "now".
    public var now: Int
    public var timeZone: TimeZone
    public var maxDays: Int
    public var profile: RecomputeProfile
    /// Manual "Recalibrate" epochs (unix seconds, 0 = none) for the HRV and the wider Charge baselines.
    public var hrvBaselineEpoch: Double
    public var recoveryBaselineEpoch: Double
    /// Experimental sleep stager V2 for the normal detected-night staging path (#690).
    public var useSleepStagerV2: Bool

    public init(deviceId: String, now: Int, timeZone: TimeZone, maxDays: Int, profile: RecomputeProfile,
                hrvBaselineEpoch: Double, recoveryBaselineEpoch: Double, useSleepStagerV2: Bool) {
        self.deviceId = deviceId; self.now = now; self.timeZone = timeZone; self.maxDays = maxDays
        self.profile = profile; self.hrvBaselineEpoch = hrvBaselineEpoch
        self.recoveryBaselineEpoch = recoveryBaselineEpoch; self.useSleepStagerV2 = useSleepStagerV2
    }

    public var computedId: String { deviceId + "-noop" }

    /// Device wall-clock offset (seconds east of UTC) at `now`, for local-day keys and the stager's
    /// daytime false-sleep guard (#90). A DST boundary inside the window is a negligible edge case.
    var tzOffset: Int { timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(now))) }
}

/// App-owned state the pipeline needs mid-run. The edited-sleep self-heal runs between the two passes
/// (it rewrites stage JSON the second pass scores), so it is a callback, not an input.
public protocol RecomputeHost {
    /// Re-derive the stages of user-edited nights in `[from, to]` and return the (refreshed) edited rows.
    func selfHealEditedStages(from: Int, to: Int) async -> [CachedSleepSession]
    /// Sleep spans the user deleted; re-detected nights overlapping them are not re-inserted (#68).
    func dismissedSleepWindows() async -> [(start: Int, end: Int)]
    /// One privacy-safe diagnostic line for the shareable strap log.
    func log(_ line: String) async
}

/// Who supplies the dashboard headline for a scored day. Imports win the per-day merge field-by-field
/// over computed rows (Repository.mergeDaily), so the badge must tell a strap-scored night apart from
/// an imported one. (Sleep overhaul §2.6.)
public enum DayProvenance: Equatable, Sendable {
    /// NOOP scored this day itself from the raw strap streams; no import covers it.
    case computed
    /// A WHOOP export covers this day and wins the dashboard merge.
    case whoopImport
    /// An Apple Health import covers this day and wins the dashboard merge.
    case appleHealth

    /// The short token for the per-day strap-log diagnostic (privacy-safe; no device ids leak).
    public var logToken: String {
        switch self {
        case .computed:    return "computed"
        case .whoopImport: return "imported:whoop"
        case .appleHealth: return "imported:apple"
        }
    }

    /// WHOOP wins over Apple, matching the merge's source priority (whoopImport 0 < appleHealth 2 in
    /// DailyMetricSource.vitalPriority); otherwise the day is purely computed. Mirrors the Android
    /// `IntelligenceEngine.daySourceToken`.
    public static func classify(day: String, importedWhoopDays: Set<String>,
                                appleHealthDays: Set<String>) -> DayProvenance {
        if importedWhoopDays.contains(day) { return .whoopImport }
        if appleHealthDays.contains(day) { return .appleHealth }
        return .computed
    }
}

/// One scored day as the By-Day list shows it: NOOP's own on-device numbers plus the real provenance.
public struct RecomputedDay: Identifiable, Sendable {
    public let day: String
    public let recovery: Double?
    public let strain: Double?
    public let sleepMin: Double?
    public let hrv: Double?
    public let rhr: Int?
    public let source: DayProvenance
    public var id: String { day }
}

/// The steps-estimate calibration state to mirror into the user's profile for the Today tile / Settings.
public struct StepsCalibrationUpdate: Equatable, Sendable {
    public let coefficient: Double
    public let sampleDays: Int
    public let confidence: Double
    public let manual: Bool
}

public struct RecomputeOutcome: Sendable {
    /// Scored days, newest first.
    public let days: [RecomputedDay]
    /// Nil when the calibration state is unchanged by this run.
    public let stepsCalibration: StepsCalibrationUpdate?
}

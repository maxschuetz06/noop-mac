import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Explainability state models (Components 2 & 3 of the sleep-guidance spec)
//
// "No bare number without a STATE, a REASON, and a NEXT STEP." Each enum carries its own
// verbatim copy from the 2026-06-20 spec so a score/tile never renders a lone blank. These are
// pure value types with pure mappers so they unit-test off the live view, and they mirror 1:1
// with the Kotlin Today lane (com.noop.ui — same case names, same order, same words).

/// COMPONENT 2 — the explained state of one score/tile on Today. `scored` carries the real value;
/// the other three NEVER carry a number (the honesty rule — calibrating / needsStrap show no value,
/// carried always stamped with its date). Each non-scored case yields a title, a detail line, and a
/// next step the UI renders instead of a bare blank.
enum MetricTileState: Equatable {
    /// Today's own value exists — the caller renders the number itself; this case is the "all good" gate.
    case scored
    /// Baselines still cold-start: `nightsRemaining` more nights until the score is personal. No number.
    case calibrating(nightsRemaining: Int)
    /// A prior scored day shown pre-tonight (#543 carry-over). `date` is that scored day's own date.
    case carriedLastNight(date: String)
    /// No data for the period — strap not worn / not connected / not synced. No number.
    case needsStrap

    /// The state's short title. `scored` has no title (the value is the headline) so it returns nil.
    /// Verbatim spec copy; `\(...)` interpolation feeds the dynamic value into the LocalizedStringKey slot.
    var title: LocalizedStringKey? {
        switch self {
        case .scored:                       return nil
        case .calibrating:                  return "Calibrating"
        case .carriedLastNight(let date):   return "Last night · \(date)"
        case .needsStrap:                   return "Needs the strap"
        }
    }

    /// The one-line detail + next step. Verbatim spec copy.
    var detail: LocalizedStringKey? {
        switch self {
        case .scored:
            return nil
        case .calibrating(let n):
            // "night(s)" pluralises honestly so a single remaining night doesn't read "1 nights".
            return "Building your baseline. About \(n) more \(n == 1 ? "night" : "nights") until your scores are personal."
        case .carriedLastNight:
            return "Tonight's lands after you sleep with the strap on."
        case .needsStrap:
            return "No data for today. Was your strap worn and connected overnight?"
        }
    }

    /// VoiceOver-friendly plain string of title + detail (no markdown interpolation surprises). nil when scored.
    var accessibilityText: String? {
        switch self {
        case .scored:
            return nil
        case .calibrating(let n):
            return "Calibrating. Building your baseline. About \(n) more \(n == 1 ? "night" : "nights") until your scores are personal."
        case .carriedLastNight(let date):
            return "Last night, \(date). Tonight's lands after you sleep with the strap on."
        case .needsStrap:
            return "Needs the strap. No data for today. Was your strap worn and connected overnight?"
        }
    }

    /// Convenience for the hero, where calibration is already richly explained by the data-confidence
    /// pill + Synthesis card + ring overlay, so the explained note defers to those for that one case.
    var isCalibrating: Bool {
        if case .calibrating = self { return true }
        return false
    }

    /// PURE mapper (unit-testable) — the honest precedence behind every Today score/tile state, given
    /// the engine outputs already computed on the view. Checks run in this order:
    ///   1. today's own value exists            → `.scored`
    ///   2. still mid-calibration (today only)  → `.calibrating(nightsRemaining)`
    ///   3. a prior scored day to carry (#543)  → `.carriedLastNight(date)`
    ///   4. nothing banked anywhere             → `.needsStrap`
    /// `nightsRemaining` is clamped to AT LEAST 1 so a boundary count never reads "0 more nights" while
    /// calibration is genuinely still on (the singular/plural rule then reads the clamped value). Mirror
    /// the Kotlin `coerceAtLeast(1)` exactly.
    static func resolve(hasTodayValue: Bool,
                        calibratingNightsRemaining: Int?,
                        carriedDate: String?) -> MetricTileState {
        if hasTodayValue { return .scored }
        if let remaining = calibratingNightsRemaining { return .calibrating(nightsRemaining: max(1, remaining)) }
        if let date = carriedDate { return .carriedLastNight(date: date) }
        return .needsStrap
    }
}

/// COMPONENT 3 — the strap's live recording status, mapped honestly from the BLE connection + last-sync.
/// One clear chip on Today so people know it's working, or know it isn't and why. Mirrors the Kotlin
/// Today lane 1:1 (same cases, same order, same words).
enum RecordingState: Equatable {
    /// Connected and saving data live.
    case recording
    /// Not connected now but synced `minutesAgo` minutes back — reconnect to pull the latest.
    case lastSynced(minutesAgo: Int)
    /// Strap not connected and nothing fresh to fall back on.
    case notRecording
    /// #580 — a connected WHOOP 5/MG streaming live HR fine, but its firmware hands over no history
    /// offload yet. NOT the WHOOP-4 "not recording" failure: the link is live, history sync is just
    /// experimental on 5.0. Surfaced from `LiveState.historySyncExperimental`, overriding the mapper.
    case historyExperimental

    /// The chip's short label. Verbatim spec copy; the dynamic "Xm" goes into the LocalizedStringKey slot.
    var label: LocalizedStringKey {
        switch self {
        case .recording:                 return "Recording"
        case .lastSynced(let mins):      return "Last synced \(mins)m ago"
        case .notRecording:              return "Not recording"
        case .historyExperimental:       return "Connected"
        }
    }

    /// The supporting detail line. Verbatim spec copy.
    var detail: LocalizedStringKey {
        switch self {
        case .recording:           return "Your strap is connected and saving data."
        case .lastSynced:          return "Reconnect to pull the latest."
        case .notRecording:        return "Strap not connected. Tap to connect."
        case .historyExperimental: return "History sync is experimental on 5.0."
        }
    }

    /// VoiceOver plain string (label + detail).
    var accessibilityText: String {
        switch self {
        case .recording:
            return "Recording. Your strap is connected and saving data."
        case .lastSynced(let mins):
            return "Last synced \(mins) minutes ago. Reconnect to pull the latest."
        case .notRecording:
            return "Not recording. Strap not connected. Tap to connect."
        case .historyExperimental:
            return "Connected. History sync is experimental on 5.0."
        }
    }

    /// PURE mapper (unit-testable) — `recording` IFF (connected AND a live heart-rate sample is currently
    /// present). A connection with no live HR yet (handshaking, no PPG, strap off the wrist) is honestly
    /// NOT recording. Otherwise, if a last-sync time is known, reads "Last synced Xm ago"; else "Not
    /// recording". `lastSyncedAt` / `now` are unix seconds; the minute count clamps at >= 0 (strap-clock
    /// skew can't read negative) and uses ceil so a 30-second-old sync reads "1m ago" rather than "0m ago".
    static func resolve(connected: Bool,
                        heartRate: Int?,
                        lastSyncedAt: TimeInterval?,
                        now: TimeInterval = Date().timeIntervalSince1970) -> RecordingState {
        if connected && heartRate != nil { return .recording }
        if let at = lastSyncedAt {
            let secs = max(0, now - at)
            let mins = Int((secs / 60).rounded(.up))
            return .lastSynced(minutesAgo: mins)
        }
        return .notRecording
    }
}

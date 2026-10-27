import Foundation

/// Physical strap inputs and wear automation: the double-tap action, wrist on/off shortcuts and
/// auto-lock, HR-zone haptic coaching and strap battery alerts (#368). All hooks fire live from
/// `FrameRouter` through `LiveState`; every behaviour is gated on its own `BehaviorStore` setting.
@MainActor
final class StrapInputAutomation {
    /// What the inputs can trigger in the rest of the app.
    struct Actions {
        /// Confirming strap buzz (`loops` sets the length).
        let buzz: (UInt8) -> Void
        let markMoment: () -> Void
        let markSleep: () -> Void
        /// Buzz the current time on the strap (Haptic Clock, #460); the flag selects a 24-hour encoding.
        let buzzTimeNow: (_ is24h: Bool) -> Void
    }

    private let live: LiveState
    private let behavior: BehaviorStore
    private let profile: ProfileStore
    private let actions: Actions
    private var lastDoubleTapAt: Date = .distantPast
    private var lastCoachZone: Int = -1

    init(live: LiveState, behavior: BehaviorStore, profile: ProfileStore, actions: Actions) {
        self.live = live
        self.behavior = behavior
        self.profile = profile
        self.actions = actions
    }

    /// Install the double-tap, wrist and battery hooks on `live`.
    func installHooks() {
        live.onDoubleTap = { [weak self] in self?.handleDoubleTap() }
        live.onWristChange = { [weak self] worn in self?.handleWristChange(worn) }
        // Strap battery alerts (#368): low-battery warning + full-charge note. The notifier self-gates
        // on the user's setting and the OS authorization, and carries its own persisted once-per-
        // crossing state, so feeding it every battery reading is safe.
        live.onBatteryUpdate = { [weak self] pct in
            guard let self else { return }
            BatteryNotifier.onBatteryUpdate(pct: Int(pct.rounded()),
                                            charging: self.live.charging,
                                            enabled: self.behavior.batteryAlerts)
        }
    }

    /// Run a configured Mac action. In-app actions (buzz/moment) stay on-device; lock + shortcuts
    /// go through MacActions.
    func runMacAction(_ kind: MacActionKind, shortcut: String) {
        switch kind {
        case .none: break
        case .lockScreen:
            if !MacActions.lockScreen() {
                MacActions.runShortcut("Lock Screen")   // login.framework unavailable — fall back to a Shortcut
            }
        case .buzzBack: actions.buzz(1)
        case .markMoment: actions.markMoment()
        case .sleepMark: actions.markSleep()
        case .hapticClock: actions.buzzTimeNow(Self.localeUses24HourClock)
        case .runShortcut: MacActions.runShortcut(shortcut)
        }
    }

    /// HR-zone haptic coaching: buzz when crossing into the top zone (ease off) or back to recovery.
    func coachZone(_ hr: Int?) {
        guard behavior.zoneCoaching, live.bonded, live.worn, let hr, hr >= 30 else { return }
        let maxHR = Double(profile.hrMax)
        guard maxHR > 0 else { return }
        let pct = Double(hr) / maxHR
        let zone = pct >= 0.9 ? 5 : pct >= 0.8 ? 4 : pct >= 0.7 ? 3 : pct >= 0.6 ? 2 : 1
        defer { lastCoachZone = zone }
        guard lastCoachZone != -1, zone != lastCoachZone else { return }
        if zone == 5, lastCoachZone < 5 { actions.buzz(3) }          // entered max — ease off
        else if zone <= 1, lastCoachZone > 1 { actions.buzz(1) }     // recovered
    }

    /// Whether the user's locale formats time on a 24-hour clock — drives the Haptic Clock's hour
    /// encoding (#460) so a double-tap buzzes the time the way the user reads it. Derived from the
    /// locale's "j" (hour) template: a 12-hour locale includes the AM/PM ("a") symbol.
    static var localeUses24HourClock: Bool {
        let fmt = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h"
        return !fmt.contains("a")
    }

    private func handleDoubleTap() {
        let now = Date()
        guard now.timeIntervalSince(lastDoubleTapAt) > 1.2 else { return }   // debounce repeats
        lastDoubleTapAt = now
        live.append(log: "Double-tap → \(behavior.doubleTapAction.label)")
        runMacAction(behavior.doubleTapAction, shortcut: behavior.doubleTapShortcut)
    }

    private func handleWristChange(_ worn: Bool) {
        if worn {
            if !behavior.wristOnShortcut.isEmpty { MacActions.runShortcut(behavior.wristOnShortcut) }
        } else {
            if behavior.autoLockOnWristOff, !MacActions.lockScreen() { MacActions.runShortcut("Lock Screen") }
            if !behavior.wristOffShortcut.isEmpty { MacActions.runShortcut(behavior.wristOffShortcut) }
        }
    }
}

import Foundation
import WhoopProtocol

// Realtime-stream wants and the keep-alive watchdog.
extension BLEManager {
    /// Enable live HR and remember we want it re-armed by keep-alive.
    /// Some WHOOP firmware acknowledges TOGGLE_REALTIME_HR but only emits usable live samples once
    /// the R10/R11 realtime stream is also on. Keep that stream scoped to the Live tab and stop it
    /// on disappear so it does not permanently compete with historical offload.
    public func startRealtime() {
        screenWantsRealtime = true
        state.liveFeedActive = true   // drives the menu-bar Start/Stop label off the real intent
        // The user explicitly (re-)asked for the full stream by opening Live / tapping Start HR — give the
        // heavy R10/R11 burst another chance even if a prior marginal-radio fallback had tripped. If the
        // radio still can't take it, the detector will simply trip again. (#80) This is screen-only intent;
        // the continuous-capture path does NOT reset the fallback (it's a passive background want).
        marginalRadio.reset()
        standardHRFallback = false
        state.standardHRMode = nil
        enableLiveNotifications(reason: "start realtime")
        send(.sendR10R11Realtime, payload: [0x01])   // the heavy burst rides alongside the toggle on Live
        reconcileRealtime()                          // arms TOGGLE_REALTIME_HR(1) on the off→on edge
        realtimeArmedAt = Date()       // start the arm→drop stopwatch for the marginal-radio detector
    }

    /// Stop the Live-tab realtime streams. The lightweight 0x2A37 HR keeps recording if firmware emits it.
    /// The TOGGLE only actually disarms if the continuous-capture preference no longer wants it either —
    /// the reconciler sends it on the on→off edge of the combined want, so a Live screen closing while
    /// continuous capture is on keeps the dense stream flowing.
    public func stopRealtime() {
        screenWantsRealtime = false
        state.liveFeedActive = false   // flip the menu-bar toggle back to "Start live feed"
        // Always stop the heavy R10/R11 burst when the Live screen leaves — it's the battery-hungry part
        // and is only ever wanted while a live screen is up. The lightweight TOGGLE/0x2A37 R-R stream is
        // what continuous capture keeps; the reconciler decides whether to disarm that.
        send(.sendR10R11Realtime, payload: [0x00])
        reconcileRealtime()
    }

    /// The "Continuous HRV capture" preference flipped: hold the realtime stream open with no Live screen
    /// visible (true) or release it (false), then reconcile. Driven from the app model. Mirrors the
    /// Android `setKeepStreamForData`.
    public func setKeepRealtimeForData(_ keep: Bool) {
        keepRealtimeForData = keep
        reconcileRealtime()
    }

    /// Single reconciler for the realtime-HR TOGGLE. The stream should be armed while EITHER a screen
    /// wants it (`screenWantsRealtime`) OR the continuous-capture preference wants it
    /// (`keepRealtimeForData`). We arm (TOGGLE_REALTIME_HR 1) / disarm (TOGGLE_REALTIME_HR 0) ONLY on the
    /// false↔true edge of that derived want — so a Live screen closing while the preference still wants
    /// it does NOT disarm, and turning the preference off with no screen open DOES disarm. The toggle only
    /// reaches the strap once it's a WHOOP4 (custom channels open immediately) or a bonded 5/MG (puffin
    /// framing); otherwise the want is remembered and the post-bond branch arms it. Mirrors the Android
    /// `reconcileRealtime`.
    private func reconcileRealtime() {
        let want = screenWantsRealtime || keepRealtimeForData
        wantsRealtime = want   // keep-alive + post-bond arm-on-connect read this derived value
        guard want != realtimeArmed else { return }                      // no edge — nothing to send
        guard selectedModel.deviceFamily == .whoop4 || state.bonded else { return }   // can't reach the strap yet
        realtimeArmed = want
        send(.toggleRealtimeHR, payload: [want ? 0x01 : 0x00])
    }

    func startKeepAlive() {
        keepAliveTimer?.cancel()
        let s = BLEManager.keepAliveIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(s), repeating: .seconds(s))
        t.setEventHandler { [weak self] in self?.keepAliveFire() }
        t.resume()
        keepAliveTimer = t
    }

    private func keepAliveFire() {
        guard state.connected, didBond else { return }
        enableLiveNotifications(reason: "keepalive")
        // Liveness watchdog: if NOTHING has arrived for a while, the stream/link stalled.
        // Bounce the connection — the auto-rescan on disconnect re-bonds and resumes streaming.
        // #580: a known history-empty 5/MG (firmware serves no offload) gets a far longer fuse. The
        // standard 0x2A37 HR profile keeps the link genuinely alive, but its packets can lull for >120s
        // when the strap is off-wrist / resting, and an empty offload leaves the data channel quiet — so
        // the old 120s rule disconnected/rescanned a perfectly healthy link every ~2 min (the thrash this
        // fixes). A WHOOP 4 (real "not recording" path) keeps the tight 120s fuse unchanged.
        let bounceFuse: TimeInterval =
            (selectedModel.deviceFamily == .whoop5 && whoop5EmptyOffload.historyEmpty) ? 600 : 120
        if Date().timeIntervalSince(lastDataAt) > bounceFuse {
            log("No data for >\(Int(bounceFuse))s — bouncing link to resume streaming")
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            return
        }
        guard !backfilling else { return }            // never poke the strap mid-offload
        // The command pings below are WHOOP4-framed; a 5/MG link drops them at the send() guard, so
        // skip them for 5/MG (it keeps the experimental strap log clean — re-subscribe + the 120s
        // bounce above are what keep a 5/MG link healthy).
        guard selectedModel.deviceFamily == .whoop4 else { return }
        // Never re-arm the heavy R10/R11 burst once the marginal-radio fallback has tripped (#80) — that
        // would just re-trigger the drop the keep-alive is meant to prevent. 0x2A37 keeps the HR flowing.
        if wantsRealtime && !standardHRFallback {
            realtimeArmed = true   // keep reconcileRealtime()'s edge tracking in sync with the re-arm
            send(.sendR10R11Realtime, payload: [0x01])
            send(.toggleRealtimeHR, payload: [0x01])
        }   // re-arm so it can't lapse
        keepAliveTick += 1
        if keepAliveTick % 2 == 0 { send(.getBatteryLevel, payload: []) }  // ~every 60s
    }
}

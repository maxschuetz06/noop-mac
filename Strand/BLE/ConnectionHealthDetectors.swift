import Foundation

/// Detects a marginal Bluetooth radio that can't sustain the WHOOP 4 R10/R11 raw realtime stream
/// (#80). On a flaky radio (2016 Mac / OpenCore) the link dies the *instant* NOOP arms that
/// high-bandwidth burst, then the auto-rescan reconnects, re-arms, and dies again — an endless loop.
///
/// The tell is a CONNECTION TIMEOUT that lands shortly after we armed realtime: arm → die → rescan →
/// arm → die. We don't trip on a single drop (links die for benign reasons), but on >= `tripThreshold`
/// CONSECUTIVE arm-then-quick-timeout cycles. Once tripped, the caller skips arming R10/R11 on the next
/// connect and relies on the independent low-bandwidth 0x2A37 standard HR profile, which NOOP already
/// subscribes — live HR survives on a radio that otherwise couldn't, and even if 0x2A37 stays silent the
/// arm/die loop stops. Pure + value-typed so the decision is unit-testable without a CoreBluetooth seam.
struct MarginalRadioDetector {
    /// How many consecutive arm-then-quick-timeout cycles before we fall back to standard-HR-only.
    /// 2 (not 1): one drop is noise; two in a row right after arming is the radio buckling under the burst.
    let tripThreshold: Int
    /// A timeout only counts as "right after arming" if it lands within this window. A drop minutes into a
    /// healthy session is unrelated to the arm burst and must NOT be blamed on it (that would mis-trip a
    /// good radio whose link merely flaps later).
    let quickTimeoutWindow: TimeInterval

    private(set) var consecutiveArmTimeouts = 0
    /// True once we've tripped: the next connect should skip the R10/R11 arm and run standard-HR-only.
    private(set) var tripped = false

    init(tripThreshold: Int = 2, quickTimeoutWindow: TimeInterval = 20) {
        self.tripThreshold = tripThreshold
        self.quickTimeoutWindow = quickTimeoutWindow
    }

    /// A connection ended. `wasArmed` = we had armed R10/R11 this connection; `secondsSinceArm` = how long
    /// after arming the link ended (nil if we never armed); `timedOut` = the drop looks like a connection
    /// timeout (vs. an intentional disconnect, a bond reset, etc.). Returns true if THIS event tripped the
    /// fallback (a freshly-crossed threshold), so the caller can log/surface it exactly once.
    mutating func connectionEnded(wasArmed: Bool, secondsSinceArm: TimeInterval?, timedOut: Bool) -> Bool {
        // Only a timeout that lands within the window after we actually armed the burst is evidence the
        // radio choked on the arm. Anything else (clean session that later flapped, non-timeout error,
        // never armed) breaks the streak — a single healthy spell should clear prior suspicion.
        let armCausedTimeout = wasArmed && timedOut
            && (secondsSinceArm.map { $0 <= quickTimeoutWindow } ?? false)
        guard armCausedTimeout else {
            consecutiveArmTimeouts = 0
            return false
        }
        consecutiveArmTimeouts += 1
        if !tripped && consecutiveArmTimeouts >= tripThreshold {
            tripped = true
            return true        // freshly tripped — caller logs/surfaces once
        }
        return false
    }

    /// Clear all suspicion: a clean session is flowing, or the user explicitly re-requested the full
    /// stream (Live re-open / manual Start HR). Lets a transient radio hiccup recover instead of
    /// permanently pinning the user to standard-HR mode.
    mutating func reset() {
        consecutiveArmTimeouts = 0
        tripped = false
    }
}

/// Detects a WHOOP 4 "bond-loop" (#617): the strap bonds successfully, then the encrypted link drops
/// ~1s later with a CONNECTION TIMEOUT (`CBError.connectionTimeout`), the auto-rescan reconnects, it
/// bonds again, and dies again — an endless bond→timeout cycle on macOS/iOS that never settles and never
/// tells the user why.
///
/// The tell is a TIMEOUT drop that lands shortly after a GENUINE bond: bond → die-soon → rescan → bond →
/// die-soon. A bond that survives well past the window is healthy and breaks the streak — links flap for
/// benign reasons minutes in, and a late drop must NOT be blamed on the bond. We don't trip on a single
/// cycle (one quick drop is noise); we trip on >= `tripThreshold` CONSECUTIVE bond-then-quick-timeout
/// cycles. Once tripped, BLEManager surfaces the EXISTING re-pair guide (`state.reconnectGuide`) so the
/// user gets the forget-and-re-pair steps instead of watching a silent loop drain the battery.
///
/// Pure + value-typed so the decision is unit-testable without a CoreBluetooth seam — same shape as
/// `MarginalRadioDetector`.
struct PostBondTimeoutLoopDetector {
    /// How many consecutive bond-then-quick-timeout cycles before we surface the re-pair guide.
    /// 2 (not 1): one quick post-bond drop is noise; two in a row is the loop, not a fluke.
    let tripThreshold: Int
    /// A timeout only counts as "right after bonding" if it lands within this window of the bond. A drop
    /// well into a healthy session is unrelated to bonding and must NOT count (that would mis-trip a good
    /// link that merely flapped later). Generous vs the radio detector's 20s: the loop's signature is a
    /// near-immediate (~1s) drop, but pre-loop links can limp a few seconds before timing out.
    let quickTimeoutWindow: TimeInterval

    private(set) var consecutiveBondTimeouts = 0
    /// True once we've tripped: BLEManager has surfaced (or should surface) the re-pair guide.
    private(set) var tripped = false

    init(tripThreshold: Int = 2, quickTimeoutWindow: TimeInterval = 8) {
        self.tripThreshold = tripThreshold
        self.quickTimeoutWindow = quickTimeoutWindow
    }

    /// A connection ended. `wasBonded` = the link reached a genuine encrypted bond this connection;
    /// `secondsSinceBond` = how long after bonding the link ended (nil if we never bonded); `timedOut` =
    /// the drop looks like a connection timeout (vs an intentional disconnect, a bond reset, a clean close).
    /// Returns true if THIS event tripped the loop (a freshly-crossed threshold), so the caller can
    /// log/surface the guide exactly once.
    mutating func connectionEnded(wasBonded: Bool, secondsSinceBond: TimeInterval?, timedOut: Bool) -> Bool {
        // Only a timeout that lands within the window after we actually bonded is evidence of the loop.
        // Anything else (never bonded, non-timeout close, a drop long after a healthy bond) breaks the
        // streak — a single healthy spell should clear prior suspicion.
        let bondThenQuickTimeout = wasBonded && timedOut
            && (secondsSinceBond.map { $0 <= quickTimeoutWindow } ?? false)
        guard bondThenQuickTimeout else {
            consecutiveBondTimeouts = 0
            return false
        }
        consecutiveBondTimeouts += 1
        if !tripped && consecutiveBondTimeouts >= tripThreshold {
            tripped = true
            return true        // freshly tripped — caller surfaces the re-pair guide once
        }
        return false
    }

    /// Clear all suspicion: a clean session is flowing, or the user explicitly disconnected. Lets a
    /// transient bond hiccup recover instead of permanently flagging the link as bond-looping.
    mutating func reset() {
        consecutiveBondTimeouts = 0
        tripped = false
    }
}

/// Decides when a completed sync that handed over only the strap's console/diagnostic output (no sensor
/// records) is sustained enough to warn that the strap's clock has lost sync and it isn't banking to flash
/// (#77 / #91 / #120). A SINGLE empty cycle is common on a perfectly healthy strap — the strap can hand
/// back a console-only window, especially under heavy live-HR polling — so warning on one cycle
/// false-alarms users whose clock is fine (#126). We require CONSECUTIVE empty cycles; any cycle that banks
/// real sensor records clears the streak. Pure value type → unit-testable without a CoreBluetooth seam.
struct EmptySyncTracker {
    /// Consecutive console-only completed syncs before the clock-lost banner shows. 3 (not 1): a genuinely
    /// un-banking strap is console-only on EVERY cycle, so 3 is reached within minutes, while a transient
    /// empty cycle amid healthy ones never accumulates.
    let threshold: Int
    private(set) var consecutiveEmptySyncs = 0

    init(threshold: Int = 3) { self.threshold = threshold }

    /// Record a COMPLETED (HISTORY_COMPLETE) offload. `bankedSensorRecords` = the strap handed over real
    /// sensor records this cycle (decoded, or undecodable-but-archived — either way the clock is banking).
    /// `consoleOnly` = it handed over only diagnostic frames and no sensor records. Returns true only once
    /// emptiness is SUSTAINED (≥ threshold consecutive console-only cycles) — the caller shows the
    /// "clock has lost sync" banner only then. Any banking cycle, or a caught-up cycle with nothing to
    /// offload, clears the streak.
    mutating func recordCompletedSync(bankedSensorRecords: Bool, consoleOnly: Bool) -> Bool {
        guard consoleOnly, !bankedSensorRecords else {
            consecutiveEmptySyncs = 0
            return false
        }
        consecutiveEmptySyncs += 1
        return consecutiveEmptySyncs >= threshold
    }
}

/// #580: a connected WHOOP 5/MG whose firmware acks SEND_HISTORICAL_DATA but emits ZERO type-0x2F
/// offload frames. Live HR streams fine over the standard 0x2A37 profile, but the historical offload is
/// empty, so every session runs the 60s idle watchdog out to a "timeout" and surfaces the WHOOP-4
/// "strap went quiet" sync error — even though nothing is wrong, the 5/MG history offload is simply
/// experimental/unsupported on that firmware. Worse, the empty offload leaves the link idle, so the
/// 120s liveness watchdog can bounce-disconnect/rescan every ~2 min in a thrash loop.
///
/// This pure tracker counts CONSECUTIVE empty 5/MG offloads (a timeout with no offload frames and no
/// rows persisted). Once `quietThreshold` is reached it reports the strap as "history-empty" so the
/// caller can (a) surface an honest "connected, history sync experimental on 5.0" state instead of a
/// sync error, and (b) back off the bounce loop. Any offload that DOES hand over real records clears the
/// streak — so a strap that later starts banking recovers immediately. Value type → unit-testable
/// (Whoop5EmptyOffloadTrackerTests) without a CoreBluetooth seam. Mirrored on Android.
struct Whoop5EmptyOffloadTracker {
    /// Consecutive empty 5/MG offloads before we treat the strap as history-empty (experimental). 2 (not
    /// 1): the very first offload after connect can race the strap waking its flash, so one empty cycle is
    /// noise; two in a row is the firmware genuinely not serving history.
    let quietThreshold: Int

    private(set) var consecutiveEmpty = 0
    /// True once `quietThreshold` consecutive empty offloads have been seen — the link is up + live HR is
    /// flowing but the 5/MG history offload is empty. Drives the honest home-state flag AND the bounce
    /// backoff. Cleared the moment any offload banks real records.
    private(set) var historyEmpty = false

    init(quietThreshold: Int = 2) { self.quietThreshold = quietThreshold }

    /// Record a completed/timed-out 5/MG offload. `bankedRecords` = this offload routed real offload
    /// frames / persisted rows (the strap IS handing over history). Returns true if THIS call freshly
    /// crossed the threshold (so the caller can log/surface once). A banking offload resets everything.
    mutating func recordOffload(bankedRecords: Bool) -> Bool {
        guard !bankedRecords else {
            consecutiveEmpty = 0
            historyEmpty = false
            return false
        }
        consecutiveEmpty += 1
        if !historyEmpty && consecutiveEmpty >= quietThreshold {
            historyEmpty = true
            return true     // freshly crossed — caller logs/surfaces once
        }
        return false
    }

    /// Clear all suspicion — a fresh connect, or the user explicitly re-requested a sync. Lets a strap
    /// that starts banking (or a transient empty spell) recover without waiting out the streak.
    mutating func reset() {
        consecutiveEmpty = 0
        historyEmpty = false
    }
}

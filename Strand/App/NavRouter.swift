import SwiftUI
import Combine

// MARK: - NavRouter
//
// A tiny shared navigation hook so a screen can ask the app shell to switch to another top-level
// destination without reaching into the `NavigationSplitView` sidebar selection (`RootView`).
//
// Usage: a screen calls `router.openDevices()`; the shell observes `requestedDestination` and sets the
// sidebar selection. The shell clears the request once it's handled so the same tap can fire again
// later. Injected at the app root (`StrandApp`) as an `@EnvironmentObject`.
@MainActor
final class NavRouter: ObservableObject {
    /// A top-level destination a screen can ask the shell to open. Deliberately minimal — the Devices
    /// manager plus the v5 pillar screens the new in-hub rows deep-link to (Insights hub, Lab Book,
    /// the fused record, the experimental Rhythm visualization).
    enum Destination: String, Equatable, Identifiable {
        case devices
        case insightsHub
        case labBook
        case fusedRecord
        case rhythm
        case trends

        var id: String { rawValue }

        /// Map a stored `UpdateItem.deepLink` route key to a Destination, if it names one. Lets the
        /// Updates inbox route a tapped item generically (e.g. a `.reading` item's "trends") without the
        /// inbox knowing every shell. Unknown keys return nil → the inbox just dismisses.
        init?(deepLinkKey: String) {
            self.init(rawValue: deepLinkKey)
        }
    }

    /// The destination a screen has asked the shell to open, or nil once handled. Published so the
    /// sidebar reacts and routes itself, then resets this to nil.
    @Published var requestedDestination: Destination?

    /// Ask the shell to open the Devices manager (pair / switch bands). The shell decides how.
    func openDevices() { requestedDestination = .devices }
    /// Open the v5 Insights hub (the n-of-1 "what moves your Charge" surface).
    func openInsightsHub() { requestedDestination = .insightsHub }
    /// Open the Lab Book (private health-records logbook).
    func openLabBook() { requestedDestination = .labBook }
    /// Open the "Your Data, Fused" multi-device record.
    func openFusedRecord() { requestedDestination = .fusedRecord }
    /// Open the experimental Rhythm visualization (self-gates on its own consent).
    func openRhythm() { requestedDestination = .rhythm }
    /// Open the Trends screen (where a "new data" reading deep-links).
    func openTrends() { requestedDestination = .trends }
}

import Foundation

/// Single source of truth for the in-app "What's New" screen and the expectation-setting copy used
/// in onboarding. The release history starts with this fork's own release line (8.0.0); the upstream
/// history lives only in CHANGELOG.md.
enum AppChangelog {

    /// Bump this when you add a release below. The "What's New" sheet shows automatically when the
    /// stored last-seen version is behind this. (Decoupled from the bundle version on purpose.)
    static let currentVersion = "8.0.0"

    /// Release copy is localized (German in Localizable.xcstrings); items may use Markdown emphasis.
    struct Release: Identifiable {
        let version: String
        let localizedTitle: LocalizedStringResource
        let localizedDate: LocalizedStringResource
        let localizedItems: [LocalizedStringResource]
        var id: String { version }
        /// Plain-text title in the app language, e.g. for the Updates inbox.
        var title: String { String(localized: localizedTitle) }
    }

    /// Newest first.
    static let releases: [Release] = [
        Release(
            version: "8.0.0",
            localizedTitle: "The first release of NOOP for Mac: macOS only, everything local",
            localizedDate: "October 2026",
            localizedItems: [
                "**A fork with its own release line.** NOOP for Mac is an unofficial, macOS-only fork of NOOP and starts its own versions at 8.0.0. The iPhone and Android apps, prebuilt downloads and donation links are gone; you build the app from source.",
                "**Local only.** No account, no cloud, no telemetry. The only network request is “Check for updates”, and only when you click it. The AI Coach, the Intelligence screen and the Smart Alarm were removed.",
                "**Optional external data folder.** A build can opt into one folder in your home directory for a database mirror for local tools, an import inbox and raw PPG capture. It is off by default, and well-known folders such as Documents or Public are refused.",
                "**Strap safety.** A WHOOP 5.0/MG only receives an allowlisted set of commands, and never a strap-held alarm or a looping vibration.",
                "**The desktop widget follows the app language** you choose in Settings, not only the system language.",
                "**Rebuilt inside, same data.** The Bluetooth layer, the app start-up, the screens and the design system were reorganised into smaller, tested parts. Your database and your scores are unchanged.",
            ]),
    ]

    /// Expectation-setting points shown during onboarding and at the top of "What's New". This is the
    /// “what is this and what should I expect” story, so people don't have to go read GitHub.
    struct Expectation: Identifiable {
        let icon: String      // SF Symbol
        let title: String
        let body: String
        var id: String { title }
    }

    static let expectations: [Expectation] = [
        Expectation(
            icon: "flask",
            title: "Independent, and experimental",
            body: "NOOP is a personal, open project — not the WHOOP app, and not affiliated with WHOOP. It reads a strap you own, on your own device. Treat it as a capable work-in-progress rather than a finished product."),
        Expectation(
            icon: "checkmark.seal",
            title: "WHOOP 4.0 is the supported path",
            body: "WHOOP 4.0 is tested and works end to end. WHOOP 5.0/MG is newer: live heart rate works today, but deeper metrics (recovery, strain, sleep) for 5/MG are still being figured out. NOOP always tells you what's live versus still building."),
        Expectation(
            icon: "hourglass",
            title: "Your scores build over a few nights",
            body: "Live heart rate is instant. Recovery, strain and sleep sharpen as NOOP learns your baseline over your first nights of wear. Want your history now? Import your WHOOP export in Data Sources and it backfills in about a minute."),
        Expectation(
            icon: "lock.shield",
            title: "Everything stays on your device",
            body: "No account, no cloud, no sync. NOOP talks only to your strap and keeps everything local. Your data is yours alone."),
    ]
}

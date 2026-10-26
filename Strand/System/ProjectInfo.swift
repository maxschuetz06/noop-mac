import Foundation

/// Single source of truth for project identity, links and attribution, shown on the About screen.
enum ProjectInfo {
    /// Where questions, feedback and bug reports for this fork go.
    static let repositoryURL = URL(string: "https://github.com/maxschuetz06/noop-mac")!
    static let issuesURL = repositoryURL.appendingPathComponent("issues")
    /// GitHub releases API for this fork, read only by the user-initiated "Check for updates".
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/maxschuetz06/noop-mac/releases/latest")!
    /// The upstream project this fork is based on.
    static let upstreamURL = URL(string: "https://github.com/NoopApp/noop")!

    /// Open-source reverse-engineering this is built on.
    static let attributions: [(repo: String, note: String)] = [
        ("johnmiddleton12/my-whoop", "WHOOP 4.0 BLE protocol"),
        ("b-nnett/goose", "WHOOP 5.0 BLE protocol"),
    ]
}

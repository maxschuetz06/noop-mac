import XCTest
import WhoopProtocol
@testable import Strand

/// This fork's release line (8.0.0+) drives What's New and the user-initiated update check.
final class AppChangelogTests: XCTestCase {

    func testWhatsNewStartsAtTheForkReleaseLine() {
        XCTAssertEqual(AppChangelog.currentVersion, "8.0.0")
        XCTAssertEqual(AppChangelog.releases.first?.version, AppChangelog.currentVersion)
        XCTAssertTrue(AppChangelog.releases.allSatisfy { !VersionCheck.isNewer("8.0.0", than: $0.version) },
                      "no upstream (pre-8.0.0) release may come back")
    }

    func testEveryReleaseStringHasAGermanTranslation() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "de", ofType: "lproj"))
        let german = try XCTUnwrap(Bundle(path: path))
        for release in AppChangelog.releases {
            for resource in [release.localizedTitle, release.localizedDate] + release.localizedItems {
                XCTAssertNotEqual(german.localizedString(forKey: resource.key, value: nil, table: nil),
                                  resource.key, resource.key)
            }
        }
    }

    func testItemsRenderTheirMarkdownEmphasis() {
        for item in AppChangelog.releases.flatMap(\.localizedItems) {
            let rendered = AttributedString(localized: item)
            XCTAssertFalse(String(rendered.characters).contains("**"), item.key)
            XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true },
                          item.key)
        }
    }
}

@MainActor
final class UpdateCheckerTagTests: XCTestCase {

    func testReleaseTagsParseToTheirVersion() {
        XCTAssertEqual(UpdateChecker.version(fromTag: "v8.0.0"), "8.0.0")
        XCTAssertEqual(UpdateChecker.version(fromTag: "V8.1.2"), "8.1.2")
        XCTAssertEqual(UpdateChecker.version(fromTag: " v8.0.0 "), "8.0.0")
        XCTAssertEqual(UpdateChecker.version(fromTag: "8.0.0"), "8.0.0")
    }

    func testForkReleasesCompareAgainstTheInstalledVersion() {
        XCTAssertFalse(VersionCheck.isNewer(UpdateChecker.version(fromTag: "v8.0.0"), than: "8.0.0"))
        XCTAssertTrue(VersionCheck.isNewer(UpdateChecker.version(fromTag: "v8.0.1"), than: "8.0.0"))
        XCTAssertTrue(VersionCheck.isNewer(UpdateChecker.version(fromTag: "v8.0.0"), than: "7.0.1"))
        XCTAssertFalse(VersionCheck.isNewer(UpdateChecker.version(fromTag: "v7.0.1"), than: "8.0.0"))
    }
}

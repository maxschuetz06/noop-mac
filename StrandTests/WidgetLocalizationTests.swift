import XCTest
@testable import Strand

/// The desktop widget renders in the app's language, not the system's: the app publishes its pinned
/// locale in the snapshot and the widget picks the matching table from its own catalog. The test bundle
/// compiles `MacWidgets/Localizable.xcstrings`, so it stands in for the widget extension's bundle.
final class WidgetLocalizationTests: XCTestCase {
    private let catalog = Bundle(for: WidgetLocalizationTests.self)

    private func text(_ key: String, _ localization: WidgetLocalization) -> String {
        localization.bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    func testPinnedGermanWinsOverAnEnglishSystem() {
        let localization = WidgetLocalization.resolve(localeIdentifier: "de_DE", system: Locale(identifier: "en_US"),
                                                      catalog: catalog)
        XCTAssertEqual(localization.locale.identifier, "de_DE")
        XCTAssertEqual(text("Recovery", localization), "Erholung")
        XCTAssertEqual(text("No sync yet", localization), "Noch kein Sync")
    }

    func testPinnedEnglishWinsOverAGermanSystem() {
        let localization = WidgetLocalization.resolve(localeIdentifier: "en_US", system: Locale(identifier: "de_DE"),
                                                      catalog: catalog)
        XCTAssertEqual(localization.locale.identifier, "en_US")
        XCTAssertEqual(text("Recovery", localization), "Recovery")
        XCTAssertEqual(text("Resting Pulse", localization), "Resting Pulse")
    }

    func testNoPinFollowsTheSystem() {
        let system = Locale(identifier: "de_CH")
        for identifier in [nil, ""] as [String?] {
            let localization = WidgetLocalization.resolve(localeIdentifier: identifier, system: system, catalog: catalog)
            XCTAssertEqual(localization.locale.identifier, "de_CH")
            XCTAssertEqual(localization.bundle.bundlePath, catalog.bundlePath)
        }
    }

    func testALanguageTheCatalogDoesNotShipFollowsTheSystem() {
        let localization = WidgetLocalization.resolve(localeIdentifier: "fr_FR", system: Locale(identifier: "en_US"),
                                                      catalog: catalog)
        XCTAssertEqual(localization.locale.identifier, "en_US")
        XCTAssertEqual(localization.bundle.bundlePath, catalog.bundlePath)
    }

    func testSnapshotCarriesTheLocaleAndOlderSnapshotsStillDecode() throws {
        var pinned = WidgetSnapshot(recovery: 50, bpm: nil, batteryPct: nil, bonded: false,
                                    updated: Date(timeIntervalSince1970: 0))
        pinned.localeIdentifier = "de_DE"
        let roundTrip = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(pinned))
        XCTAssertEqual(roundTrip.localeIdentifier, "de_DE")

        let older = Data(#"{"recovery":50,"bonded":false,"updated":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(WidgetSnapshot.self, from: older).localeIdentifier)
    }
}

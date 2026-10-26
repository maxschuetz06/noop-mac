import XCTest
@testable import Strand

/// `AppLanguage` — the pure logic behind the Settings "Language" picker. It writes/removes the app's
/// own `AppleLanguages` default (which only takes effect on the next launch). Tests use an isolated
/// `UserDefaults(suiteName:)` so the real app preferences are never touched.
final class AppLanguageTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppLanguageTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func current() -> AppLanguage {
        AppLanguage.current(defaults: defaults, domain: suiteName)
    }

    private func storedLanguages() -> [String]? {
        defaults.persistentDomain(forName: suiteName)?[AppLanguage.defaultsKey] as? [String]
    }

    func testFreshDefaultsAreSystem() {
        XCTAssertEqual(current(), .system)
        XCTAssertNil(storedLanguages())
    }

    func testRoundTripEveryCase() {
        for language in AppLanguage.allCases {
            language.apply(defaults: defaults)
            XCTAssertEqual(current(), language, "round-trip failed for \(language)")
        }
    }

    func testLanguageCodes() {
        XCTAssertNil(AppLanguage.system.languageCode)
        XCTAssertEqual(AppLanguage.german.languageCode, "de")
        XCTAssertEqual(AppLanguage.english.languageCode, "en")
    }

    func testApplyWritesAppleLanguagesArray() {
        AppLanguage.german.apply(defaults: defaults)
        XCTAssertEqual(storedLanguages(), ["de"])
        AppLanguage.english.apply(defaults: defaults)
        XCTAssertEqual(storedLanguages(), ["en"])
    }

    func testSystemRemovesKey() {
        AppLanguage.german.apply(defaults: defaults)
        XCTAssertNotNil(storedLanguages())
        AppLanguage.system.apply(defaults: defaults)
        XCTAssertNil(storedLanguages())
        XCTAssertEqual(current(), .system)
    }

    func testUnknownStoredValueMapsToSystem() {
        defaults.set(["fr"], forKey: AppLanguage.defaultsKey)
        XCTAssertEqual(current(), .system)
        defaults.set([String](), forKey: AppLanguage.defaultsKey)
        XCTAssertEqual(current(), .system)
        defaults.set("de", forKey: AppLanguage.defaultsKey) // wrong type
        XCTAssertEqual(current(), .system)
    }

    func testRegionQualifiedCodesMapToBaseLanguage() {
        defaults.set(["de-DE", "en-US"], forKey: AppLanguage.defaultsKey)
        XCTAssertEqual(current(), .german)
        defaults.set(["en-GB"], forKey: AppLanguage.defaultsKey)
        XCTAssertEqual(current(), .english)
    }

    // MARK: - Content locale

    func testSystemFollowsTheSystemLocale() {
        for identifier in ["en_US", "fr_FR", "ru_RU", "de_CH"] {
            let system = Locale(identifier: identifier)
            XCTAssertEqual(AppLanguage.system.contentLocale(system: system).identifier, identifier)
        }
    }

    func testGermanForcesGermanWhateverTheSystem() {
        for identifier in ["en_US", "fr_FR", "de_CH"] {
            let locale = AppLanguage.german.contentLocale(system: Locale(identifier: identifier))
            XCTAssertEqual(locale.identifier, "de_DE")
        }
    }

    func testEnglishForcesUSEnglishWhateverTheSystem() {
        for identifier in ["de_DE", "fr_FR"] {
            let locale = AppLanguage.english.contentLocale(system: Locale(identifier: identifier))
            XCTAssertEqual(locale.identifier, "en_US")
        }
    }
}

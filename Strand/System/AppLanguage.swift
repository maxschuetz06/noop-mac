import Foundation

/// The app-language choice behind the Settings "Language" picker.
///
/// Stored the way Cocoa expects it: the app's own `AppleLanguages` default. `.system` removes the key
/// so macOS falls back to the system language order. The value is only read at launch, so a change
/// takes effect after the app relaunches.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case german
    case english

    var id: String { rawValue }

    /// The `UserDefaults` key Cocoa reads at launch to pick the UI language.
    static let defaultsKey = "AppleLanguages"

    /// BCP-47 language code written to `AppleLanguages`; `nil` for `.system` (key removed).
    var languageCode: String? {
        switch self {
        case .system: return nil
        case .german: return "de"
        case .english: return "en"
        }
    }

    /// The language currently persisted in the app's own preferences domain.
    ///
    /// Reads the app domain only (not the merged search list): `UserDefaults.standard.array(forKey:)`
    /// would also return the *system-wide* `AppleLanguages` and misreport "System" as e.g. English.
    /// Unknown, empty or wrongly typed values map to `.system`.
    static func current(defaults: UserDefaults = .standard,
                        domain: String? = Bundle.main.bundleIdentifier) -> AppLanguage {
        guard let domain,
              let stored = defaults.persistentDomain(forName: domain)?[defaultsKey] as? [String],
              let first = stored.first else { return .system }
        let base = first.split(separator: "-").first.map(String.init)?.lowercased()
        return allCases.first { $0.languageCode == base } ?? .system
    }

    /// The locale an explicit language pins; `nil` for `.system`. Published to the desktop widget,
    /// whose extension process otherwise follows the system language.
    var pinnedLocale: Locale? {
        switch self {
        case .system: return nil
        case .german: return Locale(identifier: "de_DE")
        case .english: return Locale(identifier: "en_US")
        }
    }

    /// The locale content screens render with (strings, dates, numbers): an explicit language forces
    /// its own locale, `.system` follows the system locale unchanged.
    func contentLocale(system: Locale) -> Locale {
        pinnedLocale ?? system
    }

    /// The content locale for the persisted setting; `.system` follows the live system locale.
    static var currentContentLocale: Locale { current().contentLocale(system: .autoupdatingCurrent) }

    /// Persist this choice (`["de"]` / `["en"]`, or remove the key for `.system`).
    func apply(defaults: UserDefaults = .standard) {
        if let languageCode {
            defaults.set([languageCode], forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }
}

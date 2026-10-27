import Foundation

/// Locale and string table the widget renders with. The extension is its own process, so its
/// `Bundle.main` and `Locale.current` follow the system language even when the app pins German or
/// English; the app therefore publishes its pinned locale in the snapshot (`localeIdentifier`).
struct WidgetLocalization {
    let locale: Locale
    /// Bundle whose `Localizable` table matches `locale`: a language folder (`de.lproj`) of the
    /// widget's catalog, or the catalog bundle itself when the system language applies.
    let bundle: Bundle

    /// A missing or empty identifier, or a language the catalog does not ship, follows the system.
    static func resolve(localeIdentifier: String?, system: Locale = .autoupdatingCurrent,
                        catalog: Bundle = .main) -> WidgetLocalization {
        let following = WidgetLocalization(locale: system, bundle: catalog)
        guard let localeIdentifier, !localeIdentifier.isEmpty else { return following }
        let locale = Locale(identifier: localeIdentifier)
        guard let language = locale.language.languageCode?.identifier,
              let path = catalog.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return following }
        return WidgetLocalization(locale: locale, bundle: bundle)
    }
}

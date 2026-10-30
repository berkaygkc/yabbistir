import Foundation

/// Looks up UI strings in the language the user picked inside yabbistir (not the
/// system language). Missing translations fall back to English, then to the key.
public enum L10n {
    private static let bundles: [AppLanguage: Bundle] = Dictionary(uniqueKeysWithValues:
        AppLanguage.allCases.compactMap { language in
            Bundle.module.path(forResource: language.rawValue, ofType: "lproj")
                .flatMap(Bundle.init(path:))
                .map { (language, $0) }
        })

    public static func string(_ key: String, _ language: AppLanguage, _ arguments: CVarArg...) -> String {
        let format = lookup(key, language) ?? lookup(key, .english) ?? key
        return arguments.isEmpty ? format : String(format: format, locale: language.locale, arguments: arguments)
    }

    private static func lookup(_ key: String, _ language: AppLanguage) -> String? {
        let missing = "\u{0}missing"
        guard let value = bundles[language]?.localizedString(forKey: key, value: missing, table: nil),
              value != missing else { return nil }
        return value
    }
}

import Foundation
import Observation

/// The app's UI language. A fresh install takes the first of the system's languages it speaks (`preferred(from:)`);
/// English is the fallback. The cases come in the order every language list shows them.
public enum AppLanguage: String, CaseIterable, Sendable, Codable {
    case english = "en"
    case german = "de"
    case spanish = "es"
    case french = "fr"
    case turkish = "tr"
    case japanese = "ja"
    case korean = "ko"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    public static let `default`: AppLanguage = .english

    public var locale: Locale {
        switch self {
        case .english: Locale(identifier: "en_US")
        case .german: Locale(identifier: "de_DE")
        case .spanish: Locale(identifier: "es_ES")
        case .french: Locale(identifier: "fr_FR")
        case .turkish: Locale(identifier: "tr_TR")
        case .japanese: Locale(identifier: "ja_JP")
        case .korean: Locale(identifier: "ko_KR")
        case .simplifiedChinese: Locale(identifier: "zh_Hans_CN")
        case .traditionalChinese: Locale(identifier: "zh_Hant_TW")
        }
    }

    /// The language's own name, as shown in language pickers.
    public var nativeName: String {
        switch self {
        case .english: "English"
        case .german: "Deutsch"
        case .spanish: "Español"
        case .french: "Français"
        case .turkish: "Türkçe"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        }
    }

    /// The first language in `identifiers` (BCP 47, as `Locale.preferredLanguages` gives them) that the app speaks,
    /// or the default. A language matches by its code alone (`de-AT` → German, `es-419` → Spanish), in any letter case
    /// and with `-` or `_`. Chinese goes by its script when the identifier names one (`zh-Hans-HK` → Simplified);
    /// without one, Taiwan, Hong Kong and Macau read Traditional and everywhere else Simplified. Cantonese (`yue`)
    /// reads Traditional unless it names Simplified.
    public static func preferred(from identifiers: [String]) -> AppLanguage {
        identifiers.lazy.compactMap(match).first ?? .default
    }

    private static func match(_ identifier: String) -> AppLanguage? {
        let subtags = identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard let code = subtags.first else { return nil }
        guard code == "zh" || code == "yue" else { return AppLanguage(rawValue: String(code)) }
        let rest = subtags.dropFirst()
        if rest.contains("hant") { return .traditionalChinese }
        if rest.contains("hans") { return .simplifiedChinese }
        if code == "yue" { return .traditionalChinese }
        return rest.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? .traditionalChinese : .simplifiedChinese
    }
}

@MainActor @Observable
public final class LanguageStore {
    public static let defaultsKey = "appLanguage"

    public var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Self.defaultsKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// A stored choice wins. Without one, a fresh install takes the system's language, while someone who used the app
    /// before the language followed the system (`isExistingUser`) stays in English, as before the update. Either answer
    /// is stored at once, so a later change to the Mac's languages never moves the app's.
    public init(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages,
                isExistingUser: Bool = false) {
        self.defaults = defaults
        if let stored = defaults.string(forKey: Self.defaultsKey).flatMap(AppLanguage.init(rawValue:)) {
            self.language = stored
        } else {
            let language = isExistingUser ? AppLanguage.english : .preferred(from: preferredLanguages)
            self.language = language
            defaults.set(language.rawValue, forKey: Self.defaultsKey)
        }
    }
}

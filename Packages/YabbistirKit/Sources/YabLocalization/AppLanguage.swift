import Foundation
import Observation

/// The app's UI language. English is the default regardless of the system language.
public enum AppLanguage: String, CaseIterable, Sendable, Codable {
    case english = "en"
    case turkish = "tr"

    public static let `default`: AppLanguage = .english

    public var locale: Locale {
        switch self {
        case .english: Locale(identifier: "en_US")
        case .turkish: Locale(identifier: "tr_TR")
        }
    }

    /// The language's own name, as shown in language pickers.
    public var nativeName: String {
        switch self {
        case .english: "English"
        case .turkish: "Türkçe"
        }
    }
}

@MainActor @Observable
public final class LanguageStore {
    public static let defaultsKey = "appLanguage"

    public var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Self.defaultsKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.language = defaults.string(forKey: Self.defaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? .default
    }
}

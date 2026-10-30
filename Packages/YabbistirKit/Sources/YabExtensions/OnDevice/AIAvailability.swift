import Foundation
import YabLocalization

/// Why the on-device model cannot run, each with what the person can do about it.
public enum AIUnavailable: Sendable, Equatable, CaseIterable {
    /// This Mac cannot run Apple Intelligence.
    case device
    /// Apple Intelligence is turned off in System Settings.
    case disabled
    /// The model is still downloading or getting ready.
    case notReady

    /// What `yab.ai.generate` is told, in the app's language.
    public static func message(_ reason: AIUnavailable, language: AppLanguage) -> String {
        switch reason {
        case .device: L10n.string("ai.unavailable.device", language)
        case .disabled: L10n.string("ai.unavailable.disabled", language)
        case .notReady: L10n.string("ai.unavailable.notReady", language)
        }
    }
}

/// Whether the on-device model can run now.
public enum AIAvailabilityState: Sendable, Equatable {
    case available
    case unavailable(AIUnavailable)
}

/// A language pair's state in Apple Translation.
public enum TranslationStatus: Sendable, Equatable {
    /// Its language pack is on this Mac: it translates now.
    case installed
    /// It can be translated once its language pack is downloaded.
    case supported
    /// This Mac cannot translate it.
    case unsupported
}

/// Why a text could not be translated. Language codes are BCP-47 ("en", "tr", "zh-Hans").
public enum TranslationUnavailable: Error, Sendable, Equatable {
    /// The pair's language pack is not downloaded: the app offers the download.
    case notInstalled(from: String, to: String)
    case unsupported(from: String, to: String)
    /// No source was given and the text's language could not be recognized.
    case unknownSource

    /// What `yab.translate` is told, in the app's language, the languages named in it too
    /// ("İngilizce → Türkçe dil paketi indirilmemiş").
    public static func message(_ reason: TranslationUnavailable, language: AppLanguage) -> String {
        switch reason {
        case .notInstalled(let from, let to):
            L10n.string("translate.notInstalled", language, LanguageNames.name(from, in: language), LanguageNames.name(to, in: language))
        case .unsupported(let from, let to):
            L10n.string("translate.unsupported", language, LanguageNames.name(from, in: language), LanguageNames.name(to, in: language))
        case .unknownSource:
            L10n.string("translate.unknownSource", language)
        }
    }
}

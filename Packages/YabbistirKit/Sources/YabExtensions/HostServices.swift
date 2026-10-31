import Foundation
import YabExtensionKit
import YabLocalization

/// What the app does when an extension asks (through `HostCallRouter`, which has already checked the
/// request): show a notice, open a link, read history, run the on-device model, translate.
@MainActor public protocol HostServices: AnyObject {
    /// A short notice titled with the extension's name.
    func notify(extensionName: String, message: String)
    /// An http or https link, in the default browser.
    func open(_ url: URL)
    func recentItems(limit: Int) async -> [ExtensionItem]
    func searchItems(_ query: String, limit: Int) async -> [ExtensionItem]
    /// The on-device model's answer (`OnDeviceHostServices.generate`).
    func generate(_ prompt: String, options: AIOptions) async throws(ExtensionError) -> String
    /// `text` in `to`, from `from` or the language it is recognized as (`OnDeviceHostServices.translate`).
    func translate(_ text: String, from: String?, to: String) async throws(TranslationFailure) -> TranslationOutput
}

/// Why `translate` failed: what the extension is told, and, when the pair itself was the problem, why,
/// so the router can offer a language pack that is not downloaded.
public struct TranslationFailure: Error, Equatable, Sendable {
    /// What the extension is told, in the app's language.
    public var error: ExtensionError
    public var reason: TranslationUnavailable?

    public init(_ error: ExtensionError, reason: TranslationUnavailable? = nil) {
        (self.error, self.reason) = (error, reason)
    }
}

/// The sentences the app answers an extension's request with as `unavailable`, in the person's language: what stops
/// Apple Intelligence or the translator, and a request the app took too long on. Every other `unavailable` is the
/// app's English for the developer.
public enum AppUnavailableMessage {
    /// Said as they are.
    static let keys = ["ai.unavailable.device", "ai.unavailable.disabled", "ai.unavailable.notReady", "ai.failed", "ai.failed.tooLong",
                       "ai.failed.declined", "ai.failed.language", "ai.failed.busy", "translate.failed", "translate.unknownSource", "host.tooSlow"]
    /// Naming a language pair.
    static let pairKeys = ["translate.notInstalled", "translate.unsupported"]

    /// `message` as the person reads it in `language` when it is one of the app's sentences, nil for any other text. A
    /// plain one in either language comes back in `language`; one naming a language pair only when it is already in
    /// `language`, since the names in it can't be said again in another.
    public static func localized(_ message: String, in language: AppLanguage) -> String? {
        for key in keys where AppLanguage.allCases.contains(where: { L10n.string(key, $0) == message }) {
            return L10n.string(key, language)
        }
        for key in pairKeys where matches(message, format: L10n.string(key, language)) { return message }
        return nil
    }

    /// Whether `text` is `format` with some text in place of each `%@` (or `%1$@`).
    private static func matches(_ text: String, format: String) -> Bool {
        let literals = format.replacing(/%(?:\d+\$)?@/, with: "\u{0}").components(separatedBy: "\u{0}")
        let pattern = "^" + literals.map(NSRegularExpression.escapedPattern(for:)).joined(separator: ".+") + "$"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}

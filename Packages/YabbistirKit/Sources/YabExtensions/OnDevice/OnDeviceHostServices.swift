import Foundation
import FoundationModels
import YabExtensionKit
import YabLocalization

/// The app's `generate` and `translate` (its `HostServices` calls these): the on-device model and
/// translator, with what stops them said in the app's language as `unavailable` (never the frameworks'
/// own descriptions: FoundationModels' are English only, Translation's follow the system), and a
/// cancelled call answered `cancelled`. The router has checked the request and bounded it already.
/// Logs nothing.
public struct OnDeviceHostServices: Sendable {
    private let model: any LanguageModelService
    private let translator: any TranslationService

    public init(model: any LanguageModelService = OnDeviceAI(), translator: any TranslationService = OnDeviceTranslator()) {
        (self.model, self.translator) = (model, translator)
    }

    private static let cancelled = ExtensionError(.cancelled, "the call was cancelled")

    // MARK: Generate

    public func generate(_ prompt: String, options: AIOptions, language: AppLanguage) async throws(ExtensionError) -> String {
        if case .unavailable(let reason) = model.availability() {
            throw ExtensionError(.unavailable, AIUnavailable.message(reason, language: language))
        }
        do {
            let answer = try await model.respond(prompt, options: options)
            // An answer that comes after the call ended is not the call's.
            try Task.checkCancellation()
            return answer
        } catch {
            if Self.isCancellation(error) { throw Self.cancelled }
            throw ExtensionError(.unavailable, L10n.string(Self.modelFailureKey(error), language))
        }
    }

    /// The model's failures, each said for what the person can do: shorten the text, rephrase it, wait.
    static func modelFailureKey(_ error: any Error) -> String {
        guard let error = error as? LanguageModelSession.GenerationError else { return "ai.failed" }
        switch error {
        case .exceededContextWindowSize: return "ai.failed.tooLong"
        case .guardrailViolation, .refusal: return "ai.failed.declined"
        case .unsupportedLanguageOrLocale: return "ai.failed.language"
        case .assetsUnavailable: return "ai.unavailable.notReady"
        case .rateLimited, .concurrentRequests: return "ai.failed.busy"
        case .decodingFailure, .unsupportedGuide: return "ai.failed"
        @unknown default: return "ai.failed"
        }
    }

    // MARK: Translate

    /// `from` left out is recognized; a text already in `to` comes back as it is, with its language.
    public func translate(_ text: String, from: String?, to: String,
                          language: AppLanguage) async throws(TranslationFailure) -> TranslationOutput {
        let source: String
        if let from {
            source = from
        } else if let recognized = translator.detect(text) {
            source = recognized
        } else {
            throw Self.failure(.unknownSource, language: language)
        }
        if Self.isSameLanguage(source, to) { return TranslationOutput(text: text, from: source) }

        switch await translator.status(from: source, to: to) {
        case .unsupported: throw Self.failure(.unsupported(from: source, to: to), language: language)
        case .supported: throw Self.failure(.notInstalled(from: source, to: to), language: language)
        case .installed: break
        }
        guard !Task.isCancelled else { throw TranslationFailure(Self.cancelled) }
        do {
            let translated = try await translator.translate(text, from: source, to: to)
            try Task.checkCancellation()
            return TranslationOutput(text: translated, from: source)
        } catch {
            if Self.isCancellation(error) { throw TranslationFailure(Self.cancelled) }
            if let reason = error as? TranslationUnavailable { throw Self.failure(reason, language: language) }
            // Not about the pair (the translator says so with `TranslationUnavailable`): nothing to offer.
            throw TranslationFailure(ExtensionError(.unavailable, L10n.string("translate.failed", language)))
        }
    }

    /// Same language and script: "en" and "en-GB" are one, "zh-Hans" and "zh-Hant" are not.
    static func isSameLanguage(_ first: String, _ second: String) -> Bool {
        let (one, two) = (Locale.Language(identifier: Locale.Language(identifier: first).maximalIdentifier),
                          Locale.Language(identifier: Locale.Language(identifier: second).maximalIdentifier))
        return one.languageCode == two.languageCode && one.script == two.script
    }

    // MARK: Failures

    private static func failure(_ reason: TranslationUnavailable, language: AppLanguage) -> TranslationFailure {
        TranslationFailure(ExtensionError(.unavailable, TranslationUnavailable.message(reason, language: language)), reason: reason)
    }

    /// Cancelled however the framework says it: checked before any other reading of the error.
    private static func isCancellation(_ error: any Error) -> Bool {
        Task.isCancelled || error is CancellationError
    }
}

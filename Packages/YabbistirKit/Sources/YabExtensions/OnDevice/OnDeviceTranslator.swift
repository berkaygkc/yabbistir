import Foundation
import NaturalLanguage
import Translation

/// Apple Translation and language recognition, as the app uses them for `yab.translate`; tests put a fake
/// in its place. Codes are BCP-47 ("en", "tr", "zh-Hans").
public protocol TranslationService: Sendable {
    func status(from: String, to: String) async -> TranslationStatus
    /// Translates with the pair's installed language pack. Stops, throwing, when the calling task is
    /// cancelled; throws `TranslationUnavailable` when the pack is gone or the pair cannot be translated.
    func translate(_ text: String, from: String, to: String) async throws -> String
    /// The text's language, or nil when it cannot be told.
    func detect(_ text: String) -> String?
}

/// The system's translator. Reading a pair's status needs an app with an event loop: in a bare process it
/// hangs, so the app runs this, never the extension host, and no test calls Translation.
/// Nothing here logs a text or a translation.
public struct OnDeviceTranslator: TranslationService {
    /// Recognition reads at most this much of a text: the start says which language it is.
    static let recognitionLength = 2_000

    public init() {}

    public func status(from: String, to: String) async -> TranslationStatus {
        switch await LanguageAvailability().status(from: Locale.Language(identifier: from), to: Locale.Language(identifier: to)) {
        case .installed: .installed
        case .supported: .supported
        case .unsupported: .unsupported
        @unknown default: .unsupported
        }
    }

    public func translate(_ text: String, from: String, to: String) async throws -> String {
        let session = Session(TranslationSession(installedSource: Locale.Language(identifier: from), target: Locale.Language(identifier: to)))
        do {
            return try await withTaskCancellationHandler {
                try await session.translate(text)
            } onCancel: {
                session.cancel()
            }
        } catch TranslationError.notInstalled {
            throw TranslationUnavailable.notInstalled(from: from, to: to)
        } catch TranslationError.unsupportedLanguagePairing, TranslationError.unsupportedSourceLanguage, TranslationError.unsupportedTargetLanguage {
            throw TranslationUnavailable.unsupported(from: from, to: to)
        } catch TranslationError.alreadyCancelled {
            throw CancellationError()
        } catch TranslationError.nothingToTranslate {
            return text
        }
    }

    public func detect(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(Self.recognitionLength)))
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
    }
}

/// A session made for one translation and used by it alone; `cancel()` may come from the cancelling task.
private final class Session: @unchecked Sendable {
    private let session: TranslationSession

    init(_ session: TranslationSession) {
        self.session = session
    }

    func translate(_ text: String) async throws -> String {
        try await session.translate(text).targetText
    }

    func cancel() {
        session.cancel()
    }
}

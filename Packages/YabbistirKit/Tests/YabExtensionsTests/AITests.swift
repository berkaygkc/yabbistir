import Foundation
import FoundationModels
import Synchronization
import Testing
import Translation
import YabExtensionKit
import YabLocalization
@testable import YabExtensions

/// The on-device model, faked: says whether it can run, answers, and can take its time ("thinking"),
/// noticing when it is told to stop.
final class FakeLanguageModel: LanguageModelService {
    struct Asked: Equatable {
        let prompt: String
        let options: AIOptions
    }

    private struct State {
        var availability = AIAvailabilityState.available
        var answer = "tamam"
        var thinking: Duration?
        var failure: (any Error)?
        var asked: [Asked] = []
        var cancelled = 0
    }

    private let state = Mutex(State())

    var availabilityState: AIAvailabilityState {
        get { state.withLock { $0.availability } }
        set { state.withLock { $0.availability = newValue } }
    }
    var answer: String {
        get { state.withLock { $0.answer } }
        set { state.withLock { $0.answer = newValue } }
    }
    /// How long an answer takes; nil answers at once.
    var thinking: Duration? {
        get { state.withLock { $0.thinking } }
        set { state.withLock { $0.thinking = newValue } }
    }
    /// What the model throws instead of answering.
    var failure: (any Error)? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }
    var asked: [Asked] { state.withLock { $0.asked } }
    /// Answers that were stopped while the model was still thinking.
    var cancelled: Int { state.withLock { $0.cancelled } }

    func availability() -> AIAvailabilityState { availabilityState }

    func respond(_ prompt: String, options: AIOptions) async throws -> String {
        let (thinking, failure) = state.withLock { state in
            state.asked.append(Asked(prompt: prompt, options: options))
            return (state.thinking, state.failure)
        }
        if let thinking {
            do {
                try await Task.sleep(for: thinking)
            } catch {
                state.withLock { $0.cancelled += 1 }
                throw error
            }
        }
        if let failure { throw failure }
        return answer
    }
}

/// Apple Translation, faked: one status for every pair, a recognizer that hears `detected`, and a
/// translation that tags the text with its target, can take its time (noticing when it is told to
/// stop) and can fail.
final class FakeTranslator: TranslationService {
    private struct State {
        var status = TranslationStatus.installed
        var detected: String? = "en"
        var delay: Duration?
        var failure: (any Error)?
        var statusAsked: [[String]] = []
        var translated: [[String]] = []
        var cancelled = 0
    }

    private let state = Mutex(State())

    var status: TranslationStatus {
        get { state.withLock { $0.status } }
        set { state.withLock { $0.status = newValue } }
    }
    var detected: String? {
        get { state.withLock { $0.detected } }
        set { state.withLock { $0.detected = newValue } }
    }
    /// How long a translation takes; nil translates at once.
    var delay: Duration? {
        get { state.withLock { $0.delay } }
        set { state.withLock { $0.delay = newValue } }
    }
    /// What a translation throws instead of translating.
    var failure: (any Error)? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }
    /// Translations that were stopped while under way.
    var cancelled: Int { state.withLock { $0.cancelled } }
    /// Each pair whose status was read, as [from, to].
    var statusAsked: [[String]] { state.withLock { $0.statusAsked } }
    /// Each translation, as [text, from, to].
    var translated: [[String]] { state.withLock { $0.translated } }

    func status(from: String, to: String) async -> TranslationStatus {
        state.withLock { state in
            state.statusAsked.append([from, to])
            return state.status
        }
    }

    func translate(_ text: String, from: String, to: String) async throws -> String {
        let (delay, failure) = state.withLock { state in
            state.translated.append([text, from, to])
            return (state.delay, state.failure)
        }
        if let delay {
            do {
                try await Task.sleep(for: delay)
            } catch {
                state.withLock { $0.cancelled += 1 }
                throw error
            }
        }
        if let failure { throw failure }
        return "[\(to)] \(text)"
    }

    func detect(_ text: String) -> String? { detected }
}

/// `yab.ai.generate` and `yab.translate`: the app runs them, through the same checks and the same
/// app-language reasons, whatever the host let through.
@MainActor @Suite struct AITests {
    /// An action that runs `body` and answers with what it returned, or with the error's code and message.
    private static func catching(_ body: String) -> String {
        """
        exports.actions = { a: { async run() {
          try { return { text: String(await (async () => { \(body) })()) }; } catch (e) { return { text: e.code + ": " + e.message }; }
        } } };
        """
    }

    // MARK: Reasons

    @Test func everyAIUnavailableReasonSaysWhatToDo() async throws {
        let table: [(AIUnavailable, String, String)] = [
            (.device, "This Mac can’t run Apple Intelligence", "Bu Mac Apple Intelligence’ı çalıştıramıyor"),
            (.disabled, "Turn on Apple Intelligence in System Settings", "Apple Intelligence’ı Sistem Ayarları’ndan aç"),
            (.notReady, "Apple Intelligence is still getting ready", "Apple Intelligence henüz hazırlanıyor"),
        ]
        #expect(table.map(\.0) == AIUnavailable.allCases)
        let harness = try await HostCallHarness(js: Self.catching(#"return await yab.ai.generate("Özetle");"#))
        for (reason, english, turkish) in table {
            #expect(AIUnavailable.message(reason, language: .english) == english)
            #expect(AIUnavailable.message(reason, language: .turkish) == turkish)
            harness.services.model.availabilityState = .unavailable(reason)
            // The app says it in its own language, as `unavailable`.
            for (language, text) in [(AppLanguage.english, english), (.turkish, turkish)] {
                harness.services.language = language
                await #expect(throws: ExtensionError(.unavailable, text)) {
                    try await harness.ask("ai.generate", ["prompt": .string("Özetle")])
                }
            }
            // The script hears it as it is.
            #expect(try await harness.run() == .result(.text("unavailable: \(turkish)")))
        }
        // The model was never asked.
        #expect(harness.services.model.asked.isEmpty)
    }

    @Test func aMissingLanguagePairOffersTheDownload() async throws {
        let harness = try await HostCallHarness(js: Self.catching(#"const r = await yab.translate("Hello", { to: "tr", from: "en" }); return r.text;"#))
        harness.services.translator.status = .supported
        harness.services.language = .turkish
        var offered: [[String]] = []
        harness.router.onTranslationNeeded = { from, to in offered.append([from, to]) }

        #expect(try await harness.run() == .result(.text("unavailable: İngilizce → Türkçe dil paketi indirilmemiş")))
        #expect(offered == [["en", "tr"]])
        // A recognized source is offered the same way, and the app speaks English when it does.
        harness.services.language = .english
        await #expect(throws: ExtensionError(.unavailable, "The English → Turkish language pack isn’t downloaded")) {
            try await harness.ask("translate", ["text": .string("Hello"), "to": .string("tr")])
        }
        #expect(offered == [["en", "tr"], ["en", "tr"]])
        #expect(harness.services.translator.statusAsked == [["en", "tr"], ["en", "tr"]])
        #expect(harness.services.translator.translated.isEmpty)
        // A pair this Mac cannot translate is no download.
        harness.services.translator.status = .unsupported
        harness.services.language = .turkish
        await #expect(throws: ExtensionError(.unavailable, "İngilizce → Japonca bu Mac’te çevrilemiyor")) {
            try await harness.ask("translate", ["text": .string("Hello"), "to": .string("ja"), "from": .string("en")])
        }
        harness.services.language = .english
        await #expect(throws: ExtensionError(.unavailable, "English → Japanese can’t be translated on this Mac")) {
            try await harness.ask("translate", ["text": .string("Hello"), "to": .string("ja"), "from": .string("en")])
        }
        #expect(offered.count == 2)
    }

    @Test func aiIsNotForHints() async throws {
        let harness = try await HostCallHarness(js: #"""
        exports.actions = { a: { async run() {
          const codes = [];
          for (const ask of [() => yab.ai.generate("x"), () => yab.translate("x", { to: "tr" })]) {
            try { await ask(); codes.push("ran"); } catch (e) { codes.push(e.code); }
          }
          return { text: codes.join(",") };
        } } };
        """#)
        #expect(try await harness.run(effects: false) == .result(.text("permissionDenied,permissionDenied")))
        #expect(harness.handled == 0)
        // The app refuses too, whatever the host let through: without `effects`, and in rules, detectors and previews.
        let asks: [(String, [String: JSONValue])] = [("ai.generate", ["prompt": .string("x")]),
                                                     ("translate", ["text": .string("x"), "to": .string("tr")])]
        for (method, params) in asks {
            await #expect {
                try await harness.ask(method, params, effects: false)
            } throws: { ($0 as? ExtensionError)?.code == .permissionDenied }
            for kind in [InvokeKind.validate, .preview, .captureRule] {
                await #expect {
                    try await harness.ask(method, params, kind: kind)
                } throws: { ($0 as? ExtensionError)?.code == .permissionDenied }
            }
        }
        #expect(harness.services.model.asked.isEmpty)
        #expect(harness.services.translator.statusAsked.isEmpty)
        #expect(harness.services.translator.translated.isEmpty)
    }

    // MARK: Generate

    @Test func generatePassesInstructionsAndLimits() async throws {
        let harness = try await HostCallHarness(js: Self.catching(#"""
        return await yab.ai.generate("Kısalt", { instructions: "Tek cümle yaz.", temperature: 0.4, maxTokens: 300 });
        """#))
        harness.services.model.answer = "Kısa."
        #expect(try await harness.run() == .result(.text("Kısa.")))
        #expect(harness.services.model.asked == [.init(prompt: "Kısalt", options: AIOptions(instructions: "Tek cümle yaz.", temperature: 0.4, maxTokens: 300))])
        // Left out, they stay unset: the model's own defaults.
        _ = try await harness.ask("ai.generate", ["prompt": .string("Kısalt")])
        #expect(harness.services.model.asked.last == .init(prompt: "Kısalt", options: AIOptions()))
        let answer = try await harness.ask("ai.generate", ["prompt": .string("Kısalt"), "options": .object([:])])
        #expect(answer == .string("Kısa."))
        #expect(harness.services.model.asked.last?.options == AIOptions())
    }

    @Test func optionsAndTextsAreBounded() async throws {
        let harness = try await HostCallHarness(js: Self.catching(#"return await yab.ai.generate("x", { temperature: 9, maxTokens: 1e9 });"#))
        _ = try await harness.run()
        #expect(harness.services.model.asked.last?.options == AIOptions(temperature: 2, maxTokens: 2048))
        _ = try await harness.ask("ai.generate", ["prompt": .string("x"), "options": .object(["temperature": .number(-1), "maxTokens": .number(0)])])
        #expect(harness.services.model.asked.last?.options == AIOptions(temperature: 0, maxTokens: 1))
        _ = try await harness.ask("ai.generate", ["prompt": .string("x"), "options": .object(["maxTokens": .number(12.7)])])
        #expect(harness.services.model.asked.last?.options == AIOptions(maxTokens: 12))
        // One character each, two code points and four UTF-16 units: a cut anywhere else would split one.
        let long = String(repeating: "👍🏽", count: 40_000)
        let cut = String(repeating: "👍🏽", count: 32_000)
        _ = try await harness.ask("ai.generate", ["prompt": .string(long), "options": .object(["instructions": .string(long)])])
        #expect(harness.services.model.asked.last?.prompt == cut)
        #expect(harness.services.model.asked.last?.options.instructions == cut)
        _ = try await harness.ask("translate", ["text": .string(long), "to": .string("tr")])
        #expect(harness.services.translator.translated.last?.first == cut)
    }

    @Test func cancellingTheCallStopsTheModel() async throws {
        let harness = try await HostCallHarness(js: Self.catching(#"return await yab.ai.generate("Uzun uzun düşün");"#))
        harness.services.model.thinking = .seconds(30)
        let call = Task { try await harness.run() }
        try await eventually { harness.services.model.asked.count == 1 }
        let start = ContinuousClock.now
        call.cancel()
        await #expect { _ = try await call.value } throws: { ($0 as? ExtensionError)?.code == .cancelled }
        // The model stops thinking: the app's request is cancelled with the call.
        try await eventually { harness.services.model.cancelled == 1 }
        #expect(ContinuousClock.now - start < .seconds(2))
        // Straight to the services, a cancelled task answers `cancelled`, not the model's answer.
        harness.services.model.thinking = .seconds(30)
        let services = harness.services
        let direct = Task { @MainActor in try await services.generate("x", options: AIOptions()) }
        try await eventually { harness.services.model.asked.count == 2 }
        direct.cancel()
        await #expect(throws: ExtensionError(.cancelled, "the call was cancelled")) { try await direct.value }
    }

    /// What the model throws instead of answering, in the app's language: FoundationModels' own
    /// descriptions are English only.
    @Test(arguments: modelFailures)
    func aModelFailureSpeaksTheAppsLanguage(_ failure: FailureCase) async throws {
        let model = FakeLanguageModel()
        model.failure = failure.error
        let services = OnDeviceHostServices(model: model, translator: FakeTranslator())
        for (language, text) in [(AppLanguage.english, failure.english), (.turkish, failure.turkish)] {
            await #expect(throws: ExtensionError(.unavailable, text)) {
                try await services.generate("Özetle", options: AIOptions(), language: language)
            }
        }
    }

    @Test func badArgumentsAreRefused() async throws {
        let harness = try await HostCallHarness(js: #"""
        exports.actions = { a: { async run() {
          const out = [];
          for (const ask of [() => yab.ai.generate(42), () => yab.ai.generate("x", { temperature: "sıcak" }),
                             () => yab.ai.generate("x", { maxTokens: NaN }), () => yab.ai.generate("x", { instructions: 3 }),
                             () => yab.translate(5, { to: "tr" }), () => yab.translate("x"), () => yab.translate("x", { to: "" }),
                             () => yab.translate("x", { to: "tr", from: 7 })]) {
            try { await ask(); out.push("ran"); } catch (e) { out.push(e.code); }
          }
          return { text: out.join(",") };
        } } };
        """#)
        #expect(try await harness.run() == .result(.text([String](repeating: "badResult", count: 8).joined(separator: ","))))
        #expect(harness.handled == 0)
        // The app holds the same line.
        for params: [String: JSONValue] in [[:], ["text": .string("x")], ["text": .string("x"), "to": .string("")],
                                            ["text": .string("x"), "to": .string("tr; rm -rf")], ["to": .string("tr")]] {
            await #expect {
                try await harness.ask("translate", params)
            } throws: { ($0 as? ExtensionError)?.code == .badResult }
        }
        await #expect {
            try await harness.ask("ai.generate", [:])
        } throws: { ($0 as? ExtensionError)?.code == .badResult }
        #expect(harness.services.model.asked.isEmpty)
        #expect(harness.services.translator.translated.isEmpty)
    }

    // MARK: Translate

    @Test func aTranslationReachesTheScript() async throws {
        let harness = try await HostCallHarness(js: Self.catching(#"""
        const r = await yab.translate("Good morning", { to: "tr" });
        return r.text + "|" + r.from;
        """#))
        #expect(try await harness.run() == .result(.text("[tr] Good morning|en")))
        #expect(harness.services.translator.statusAsked == [["en", "tr"]])
        #expect(harness.services.translator.translated == [["Good morning", "en", "tr"]])
        // A source the extension names is taken as it is.
        let reply = try await harness.ask("translate", ["text": .string("Bonjour"), "to": .string("tr"), "from": .string("fr")])
        #expect(reply == .object(["text": .string("[tr] Bonjour"), "from": .string("fr")]))
    }

    @Test func aTextAlreadyInTheTargetComesBackAsItIs() async throws {
        let harness = try await HostCallHarness(js: Self.catching(#"const r = await yab.translate("Merhaba", { to: "tr" }); return r.text + "|" + r.from;"#))
        harness.services.translator.detected = "tr"
        #expect(try await harness.run() == .result(.text("Merhaba|tr")))
        // A regional variant of the same language is the same language; another script is not.
        harness.services.translator.detected = "en"
        let same = try await harness.ask("translate", ["text": .string("Colour"), "to": .string("en-GB")])
        #expect(same == .object(["text": .string("Colour"), "from": .string("en")]))
        harness.services.translator.detected = "zh-Hans"
        _ = try await harness.ask("translate", ["text": .string("你好"), "to": .string("zh-Hant")])
        #expect(harness.services.translator.statusAsked == [["zh-Hans", "zh-Hant"]])
    }

    @Test func anUnknownSourceLanguageIsSaid() async throws {
        let harness = try await HostCallHarness(js: Self.catching(#"return (await yab.translate("1234 !!", { to: "tr" })).text;"#))
        harness.services.translator.detected = nil
        harness.services.language = .turkish
        #expect(try await harness.run() == .result(.text("unavailable: Bu metnin dili anlaşılamadı")))
        harness.services.language = .english
        await #expect(throws: ExtensionError(.unavailable, "Couldn’t tell which language this is")) {
            try await harness.ask("translate", ["text": .string("1234 !!"), "to": .string("tr")])
        }
        #expect(harness.services.translator.statusAsked.isEmpty)
    }

    /// What Translation throws that is not about the pair, in the app's language; no download is offered.
    @Test(arguments: translationFailures)
    func aTranslationFailureSpeaksTheAppsLanguage(_ failure: FailureCase) async throws {
        let translator = FakeTranslator()
        translator.failure = failure.error
        let services = OnDeviceHostServices(model: FakeLanguageModel(), translator: translator)
        for (language, text) in [(AppLanguage.english, failure.english), (.turkish, failure.turkish)] {
            await #expect(throws: TranslationFailure(ExtensionError(.unavailable, text))) {
                try await services.translate("Good morning", from: "en", to: "tr", language: language)
            }
        }
    }

    @Test func cancellingTheCallStopsTheTranslation() async throws {
        let harness = try await HostCallHarness(js: Self.catching(#"return (await yab.translate("Good morning", { to: "tr" })).text;"#))
        harness.services.translator.delay = .seconds(30)
        var offered = 0
        harness.router.onTranslationNeeded = { _, _ in offered += 1 }
        let call = Task { try await harness.run() }
        try await eventually { harness.services.translator.translated.count == 1 }
        let start = ContinuousClock.now
        call.cancel()
        // The call ends cancelled, not failed.
        await #expect { _ = try await call.value } throws: { ($0 as? ExtensionError)?.code == .cancelled }
        // The translation stops: the app's request is cancelled with the call.
        try await eventually { harness.services.translator.cancelled == 1 }
        #expect(ContinuousClock.now - start < .seconds(2))
        // Nothing goes back for it, and nothing is offered.
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.transport.requests.allSatisfy { $0.reply == nil })
        #expect(offered == 0)
        // Straight to the services, a cancelled translation is `cancelled`, with no reason about the pair.
        let services = harness.services
        let direct = Task { @MainActor in try await services.translate("Good morning", from: "en", to: "tr") }
        try await eventually { harness.services.translator.translated.count == 2 }
        direct.cancel()
        await #expect(throws: TranslationFailure(ExtensionError(.cancelled, "the call was cancelled"))) { try await direct.value }
    }

    /// NaturalLanguage, not Translation: it answers in any process.
    @Test func theRealRecognizerTellsTheLanguage() {
        let translator = OnDeviceTranslator()
        #expect(translator.detect("Merhaba dünya, bugün hava çok güzel ve dışarı çıkmak istiyorum.") == "tr")
        #expect(translator.detect("Good morning, the weather is lovely and I would like to go outside.") == "en")
        #expect(translator.detect("1234 !!") == nil)
        #expect(translator.detect("") == nil)
    }

    // MARK: The real model

    /// The on-device model itself, when this Mac has it. Translation has no such test: reading a pair's
    /// status hangs in a process without an event loop; a manual check covers it.
    @Test(.enabled(if: OnDeviceAI().availability() == .available,
                   "Apple Intelligence is not available on this Mac (not eligible, turned off, or still getting ready)"),
          .timeLimit(.minutes(1)))
    func theRealModelAnswersWhenAvailable() async throws {
        let services = OnDeviceHostServices(model: OnDeviceAI(), translator: FakeTranslator())
        let answer = try await withDeadline(.seconds(60)) {
            try await services.generate("Say OK", options: AIOptions(maxTokens: 16), language: .english)
        }
        #expect(!answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

/// An error a fake throws, and what the person is told for it in each language.
struct FailureCase: Sendable, CustomTestStringConvertible {
    let name: String
    let error: any Error
    let english: String
    let turkish: String
    var testDescription: String { name }
}

/// Not a framework error: anything else a model or translator might throw.
private struct SomethingElse: Error {}

private let modelFailures: [FailureCase] = {
    typealias Failure = LanguageModelSession.GenerationError
    let context = Failure.Context(debugDescription: "test")
    let (tooLong, declined, language, busy, failed) = (
        ("This text is too long for Apple Intelligence", "Bu metin Apple Intelligence için çok uzun"),
        ("Apple Intelligence won’t answer this", "Apple Intelligence buna yanıt vermiyor"),
        ("Apple Intelligence doesn’t support this language yet", "Apple Intelligence bu dili henüz desteklemiyor"),
        ("Apple Intelligence is busy, try again in a moment", "Apple Intelligence meşgul, birazdan yeniden dene"),
        ("Apple Intelligence couldn’t answer", "Apple Intelligence yanıt veremedi"))
    let cases: [(String, any Error, (String, String))] = [
        ("exceededContextWindowSize", Failure.exceededContextWindowSize(context), tooLong),
        ("guardrailViolation", Failure.guardrailViolation(context), declined),
        ("refusal", Failure.refusal(Failure.Refusal(transcriptEntries: []), context), declined),
        ("unsupportedLanguageOrLocale", Failure.unsupportedLanguageOrLocale(context), language),
        ("assetsUnavailable", Failure.assetsUnavailable(context), ("Apple Intelligence is still getting ready", "Apple Intelligence henüz hazırlanıyor")),
        ("rateLimited", Failure.rateLimited(context), busy),
        ("concurrentRequests", Failure.concurrentRequests(context), busy),
        ("decodingFailure", Failure.decodingFailure(context), failed),
        ("unsupportedGuide", Failure.unsupportedGuide(context), failed),
        ("another error", SomethingElse(), failed),
    ]
    return cases.map { FailureCase(name: $0.0, error: $0.1, english: $0.2.0, turkish: $0.2.1) }
}()

private let translationFailures: [FailureCase] = {
    let failed = ("This text couldn’t be translated", "Bu metin çevrilemedi")
    let cases: [(String, any Error)] = [("internalError", TranslationError.internalError),
                                        ("unableToIdentifyLanguage", TranslationError.unableToIdentifyLanguage),
                                        ("another error", SomethingElse())]
    return cases.map { FailureCase(name: $0.0, error: $0.1, english: failed.0, turkish: failed.1) }
}()

/// Gave up waiting.
struct DeadlinePassed: Error {}

/// `work`'s answer, or `DeadlinePassed` once `limit` is up, without waiting for `work` to notice it was
/// cancelled: a framework that ignores cancellation cannot hold the test.
func withDeadline<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    let once = Once<T>()
    return try await withCheckedThrowingContinuation { continuation in
        once.waiting.withLock { $0 = continuation }
        let job = Task {
            let outcome: Result<T, any Error>
            do { outcome = .success(try await work()) } catch { outcome = .failure(error) }
            once.settle(outcome)
        }
        Task {
            try? await Task.sleep(for: limit)
            job.cancel()
            once.settle(.failure(DeadlinePassed()))
        }
    }
}

/// A continuation resumed by whichever comes first.
private final class Once<T: Sendable>: Sendable {
    let waiting = Mutex<CheckedContinuation<T, any Error>?>(nil)

    func settle(_ outcome: Result<T, any Error>) {
        waiting.withLock { $0.take() }?.resume(with: outcome)
    }
}

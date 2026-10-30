import Foundation
import Synchronization
import YabExtensionKit
import YabLocalization

/// A request an extension's call made of the app. `kind` and `effects` are those of the call that asked.
public struct HostCall: Equatable, Sendable {
    public var extensionID: String
    /// The invoke that asked; its requests end with it.
    public var invokeID: Int
    public var requestID: Int
    public var kind: InvokeKind
    public var method: String
    public var params: JSONValue
    public var effects: Bool

    public init(extensionID: String, invokeID: Int, requestID: Int, kind: InvokeKind, method: String, params: JSONValue, effects: Bool) {
        (self.extensionID, self.invokeID, self.requestID, self.kind) = (extensionID, invokeID, requestID, kind)
        (self.method, self.params, self.effects) = (method, params, effects)
    }
}

/// Answers extensions' requests to the app. The host checked them already; this checks them again, so
/// a host that lets one through still gets no further: `effects`, the notice's limits, the link's scheme.
@MainActor public final class HostCallRouter {
    /// A notice's longest message, in characters.
    public static let noticeLength = 200
    /// An extension gets at most one notice in this long; more are dropped without an error.
    public static let noticeInterval: Duration = .seconds(3)
    /// The longest the app works on one request. The call's own clock waits while it does (`ExtensionHostClient`),
    /// so without this a request the app never finishes (a translation or the model stuck) would hold the call forever.
    public static let serviceLimit: Duration = .seconds(60)

    private let services: any HostServices
    private let registry: ExtensionRegistry
    private let clock: () -> ContinuousClock.Instant
    private let serviceLimit: Duration
    /// When each extension's last notice went up.
    private var lastNotice: [String: ContinuousClock.Instant] = [:]
    /// The app's language, for the names notices carry and the refusals the person reads.
    public var language: () -> String = { AppLanguage.default.rawValue }
    /// A translation failed for a language pack that is not downloaded: the app offers it (a notice
    /// with "Download"). The extension is still told why, as `unavailable`.
    public var onTranslationNeeded: (@MainActor (_ from: String, _ to: String) -> Void)?
    /// How many language packs each extension's calls have been offered (`failureNeedsNotice(_:)`).
    private var translationOffers: [String: Int] = [:]

    /// `serviceLimit`: the longest one request may take (tests make it short).
    public init(services: any HostServices, registry: ExtensionRegistry, clock: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
                serviceLimit: Duration = HostCallRouter.serviceLimit) {
        self.services = services
        self.registry = registry
        self.clock = clock
        self.serviceLimit = serviceLimit
    }

    /// Answers a request, within `serviceLimit`. Past it the work is cancelled and left to wind down on its own, and
    /// the call is answered `unavailable` in the app's language. Cancelling the calling Task (the call ended) cancels
    /// the work too.
    public func handle(_ call: HostCall) async throws(ExtensionError) -> JSONValue {
        let first = FirstOutcome()
        let work = Task { @MainActor in
            do throws(ExtensionError) { first.finish(.success(try await answer(call))) } catch { first.finish(.failure(error)) }
        }
        let tooSlow = ExtensionError(.unavailable, L10n.string("host.tooSlow", AppLanguage(rawValue: language()) ?? .default))
        let clock = Task { [serviceLimit] in
            try? await Task.sleep(for: serviceLimit)
            if !Task.isCancelled { first.finish(.failure(tooSlow)) }
        }
        let outcome = await withTaskCancellationHandler {
            await first.outcome
        } onCancel: {
            first.finish(.failure(ExtensionError(.cancelled, "the call was cancelled")))
        }
        work.cancel()
        clock.cancel()
        return try outcome.get()
    }

    private func answer(_ call: HostCall) async throws(ExtensionError) -> JSONValue {
        switch call.method {
        case "notify":
            try notify(call)
        case "open":
            try open(call)
        case "history.recent":
            try requireHistory(call)
            return history(call) { limit in services.recentItems(limit: limit) }
        case "history.search":
            try requireHistory(call)
            guard let query = call.params["query"]?.stringValue else { throw ExtensionError(.badResult, "yab.history.search takes a query") }
            return history(call) { limit in services.searchItems(query, limit: limit) }
        case "ai.generate":
            return try await generate(call)
        case "translate":
            return try await translate(call)
        default:
            throw ExtensionError(.notFound, "unknown host call \(call.method)")
        }
        return .null
    }

    // MARK: History

    /// A call reads this much history at most, and this much when it does not say.
    public static let historyLimit = 50
    public static let historyDefaultLimit = 20
    /// A text (and an item's HTML) is cut to this many bytes of UTF-8, at a character boundary.
    public static let historyTextBytes = 65_536

    /// History needs the `history` permission, and a run the person started or a job: never a rule, detector or
    /// preview. Checked before anything else about the request. The refusal is the person's to read (a card or
    /// notice shows it as it is): in the app's language. The helper refuses too, and asks here anyway so that
    /// this refusal is the one the extension sees.
    private func requireHistory(_ call: HostCall) throws(ExtensionError) {
        let granted = registry.installed.first { $0.id == call.extensionID }.flatMap { installed in
            installed.isUsable ? installed.manifest.map { PermissionGrant.requested(by: $0).permissions.contains("history") } : false
        } ?? false
        let language = AppLanguage(rawValue: language()) ?? .default
        guard granted else { throw ExtensionError(.permissionDenied, L10n.string("history.denied.permission", language)) }
        guard !Self.rulesAndDetectors.contains(call.kind) else {
            throw ExtensionError(.permissionDenied, L10n.string("history.denied.kind", language))
        }
    }

    /// The newest items, or those `read` finds, at most the call's limit (1 to 50, 20 when it does not say).
    private func history(_ call: HostCall, _ read: (Int) -> [ExtensionItem]) -> JSONValue {
        var limit = Self.historyDefaultLimit
        if let number = call.params["limit"]?.numberValue, number.isFinite {
            limit = Int(min(max(number, 1), Double(Self.historyLimit)))
        }
        return .array(read(limit).prefix(limit).map(Self.trimmed))
    }

    /// An item as an extension sees it from history: no pixels (width and height stay), a bounded text.
    private static func trimmed(_ item: ExtensionItem) -> JSONValue {
        var item = item
        item.text = item.text.map(cut)
        if let html = item.richText?.html { item.richText?.html = cut(html) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let image = item.image
        item.image = nil
        guard let data = try? encoder.encode(item), var value = try? JSONDecoder().decode(JSONValue.self, from: data),
              var object = value.objectValue else { return .null }
        if let image { object["image"] = .object(["width": .number(Double(image.width)), "height": .number(Double(image.height))]) }
        value = .object(object)
        return value
    }

    private static func cut(_ text: String) -> String {
        text.cut(toUTF8Bytes: historyTextBytes)
    }

    // MARK: On-device model and translation

    /// A prompt, instructions or text to translate is cut to this many characters, at a character boundary.
    public static let textLength = 32_000
    /// `maxTokens` and `temperature` are held to these. 4096 tokens is the model's whole context, prompt
    /// included, so an answer may ask for half of it.
    public static let maxTokensRange = 1...2048
    public static let temperatureRange = 0.0...2.0

    /// Only in a run the person started or a job: the model is too costly to run on every keystroke.
    private func generate(_ call: HostCall) async throws(ExtensionError) -> JSONValue {
        try requireEffects(call)
        guard let prompt = call.params["prompt"]?.stringValue else { throw ExtensionError(.badResult, "yab.ai.generate takes a prompt") }
        let fields = call.params["options"]?.objectValue ?? [:]
        var options = AIOptions()
        options.instructions = fields["instructions"]?.stringValue.map { String($0.prefix(Self.textLength)) }
        if let temperature = fields["temperature"]?.numberValue, temperature.isFinite {
            options.temperature = min(max(temperature, Self.temperatureRange.lowerBound), Self.temperatureRange.upperBound)
        }
        if let maxTokens = fields["maxTokens"]?.numberValue, maxTokens.isFinite {
            options.maxTokens = Int(min(max(maxTokens, Double(Self.maxTokensRange.lowerBound)), Double(Self.maxTokensRange.upperBound)))
        }
        return .string(try await services.generate(String(prompt.prefix(Self.textLength)), options: options))
    }

    /// Same rule as the model. A language pack that is not downloaded is offered (`onTranslationNeeded`).
    private func translate(_ call: HostCall) async throws(ExtensionError) -> JSONValue {
        try requireEffects(call)
        guard let text = call.params["text"]?.stringValue, let to = call.params["to"]?.stringValue, Self.isLanguageCode(to) else {
            throw ExtensionError(.badResult, "yab.translate takes a text and a target language code: { to: \"tr\" }")
        }
        let from = call.params["from"]?.stringValue
        if let from, !Self.isLanguageCode(from) { throw ExtensionError(.badResult, "from must be a language code, like \"en\"") }
        do throws(TranslationFailure) {
            let output = try await services.translate(String(text.prefix(Self.textLength)), from: from, to: to)
            return .object(["text": .string(output.text), "from": .string(output.from)])
        } catch {
            if case .notInstalled(let source, let target)? = error.reason {
                translationOffers[call.extensionID, default: 0] += 1
                onTranslationNeeded?(source, target)
            }
            throw error.error
        }
    }

    /// A run of one extension's, noted as it starts (`failureNeedsNotice(_:)`).
    public struct RunMark: Equatable, Sendable {
        let extensionID: String
        let offers: Int
    }

    /// Taken before the run reaches its extension.
    public func mark(runOf extensionID: String) -> RunMark {
        RunMark(extensionID: extensionID, offers: translationOffers[extensionID] ?? 0)
    }

    /// Whether a run that failed needs a failure notice of its own: not when its extension was offered a language pack
    /// meanwhile. That offer says what failed and what to do about it ("Download"); a second notice would cover it.
    public func failureNeedsNotice(_ run: RunMark) -> Bool {
        (translationOffers[run.extensionID] ?? 0) == run.offers
    }

    /// A BCP-47 code as far as it matters here: letters, digits and hyphens, a language first ("tr", "zh-Hans", "pt-BR").
    private static func isLanguageCode(_ code: String) -> Bool {
        code.wholeMatch(of: /[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{1,8})*/) != nil
    }

    private func notify(_ call: HostCall) throws(ExtensionError) {
        try requireEffects(call)
        guard let message = call.params["message"]?.stringValue else { throw ExtensionError(.badResult, "yab.notify takes a message") }
        let now = clock()
        if let last = lastNotice[call.extensionID], now - last < Self.noticeInterval { return }
        lastNotice[call.extensionID] = now
        services.notify(extensionName: name(of: call.extensionID), message: String(message.prefix(Self.noticeLength)))
    }

    private func open(_ call: HostCall) throws(ExtensionError) {
        try requireEffects(call)
        guard let text = call.params["url"]?.stringValue, let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else {
            throw ExtensionError(.badResult, "only http and https links open")
        }
        services.open(url)
    }

    /// Calls whose answer must not depend on anything outside the item: rules, detectors and previews.
    private static let rulesAndDetectors: Set<InvokeKind> = [.validate, .preview, .captureRule]

    /// What reaches beyond the call (notices, links, the model, translation) belongs to a run the person started.
    private func requireEffects(_ call: HostCall) throws(ExtensionError) {
        guard call.effects, !Self.rulesAndDetectors.contains(call.kind) else {
            throw ExtensionError(.permissionDenied, "\(call.method) is not available in hints, detectors and previews")
        }
    }

    private func name(of extensionID: String) -> String {
        registry.installed.first { $0.id == extensionID }?.name(language: language()) ?? extensionID
    }
}

/// Whichever ends a request first: its answer, the limit, or the call's end. Finished from any thread; only the first
/// ending counts.
private final class FirstOutcome: Sendable {
    private struct State {
        var outcome: Result<JSONValue, ExtensionError>?
        var waiting: CheckedContinuation<Result<JSONValue, ExtensionError>, Never>?
    }

    private let state = Mutex(State())

    func finish(_ outcome: Result<JSONValue, ExtensionError>) {
        let waiting = state.withLock { state -> CheckedContinuation<Result<JSONValue, ExtensionError>, Never>? in
            guard state.outcome == nil else { return nil }
            state.outcome = outcome
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume(returning: outcome)
    }

    var outcome: Result<JSONValue, ExtensionError> {
        get async {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> Result<JSONValue, ExtensionError>? in
                    if let outcome = state.outcome { return outcome }
                    state.waiting = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }
}

extension String {
    /// At most `limit` bytes of UTF-8, at a character boundary.
    func cut(toUTF8Bytes limit: Int) -> String {
        guard utf8.count > limit else { return self }
        var bytes = 0
        var end = startIndex
        for index in indices {
            let next = self.index(after: index)
            bytes += self[index..<next].utf8.count
            if bytes > limit { break }
            end = next
        }
        return String(self[..<end])
    }
}

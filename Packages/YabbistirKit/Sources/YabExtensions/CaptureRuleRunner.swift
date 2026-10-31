import Foundation
import Synchronization
import YabCore
import YabExtensionKit

/// What a new copy becomes in its place: plain text, or a link.
public enum Replacement: Equatable, Sendable {
    case text(String)
    case url(String)
}

/// What the capture rules decided about one new copy, all together.
public struct CaptureRuleDecision: Equatable, Sendable {
    /// The copy is saved as this instead (text and link copies only); nil keeps it as it is.
    public var replacement: Replacement?
    /// Categories to put it in once it is saved, in the order the rules named them; each name once.
    public var categories: [String]
    /// A rule said not to save it: nothing else applies.
    public var ignore: Bool

    public init(replacement: Replacement? = nil, categories: [String] = [], ignore: Bool = false) {
        (self.replacement, self.categories, self.ignore) = (replacement, categories, ignore)
    }
}

/// Decides what happens to a new copy before it reaches history.
@MainActor
public protocol CaptureRuling: AnyObject {
    /// Whether any rule could run on a copy now. Cheap and synchronous: with none, a copy goes straight to history.
    var hasRules: Bool { get }
    /// The longest `run(on:)` takes on one copy when every rule keeps to its time. The copy path stops waiting a
    /// little past it, so a runner that stops answering never stalls capture.
    var budget: Duration { get }
    func run(on item: ExtensionItem) async -> CaptureRuleDecision
}

/// Runs the capture rules on a new copy: the rules of usable extensions with the
/// `capture` permission, unless switched off in Settings, one after another in the registry's order and
/// each extension's manifest order, on the rules whose `accepts` takes the copy as it stands by then.
///
/// Each rule sees what the rules before it made of the copy. `ignore` ends the chain. A rule that fails,
/// or does not answer within its time, is skipped and the copy goes on as if it were not there: the
/// Development log names the rule and the error's code, never what it saw or said. Concealed copies never
/// get here (`CaptureFilter`), and a copy whose text or link is over `ExtensionService.speculativeLimit` meets no rule.
@MainActor
public final class CaptureRuleRunner: CaptureRuling {
    /// How far past a rule's own limit the runner waits for it. A rule that hangs once loaded runs out the
    /// host client's clock first (a rule has no effects, so its clock never waits for the app), which restarts
    /// the host and counts against its extension; the runner's deadline only ends a call still waiting for its
    /// extension to load, which costs nobody.
    static let margin: Duration = .milliseconds(50)
    /// How much of a copy's text, in bytes of UTF-8, a rule's `accepts.pattern` is matched against. It runs on the
    /// main actor in the copy's path, where a pattern that backtracks over a megabyte would hold every copy behind
    /// it. The rule itself gets the whole copy.
    static let patternTextBytes = 65_536

    private let service: ExtensionService
    private let registry: ExtensionRegistry
    private let settings: ExtensionSettings
    private let timeout: Duration

    /// `timeout`: each rule's own limit.
    public init(service: ExtensionService, registry: ExtensionRegistry, settings: ExtensionSettings, timeout: Duration = .milliseconds(200)) {
        self.service = service
        self.registry = registry
        self.settings = settings
        self.timeout = timeout
    }

    public var hasRules: Bool { enabledRules > 0 }

    /// Each rule that could run, at its own limit and the margin.
    public var budget: Duration { (timeout + Self.margin) * enabledRules }

    /// The rules of usable extensions with `capture` that are switched on.
    private var enabledRules: Int {
        registry.installed.reduce(0) { count, installed in
            guard installed.isUsable, let manifest = installed.manifest, manifest.permissions.contains("capture") else { return count }
            return count + manifest.contributes.captureRules.count { settings.isRuleEnabled(installed.id, $0.id) }
        }
    }

    public func run(on item: ExtensionItem) async -> CaptureRuleDecision {
        // Too big to ship to a rule and back within its time, as for hints and detectors: the copy is kept as it is,
        // and no rule is called, so none runs out of time on it and counts against its extension.
        guard Self.fitsRules(item) else { return CaptureRuleDecision() }
        var decision = CaptureRuleDecision()
        var current = item
        var matched = Self.matchable(item)
        let catalog = service.catalog
        for installed in registry.installed where installed.isUsable {
            guard let manifest = installed.manifest, manifest.permissions.contains("capture") else { continue }
            for rule in manifest.contributes.captureRules where settings.isRuleEnabled(installed.id, rule.id) {
                guard catalog.accepts(CommandCatalog.qualified(rule.accepts, extensionID: installed.id), matched),
                      let outcome = await outcome(of: rule.id, in: installed.id, on: current) else { continue }
                switch outcome {
                case .keep:
                    break
                case .ignore:
                    // Not saved: nothing it would have become or been filed under matters.
                    return CaptureRuleDecision(ignore: true)
                case .replaceText(let text) where Self.isTextual(current):
                    decision.replacement = .text(text)
                    current = Self.replacing(current, with: .text(text))
                    matched = Self.matchable(current)
                case .replaceURL(let url) where Self.isTextual(current):
                    decision.replacement = .url(url)
                    current = Self.replacing(current, with: .url(url))
                    matched = Self.matchable(current)
                case .replaceText, .replaceURL:
                    // Pixels, files and colours stay what they are.
                    break
                case .addToCategory(let name):
                    let folded = SearchNormalizer.normalize(name)
                    if !decision.categories.contains(where: { SearchNormalizer.normalize($0) == folded }) { decision.categories.append(name) }
                }
            }
        }
        return decision
    }

    /// One rule's answer; nil when it failed or ran out of time. The rule's call races the deadline, and
    /// the copy goes on as soon as either ends: a call cut off is cancelled (the host is told to stop it,
    /// and nobody is blamed) and winds down on its own, without the copy waiting for that.
    private func outcome(of rule: String, in extensionID: String, on item: ExtensionItem) async -> CaptureOutcome? {
        let service = service
        let timeout = timeout
        let deadline = timeout + Self.margin
        let first = FirstEnding()
        // Started at once, in this turn: a loaded rule's call is in the host, its own clock running, before the
        // deadline starts below. A busy main actor would otherwise hold the call back while the deadline ran, and cut
        // a rule that hangs before its own time was up, so it would never be counted.
        let call = Task.immediate {
            first.finish(.answered(await CaptureRuleRunner.call(rule, in: extensionID, on: item, service: service, timeout: timeout)))
        }
        let clock = Self.startClock(first, deadline)
        let ending = await withTaskCancellationHandler {
            await first.ending
        } onCancel: {
            first.finish(.outOfTime)
        }
        call.cancel()
        clock.cancel()
        guard case .answered(let answer) = ending else {
            log(extensionID, rule, .timeout)
            return nil
        }
        do throws(ExtensionError) {
            return try answer.get()
        } catch {
            if error.code != .cancelled { log(extensionID, rule, error.code) }
            return nil
        }
    }

    private static func call(_ rule: String, in extensionID: String, on item: ExtensionItem, service: ExtensionService,
                             timeout: Duration) async -> Result<CaptureOutcome, ExtensionError> {
        do throws(ExtensionError) {
            return .success(try await service.runCaptureRule(extensionID: extensionID, rule: rule, item: item, timeout: timeout))
        } catch {
            return .failure(error)
        }
    }

    /// A plain timer, off the main actor and the task pool, so the deadline is kept however busy they are.
    /// Nonisolated: the timer's block runs on a global queue.
    nonisolated private static func startClock(_ first: FirstEnding, _ deadline: Duration) -> DispatchWorkItem {
        let clock = DispatchWorkItem { first.finish(.outOfTime) }
        let (seconds, attoseconds) = deadline.components
        let interval = DispatchTimeInterval.nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + interval, execute: clock)
        return clock
    }

    private func log(_ extensionID: String, _ rule: String, _ code: ExtensionError.Code) {
        service.client.log(extensionID, "\(extensionID): rule \(rule) failed (\(code.rawValue))")
    }

    /// Whether a copy's text and link are within `ExtensionService.speculativeLimit`, the size speculative work takes.
    private static func fitsRules(_ item: ExtensionItem) -> Bool {
        (item.text?.utf8.count ?? 0) <= ExtensionService.speculativeLimit && (item.url?.utf8.count ?? 0) <= ExtensionService.speculativeLimit
    }

    /// The copy as `accepts` matches it: its text and link cut to `patternTextBytes`.
    private static func matchable(_ item: ExtensionItem) -> ExtensionItem {
        var item = item
        item.text = item.text?.cut(toUTF8Bytes: patternTextBytes)
        item.url = item.url?.cut(toUTF8Bytes: patternTextBytes)
        return item
    }

    /// Copies whose content is text: what `replace` may rewrite.
    private static func isTextual(_ item: ExtensionItem) -> Bool {
        ["text", "code", "link"].contains(item.kind)
    }

    /// The copy as the next rule sees it: only the new text or link, rich text gone.
    private static func replacing(_ item: ExtensionItem, with replacement: Replacement) -> ExtensionItem {
        let (kind, text, url): (String, String, String?) = switch replacement {
        case .text(let text): ("text", text, nil)
        case .url(let url): ("link", url, url)
        }
        return ExtensionItem(id: item.id, kind: kind, text: text, url: url, tags: item.tags, source: item.source, copiedAt: item.copiedAt)
    }
}

/// How one rule's call ended, whichever came first: its answer or the deadline. Finished from any thread;
/// only the first ending counts.
private final class FirstEnding: Sendable {
    enum Ending: Sendable {
        case answered(Result<CaptureOutcome, ExtensionError>)
        case outOfTime
    }

    private struct State {
        var ending: Ending?
        var waiting: CheckedContinuation<Ending, Never>?
    }

    private let state = Mutex(State())

    func finish(_ ending: Ending) {
        let waiting = state.withLock { state -> CheckedContinuation<Ending, Never>? in
            guard state.ending == nil else { return nil }
            state.ending = ending
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume(returning: ending)
    }

    var ending: Ending {
        get async {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> Ending? in
                    if let ending = state.ending { return ending }
                    state.waiting = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }
}

import Foundation
import Synchronization
import YabCore
import YabExtensionKit
import YabPasteboard

/// The library's categories as capture rules reach them: by name, never made by an extension.
@MainActor
public protocol CategoryResolving: AnyObject {
    /// The existing category with this name, whatever its case and Turkish letters; nil when there is none.
    func categoryID(named name: String) -> Int64?
    func add(itemID: Int64, to categoryID: Int64)
}

/// `CategoryResolving` on the library: names match as category names do (`SearchNormalizer`, trimmed).
@MainActor
public final class LibraryCategories: CategoryResolving {
    private let library: Library

    public init(library: Library) {
        self.library = library
    }

    public func categoryID(named name: String) -> Int64? {
        let folded = SearchNormalizer.normalize(name.trimmingCharacters(in: .whitespacesAndNewlines))
        return ((try? library.store.categories()) ?? []).first { SearchNormalizer.normalize($0.name) == folded }?.id
    }

    public func add(itemID: Int64, to categoryID: Int64) {
        try? library.add(itemID, toCategory: categoryID)
    }
}

/// Between the pasteboard monitor and history: each new copy goes past the capture rules,
/// then on to history as they decided.
///
/// - Copies go through one at a time, in the order they came: a copy's rules start once the copy before it is
///   through. With no rule that could run and nothing waiting, a copy goes straight on, in the same turn.
/// - `replace` saves the copy as plain text or a link (rich formats drop; the source app and device stay). The
///   clipboard gets that clean copy too, only while it still holds the copy the rules saw and the Sıra is closed
///   (the Sıra keeps its head there); the monitor lets that write pass.
/// - `ignore`: the copy never reaches history, and the clipboard is left as it is.
/// - `addToCategory`: once history has the item, it goes into each named category that exists. Unknown names are
///   skipped, and the Development log says so without the name (a rule may have made it from the copy).
/// - The rules keep their own time, rule by rule; the pipeline still never waits on them past their budget and some
///   grace (at most `backstop`). Past that the copy is saved as it is, the clipboard is left alone, the rules' call
///   is cancelled and whatever it decides later is dropped: a runner that stops answering costs a copy its rules,
///   never history capture.
///
/// Nothing a copy holds is ever logged.
@MainActor
public final class CapturePipeline {
    /// Hears the stored item's id once history has the clip; nil when it kept nothing.
    public typealias Saved = IngestQueue.Saved
    /// How far past the rules' own budget a copy waits for them: the turns between rules, the hops back.
    static let grace: Duration = .milliseconds(500)

    private let rules: CaptureRuling
    private let ingest: (CapturedClip, Saved?) -> Void
    private let pasteboard: CleanWriting
    private let stack: () -> Bool
    private let categories: CategoryResolving
    private let log: (String) -> Void
    private let backstop: Duration
    /// Copies waiting for the rules, oldest first, with the change count each was read at.
    private var waiting: [(clip: CapturedClip, changeCount: Int)] = []
    /// Works through `waiting`; nil when nothing is with the rules.
    private var worker: Task<Void, Never>?

    /// `ingest` hands a clip to history (in order), and calls its `Saved` (when given) once the item is stored.
    /// `stack`: whether the Sıra is open. `log` writes a line to the Development log. `backstop`: the longest a copy
    /// waits for the rules, whatever their budget.
    public init(rules: CaptureRuling, ingest: @escaping (CapturedClip, Saved?) -> Void, pasteboard: CleanWriting,
                stack: @escaping () -> Bool, categories: CategoryResolving, log: @escaping (String) -> Void = { _ in },
                backstop: Duration = .seconds(3)) {
        self.rules = rules
        self.ingest = ingest
        self.pasteboard = pasteboard
        self.stack = stack
        self.categories = categories
        self.log = log
        self.backstop = backstop
    }

    /// A new copy, read when the pasteboard's change count was `changeCount`.
    public func submit(_ clip: CapturedClip, changeCount: Int) {
        guard worker != nil || rules.hasRules else {
            ingest(clip, nil)
            return
        }
        waiting.append((clip, changeCount))
        guard worker == nil else { return }
        worker = Task {
            while !waiting.isEmpty {
                let next = waiting.removeFirst()
                await process(next.clip, changeCount: next.changeCount)
            }
            worker = nil
        }
    }

    private func process(_ clip: CapturedClip, changeCount: Int) async {
        // Classifying reads the whole copy (an RTF is parsed): off the main actor.
        guard let item = await Task.detached(priority: .userInitiated, operation: { Self.item(from: clip) }).value else {
            // Nothing history would keep: it decides that on its own.
            ingest(clip, nil)
            return
        }
        guard let decision = await decide(item) else {
            log("capture rules: gave up on a copy")
            ingest(clip, nil)
            return
        }
        guard !decision.ignore else { return }
        var saved = clip
        if let replacement = decision.replacement {
            saved.items = Self.representations(of: replacement, replacing: clip.items)
            if !stack() { _ = pasteboard.writeIfUnchanged(saved.items, expected: changeCount) }
        }
        let names = decision.categories
        guard !names.isEmpty else {
            ingest(saved, nil)
            return
        }
        ingest(saved) { [weak self] itemID in
            guard let self, let itemID else { return }
            file(itemID, under: names)
        }
    }

    /// The rules' decision, or nil when they are not done within their budget and the grace (at most `backstop`).
    /// Either way their call ends here: it is cancelled, and an answer that comes after the deadline is dropped.
    private func decide(_ item: ExtensionItem) async -> CaptureRuleDecision? {
        let deadline = min(rules.budget + Self.grace, backstop)
        let first = FirstDecision()
        let call = Task { first.finish(await rules.run(on: item)) }
        let clock = Self.startClock(first, deadline)
        let decision = await first.decision
        call.cancel()
        clock.cancel()
        return decision
    }

    /// A plain timer, off the main actor and the task pool, so the deadline is kept however busy they are.
    /// Nonisolated: the timer's block runs on a global queue.
    nonisolated private static func startClock(_ first: FirstDecision, _ deadline: Duration) -> DispatchWorkItem {
        let clock = DispatchWorkItem { first.finish(nil) }
        let (seconds, attoseconds) = deadline.components
        let interval = DispatchTimeInterval.nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + interval, execute: clock)
        return clock
    }

    private func file(_ itemID: Int64, under names: [String]) {
        for name in names {
            guard let categoryID = categories.categoryID(named: name) else {
                log("capture rules: a category was not found")
                continue
            }
            categories.add(itemID: itemID, to: categoryID)
        }
    }

    /// A copy on its way to history, as the rules see it: not stored yet (id 0), no pixels, no tags yet.
    nonisolated static func item(from clip: CapturedClip) -> ExtensionItem? {
        guard let classification = ItemClassifier.classify(clip.items) else { return nil }
        var item = ExtensionService.extensionItem(
            id: 0, kind: classification.kind, clip.items,
            text: ItemClassifier.plainText(in: clip.items.first ?? []) ?? classification.searchText,
            preview: classification.previewText, copiedAt: clip.capturedAt, includeImage: false)
        item.source = .init(name: clip.source?.name, bundleID: clip.source?.bundleID, device: clip.device.rawValue)
        return item
    }

    /// What a replaced copy is saved and written as: one pasteboard item, the clean text alone, or the clean link as a
    /// link result is (URL and plain text). A link keeps the original's title, unless that title was only its address.
    static func representations(of replacement: Replacement,
                                replacing original: [[PasteboardRepresentation]]) -> [[PasteboardRepresentation]] {
        switch replacement {
        case .text(let text):
            return ResultRepresentations.make(.text(text))
        case .url(let url):
            let first = original.first ?? []
            func string(_ type: String) -> String? {
                first.first { $0.type == type }
                    .map { String(decoding: $0.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            let address = string(TypeIdentifiers.url) ?? string(TypeIdentifiers.plainText)
            let title = string(TypeIdentifiers.urlName).flatMap { $0.isEmpty || $0 == address ? nil : $0 }
            return ResultRepresentations.make(.link(url: url, title: title))
        }
    }
}

/// Whichever ends first for one copy: the rules' decision, or the deadline (nil). Finished from any thread; only the
/// first ending counts.
private final class FirstDecision: Sendable {
    private struct State {
        var finished = false
        var decision: CaptureRuleDecision?
        var waiting: CheckedContinuation<CaptureRuleDecision?, Never>?
    }

    private let state = Mutex(State())

    func finish(_ decision: CaptureRuleDecision?) {
        let waiting = state.withLock { state -> CheckedContinuation<CaptureRuleDecision?, Never>? in
            guard !state.finished else { return nil }
            state.finished = true
            state.decision = decision
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume(returning: decision)
    }

    var decision: CaptureRuleDecision? {
        get async {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> CaptureRuleDecision?? in
                    if state.finished { return .some(state.decision) }
                    state.waiting = continuation
                    return .none
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }
}

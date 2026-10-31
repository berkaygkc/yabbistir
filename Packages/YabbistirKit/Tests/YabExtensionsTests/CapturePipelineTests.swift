import Foundation
import Testing
import YabCore
import YabExtensionKit
import YabPasteboard
@testable import YabExtensions

/// Rules the test decides: `decide` answers each copy.
@MainActor final class FakeRules: CaptureRuling {
    var hasRules = true
    /// Generous, so the pipeline's deadline (budget plus its grace, capped by the backstop) does not lose to a main
    /// actor that other suites keep busy. Tests about timing set a short `backstop` on the fixture instead.
    var budget: Duration = .seconds(2)
    var decide: @MainActor (ExtensionItem) async -> CaptureRuleDecision
    private(set) var seen: [ExtensionItem] = []

    init(_ decide: @escaping @MainActor (ExtensionItem) async -> CaptureRuleDecision = { _ in CaptureRuleDecision() }) {
        self.decide = decide
    }

    func run(on item: ExtensionItem) async -> CaptureRuleDecision {
        seen.append(item)
        return await decide(item)
    }
}

/// The clipboard as the pipeline sees it: a copy bumps the change count, and a clean write lands only over the
/// copy it came from, then tells the monitor to let it pass, as the app's writer does.
@MainActor final class FakeBoard: CleanWriting {
    private(set) var changeCount = 41
    private(set) var items: [[PasteboardRepresentation]] = []
    private(set) var writes: [[[PasteboardRepresentation]]] = []
    /// What the monitor was told to let pass.
    private(set) var ignored: [Int] = []

    func copy(_ items: [[PasteboardRepresentation]]) {
        changeCount += 1
        self.items = items
    }

    func writeIfUnchanged(_ items: [[PasteboardRepresentation]], expected changeCount: Int) -> Bool {
        guard self.changeCount == changeCount else { return false }
        copy(items)
        writes.append(items)
        ignored.append(self.changeCount)
        return true
    }
}

/// The library's categories, by exact name.
@MainActor final class FakeCategories: CategoryResolving {
    var known: [String: Int64]
    private(set) var added: [(itemID: Int64, categoryID: Int64)] = []

    init(_ known: [String: Int64] = [:]) { self.known = known }

    func categoryID(named name: String) -> Int64? { known[name] }
    func add(itemID: Int64, to categoryID: Int64) { added.append((itemID, categoryID)) }
}

/// A pipeline between a fake clipboard and a fake history: what reached history, when, and under which id.
@MainActor final class PipelineFixture {
    let board = FakeBoard()
    let categories: FakeCategories
    var stackOpen = false
    private(set) var ingested: [CapturedClip] = []
    private(set) var ingestedAt: [ContinuousClock.Instant] = []
    private(set) var logs: [String] = []
    private(set) var pipeline: CapturePipeline!
    private var nextID: Int64 = 100

    init(rules: CaptureRuling, categories: FakeCategories = FakeCategories(), backstop: Duration = .seconds(3)) {
        self.categories = categories
        pipeline = CapturePipeline(rules: rules, ingest: { [weak self] clip, saved in
            guard let self else { return }
            ingested.append(clip)
            ingestedAt.append(.now)
            let id = nextID
            nextID += 1
            // History reports the stored item a moment later, on the main actor, as the ingest queue does.
            Task { saved?(id) }
        }, pasteboard: board, stack: { [weak self] in self?.stackOpen ?? false }, categories: categories,
           log: { [weak self] line in self?.logs.append(line) }, backstop: backstop)
    }

    /// A copy lands on the clipboard and the monitor hands it on with the change count it read.
    func copy(_ clip: CapturedClip) {
        board.copy(clip.items)
        pipeline.submit(clip, changeCount: board.changeCount)
    }

    /// The texts that reached history, in order.
    var texts: [String] {
        ingested.map { clip in clip.items.first?.first { $0.type == TypeIdentifiers.plainText }.map { String(decoding: $0.data, as: UTF8.self) } ?? "" }
    }
}

@MainActor @Suite struct CapturePipelineTests {
    static let safari = SourceApp(bundleID: "com.apple.Safari", name: "Safari")
    static let copiedAt = Date(timeIntervalSinceReferenceDate: 815_000_000)
    static let dirty = "https://a.dev/x?utm_source=news"
    static let clean = "https://a.dev/x"

    static func rep(_ type: String, _ text: String) -> PasteboardRepresentation { PasteboardRepresentation(type: type, data: Data(text.utf8)) }

    static func clip(_ items: [[PasteboardRepresentation]], device: DeviceKind = .local) -> CapturedClip {
        CapturedClip(items: items, source: device == .local ? safari : nil, device: device, capturedAt: copiedAt)
    }

    static func text(_ text: String) -> CapturedClip { clip([[rep(TypeIdentifiers.plainText, text)]]) }

    /// A link as Safari's Copy Link puts it on the clipboard.
    static func link(_ url: String, title: String? = nil) -> CapturedClip {
        clip([[rep(TypeIdentifiers.url, url), rep(TypeIdentifiers.plainText, url)] + (title.map { [rep(TypeIdentifiers.urlName, $0)] } ?? [])])
    }

    // MARK: A rule never delays or loses a copy

    @Test func aHangingRuleDoesNotHoldTheCopy() async throws {
        let harness = try await RuleHarness([RuleHarness.Extension(id: "dev.example.hang", name: "Hang", rules: [RuleHarness.rule("hang")],
                                                                   js: #"exports.captureRules = { hang: { run: () => new Promise(() => {}) } };"#)],
                                            timeout: nil)
        let fixture = PipelineFixture(rules: harness.runner)
        await RuleHarness.mainActorKeepsUp()
        let start = ContinuousClock.now
        fixture.copy(Self.text("a"))
        try await eventually { fixture.ingested.count == 1 }
        // The rule ran and was cut off at its 200 ms: the copy went on as it was. The wall-clock bound only tells that
        // apart from a copy held until the pipeline's 3 s backstop; it is loose because a busy main actor delays it.
        #expect(harness.ruleCalls == ["hang"])
        #expect(try #require(fixture.ingestedAt.first) - start < .milliseconds(2500))
        #expect(fixture.ingested.first?.items == Self.text("a").items)
        #expect(fixture.board.writes.isEmpty)
    }

    @Test func aThrowingRuleKeepsTheCopy() async throws {
        let harness = try await RuleHarness([RuleHarness.Extension(id: "dev.example.boom", name: "Boom", rules: [RuleHarness.rule("boom")],
                                                                   js: #"exports.captureRules = { boom: { run: () => { throw new Error("boom"); } } };"#)])
        let fixture = PipelineFixture(rules: harness.runner)
        fixture.copy(Self.link(Self.dirty))
        try await eventually { fixture.ingested.count == 1 }
        #expect(harness.ruleCalls == ["boom"])
        #expect(fixture.ingested.first?.items == Self.link(Self.dirty).items)
        #expect(fixture.ingested.first?.source == Self.safari)
        #expect(fixture.board.writes.isEmpty)
        try await eventually { harness.logs.lines.contains { $0.hasPrefix("dev.example.boom: rule boom failed") } }
    }

    @Test func quickCopiesKeepTheirOrder() async throws {
        let rules = FakeRules { item in
            if item.text == "1" { try? await Task.sleep(for: .milliseconds(150)) }
            return CaptureRuleDecision()
        }
        let fixture = PipelineFixture(rules: rules)
        fixture.copy(Self.text("1"))
        fixture.copy(Self.text("2"))
        fixture.copy(Self.text("3"))
        try await eventually { fixture.ingested.count == 3 }
        #expect(fixture.texts == ["1", "2", "3"])
        // One at a time: the next copy's rules start only once the one before is through.
        #expect(rules.seen.map(\.text) == ["1", "2", "3"])
    }

    /// No rule could run: the copy reaches history in the same turn, with nothing to wait for.
    @Test func withoutRulesACopyGoesStraightThrough() {
        let rules = FakeRules()
        rules.hasRules = false
        let fixture = PipelineFixture(rules: rules)
        fixture.copy(Self.text("a"))
        #expect(fixture.texts == ["a"])
        #expect(rules.seen.isEmpty)
    }

    /// The rules went away (switched off) while an earlier copy was with them: the next copy still waits its turn.
    @Test func aCopyWithoutRulesWaitsForTheOnesBefore() async throws {
        let rules = FakeRules { _ in
            try? await Task.sleep(for: .milliseconds(100))
            return CaptureRuleDecision()
        }
        let fixture = PipelineFixture(rules: rules)
        fixture.copy(Self.text("1"))
        rules.hasRules = false
        fixture.copy(Self.text("2"))
        #expect(fixture.ingested.isEmpty)
        try await eventually { fixture.ingested.count == 2 }
        #expect(fixture.texts == ["1", "2"])
    }

    // MARK: Replace

    @Test func aCleanLinkIsSavedAndWritten() async throws {
        let rules = FakeRules { _ in CaptureRuleDecision(replacement: .url(Self.clean)) }
        let fixture = PipelineFixture(rules: rules)
        fixture.copy(Self.link(Self.dirty))
        let copied = fixture.board.changeCount
        try await eventually { fixture.ingested.count == 1 }
        // The rules saw the copy as an extension item that is not stored yet.
        let seen = try #require(rules.seen.first)
        #expect(seen.id == 0 && seen.kind == "link" && seen.url == Self.dirty && seen.text == Self.dirty)
        #expect(seen.source == ExtensionItem.SourcePayload(name: "Safari", bundleID: "com.apple.Safari", device: "local"))
        #expect(seen.copiedAt == Self.copiedAt)
        // Saved as the clean link, from the same app and device.
        let cleanItems = [[Self.rep(TypeIdentifiers.url, Self.clean), Self.rep(TypeIdentifiers.plainText, Self.clean)]]
        let saved = try #require(fixture.ingested.first)
        #expect(saved.items == cleanItems)
        #expect(saved.source == Self.safari && saved.device == .local && saved.capturedAt == Self.copiedAt)
        // Written over the copy it came from, and the monitor lets that write pass.
        #expect(fixture.board.writes == [cleanItems])
        #expect(fixture.board.ignored == [copied + 1])
    }

    /// A link keeps its title; a title that was only the old address goes with it.
    @Test func aCleanLinkKeepsItsTitle() async throws {
        let fixture = PipelineFixture(rules: FakeRules { _ in CaptureRuleDecision(replacement: .url(Self.clean)) })
        fixture.copy(Self.link(Self.dirty, title: "A page"))
        fixture.copy(Self.link(Self.dirty + "&b=1", title: Self.dirty + "&b=1"))
        try await eventually { fixture.ingested.count == 2 }
        let link = [Self.rep(TypeIdentifiers.url, Self.clean), Self.rep(TypeIdentifiers.plainText, Self.clean)]
        #expect(fixture.ingested.map(\.items) == [[link + [Self.rep(TypeIdentifiers.urlName, "A page")]], [link]])
    }

    /// Rich text goes: a cleaned text is saved and written as plain text alone.
    @Test func aCleanTextIsPlainText() async throws {
        let fixture = PipelineFixture(rules: FakeRules { _ in CaptureRuleDecision(replacement: .text("clean")) })
        fixture.copy(Self.clip([[Self.rep(ResultRepresentations.html, "<b>dirty</b>"), Self.rep(TypeIdentifiers.plainText, "dirty"),
                                 Self.rep(TypeIdentifiers.rtf, "{\\rtf1 dirty}")]]))
        try await eventually { fixture.ingested.count == 1 }
        #expect(fixture.ingested.first?.items == [[Self.rep(TypeIdentifiers.plainText, "clean")]])
        #expect(fixture.board.writes == [[[Self.rep(TypeIdentifiers.plainText, "clean")]]])
    }

    // MARK: The clipboard is written only over the same copy

    @Test func aNewerCopyIsNeverOverwritten() async throws {
        let newer = [[Self.rep(TypeIdentifiers.plainText, "newer")]]
        var fixture: PipelineFixture!
        fixture = PipelineFixture(rules: FakeRules { _ in
            // Another copy lands while the rule runs.
            fixture.board.copy(newer)
            return CaptureRuleDecision(replacement: .url(Self.clean))
        })
        fixture.copy(Self.link(Self.dirty))
        try await eventually { fixture.ingested.count == 1 }
        #expect(fixture.board.items == newer)
        #expect(fixture.board.writes.isEmpty && fixture.board.ignored.isEmpty)
        // History still gets the clean link.
        #expect(fixture.ingested.first?.items == [[Self.rep(TypeIdentifiers.url, Self.clean), Self.rep(TypeIdentifiers.plainText, Self.clean)]])
    }

    @Test func withTheStackOpenThePasteboardIsLeftAlone() async throws {
        let fixture = PipelineFixture(rules: FakeRules { _ in CaptureRuleDecision(replacement: .url(Self.clean)) })
        fixture.stackOpen = true
        fixture.copy(Self.link(Self.dirty))
        try await eventually { fixture.ingested.count == 1 }
        // The Sıra keeps its head on the clipboard; only the history item is clean.
        #expect(fixture.board.items == Self.link(Self.dirty).items)
        #expect(fixture.board.writes.isEmpty && fixture.board.ignored.isEmpty)
        #expect(fixture.ingested.first?.items == [[Self.rep(TypeIdentifiers.url, Self.clean), Self.rep(TypeIdentifiers.plainText, Self.clean)]])
    }

    // MARK: Ignore and categories

    @Test func ignoredCopiesNeverReachHistory() async throws {
        let rules = FakeRules { item in
            CaptureRuleDecision(replacement: .text("clean " + (item.text ?? "")), categories: ["İş"], ignore: item.text == "secret")
        }
        let fixture = PipelineFixture(rules: rules, categories: FakeCategories(["İş": 7]))
        fixture.copy(Self.text("secret"))
        fixture.copy(Self.text("after"))
        // Copies go through in order: once the second is saved, the first is done with.
        try await eventually { fixture.texts.contains("clean after") }
        #expect(rules.seen.map(\.text) == ["secret", "after"])
        // Only the second copy was saved, written and filed; nothing of the ignored one.
        #expect(fixture.texts == ["clean after"])
        #expect(fixture.board.writes == [[[Self.rep(TypeIdentifiers.plainText, "clean after")]]])
        try await eventually { fixture.categories.added.count == 1 }
        #expect(fixture.categories.added.map(\.itemID) == [100])
    }

    /// The pipeline's own backstop: rules that never answer (a broken deadline in the runner) cost one copy a short
    /// wait, never history capture. A decision that comes after it is dropped.
    @Test func aRunnerThatNeverAnswersDoesNotStopCapture() async throws {
        let rules = FakeRules { item in
            guard item.text == "late" else { return await withUnsafeContinuation { _ in } }
            // Answers after the backstop, whatever happened to its call.
            await Task.detached { try? await Task.sleep(for: .milliseconds(300)) }.value
            return CaptureRuleDecision(replacement: .text("late answer"), categories: ["İş"])
        }
        let fixture = PipelineFixture(rules: rules, categories: FakeCategories(["İş": 7]), backstop: .milliseconds(100))
        await RuleHarness.mainActorKeepsUp()
        let start = ContinuousClock.now
        fixture.copy(Self.text("never"))
        fixture.copy(Self.text("late"))
        try await eventually { fixture.ingested.count == 2 }
        // Each saved as it was, within the backstop (the bound is loose: a busy main actor delays it); the clipboard left alone.
        #expect(try #require(fixture.ingestedAt.first) - start < .milliseconds(2000))
        #expect(fixture.ingested.map(\.items) == [Self.text("never").items, Self.text("late").items])
        #expect(fixture.logs == ["capture rules: gave up on a copy", "capture rules: gave up on a copy"])
        // The late decision changes nothing.
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.ingested.count == 2)
        #expect(fixture.board.writes.isEmpty && fixture.categories.added.isEmpty)
        // And copies go on as before. With the app's backstop again: the answer needs a turn on the main actor, which
        // other suites can hold for longer than the short one above.
        fixture.pipeline.backstop = .seconds(3)
        rules.decide = { _ in CaptureRuleDecision(replacement: .text("clean")) }
        fixture.copy(Self.text("after"))
        try await eventually { fixture.ingested.count == 3 }
        #expect(fixture.texts.last == "clean")
    }

    @Test func anUnknownCategoryIsSkipped() async throws {
        let fixture = PipelineFixture(rules: FakeRules { _ in CaptureRuleDecision(categories: ["Yok", "İş"]) },
                                      categories: FakeCategories(["İş": 7]))
        fixture.copy(Self.text("a"))
        try await eventually { fixture.categories.added.count == 1 }
        // Saved, and put only in the category that exists, once it has its id.
        #expect(fixture.texts == ["a"])
        #expect(fixture.categories.added.map(\.itemID) == [100])
        #expect(fixture.categories.added.map(\.categoryID) == [7])
        // The Development log says so without the name a rule may have made from the copy.
        #expect(fixture.logs == ["capture rules: a category was not found"])
    }

    /// Category names match whatever their case and Turkish letters; extensions never make categories.
    @Test func aCategoryIsFoundWhateverItsCase() throws {
        let library = try Library(store: ItemStore.temporary())
        let work = try library.createCategory(name: "İş")
        let item = try #require(try library.store.ingest(Self.text("a"))?.item.id)
        let categories = LibraryCategories(library: library)
        #expect(categories.categoryID(named: "iş") == work.id)
        #expect(categories.categoryID(named: " IŞ ") == work.id)
        #expect(categories.categoryID(named: "Yok") == nil)
        categories.add(itemID: item, to: try #require(work.id))
        #expect(library.itemIDs(inCategory: try #require(work.id)) == [item])
        #expect(try library.store.categories().count == 1)
    }
}

import Foundation
import Testing
import YabCore
import YabExtensionKit
import YabLocalization
@testable import YabExtensions

/// Extensions with capture rules, in a real host over a pipe, behind the service and the rule runner.
/// They are written, and approved, before the registry first looks, and as built-ins: the registry does
/// not watch that folder. The extensions folder it does watch is one empty folder that has long settled.
///
/// Rules get `timeout` each (the app's 200 ms when nil) and are loaded first, as at launch, unless
/// `preload` is false: a test about what a rule does must not depend on how busy the machine is.
@MainActor final class RuleHarness {
    struct Extension {
        var id: String
        var name: String
        var rules: [[String: Any]]
        var js: String
        var permissions = ["capture"]
        var domains: [String]?
    }

    final class LogBox {
        var lines: [String] = []
    }

    let settings = ExtensionSettings(defaults: UserDefaults(suiteName: "yab-rules-\(UUID().uuidString)")!)
    let transport = RecordingTransport()
    let logs = LogBox()
    let registry: ExtensionRegistry
    let service: ExtensionService
    let runner: CaptureRuleRunner
    /// Where the extensions are, by id as folder name.
    let root = RegistryFixture.temporary("BuiltinExtensions")

    /// `host`: another transport than the recording pipe (`transport` then stays unused). `built`: extensions as
    /// `make extensions` builds them, copied in beside `extensions` and approved for what their manifests ask.
    init(_ extensions: [Extension], built: [URL] = [], timeout: Duration? = .seconds(2), preload: Bool = true,
         host: (any HostTransport)? = nil) async throws {
        for spec in extensions {
            try Self.write(spec, in: root)
            // Consent covers what the manifest asks for, as the person's approval would.
            settings.setGrant(spec.id, PermissionGrant(permissions: spec.permissions, domains: spec.domains ?? [], tools: []))
        }
        for folder in built {
            try FileManager.default.copyItem(at: folder, to: root.appendingPathComponent(folder.lastPathComponent))
            guard case .valid(let manifest, _) = ManifestValidator.validate(folder: folder) else { throw ExtensionError(.notFound, folder.path) }
            settings.setGrant(manifest.id, PermissionGrant.requested(by: manifest))
        }
        registry = ExtensionRegistry(builtInRoot: root, userRoot: await Self.quietUserRoot(),
                                     dataRoot: RegistryFixture.temporary("ExtensionData"), settings: settings)
        let logs = logs
        let client = ExtensionHostClient(transport: host ?? transport) { _, line in logs.lines.append(line) }
        let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-rules-lang-\(UUID().uuidString)")!)
        service = ExtensionService(registry: registry, client: client, library: try Library(store: ItemStore.temporary()),
                                   settings: settings, language: language)
        runner = if let timeout {
            CaptureRuleRunner(service: service, registry: registry, settings: settings, timeout: timeout)
        } else {
            CaptureRuleRunner(service: service, registry: registry, settings: settings)
        }
        #expect(registry.installed.map(\.isUsable) == Array(repeating: true, count: extensions.count + built.count))
        if preload { await service.preloadCaptureRules().value }
    }

    static func rule(_ id: String, kinds: [String] = ["text", "link"]) -> [String: Any] {
        ["id": id, "title": "rule", "description": "rule.description", "accepts": ["kinds": kinds]]
    }

    private static var userRoot: Task<URL, Never>?

    /// One empty extensions folder for every harness, made once and left alone: a folder made just before a registry
    /// starts watching it can still announce its own creation a moment later, which reloads the registry.
    static func quietUserRoot() async -> URL {
        if userRoot == nil {
            userRoot = Task {
                let url = RegistryFixture.temporary("QuietExtensions")
                try? await Task.sleep(for: .milliseconds(600))
                return url
            }
        }
        return await userRoot!.value
    }

    private static func write(_ spec: Extension, in root: URL) throws {
        let folder = root.appendingPathComponent(spec.id)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("locales"), withIntermediateDirectories: true)
        var manifest: [String: Any] = [
            "id": spec.id, "version": "1.0.0", "apiVersion": 1, "defaultLocale": "en", "name": "name", "description": "name",
            "icon": "sf:wand.and.stars", "author": "berkaygkc", "license": "MIT", "permissions": spec.permissions,
            "contributes": ["captureRules": spec.rules],
        ]
        if let domains = spec.domains { manifest["network"] = ["domains": domains] }
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: ["name": spec.name, "rule": "Rule", "rule.description": "What the rule does"])
            .write(to: folder.appendingPathComponent("locales/en.json"))
        try spec.js.write(to: folder.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
    }

    /// The rule calls sent to the host, by rule id, in order.
    var ruleCalls: [String] { transport.requests.compactMap(\.invoke).filter { $0.kind == .captureRule }.map(\.name) }

    func run(_ item: ExtensionItem) async -> CaptureRuleDecision { await runner.run(on: item) }

    /// How long a copy that a rule must not hold may take, as these tests check it: well short of the copy path's 3 s
    /// backstop, which would cut it otherwise. A rule's own limit is 200 ms, but the copy comes back through the main
    /// actor, which every suite shares: even once the start-up rush is over it can be most of a second behind. (That
    /// a rule was cut at its own limit shows in how its call ended, not in this.)
    static let promptly: Duration = .seconds(2)

    /// Returns once the main actor keeps up (a turn on it takes under 10 ms, three times running), or after
    /// 3 s. Every suite starts at once and queues its setup there; a copy timed in that rush would measure
    /// the rush, not the rule.
    static func mainActorKeepsUp() async {
        var quick = 0
        let start = ContinuousClock.now
        while quick < 3, ContinuousClock.now - start < .seconds(3) {
            let turn = ContinuousClock.now
            await Task.yield()
            quick = ContinuousClock.now - turn < .milliseconds(10) ? quick + 1 : 0
            if quick == 0 { try? await Task.sleep(for: .milliseconds(20)) }
        }
    }
}

extension ExtensionItem {
    static func text(_ text: String) -> ExtensionItem { ExtensionItem(id: 0, kind: "text", text: text, copiedAt: Date()) }
    static func link(_ url: String) -> ExtensionItem { ExtensionItem(id: 0, kind: "link", text: url, url: url, copiedAt: Date()) }
}

/// A host that dies whenever it is asked to load something. Each launch (the first and every restart) is counted.
final class DyingTransport: HostTransport, @unchecked Sendable {
    private let lock = NSLock()
    /// Touched only under `lock`.
    private var onExit: (@Sendable () -> Void)?
    private var count = 0

    var launches: Int { lock.withLock { count } }

    func start(onLine: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable () -> Void) throws {
        lock.withLock { (self.onExit, count) = (onExit, count + 1) }
    }

    func send(_ line: Data) {
        guard let request = try? JSONDecoder().decode(HostRequest.self, from: line), request.load != nil else { return }
        let onExit = lock.withLock { self.onExit }
        DispatchQueue.global().async { onExit?() }
    }

    func restart() throws { lock.withLock { count += 1 } }
    func stop() {}
}

@MainActor @Suite struct CaptureRuleTests {
    typealias Spec = RuleHarness.Extension
    static func rule(_ id: String, kinds: [String] = ["text", "link"]) -> [String: Any] { RuleHarness.rule(id, kinds: kinds) }

    /// A 1×1 PNG.
    static let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    @Test func aRuleCleansALink() async throws {
        let harness = try await RuleHarness([Spec(id: "dev.example.clean", name: "Clean", rules: [Self.rule("clean", kinds: ["link"])], js: #"""
        exports.captureRules = { clean: { run(item, ctx) {
          return ctx.trigger === "capture" ? { replace: { url: item.url.split("?")[0] } } : { keep: true };
        } } };
        """#)])
        #expect(await harness.run(.link("https://a.dev/x?utm_source=news")) == CaptureRuleDecision(replacement: .url("https://a.dev/x")))
        // A rule call: its own kind, nothing that reaches out, the capture trigger.
        let call = try #require(harness.transport.requests.compactMap(\.invoke).first { $0.kind == .captureRule })
        #expect(call.name == "clean" && call.extensionID == "dev.example.clean")
        #expect(call.effects == false && call.context.trigger == .capture)
        // A link rule leaves text alone.
        #expect(await harness.run(.text("merhaba")) == CaptureRuleDecision())
        #expect(harness.ruleCalls == ["clean"])
    }

    @Test func rulesRunInOrderAndSeeEachOther() async throws {
        let harness = try await RuleHarness([
            Spec(id: "dev.example.first", name: "Alpha", rules: [Self.rule("first")],
                 js: #"exports.captureRules = { first: { run: (item) => item.text === "a" ? { replace: { text: "b" } } : { keep: true } } };"#),
            Spec(id: "dev.example.second", name: "Beta", rules: [Self.rule("second"), Self.rule("third")], js: #"""
            exports.captureRules = {
              second: { run: (item) => ({ replace: { text: item.text === "b" && item.kind === "text" ? "c" : "wrong" } }) },
              third: { run: (item) => item.text === "c" ? { replace: { url: "https://c.dev/" } } : { ignore: true } },
            };
            """#),
        ])
        #expect(harness.registry.installed.map(\.id) == ["dev.example.first", "dev.example.second"])
        // Within an extension, manifest order; a replaced text can become a link.
        #expect(await harness.run(.text("a")) == CaptureRuleDecision(replacement: .url("https://c.dev/")))
        #expect(harness.ruleCalls == ["first", "second", "third"])
    }

    @Test func ignoreStopsTheChain() async throws {
        let harness = try await RuleHarness([
            Spec(id: "dev.example.a", name: "Alpha", rules: [Self.rule("file")], js: #"exports.captureRules = { file: { run: () => ({ addToCategory: "Work" }) } };"#),
            Spec(id: "dev.example.b", name: "Beta", rules: [Self.rule("drop")], js: #"exports.captureRules = { drop: { run: () => ({ ignore: true }) } };"#),
            Spec(id: "dev.example.c", name: "Gamma", rules: [Self.rule("late")],
                 js: #"exports.captureRules = { late: { run: () => ({ replace: { text: "late" } }) } };"#),
        ])
        // What came before goes too: the copy is not saved.
        #expect(await harness.run(.text("a")) == CaptureRuleDecision(ignore: true))
        #expect(harness.ruleCalls == ["file", "drop"])
    }

    @Test func categoriesGatherInOrderWithoutRepeats() async throws {
        let harness = try await RuleHarness([
            Spec(id: "dev.example.a", name: "Alpha", rules: [Self.rule("work"), Self.rule("nothing")], js: #"""
            exports.captureRules = { work: { run: () => ({ addToCategory: "İş" }) }, nothing: { run: () => undefined } };
            """#),
            Spec(id: "dev.example.b", name: "Beta", rules: [Self.rule("again"), Self.rule("home")], js: #"""
            exports.captureRules = { again: { run: () => ({ addToCategory: "iş" }) }, home: { run: () => ({ addToCategory: "Ev" }) } };
            """#),
        ])
        #expect(await harness.run(.text("a")) == CaptureRuleDecision(categories: ["İş", "Ev"]))
    }

    @Test func aSlowRuleIsSkipped() async throws {
        let harness = try await RuleHarness([Spec(id: "dev.example.slow", name: "Slow", rules: [Self.rule("slow")], js: #"""
        exports.captureRules = { slow: { run: () => new Promise((resolve) => setTimeout(() => resolve({ replace: { text: "late" } }), 5000)) } };
        """#)], timeout: nil)
        await RuleHarness.mainActorKeepsUp()
        let start = ContinuousClock.now
        #expect(await harness.run(.text("a")) == CaptureRuleDecision())
        // Back long before its answer was due.
        #expect(ContinuousClock.now - start < RuleHarness.promptly)
        // Cut at its time: the Development log names the rule and the code, nothing it saw.
        try await eventually { harness.logs.lines.contains("dev.example.slow: rule slow failed (timeout)") }
    }

    /// The rule: a rule that hangs once loaded runs out the host client's own clock, which restarts
    /// the host and counts; three in a row turn its extension off.
    @Test func aRuleThatKeepsHangingTurnsItsExtensionOff() async throws {
        let harness = try await RuleHarness([Spec(id: "dev.example.hang", name: "Hang", rules: [Self.rule("hang")],
                                            js: #"exports.captureRules = { hang: { run: () => new Promise(() => {}) } };"#)], timeout: nil)
        await RuleHarness.mainActorKeepsUp()
        var copies = 0
        while harness.settings.isEnabled("dev.example.hang"), copies < 10 {
            let start = ContinuousClock.now
            #expect(await harness.run(.text("a")) == CaptureRuleDecision())
            #expect(ContinuousClock.now - start < RuleHarness.promptly)
            copies += 1
            // The host restarted: its extensions load again, and the next copy finds this one in.
            await harness.service.preloadCaptureRules().value
        }
        #expect(!harness.settings.isEnabled("dev.example.hang"))
        #expect(copies == ExtensionHostClient.failureLimit)
        // Off: its rules no longer run.
        let calls = harness.ruleCalls.count
        #expect(await harness.run(.text("a")) == CaptureRuleDecision())
        #expect(harness.ruleCalls.count == calls)
    }

    @Test func aSlowFirstLoadSkipsTheRuleButNotTheCopy() async throws {
        // Longer than a copy may take (`promptly`), so the copy below is timed against a load still running.
        let harness = try await RuleHarness([Spec(id: "dev.example.heavy", name: "Heavy", rules: [Self.rule("clean")], js: #"""
        const end = Date.now() + 3000;
        while (Date.now() < end) {}
        exports.captureRules = { clean: { run: () => ({ replace: { text: "clean" } }) } };
        """#)], timeout: nil, preload: false)
        var changes = 0
        harness.service.onExtensionsChanged = { changes += 1 }
        await RuleHarness.mainActorKeepsUp()
        // A registry change (an install, a switch, an edit) starts loading its rules at once.
        harness.registry.reload()
        try await eventually { harness.transport.requests.contains { $0.load?.extensionID == "dev.example.heavy" } }
        // A copy does not wait for that load: it is back well before the load's 3 s are up.
        let start = ContinuousClock.now
        #expect(await harness.run(.text("a")) == CaptureRuleDecision())
        #expect(ContinuousClock.now - start < RuleHarness.promptly)
        // The load went on: once it is in, the rule applies. (A late folder event for the new, empty extensions
        // folder can change the registry once more, which starts the load over.)
        var decision = CaptureRuleDecision()
        for _ in 0..<3 where decision.replacement == nil {
            await harness.service.preloadCaptureRules().value
            decision = await harness.run(.text("a"))
        }
        #expect(decision == CaptureRuleDecision(replacement: .text("clean")))
        // One load per registry change: the copies sent none of their own, and waiting is nobody's failure.
        #expect(harness.transport.requests.filter { $0.load?.extensionID == "dev.example.heavy" }.count == changes)
        #expect(!harness.service.client.isDisabled("dev.example.heavy"))
    }

    @Test func aDisabledRuleDoesNotRun() async throws {
        let harness = try await RuleHarness([Spec(id: "dev.example.two", name: "Two", rules: [Self.rule("off"), Self.rule("on")], js: #"""
        exports.captureRules = { off: { run: () => ({ replace: { text: "x" } }) }, on: { run: () => ({ addToCategory: "Work" }) } };
        """#)])
        #expect(harness.settings.isRuleEnabled("dev.example.two", "off"))
        harness.settings.setRuleEnabled("dev.example.two", "off", false)
        #expect(await harness.run(.text("a")) == CaptureRuleDecision(categories: ["Work"]))
        #expect(harness.ruleCalls == ["on"])
        #expect(!harness.settings.isRuleEnabled("dev.example.two", "off") && harness.settings.isRuleEnabled("dev.example.two", "on"))
        // Removing the extension forgets its switches.
        harness.settings.remove("dev.example.two", specs: [])
        #expect(harness.settings.isRuleEnabled("dev.example.two", "off"))
    }

    @Test func rulesCannotReachTheNetwork() async throws {
        let harness = try await RuleHarness([Spec(id: "dev.example.net", name: "Net", rules: [Self.rule("phone")], js: #"""
        exports.captureRules = { phone: { async run(item) {
          await yab.http.fetch("https://a.dev/?q=" + encodeURIComponent(item.text));
          return { replace: { text: "sent" } };
        } } };
        """#, permissions: ["capture", "network"], domains: ["a.dev"])])
        #expect(await harness.run(.text("gizli-123")) == CaptureRuleDecision())
        try await eventually { harness.logs.lines.contains("dev.example.net: rule phone failed (permissionDenied)") }
        // Only the code: never what the rule saw or what it said.
        #expect(!harness.logs.lines.contains { $0.contains("gizli") || $0.contains("not available") })
        // Refused, not broken: nothing counts against it.
        #expect(!harness.service.client.isDisabled("dev.example.net"))
    }

    @Test func replaceIsOnlyForTextAndLinks() async throws {
        let harness = try await RuleHarness([Spec(id: "dev.example.any", name: "Any", rules: [Self.rule("rewrite", kinds: ["image", "file", "text"])],
                                            js: #"exports.captureRules = { rewrite: { run: () => ({ replace: { text: "x" } }) } };"#)])
        let image = ExtensionItem(id: 0, kind: "image", image: .init(data: Self.pixel, width: 1, height: 1), copiedAt: Date())
        #expect(await harness.run(image) == CaptureRuleDecision())
        let file = ExtensionItem(id: 0, kind: "file", files: [.init(path: "/tmp/a.txt", name: "a.txt", size: 1, uti: "public.plain-text")],
                                 copiedAt: Date())
        #expect(await harness.run(file) == CaptureRuleDecision())
        // It ran each time; only its answer was set aside.
        #expect(harness.ruleCalls == ["rewrite", "rewrite"])
        #expect(await harness.run(.text("a")) == CaptureRuleDecision(replacement: .text("x")))
    }

    /// A rule's pattern runs on the main actor in the copy's path: it sees the first 64 KB of the text, and the
    /// rule itself the whole copy.
    @Test func aPatternSeesOnlyTheFirst64KB() async throws {
        var rule = Self.rule("tail", kinds: ["text"])
        rule["accepts"] = ["kinds": ["text"], "pattern": "TAIL"]
        let harness = try await RuleHarness([Spec(id: "dev.example.tail", name: "Tail", rules: [rule],
                                                  js: #"exports.captureRules = { tail: { run: (item) => ({ replace: { text: String(item.text.length) } }) } };"#)])
        let filler = String(repeating: "ğ", count: CaptureRuleRunner.patternTextBytes)
        // Past the first 64 KB (two bytes a letter): the pattern never sees it, the rule never runs.
        #expect(await harness.run(.text(filler + "TAIL")) == CaptureRuleDecision())
        #expect(harness.ruleCalls.isEmpty)
        // Within them: the rule runs on all of it.
        #expect(await harness.run(.text("TAIL" + filler)) == CaptureRuleDecision(replacement: .text(String(4 + filler.count))))
        #expect(harness.ruleCalls == ["tail"])
    }

    /// A copy too big for speculative work (`ExtensionService.speculativeLimit`) goes past every rule
    /// untouched. No call is made, so nothing runs out of time on it and nothing counts against its extension.
    /// (Rules get the harness's 2 s: the ordinary copy at the end must not race a busy main actor for its answer.)
    @Test func aCopyTooBigForSpeculativeWorkSkipsEveryRule() async throws {
        let harness = try await RuleHarness([Spec(id: "dev.example.big", name: "Big", rules: [Self.rule("clean")], js: #"""
        exports.captureRules = { clean: { run: (item) => (item.text ?? "").length > 1000 ? new Promise(() => {}) : { replace: { text: "clean" } } } };
        """#)])
        let big = String(repeating: "a", count: ExtensionService.speculativeLimit + 1)
        for _ in 0..<ExtensionHostClient.failureLimit {
            #expect(await harness.run(.text(big)) == CaptureRuleDecision())
        }
        #expect(await harness.run(.link("https://a.dev/?q=" + big)) == CaptureRuleDecision())
        #expect(harness.ruleCalls.isEmpty)
        // Nothing counted against it: still on, and its rule still runs on an ordinary copy.
        #expect(harness.settings.isEnabled("dev.example.big") && !harness.service.client.isDisabled("dev.example.big"))
        #expect(await harness.run(.text("a")) == CaptureRuleDecision(replacement: .text("clean")))
        #expect(harness.ruleCalls == ["clean"])
    }

    /// A rule's manifest pattern ignores case when it says so: an upper-case address still reaches the rule.
    @Test func anAddressPatternIgnoresCase() async throws {
        let rule: [String: Any] = ["id": "clean", "title": "rule", "description": "rule.description",
                                   "accepts": ["kinds": ["text", "link"], "pattern": #"(?i)^\s*https?://\S+\s*$"#]]
        let harness = try await RuleHarness([Spec(id: "dev.example.clean", name: "Clean", rules: [rule],
                                                  js: #"exports.captureRules = { clean: { run: (item) => ({ replace: { text: item.text.split("?")[0] } }) } };"#)])
        #expect(await harness.run(.text("HTTPS://WWW.EXAMPLE.COM/watch?v=a&si=x"))
            == CaptureRuleDecision(replacement: .text("HTTPS://WWW.EXAMPLE.COM/watch")))
        #expect(harness.ruleCalls == ["clean"])
    }

    /// Whether a copy needs the rules at all: a usable extension with `capture` and a rule that is switched on.
    @Test func hasRulesFollowsTheSwitches() async throws {
        let harness = try await RuleHarness([Spec(id: "dev.example.one", name: "One", rules: [Self.rule("only")],
                                                  js: #"exports.captureRules = { only: { run: () => ({ keep: true }) } };"#)])
        #expect(harness.runner.hasRules)
        // What a copy may wait for them: each rule at its limit (2 s here) and the margin.
        #expect(harness.runner.budget == .seconds(2) + CaptureRuleRunner.margin)
        harness.settings.setRuleEnabled("dev.example.one", "only", false)
        #expect(!harness.runner.hasRules)
        #expect(harness.runner.budget == .zero)
        harness.settings.setRuleEnabled("dev.example.one", "only", true)
        harness.registry.setEnabled("dev.example.one", false)
        #expect(!harness.runner.hasRules)
    }

    @Test func anUnknownAnswerIsSkipped() async throws {
        let harness = try await RuleHarness([Spec(id: "dev.example.odd", name: "Odd", rules: [Self.rule("odd"), Self.rule("fine")], js: #"""
        exports.captureRules = { odd: { run: (item) => ({ replace: item.text }) }, fine: { run: () => ({ addToCategory: "Work" }) } };
        """#)])
        #expect(await harness.run(.text("gizli-123")) == CaptureRuleDecision(categories: ["Work"]))
        try await eventually { harness.logs.lines.contains("dev.example.odd: rule odd failed (badResult)") }
        #expect(!harness.logs.lines.contains { $0.contains("gizli") })
    }

    /// A host restart drops what the service had loaded there, and the reload goes the shared way,
    /// so the next copies' deadlines cannot cut it short again and again.
    @Test func aRestartDoesNotSilenceASlowLoadingRule() async throws {
        let harness = try await RuleHarness([Spec(id: "dev.example.restart", name: "Restart", rules: [Self.rule("clean")], js: #"""
        const end = Date.now() + 300;
        while (Date.now() < end) {}
        exports.captureRules = { clean: { run: (item) => item.text === "hang" ? new Promise(() => {}) : { replace: { text: "clean" } } } };
        """#)], timeout: nil)
        await RuleHarness.mainActorKeepsUp()
        #expect(await harness.run(.text("a")) == CaptureRuleDecision(replacement: .text("clean")))
        // A rule that hangs runs out the host's clock: the host restarts, and its extensions load again.
        #expect(await harness.run(.text("hang")) == CaptureRuleDecision())
        try await eventually { harness.logs.lines.contains("dev.example.restart: rule clean failed (timeout)") }
        // That reload runs to its end: once it is in, the rule applies again.
        var decision = CaptureRuleDecision()
        for _ in 0..<3 where decision.replacement == nil {
            await harness.service.preloadCaptureRules().value
            decision = await harness.run(.text("a"))
        }
        #expect(decision == CaptureRuleDecision(replacement: .text("clean")))
    }

    /// What a rule returns never reaches the Development log, whatever its shape.
    @Test func aRuleAnswerNeverReachesTheLog() async throws {
        let harness = try await RuleHarness([Spec(id: "dev.example.echo", name: "Echo", rules: [Self.rule("number"), Self.rule("flag")], js: #"""
        exports.captureRules = { number: { run: (item) => Number(item.text) }, flag: { run: (item) => item.text.length > 3 } };
        """#)])
        #expect(await harness.run(.text("123456")) == CaptureRuleDecision())
        try await eventually { harness.logs.lines.contains("dev.example.echo: rule flag failed (badResult)") }
        #expect(harness.logs.lines.contains("dev.example.echo: rule number failed (badResult)"))
        #expect(!harness.logs.lines.contains { $0.contains("123456") || $0.contains("returned true") })
    }

    /// A load of the old code that fails after the extension changed does not hide the new code.
    @Test func aFailureFromBeforeAChangeDoesNotHideTheFix() async throws {
        // The old code runs 3 s: the change below lands while it does, however far behind the main actor is.
        let harness = try await RuleHarness([Spec(id: "dev.example.fixed", name: "Fixed", rules: [Self.rule("clean")], js: #"""
        console.log("old code running");
        const end = Date.now() + 3000;
        while (Date.now() < end) {}
        throw new Error("broken");
        """#)], preload: false)
        await RuleHarness.mainActorKeepsUp()
        // A change starts loading the broken code…
        harness.registry.reload()
        try await eventually { harness.logs.lines.contains("old code running") }
        // …and the fix lands while it runs: another change, which loads the fixed code.
        try #"exports.captureRules = { clean: { run: () => ({ replace: { text: "clean" } }) } };"#
            .write(to: harness.root.appendingPathComponent("dev.example.fixed/index.js"), atomically: true, encoding: .utf8)
        harness.registry.reload()
        // The old load fails after that.
        try await eventually { harness.logs.lines.contains { $0.contains("index.js could not load") } }
        await harness.service.preloadCaptureRules().value
        #expect(await harness.run(.text("a")) == CaptureRuleDecision(replacement: .text("clean")))
    }

    /// The caller's retry after a stale failure does not load code the current revision already
    /// found broken; a third failure would turn the extension off, when it should only be hidden.
    @Test func aBrokenExtensionIsHiddenNotTurnedOff() async throws {
        // The old code runs 3 s, so the change below lands while it does, however far behind the main actor is; the
        // copy's rule gets 5 s, so the copy is still waiting when that load fails.
        let harness = try await RuleHarness([Spec(id: "dev.example.broken", name: "Broken", rules: [Self.rule("clean")], js: #"""
        console.log("old code running");
        const end = Date.now() + 3000;
        while (Date.now() < end) {}
        throw new Error("broken");
        """#)], timeout: .seconds(5), preload: false)
        await RuleHarness.mainActorKeepsUp()
        // A change loads the old code, and a copy waits for that load.
        harness.registry.reload()
        try await eventually { harness.logs.lines.contains("old code running") }
        let copy = Task { await harness.run(.text("a")) }
        try await Task.sleep(for: .milliseconds(50))
        // Another change: the current code is still broken, and fails at once.
        try #"throw new Error("still broken");"#
            .write(to: harness.root.appendingPathComponent("dev.example.broken/index.js"), atomically: true, encoding: .utf8)
        harness.registry.reload()
        try await eventually { harness.logs.lines.filter { $0.contains("index.js could not load") }.count == 1 }
        // The old load fails after that; the copy goes on without its rule.
        #expect(await copy.value == CaptureRuleDecision())
        try await eventually { harness.logs.lines.filter { $0.contains("index.js could not load") }.count == 2 }
        try await Task.sleep(for: .milliseconds(200))
        // Two loads, two failures: hidden until its files change, and still on.
        #expect(harness.transport.requests.filter { $0.load != nil }.count == 2)
        #expect(harness.settings.isEnabled("dev.example.broken"))
        #expect(await harness.run(.text("a")) == CaptureRuleDecision())
        #expect(harness.transport.requests.filter { $0.load != nil }.count == 2)
    }

    /// A host that stops on every load is not started again and again by the loads a restart
    /// brings on by itself.
    @Test func aHostThatDiesOnEveryLoadIsNotRespawnedEndlessly() async throws {
        let host = DyingTransport()
        let harness = try await RuleHarness([Spec(id: "dev.example.crash", name: "Crash", rules: [Self.rule("clean")],
                                                  js: #"exports.captureRules = { clean: { run: () => ({ keep: true }) } };"#)],
                                            preload: false, host: host)
        harness.registry.reload()
        try await Task.sleep(for: .seconds(2))
        #expect(host.launches >= 1)
        #expect(host.launches <= 3)
    }
}

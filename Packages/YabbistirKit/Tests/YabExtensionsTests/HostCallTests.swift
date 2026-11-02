import Foundation
import Testing
import YabExtensionKit
import YabLocalization
@testable import YabExtensions

/// The app's side of host calls, recorded.
@MainActor final class FakeHostServices: HostServices {
    struct Notice: Equatable {
        let name: String
        let message: String
    }

    private(set) var notifications: [Notice] = []
    private(set) var opened: [URL] = []

    func notify(extensionName: String, message: String) { notifications.append(Notice(name: extensionName, message: message)) }
    func open(_ url: URL) { opened.append(url) }
    /// What history holds, and what the router asked of it.
    var items: [ExtensionItem] = []
    private(set) var recentLimits: [Int] = []
    private(set) var searches: [Search] = []

    struct Search: Equatable {
        let query: String
        let limit: Int
    }

    func recentItems(limit: Int) async -> [ExtensionItem] {
        recentLimits.append(limit)
        return items
    }

    func searchItems(_ query: String, limit: Int) async -> [ExtensionItem] {
        searches.append(Search(query: query, limit: limit))
        return items
    }
    /// The on-device model and translator behind `generate` and `translate`: fakes, reached through the
    /// app's own checks and reasons, which speak `language`.
    let model = FakeLanguageModel()
    let translator = FakeTranslator()
    var language = AppLanguage.english

    func generate(_ prompt: String, options: AIOptions) async throws(ExtensionError) -> String {
        try await OnDeviceHostServices(model: model, translator: translator).generate(prompt, options: options, language: language)
    }

    func translate(_ text: String, from: String?, to: String) async throws(TranslationFailure) -> TranslationOutput {
        try await OnDeviceHostServices(model: model, translator: translator).translate(text, from: from, to: to, language: language)
    }
}

/// The router's clock, moved by hand.
@MainActor final class RouterClock {
    private(set) var now = ContinuousClock.now
    func advance(by duration: Duration) { now = now.advanced(by: duration) }
}

/// A pipe to a real host that keeps what the app sent it.
final class RecordingTransport: HostTransport, @unchecked Sendable {
    private let pipe = PipeTransport()
    private let lock = NSLock()
    /// Touched only under `lock`.
    private var sent: [HostRequest] = []

    var requests: [HostRequest] { lock.withLock { sent } }

    func start(onLine: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable () -> Void) throws {
        try pipe.start(onLine: onLine, onExit: onExit)
    }

    func send(_ line: Data) {
        if let request = try? JSONDecoder().decode(HostRequest.self, from: line) { lock.withLock { sent.append(request) } }
        pipe.send(line)
    }

    func restart() throws { try pipe.restart() }
    func stop() { pipe.stop() }
}

/// A real host over a pipe, with one extension ("Test") loaded and its requests going through a router
/// to fake services.
@MainActor final class HostCallHarness {
    static let id = "dev.example.fixture"
    let services = FakeHostServices()
    let clock = RouterClock()
    let transport = RecordingTransport()
    let registry: ExtensionRegistry
    let router: HostCallRouter
    let client: ExtensionHostClient
    /// Requests the router has answered (or refused).
    private(set) var handled = 0
    /// What the extension logged.
    let logs = LogBox()

    final class LogBox {
        var lines: [String] = []
    }

    /// `serviceLimit`: the longest the router works on one request; `pauseLimit`: the longest a call's clock waits for the app.
    init(js: String, permissions: [String] = [], serviceLimit: Duration = HostCallRouter.serviceLimit,
         pauseLimit: Duration = HostCallRouter.serviceLimit) async throws {
        let settings = ExtensionSettings(defaults: UserDefaults(suiteName: "yab-calls-\(UUID().uuidString)")!)
        registry = ExtensionRegistry(builtInRoot: RegistryFixture.temporary("BuiltinExtensions"), userRoot: RegistryFixture.temporary("Extensions"),
                                     dataRoot: RegistryFixture.temporary("ExtensionData"), settings: settings)
        let folder = try ExtensionFixture.folder(id: Self.id, name: "Test", permissions: permissions, js: js)
        try registry.install(folder: folder)
        // Consent covers what the manifest asks for, as the person's approval would.
        let grant = PermissionGrant.requested(by: try #require(registry.installed.first { $0.id == Self.id }?.manifest))
        registry.approve(Self.id, grant: grant)
        let clock = clock
        router = HostCallRouter(services: services, registry: registry, clock: { clock.now }, serviceLimit: serviceLimit)
        let logs = logs
        client = ExtensionHostClient(transport: transport, pauseLimit: pauseLimit) { _, line in logs.lines.append(line) }
        let router = router
        client.onHostCall = { [unowned self] call throws(ExtensionError) in
            defer { handled += 1 }
            return try await router.handle(call)
        }
        try await client.load(Self.id, folder: folder, dataFolder: ExtensionFixture.dataFolder, language: "en", grant: grant)
    }

    func run(_ name: String = "a", effects: Bool = true, timeout: Duration = .seconds(5)) async throws -> InvokeOutput {
        try await client.invoke(Self.id, .run, name: name, item: nil, context: ExtensionContext(language: "en", trigger: .search),
                                effects: effects, timeout: timeout)
    }

    /// A request as the client would hand it over, straight to the router.
    @discardableResult
    func ask(_ method: String, _ params: [String: JSONValue], extensionID: String = id, effects: Bool = true,
             kind: InvokeKind = .run) async throws(ExtensionError) -> JSONValue {
        try await router.handle(HostCall(extensionID: extensionID, invokeID: 1, requestID: 1, kind: kind, method: method,
                                         params: .object(params), effects: effects))
    }
}

@MainActor @Suite struct HostCallTests {
    @Test func aNotificationReachesTheApp() async throws {
        let harness = try await HostCallHarness(js: #"exports.actions = { a: { run() { yab.notify("bitti"); return { text: "ok" }; } } };"#)
        #expect(try await harness.run() == .result(.text("ok")))
        try await eventually { harness.handled == 1 }
        #expect(harness.services.notifications == [.init(name: "Test", message: "bitti")])
    }

    @Test func notificationsAreThrottled() async throws {
        let harness = try await HostCallHarness(js: #"""
        exports.actions = { a: { run() { yab.notify("bir"); yab.notify("iki"); yab.notify("üç"); return { text: "ok" }; } } };
        """#)
        _ = try await harness.run()
        try await eventually { harness.handled == 3 }
        // The extra ones go quietly: no error reaches the extension.
        #expect(harness.services.notifications.map(\.message) == ["bir"])
        // Each extension has its own pace.
        try await harness.ask("notify", ["message": .string("başka")], extensionID: "dev.example.other")
        #expect(harness.services.notifications.count == 2)
        // Straight to the router: the dropped one is no error there either.
        _ = try await harness.ask("notify", ["message": .string("dördüncü")])
        #expect(harness.services.notifications.count == 2)

        harness.clock.advance(by: .milliseconds(3100))
        _ = try await harness.run()
        // The helper lets five through in ten seconds, so the sixth never reaches the router.
        try await eventually { harness.handled == 5 }
        #expect(harness.services.notifications.filter { $0.name == "Test" }.map(\.message) == ["bir", "bir"])
    }

    @Test func aLongNotificationIsCut() async throws {
        // One character each, two code points and four UTF-16 units: a cut anywhere else would split one.
        let harness = try await HostCallHarness(js: #"exports.actions = { a: { run() { yab.notify("👍🏽".repeat(300)); return { text: "ok" }; } } };"#)
        _ = try await harness.run()
        try await eventually { harness.handled == 1 }
        #expect(harness.services.notifications.map(\.message) == [String(repeating: "👍🏽", count: 200)])
    }

    @Test func openTakesOnlyWebLinks() async throws {
        let harness = try await HostCallHarness(js: #"""
        exports.actions = { a: { run() {
          yab.open("https://a.dev");
          const refused = [];
          for (const link of ["file:///etc", "https:", "http://", "https:foo"]) {
            try { yab.open(link); refused.push("opened " + link); } catch (e) { refused.push(e.code + ": " + e.message); }
          }
          return { text: refused.join("|") };
        } } };
        """#)
        let refusal = "badResult: only http and https links open"
        #expect(try await harness.run() == .result(.text([String](repeating: refusal, count: 4).joined(separator: "|"))))
        try await eventually { harness.handled == 1 }
        #expect(harness.services.opened == [URL(string: "https://a.dev")!])
        // The app holds the same line on its own.
        await #expect(throws: ExtensionError(.badResult, "only http and https links open")) {
            try await harness.ask("open", ["url": .string("file:///etc")])
        }
        for link in ["https:", "http://", "https:foo"] {
            await #expect(throws: ExtensionError(.badResult, "only http and https links open")) {
                try await harness.ask("open", ["url": .string(link)])
            }
        }
        #expect(harness.services.opened == [URL(string: "https://a.dev")!])
    }

    @Test func hintsCannotNotifyOrOpen() async throws {
        let harness = try await HostCallHarness(js: #"""
        exports.actions = { a: { run() {
          const codes = [];
          for (const ask of [() => yab.notify("x"), () => yab.open("https://a.dev")]) {
            try { ask(); codes.push("sent"); } catch (e) { codes.push(e.code); }
          }
          return { text: codes.join(",") };
        } } };
        """#)
        #expect(try await harness.run(effects: false) == .result(.text("permissionDenied,permissionDenied")))
        // The app refuses too, whatever the host let through.
        for (method, params) in [("notify", ["message": JSONValue.string("x")]), ("open", ["url": .string("https://a.dev")])] {
            await #expect {
                try await harness.ask(method, params, effects: false)
            } throws: { ($0 as? ExtensionError)?.code == .permissionDenied }
        }
        // Nor are rules and detectors a way round `effects`.
        for kind in [InvokeKind.validate, .preview, .captureRule] {
            for (method, params) in [("notify", ["message": JSONValue.string("x")]), ("open", ["url": .string("https://a.dev")])] {
                await #expect {
                    try await harness.ask(method, params, kind: kind)
                } throws: { ($0 as? ExtensionError)?.code == .permissionDenied }
            }
        }
        #expect(harness.services.notifications.isEmpty)
        #expect(harness.services.opened.isEmpty)
        #expect(harness.handled == 0)
    }

    /// A source's list or run cannot open a link or put up a notice, whatever the helper let through: a link needs no
    /// permission, and its address could carry a value to a website. Actions keep both.
    @Test func sourcesCannotNotifyOrOpen() async throws {
        let harness = try await HostCallHarness(js: #"exports.actions = { a: { run: () => ({ text: "ok" }) } };"#)
        let refusal = ExtensionError(.permissionDenied, "a source cannot open links or show notices")
        for kind in [InvokeKind.sourceList, .sourceRun] {
            for (method, params) in [("notify", ["message": JSONValue.string("x")]), ("open", ["url": .string("https://ornek.dev/?p=s3cr3t-örnek")])] {
                await #expect(throws: refusal) { try await harness.ask(method, params, kind: kind) }
            }
        }
        #expect(harness.services.notifications.isEmpty)
        #expect(harness.services.opened.isEmpty)
        try await harness.ask("notify", ["message": .string("x")])
        try await harness.ask("open", ["url": .string("https://ornek.dev")])
        #expect(harness.services.notifications.map(\.message) == ["x"])
        #expect(harness.services.opened == [URL(string: "https://ornek.dev")!])
    }

    @Test func aCallsRequestsEndWithIt() async throws {
        let harness = try await HostCallHarness(js: #"""
        exports.actions = {
          a: { run() { yab.notify("bekle"); return new Promise(() => {}); } },
          b: { run: () => ({ text: "ok" }) },
        };
        """#)
        var asked: [HostCall] = []
        var sawCancel = false
        harness.client.onHostCall = { call throws(ExtensionError) in
            asked.append(call)
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                sawCancel = true
                throw ExtensionError(.cancelled, "the call was cancelled")
            }
            return .null
        }
        let call = Task { try await harness.run() }
        try await eventually { !asked.isEmpty }
        let invokeID = try #require(harness.transport.requests.first { $0.invoke != nil }?.id)
        #expect(asked.map { [$0.extensionID, $0.method, "\($0.kind)", "\($0.effects)", "\($0.invokeID)"] }
            == [[HostCallHarness.id, "notify", "run", "true", "\(invokeID)"]])

        let start = ContinuousClock.now
        call.cancel()
        await #expect { _ = try await call.value } throws: { ($0 as? ExtensionError)?.code == .cancelled }
        try await eventually { sawCancel }
        #expect(ContinuousClock.now - start < .seconds(1))
        // Nothing goes back for it; a reply that comes late anyway finds nobody waiting, and the host answers on.
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.transport.requests.allSatisfy { $0.reply == nil })
        harness.transport.send(try JSONEncoder().encode(HostRequest(reply: ReplyRequest(requestID: asked[0].requestID, ok: .string("late")))))
        #expect(try await harness.run("b") == .result(.text("ok")))
    }

    // MARK: Time

    /// The time the app takes to answer a call's requests (a translation, the model) is the app's, not
    /// the extension's. Its own time still counts, before and after a request alike.
    @Test func timeSpentInTheAppDoesNotCountAgainstTheCall() async throws {
        let harness = try await HostCallHarness(js: #"""
        const busy = (ms) => { const end = Date.now() + ms; while (Date.now() < end) {} };
        exports.actions = {
          a: { async run() { const out = await yab.translate("hello", { to: "tr" }); return { text: out.text }; } },
          b: { run() { busy(400); return { text: "late" }; } },
          c: { async run() { busy(200); const out = await yab.translate("hello", { to: "tr" }); busy(200); return { text: out.text }; } },
        };
        """#)
        harness.services.translator.delay = .milliseconds(600)
        #expect(try await harness.run("a", timeout: .milliseconds(300)) == .result(.text("[tr] hello")))
        #expect(harness.services.translator.translated == [["hello", "en", "tr"]])
        // 400 ms of its own against 300: out of time, as before.
        await #expect { try await harness.run("b", timeout: .milliseconds(300)) } throws: { ($0 as? ExtensionError)?.code == .timeout }
        // 200 ms before the request and 200 after: the clock picks up where it stopped, it does not start over.
        await #expect { try await harness.run("c", timeout: .milliseconds(300)) } throws: { ($0 as? ExtensionError)?.code == .timeout }
    }

    @MainActor final class RunBox {
        var output: InvokeOutput?
        var failure: ExtensionError?
        var elapsed: Duration = .zero
        var done = false
    }

    /// Only a run the person started waits for the app. A hint (no effects) keeps its clock
    /// running while the app answers it, as rules, detectors and previews do.
    @Test func aHintsClockNeverPauses() async throws {
        let harness = try await HostCallHarness(js: #"""
        exports.actions = { a: { async run() { const items = await yab.history.recent(1); return { text: "read " + items.length }; } } };
        """#, permissions: ["history"])
        harness.client.onHostCall = { _ throws(ExtensionError) in
            try? await Task.sleep(for: .milliseconds(600))
            return .array([])
        }
        await #expect { try await harness.run(effects: false, timeout: .milliseconds(300)) } throws: { ($0 as? ExtensionError)?.code == .timeout }
        // The same request in a run the person started: its clock waits.
        #expect(try await harness.run(timeout: .milliseconds(300)) == .result(.text("read 0")))
    }

    /// A call waits for the app at most `pauseLimit` in all (short here). Requests kept
    /// outstanding one over another cannot hold its clock past that: it then runs out its own time.
    @Test func pausingIsBoundedPerCall() async throws {
        let harness = try await HostCallHarness(js: #"""
        exports.actions = { a: { async run() {
          for (;;) { yab.history.recent(1).catch(() => {}); await new Promise((resolve) => setTimeout(resolve, 50)); }
        } } };
        """#, permissions: ["history"], pauseLimit: .milliseconds(400))
        harness.client.onHostCall = { _ throws(ExtensionError) in
            try? await Task.sleep(for: .milliseconds(200))
            return .array([])
        }
        let box = RunBox()
        let start = ContinuousClock.now
        let run = Task { @MainActor in
            do { box.output = try await harness.run(timeout: .milliseconds(300)) } catch { box.failure = error as? ExtensionError }
            (box.elapsed, box.done) = (ContinuousClock.now - start, true)
        }
        try await eventually { box.done }
        run.cancel()
        #expect(box.failure?.code == .timeout)
        // It did wait for the app first: past its own 300 ms.
        #expect(box.elapsed > .milliseconds(500))
    }

    /// The app gives each request at most `HostCallRouter.serviceLimit` (short here). Past it
    /// the work is stopped and the call is told why in the app's language; the call's own clock then goes on, so it
    /// ends as it would have.
    @Test func aRequestTheAppCannotFinishIsCutOff() async throws {
        let harness = try await HostCallHarness(js: #"""
        exports.actions = { a: { async run() {
          try { await yab.ai.generate("hello"); return { text: "answered" }; } catch (e) { return { text: e.code + ": " + e.message }; }
        } } };
        """#, serviceLimit: .milliseconds(500))
        harness.router.language = { "tr" }
        harness.services.model.thinking = .seconds(3600)
        let box = RunBox()
        // 300 ms of its own against a 500 ms request: the clock waited for the app.
        let run = Task { @MainActor in
            box.output = try? await harness.run(timeout: .milliseconds(300))
            box.done = true
        }
        try await eventually { box.done }
        try await eventually { harness.services.model.cancelled == 1 }
        run.cancel()
        #expect(box.output == .result(.text("unavailable: Bu çok uzun sürdü")))
    }

    // MARK: History

    private static func item(_ id: Int64, text: String = "metin") -> ExtensionItem {
        ExtensionItem(id: id, kind: "text", text: text, tags: [], copiedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func historyNeedsItsPermission() async throws {
        let harness = try await HostCallHarness(js: #"""
        exports.actions = { a: { async run() {
          try { await yab.history.recent(3); return { text: "read" }; } catch (e) { return { text: e.code + ": " + e.message }; }
        } } };
        """#)
        // The app's check runs too, and its refusal, in the app's language, is the one the script sees.
        #expect(try await harness.run() == .result(.text("permissionDenied: This extension isn’t allowed to read your history")))
        #expect(harness.handled == 1)
        // The app holds the same line: no permission, no read, and an extension it does not know has none either.
        for id in [HostCallHarness.id, "dev.example.other"] {
            await #expect(throws: ExtensionError(.permissionDenied, "This extension isn’t allowed to read your history")) {
                try await harness.ask("history.recent", [:], extensionID: id)
            }
        }
        #expect(harness.services.recentLimits.isEmpty)
    }

    /// A refused history call says why in the app's language, whichever check refuses it.
    @Test func aRefusedHistoryCallSpeaksTheAppsLanguage() async throws {
        let js = #"""
        const why = (e) => e.code + ": " + e.message;
        exports.actions = { a: { async run() { try { await yab.history.search("x"); return { text: "read" }; } catch (e) { return { text: why(e) }; } } } };
        exports.captureRules = { r: { async run() { try { await yab.history.recent(); return { keep: true }; } catch (e) { return { replace: { text: why(e) } }; } } } };
        """#
        let without = try await HostCallHarness(js: js)
        without.router.language = { "tr" }
        #expect(try await without.run() == .result(.text("permissionDenied: Bu uzantının geçmişini okuma izni yok")))

        let with = try await HostCallHarness(js: js, permissions: ["history"])
        with.router.language = { "tr" }
        let rule = try await with.client.invoke(HostCallHarness.id, .captureRule, name: "r", item: ExtensionItem(id: 0, kind: "text", text: "a", copiedAt: Date()),
                                                context: ExtensionContext(language: "tr", trigger: .capture), timeout: .seconds(5))
        #expect(rule == .capture(.replaceText("permissionDenied: Geçmiş burada kullanılamaz")))
        #expect(with.services.recentLimits.isEmpty)
    }

    /// The helper's own check still holds: an app that answers a request it should have refused hands the script
    /// nothing, and the refusal is the helper's (for the developer, in English).
    @Test func theHelperStillRefusesWhatTheAppLetsThrough() async throws {
        let harness = try await HostCallHarness(js: #"""
        exports.actions = { a: { async run() {
          try { const items = await yab.history.recent(3); return { text: "read " + items.length }; } catch (e) { return { text: e.code + ": " + e.message }; }
        } } };
        """#)
        var asked = 0
        harness.client.onHostCall = { _ throws(ExtensionError) in
            asked += 1
            return .array([.object(["id": .number(1), "kind": .string("text"), "text": .string("gizli")])])
        }
        #expect(try await harness.run() == .result(.text("permissionDenied: \(HostCallHarness.id) has no history permission")))
        #expect(asked == 1)
    }

    @Test func historyIsNotForRulesAndDetectors() async throws {
        let harness = try await HostCallHarness(js: #"exports.actions = { a: { run: () => ({ text: "ok" }) } };"#, permissions: ["history"])
        for kind in [InvokeKind.validate, .preview, .captureRule] {
            await #expect(throws: ExtensionError(.permissionDenied, "History isn’t available here")) {
                try await harness.ask("history.recent", [:], kind: kind)
            }
        }
        #expect(harness.services.recentLimits.isEmpty)
        // A run reads it, with or without `effects`.
        _ = try await harness.ask("history.recent", [:], effects: false)
        #expect(harness.services.recentLimits == [20])
    }

    @Test func historyReturnsAtMostFifty() async throws {
        let harness = try await HostCallHarness(js: #"exports.actions = { a: { run: () => ({ text: "ok" }) } };"#, permissions: ["history"])
        _ = try await harness.ask("history.recent", ["limit": .number(500)])
        _ = try await harness.ask("history.recent", ["limit": .number(0)])
        _ = try await harness.ask("history.recent", ["limit": .number(7)])
        _ = try await harness.ask("history.recent", [:])
        _ = try await harness.ask("history.search", ["query": .string("x"), "limit": .number(-4)])
        #expect(harness.services.recentLimits == [50, 1, 7, 20])
        #expect(harness.services.searches == [.init(query: "x", limit: 1)])
    }

    @Test func historySearchPassesTheQuery() async throws {
        let harness = try await HostCallHarness(js: #"exports.actions = { a: { run: () => ({ text: "ok" }) } };"#, permissions: ["history"])
        _ = try await harness.ask("history.search", ["query": .string("fatura"), "limit": .number(5)])
        #expect(harness.services.searches == [.init(query: "fatura", limit: 5)])
        await #expect {
            try await harness.ask("history.search", [:])
        } throws: { ($0 as? ExtensionError)?.code == .badResult }
    }

    @Test func aHistoryAnswerReachesTheScript() async throws {
        let harness = try await HostCallHarness(js: #"""
        exports.actions = { a: { async run() {
          const items = await yab.history.recent(3);
          const found = await yab.history.search("b", 2);
          return { text: items.map(i => i.text).join(",") + "|" + found.length + "|" + typeof items[0].copiedAt };
        } } };
        """#, permissions: ["history"])
        harness.services.items = [Self.item(1, text: "bir"), Self.item(2, text: "iki")]
        #expect(try await harness.run() == .result(.text("bir,iki|2|string")))
        #expect(harness.services.recentLimits == [3])
        #expect(harness.services.searches == [.init(query: "b", limit: 2)])
    }

    @Test func aRequestStillOpenWhenTheCallEndsIsRejected() async throws {
        let harness = try await HostCallHarness(js: #"""
        exports.actions = {
          a: { run() { yab.history.recent(1).catch(e => console.log("rejected " + e.code + ": " + e.message)); return { text: "ok" }; } },
          b: { run: () => ({ text: "still here" }) },
        };
        """#, permissions: ["history"])
        var asked: [HostCall] = []
        harness.client.onHostCall = { call throws(ExtensionError) in
            asked.append(call)
            try? await Task.sleep(for: .seconds(2))
            throw ExtensionError(.cancelled, "the call was cancelled")
        }
        #expect(try await harness.run() == .result(.text("ok")))
        try await eventually { asked.count == 1 }
        try await eventually { harness.logs.lines.contains { $0.hasPrefix("rejected ") } }
        let line = try #require(harness.logs.lines.first { $0.hasPrefix("rejected ") })
        #expect(line.hasPrefix("rejected permissionDenied") || line.hasPrefix("rejected cancelled"))
        // The late answer finds nobody waiting, and the host answers on.
        harness.transport.send(try JSONEncoder().encode(HostRequest(reply: ReplyRequest(requestID: asked[0].requestID, ok: .array([])))))
        #expect(try await harness.run("b") == .result(.text("still here")))
    }

    @Test func historyItemsAreTrimmed() async throws {
        let harness = try await HostCallHarness(js: #"exports.actions = { a: { run: () => ({ text: "ok" }) } };"#, permissions: ["history"])
        // 3 bytes each: a cut at 65536 bytes would land inside the 22 369th, so it stops after 21 845.
        let long = String(repeating: "€", count: 30_000)
        var picture = Self.item(2)
        picture.kind = "image"
        picture.text = nil
        picture.image = .init(data: Data(repeating: 7, count: 1000), width: 640, height: 480)
        var rich = Self.item(3, text: "kısa")
        rich.richText = .init(html: long)
        harness.services.items = [Self.item(1, text: long), picture, rich]

        let reply = try await harness.ask("history.recent", [:])
        let items = try #require(reply.arrayValue)
        let text = try #require(items[0]["text"]?.stringValue)
        #expect(text == String(repeating: "€", count: 21_845))
        #expect(text.utf8.count <= 65_536)
        #expect(items[1]["image"] == .object(["width": .number(640), "height": .number(480)]))
        #expect(items[2]["text"]?.stringValue == "kısa")
        #expect(items[2]["richText"]?["html"]?.stringValue == text)
        #expect(items[0]["id"] == .number(1))
        // A short one is left alone.
        harness.services.items = [Self.item(4, text: "kısa")]
        let short = try await harness.ask("history.search", ["query": .string("k")])
        #expect(short.arrayValue?.first?["text"]?.stringValue == "kısa")
    }
}

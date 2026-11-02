import Foundation
import Testing
import YabExtensionKit
@testable import YabExtensionRuntime

/// Sources: `sources[name].list(ctx)` and `sources[name].run(rowId, actionId, ctx)`, and what the host lets through
/// of their answers. The values are synthetic; still, no message checked here may carry one.
@Suite struct SourceRuntimeTests {
    let context = ExtensionContext(language: "tr", trigger: .source)

    func list(_ js: String, log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> InvokeOutput {
        try await RuntimeFixture.load(js: js, log: log).invoke(.sourceList, name: "vault", item: nil, context: context, effects: true)
    }

    func run(_ js: String, action: String = "password", kind: SourceActionSpec.Kind = .secret) async throws -> InvokeOutput {
        try await RuntimeFixture.load(js: js).invoke(.sourceRun, name: "vault", item: nil, context: context, effects: true,
                                                     source: SourceInvocation(rowID: "42", actionID: action, kind: kind))
    }

    /// The call's error, or nil when it answered.
    func failure(_ call: () async throws -> InvokeOutput) async -> ExtensionError? {
        do {
            _ = try await call()
            return nil
        } catch {
            return error as? ExtensionError
        }
    }

    func listing(_ answer: String) -> String {
        "module.exports = { sources: { vault: { list: () => (\(answer)) } } };"
    }

    @Test func aSourceListsItsRows() async throws {
        let js = #"module.exports = { sources: { vault: { list: () => ({ rows: [{ id: "1", title: "ornek.dev", subtitle: "deniz.k" }] }) } } };"#
        #expect(try await list(js) == .listing(.rows([SourceRow(id: "1", title: "ornek.dev", subtitle: "deniz.k")])))
    }

    /// `list` gets the context alone, with its signal; no item.
    @Test func listGetsAContextOnly() async throws {
        let js = #"""
        module.exports = { sources: { vault: { list: (...args) => ({
          rows: [{ id: String(args.length), title: args[0].trigger + " " + typeof args[0].signal + " " + args[0].language }],
        }) } } };
        """#
        #expect(try await list(js) == .listing(.rows([SourceRow(id: "1", title: "source object tr")])))
    }

    @Test func aLockedSourceSaysSo() async throws {
        let js = listing(#"{ locked: true, message: "Kasa kilitli", command: "vault login" }"#)
        #expect(try await list(js) == .listing(.locked(message: "Kasa kilitli", command: "vault login")))
    }

    /// The locked row is one calm line and a command to copy: both are cleaned like rows and cut to 200 characters,
    /// and a blank command is none.
    @Test func aLockedListingIsCleanedAndCut() async throws {
        let long = listing(#"{ locked: true, message: "k".repeat(300), command: "vault login\n" }"#)
        #expect(try await list(long) == .listing(.locked(message: String(repeating: "k", count: 200), command: "vault login")))
        let bare = listing(#"{ locked: true, message: " Kasa\tkilitli ", command: "  " }"#)
        #expect(try await list(bare) == .listing(.locked(message: "Kasa kilitli", command: nil)))
    }

    @Test func runGetsTheRowTheActionAndAContext() async throws {
        let js = #"module.exports = { sources: { vault: { run: (r, a, ctx) => ({ secret: r + ":" + a + ":" + typeof ctx.signal }) } } };"#
        #expect(try await run(js) == .value(.secret("42:password:object")))
    }

    @Test func aTextActionReturnsText() async throws {
        let js = #"module.exports = { sources: { vault: { run: async () => ({ text: "deniz.k" }) } } };"#
        #expect(try await run(js, action: "username", kind: .text) == .value(.text("deniz.k")))
    }

    @Test func aSecretActionMustReturnASecret() async throws {
        let js = #"module.exports = { sources: { vault: { run: () => ({ text: "s3cr3t-örnek" }) } } };"#
        let error = await failure { try await run(js) }
        #expect(error?.code == .badResult)
        #expect(error?.message.contains("s3cr3t") == false)
        #expect(error?.message == "run returned {text}; this action expects {secret}")
    }

    /// The other way round too, and every other shape: the reason names shapes, never the value.
    @Test(arguments: [
        (#"({ secret: "s3cr3t-örnek" })"#, SourceActionSpec.Kind.text, "run returned {secret}; this action expects {text}"),
        (#""s3cr3t-örnek""#, .secret, "run returned a string; this action expects {secret}"),
        ("undefined", .text, "run returned nothing; this action expects {text}"),
        (#"({ value: "s3cr3t-örnek" })"#, .secret, "run returned an object of another shape; this action expects {secret}"),
        (#"({ secret: ["s3cr3t-örnek"] })"#, .secret, "secret must be a string"),
        (#"({ text: { s3cr3t: 1 } })"#, .text, "text must be a string"),
    ])
    func everyOtherValueIsABadResult(answer: String, kind: SourceActionSpec.Kind, message: String) async throws {
        let js = "module.exports = { sources: { vault: { run: () => \(answer) } } };"
        let error = await failure { try await run(js, kind: kind) }
        #expect(error?.code == .badResult)
        #expect(error?.message == message)
    }

    @Test func anEmptySecretIsRefused() async throws {
        let js = #"module.exports = { sources: { vault: { run: () => ({ secret: "  \n" }) } } };"#
        let error = await failure { try await run(js) }
        #expect(error?.code == .badResult)
        #expect(error?.message == "run returned an empty value")
        let text = #"module.exports = { sources: { vault: { run: () => ({ text: "" }) } } };"#
        #expect(await failure { try await run(text, kind: .text) }?.message == "run returned an empty value")
    }

    /// Tabs and line ends become spaces, the ends are trimmed, long strings are cut and a blank subtitle is none; past
    /// 10 000 rows the rest are dropped, with one line in the Development log that names no row.
    @Test func rowsAreCappedAndCleaned() async throws {
        let sink = LogSink()
        let js = #"""
        module.exports = { sources: { vault: { list: () => ({ rows: [
          { id: "0", title: "a\tb\nc", subtitle: "  \n " },
          { id: "1", title: "x".repeat(300), subtitle: " deniz.k\r\n" },
          ...Array.from({ length: 9999 }, (_, i) => ({ id: String(i + 2), title: "ornek.dev", subtitle: null })),
        ] }) } } };
        """#
        guard case .listing(.rows(let rows)) = try await list(js, log: sink.append) else {
            Issue.record("expected rows")
            return
        }
        #expect(rows.count == 10_000)
        #expect(rows[0] == SourceRow(id: "0", title: "a b c"))
        #expect(rows[1] == SourceRow(id: "1", title: String(repeating: "x", count: 256), subtitle: "deniz.k"))
        #expect(rows.last == SourceRow(id: "9999", title: "ornek.dev"))
        #expect(sink.lines == ["list returned more than 10000 rows; kept the first 10000"])
    }

    /// The id goes back to `run` exactly as listed: never cleaned or cut, so one it could not carry is refused.
    @Test func anIdGoesBackAsListed() async throws {
        let js = listing(#"{ rows: [{ id: " 4\t2 ", title: "ornek.dev" }] }"#)
        #expect(try await list(js) == .listing(.rows([SourceRow(id: " 4\t2 ", title: "ornek.dev")])))
    }

    /// Any other answer fails the whole listing; the reason names shapes and places, never what a row holds.
    @Test(arguments: [
        (#""ornek.dev""#, "list returned a string; expected {rows} or {locked}"),
        ("[]", "list returned an array; expected {rows} or {locked}"),
        ("undefined", "list returned nothing; expected {rows} or {locked}"),
        (#"{ items: [] }"#, "list returned an object of another shape; expected {rows} or {locked}"),
        (#"{ locked: false, message: "Kasa kilitli" }"#, "list returned an object of another shape; expected {rows} or {locked}"),
        (#"{ rows: "ornek.dev" }"#, "rows must be an array of {id, title, subtitle?}"),
        (#"{ rows: ["ornek.dev"] }"#, "rows[0] is a string; expected {id, title, subtitle?}"),
        (#"{ rows: [{ id: "1", title: "ornek.dev" }, { id: 2, title: "ornek.dev" }] }"#, "rows[1].id must be a non-empty string"),
        (#"{ rows: [{ id: "", title: "ornek.dev" }] }"#, "rows[0].id must be a non-empty string"),
        (#"{ rows: [{ id: "x".repeat(257), title: "ornek.dev" }] }"#, "rows[0].id is longer than 256 characters"),
        (#"{ rows: [{ id: "1", title: "ornek.dev" }, { id: "2", title: "deniz.k" }, { id: "1", title: "Kasa" }] }"#,
         "rows[2].id repeats an earlier row's id"),
        (#"{ rows: [{ id: "1", title: " \n " }] }"#, "rows[0].title must be a non-empty string"),
        (#"{ rows: [{ id: "1" }] }"#, "rows[0].title must be a non-empty string"),
        (#"{ rows: [{ id: "1", title: "ornek.dev", subtitle: 7 }] }"#, "rows[0].subtitle must be a string"),
        (#"{ locked: true }"#, "a locked listing needs a non-empty message"),
        (#"{ locked: true, message: " " }"#, "a locked listing needs a non-empty message"),
        (#"{ locked: true, message: "Kasa kilitli", command: ["vault", "login"] }"#, "command must be a string"),
    ])
    func everyOtherListingIsABadResult(answer: String, message: String) async throws {
        let error = await failure { try await list(listing(answer)) }
        #expect(error?.code == .badResult)
        #expect(error?.message == message)
    }

    /// A locked answer wins over rows that came with it.
    @Test func lockedWinsOverRows() async throws {
        let js = listing(#"{ locked: true, message: "Kasa kilitli", rows: [{ id: "1", title: "ornek.dev" }] }"#)
        #expect(try await list(js) == .listing(.locked(message: "Kasa kilitli", command: nil)))
    }

    @Test func aMissingSourceIsNotFound() async throws {
        let none = await failure { try await list("module.exports = { sources: {} };") }
        #expect(none?.code == .notFound)
        #expect(none?.message == "sources.vault.list is not exported")
        let noRun = await failure { try await run(#"module.exports = { sources: { vault: { list: () => ({ rows: [] }) } } };"#) }
        #expect(noRun?.code == .notFound)
        #expect(noRun?.message == "sources.vault.run is not exported")
    }

    /// The app always says which row and action a run is for.
    @Test func aRunWithoutItsRowIsRefused() async throws {
        let runtime = try RuntimeFixture.load(js: #"module.exports = { sources: { vault: { run: () => ({ secret: "s3cr3t-örnek" }) } } };"#)
        let error = await failure { try await runtime.invoke(.sourceRun, name: "vault", item: nil, context: context, effects: true) }
        #expect(error?.code == .badResult)
        #expect(error?.message == "a source run needs its row and action")
    }

    /// Both calls are the person's own: a source may run its tool, and its `ctx.signal` reaches the tool.
    @Test func aSourceMayRunItsTool() async throws {
        let tools = try ExecAPITests.tools(["fake": #"printf 'ornek.dev'"#])
        let js = #"""
        module.exports = { sources: { vault: { async list(ctx) {
          const r = await yab.exec("fake", [], { signal: ctx.signal });
          return { rows: [{ id: "1", title: r.stdout }] };
        } } } };
        """#
        let runtime = try ExecAPITests().runtime(js, tools: tools)
        let output = try await runtime.invoke(.sourceList, name: "vault", item: nil, context: context, effects: true)
        #expect(output == .listing(.rows([SourceRow(id: "1", title: "ornek.dev")])))
    }

    @Test func aSourceValueNeverPrintsItself() {
        for value in [SourceValue.secret("s3cr3t"), .text("s3cr3t")] {
            var dumped = ""
            dump(value, to: &dumped)
            dump(InvokeOutput.value(value), to: &dumped)
            let printed = ["\(value)", String(reflecting: value), dumped, "\(InvokeOutput.value(value))",
                           String(reflecting: HostMessage(id: 1, ok: .value(value))), "\(Mirror(reflecting: value).children.map(\.value))"]
            #expect(!printed.contains { $0.contains("s3cr3t") })
        }
        #expect("\(SourceValue.secret("s3cr3t"))" == "SourceValue.secret(<redacted>)")
        #expect("\(SourceValue.text("s3cr3t"))" == "SourceValue.text(<redacted>)")
    }

    @Test func blankIsWhitespaceOnly() {
        #expect(SourceValue.secret("").isBlank)
        #expect(SourceValue.text(" \t\r\n ").isBlank)
        #expect(!SourceValue.secret(" s3cr3t ").isBlank)
    }
}

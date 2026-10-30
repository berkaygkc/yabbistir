import Foundation
import Testing
import YabExtensionKit
@testable import YabExtensionRuntime

@Suite struct RuntimeTests {
    func run(_ js: String, log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> JSONValue {
        try await RuntimeFixture.load(js: js, log: log).call(.run, name: "a", arguments: [])
    }

    @Test func runReturnsAValue() async throws {
        #expect(try await run(#"exports.actions = { a: { run: () => ({ text: "ok" }) } };"#) == .object(["text": .string("ok")]))
    }

    @Test func asyncRunsAreAwaited() async throws {
        let js = #"exports.actions = { a: { async run() { await new Promise(r => setTimeout(r, 20)); return { text: "later" }; } } };"#
        #expect(try await run(js) == .object(["text": .string("later")]))
    }

    @Test func aThrowIsAScriptError() async throws {
        await #expect {
            _ = try await run(#"exports.actions = { a: { run() { throw new Error("nope"); } } };"#)
        } throws: { ($0 as? ExtensionError)?.code == .script && ($0 as? ExtensionError)?.message.contains("nope") == true }
    }

    /// A broken script fails loading with the line, and nothing else.
    @Test func aSyntaxErrorFailsLoadingWithTheLine() throws {
        let js = "exports.actions = {\n  a: { run() { return { text: \"ok\" }; } },\n  b: { run() { return { text: \"ok\" } ,, } },\n};"
        #expect {
            _ = try RuntimeFixture.load(js: js)
        } throws: { ($0 as? ExtensionError)?.code == .syntax && ($0 as? ExtensionError)?.message.contains("line 3") == true }
    }

    @Test func webStandardsWork() async throws {
        let js = #"""
        exports.actions = { a: { run() {
          const bytes = new TextEncoder().encode("ş");
          const b = btoa(String.fromCharCode(...bytes));
          const back = new TextDecoder().decode(Uint8Array.from(atob(b), c => c.charCodeAt(0)));
          const url = new URL("https://a.b/c?x=1");
          return { text: [back, crypto.randomUUID(), url.searchParams.get("x"), url.hostname].join("|") };
        } } };
        """#
        let parts = try #require(try await run(js)["text"]?.stringValue).split(separator: "|").map(String.init)
        #expect(parts[0] == "ş")
        #expect(parts[1].range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil)
        #expect(parts[2] == "1")
        #expect(parts[3] == "a.b")
    }

    @Test func nodeBuiltinsAreAbsent() async throws {
        let js = #"exports.actions = { a: { run: () => ({ text: [typeof require, typeof process, typeof Buffer].join(",") }) } };"#
        #expect(try await run(js) == .object(["text": .string("undefined,undefined,undefined")]))
    }

    @Test func consoleGoesToTheLog() async throws {
        let sink = LogSink()
        _ = try await run(#"exports.actions = { a: { run() { console.log("merhaba", 2); return { text: "" }; } } };"#, log: sink.append)
        #expect(sink.lines.contains("merhaba 2"))
    }

    @Test func unknownActionIsNotFound() async throws {
        let runtime = try RuntimeFixture.load(js: "exports.actions = {};")
        await #expect {
            _ = try await runtime.call(.run, name: "missing", arguments: [])
        } throws: { ($0 as? ExtensionError)?.code == .notFound }
    }
}

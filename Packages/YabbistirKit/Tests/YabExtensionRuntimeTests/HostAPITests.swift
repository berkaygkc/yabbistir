import Foundation
import Testing
import YabExtensionKit
@testable import YabExtensionRuntime

@Suite struct HostAPITests {
    let locales: [String: [String: Any]] = [
        "en": ["name": "Fixture", "keywords": ["fixture"], "hello": "Hello {name}", "only.en": "Only English"],
        "tr": ["hello": "Merhaba {name}"],
    ]
    let copiedAt = ISO8601DateFormatter().date(from: "2026-10-28T10:00:00Z")!

    func context(_ language: String = "tr", preferences: [String: JSONValue] = [:]) -> ExtensionContext {
        ExtensionContext(language: language, preferences: preferences, trigger: .search)
    }

    func text(_ output: InvokeOutput) -> String? {
        if case .result(.text(let text)) = output { text } else { nil }
    }

    @Test func anItemReachesJavaScriptAsIs() async throws {
        let js = #"exports.actions = { a: { run: (item) => ({ text: [item.kind, item.color.hex, item.color.r, item.tags[0], item.source.name, item.copiedAt].join("|") }) } };"#
        let item = ExtensionItem(id: 7, kind: "color", color: .init(hex: "#6E56CF", r: 110, g: 86, b: 207, a: 1),
                                 tags: ["dev.yabbistir.base64:base64"], source: .init(name: "TextEdit", bundleID: "com.apple.TextEdit", device: "local"),
                                 copiedAt: copiedAt)
        let output = try await RuntimeFixture.load(js: js).invoke(.run, name: "a", item: item, context: context())
        #expect(text(output) == "color|#6E56CF|110|dev.yabbistir.base64:base64|TextEdit|2026-10-28T10:00:00Z")
    }

    @Test func translationsFollowTheFallback() async throws {
        let js = #"exports.actions = { a: { run: () => ({ text: yab.t("hello", { name: "Ada" }) + "|" + yab.t("only.en") + "|" + yab.language }) } };"#
        let output = try await RuntimeFixture.load(js: js, locales: locales).invoke(.run, name: "a", item: nil, context: context("tr"))
        #expect(text(output) == "Merhaba Ada|Only English|tr")
    }

    /// Review I3: huge numbers and array lengths from JavaScript never trap the host.
    @Test func hugeNumbersNeverTrap() async throws {
        let js = #"exports.actions = { a: { run: () => ({ text: yab.t("count", { n: 1e300 }) + "|" + yab.t("count", { n: -Infinity }) }) } };"#
        let output = try await RuntimeFixture.load(js: js, locales: ["en": ["name": "F", "keywords": ["f"], "count": "{n} items"]])
            .invoke(.run, name: "a", item: nil, context: context())
        #expect(text(output)?.hasSuffix("items") == true)
        let sparse = #"exports.actions = { a: { run: () => { const a = []; a.length = 4294967295; return { text: "x", extra: a }; } } };"#
        _ = try? await RuntimeFixture.load(js: sparse).invoke(.run, name: "a", item: nil, context: context())
    }

    @Test func preferencesComeFromTheContext() async throws {
        let js = #"exports.actions = { a: { run: (item, ctx) => ({ text: String(ctx.preferences.uppercase) + String(yab.preferences.uppercase) }) } };"#
        let output = try await RuntimeFixture.load(js: js).invoke(.run, name: "a", item: nil, context: context(preferences: ["uppercase": .bool(true)]))
        #expect(text(output) == "truetrue")
    }

    /// The app's target reaches JavaScript as `ctx.target`, and `null` when there is none.
    @Test func theTargetReachesJavaScript() async throws {
        let js = #"exports.actions = { a: { run: (item, ctx) => ({ text: ctx.target === null ? "null" : [ctx.target.kind, ctx.target.bundleID, ctx.target.name].join("|") }) } };"#
        let runtime = try RuntimeFixture.load(js: js)
        let finder = ExtensionContext(language: "tr", trigger: .search,
                                      target: TargetInfo(bundleID: "com.apple.finder", name: "Finder", kind: .finder))
        #expect(text(try await runtime.invoke(.run, name: "a", item: nil, context: finder)) == "finder|com.apple.finder|Finder")
        #expect(text(try await runtime.invoke(.run, name: "a", item: nil, context: context())) == "null")
    }

    @Test func storageSurvivesAReload() async throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("yab-data-\(UUID().uuidString)")
        let writer = try RuntimeFixture.load(js: #"exports.actions = { a: { run() { yab.storage.set("k", { a: 1 }); return { text: "" }; } } };"#, dataFolder: data)
        _ = try await writer.invoke(.run, name: "a", item: nil, context: context())
        let reader = try RuntimeFixture.load(js: #"exports.actions = { a: { run: () => ({ text: String(yab.storage.get("k").a) + String(yab.storage.get("missing")) }) } };"#, dataFolder: data)
        #expect(text(try await reader.invoke(.run, name: "a", item: nil, context: context())) == "1undefined")
    }

    @Test func storageIsCappedAtOneMegabyte() async throws {
        let js = #"exports.actions = { a: { run() { try { yab.storage.set("big", "x".repeat(1100000)); return { text: "stored" }; } catch (e) { return { text: "threw" }; } } } };"#
        #expect(text(try await RuntimeFixture.load(js: js).invoke(.run, name: "a", item: nil, context: context())) == "threw")
    }

    @Test func everyResultShapeParses() async throws {
        let js = #"""
        exports.actions = {
          text: { run: () => ({ text: "a" }) },
          html: { run: () => ({ html: "<b>a</b>", text: "a" }) },
          link: { run: () => ({ link: { url: "https://yabbistir.dev", title: "yabbistir" } }) },
          none: { run: () => ({ none: true, message: "done" }) },
          bad: { run: () => ({ foo: 1 }) },
        };
        """#
        let runtime = try RuntimeFixture.load(js: js)
        func result(_ name: String) async throws -> InvokeOutput { try await runtime.invoke(.run, name: name, item: nil, context: context()) }
        #expect(try await result("text") == .result(.text("a")))
        #expect(try await result("html") == .result(.html(html: "<b>a</b>", text: "a")))
        #expect(try await result("link") == .result(.link(url: "https://yabbistir.dev", title: "yabbistir")))
        #expect(try await result("none") == .result(.none(message: "done")))
        await #expect { _ = try await result("bad") } throws: { ($0 as? ExtensionError)?.code == .badResult }
    }

    /// A bad result's reason goes to the Development log, so it never quotes what the
    /// run returned (it may come from the clipboard).
    @Test func aBadResultDoesNotQuoteWhatWasReturned() async throws {
        let js = #"exports.actions = { a: { run: (item) => item.text } };"#
        let item = ExtensionItem(id: 1, kind: "text", text: "my secret note", copiedAt: copiedAt)
        let runtime = try RuntimeFixture.load(js: js)
        do throws(ExtensionError) {
            _ = try await runtime.invoke(.run, name: "a", item: item, context: context())
            Issue.record("expected a failure")
        } catch {
            #expect(error.code == .badResult)
            #expect(error.message.hasPrefix("run returned a string;"))
            #expect(!error.message.contains("secret"))
        }
    }

    @Test func previewSectionsParse() async throws {
        let js = #"""
        exports.detectors = { d: {
          validate: (item) => item.text.length > 3,
          preview: () => [{ type: "code", title: "Çözülmüş hali", code: "Hello" }, { type: "keyValue", title: "Bilgi", rows: [["a", "b"]] }],
        } };
        """#
        let runtime = try RuntimeFixture.load(js: js)
        let item = ExtensionItem(id: 1, kind: "text", text: "SGVsbG8=", copiedAt: copiedAt)
        #expect(try await runtime.invoke(.validate, name: "d", item: item, context: context()) == .valid(true))
        #expect(try await runtime.invoke(.preview, name: "d", item: item, context: context())
            == .sections([.code(title: "Çözülmüş hali", code: "Hello", language: nil), .keyValue(title: "Bilgi", rows: [["a", "b"]])]))
    }
}

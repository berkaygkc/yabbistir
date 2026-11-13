import Foundation
import Testing
import YabCore
import YabExtensionKit
import YabLocalization
import YabTestSupport
@testable import YabExtensions

/// Secret and folder preferences. Only synthetic values are used here.
@MainActor @Suite struct SecretTests {
    let suiteName = TestScratch.suiteName("yab-secret")
    let defaults: UserDefaults
    let secrets = InMemorySecretStore()
    let settings: ExtensionSettings
    let registry: ExtensionRegistry
    let library: Library

    init() throws {
        defaults = UserDefaults(suiteName: suiteName)!
        settings = ExtensionSettings(defaults: defaults, secrets: secrets)
        registry = ExtensionRegistry(builtInRoot: RegistryFixture.temporary("BuiltinExtensions"), userRoot: RegistryFixture.temporary("Extensions"),
                                     dataRoot: RegistryFixture.temporary("Data"), settings: settings)
        library = try Library(store: ItemStore(directory: TestScratch.url("items")))
    }

    func install(_ id: String, preferences: [[String: Any]], js: String) throws {
        var manifest = RegistryFixture.manifest(id: id)
        manifest["preferences"] = preferences
        let folder = try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: id, manifest: manifest)
        try js.write(to: folder.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        try registry.install(folder: folder)
    }

    func service(transport: any HostTransport = PipeTransport()) -> ExtensionService {
        let language = LanguageStore(defaults: TestScratch.defaults("yab-secret-lang"), preferredLanguages: ["en"])
        return ExtensionService(registry: registry, client: ExtensionHostClient(transport: transport) { _, _ in }, library: library,
                                settings: settings, language: language)
    }

    func text(_ service: ExtensionService, _ id: String) async throws -> String {
        let command = try #require(service.commands(matching: "kx", subjectID: nil).first { $0.extensionID == id })
        guard case .text(let text) = try await service.output(of: command, subjectID: nil) else { Issue.record("expected text"); return "" }
        return text
    }

    static let tokenPreference: [[String: Any]] = [["id": "token", "type": "secret", "title": "upper"]]

    @Test func secretsLiveOnlyInTheKeychain() throws {
        try install("dev.example.s", preferences: Self.tokenPreference, js: "exports.actions = {};")
        let specs = try #require(registry.installed.first?.manifest?.preferences)
        try settings.setSecret("sk-synthetic-1", "dev.example.s", "token")
        #expect(secrets.read("dev.example.s", "token") == "sk-synthetic-1")
        #expect(settings.hasSecret("dev.example.s", "token"))
        let dump = defaults.persistentDomain(forName: suiteName).map { "\($0)" } ?? ""
        #expect(!dump.contains("sk-synthetic-1"))
        #expect(!defaults.dictionaryRepresentation().values.contains { "\($0)".contains("sk-synthetic-1") })
        // The generic preference path refuses a secret's key.
        #expect(!settings.setPreference("dev.example.s", "token", .string("sk-synthetic-2"), specs: specs))
        #expect(defaults.data(forKey: "preferences.dev.example.s") == nil)
        #expect(settings.preferences("dev.example.s", specs: specs)["token"] == nil)
        try settings.setSecret(nil, "dev.example.s", "token")
        #expect(!settings.hasSecret("dev.example.s", "token"))
    }

    @Test func removingAnExtensionRemovesItsSecrets() throws {
        try install("dev.example.s", preferences: Self.tokenPreference, js: "exports.actions = {};")
        try settings.setSecret("sk-synthetic-1", "dev.example.s", "token")
        try registry.uninstall("dev.example.s")
        #expect(secrets.read("dev.example.s", "token") == nil)
    }

    @Test func anotherExtensionCannotReadASecret() async throws {
        let js = #"exports.actions = { a: { run: () => ({ text: String(yab.secrets.get("token")) }) } };"#
        try install("dev.example.a", preferences: Self.tokenPreference, js: js)
        try install("dev.example.b", preferences: [], js: js)
        registry.approveRequested("dev.example.a")
        registry.approveRequested("dev.example.b")
        try settings.setSecret("sk-synthetic-a", "dev.example.a", "token")
        try secrets.write("sk-synthetic-b", "dev.example.b", "token") // stored, but b never declared it

        let transport = FakeTransport { request in
            request.load != nil ? HostMessage(id: request.id, done: true) : HostMessage(id: request.id, ok: .result(.text("ok")))
        }
        let fake = service(transport: transport)
        _ = try await text(fake, "dev.example.a")
        _ = try await text(fake, "dev.example.b")
        let loads = transport.requests.compactMap(\.load)
        #expect(loads.first { $0.extensionID == "dev.example.a" }?.secrets == ["token": "sk-synthetic-a"])
        #expect(loads.first { $0.extensionID == "dev.example.b" }?.secrets == [:])

        let real = service()
        #expect(try await text(real, "dev.example.a") == "sk-synthetic-a")
        #expect(try await text(real, "dev.example.b") == "null")
    }

    @Test func secretsAreNotInPreferences() async throws {
        let js = #"exports.actions = { a: { run: (item, ctx) => ({ text: JSON.stringify(ctx) + JSON.stringify(yab.preferences) }) } };"#
        try install("dev.example.s", preferences: Self.tokenPreference + [["id": "shout", "type": "toggle", "title": "upper", "default": false]], js: js)
        try settings.setSecret("sk-synthetic-1", "dev.example.s", "token")
        let shown = try await text(service(), "dev.example.s")
        #expect(shown.contains("shout"))
        #expect(!shown.contains("sk-synthetic-1"))
        #expect(!shown.contains("token"))

        let transport = FakeTransport { request in
            request.load != nil ? HostMessage(id: request.id, done: true) : HostMessage(id: request.id, ok: .result(.text("ok")))
        }
        _ = try await text(service(transport: transport), "dev.example.s")
        let context = try #require(transport.requests.compactMap(\.invoke).first?.context)
        #expect(context.preferences["token"] == nil)
    }

    @Test func aSecretReachesItsExtension() async throws {
        let js = #"""
        const early = yab.secrets.get("token");
        exports.actions = { a: { run: () => ({ text: [early, yab.secrets.get("token"), yab.secrets.get("nope")].join("|") }) } };
        """#
        try install("dev.example.s", preferences: Self.tokenPreference, js: js)
        try settings.setSecret("abc", "dev.example.s", "token")
        #expect(try await text(service(), "dev.example.s") == "abc|abc|")
    }

    @Test func aFolderPreferenceCanBeRead() async throws {
        let chosen = RegistryFixture.temporary("chosen")
        let outside = RegistryFixture.temporary("outside")
        try "inside".write(to: chosen.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "outside".write(to: outside.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: chosen.appendingPathComponent("escape.txt"), withDestinationURL: outside.appendingPathComponent("b.txt"))
        let js = #"""
        exports.actions = { a: { run: () => {
          const dir = yab.preferences.dir;
          const read = new TextDecoder().decode(yab.files.read(dir + "/a.txt"));
          let denied = "no", escaped = "no", wrote = "no";
          try { yab.files.read(\#(jsString(outside.appendingPathComponent("b.txt").path))); } catch (e) { denied = e.code; }
          try { yab.files.read(dir + "/escape.txt"); } catch (e) { escaped = e.code; }
          try { yab.files.write(dir + "/x.txt", "x"); wrote = "yes"; } catch (e) { wrote = "no"; }
          return { text: [read, yab.files.exists(dir + "/a.txt"), yab.files.exists(dir + "/escape.txt"),
                          yab.files.exists(\#(jsString(outside.appendingPathComponent("b.txt").path))), denied, escaped].join("|") };
        } } };
        """#
        try install("dev.example.f", preferences: [["id": "dir", "type": "folder", "title": "upper"]], js: js)
        _ = settings.setFolder("dev.example.f", "dir", chosen.path, specs: registry.installed[0].manifest!.preferences)
        let answer = try await text(service(), "dev.example.f")
        #expect(answer.hasPrefix("inside|true|false|false|"))
        #expect(answer.hasSuffix("|badResult|badResult"))
        #expect(!FileManager.default.fileExists(atPath: chosen.appendingPathComponent("x.txt").path))
    }

    @Test func aManifestDefaultFolderIsNotReadableUntilChosen() async throws {
        let name = ".yab-test-\(UUID().uuidString)"
        let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "inside".write(to: home.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let js = #"""
        exports.actions = { a: { run: () => {
          const path = yab.preferences.dir + "/a.txt";
          let first = "read";
          try { yab.files.read(path); } catch (e) { first = e.code; }
          return { text: [yab.preferences.dir.length > 0, first, yab.files.exists(path)].join("|") };
        } } };
        """#
        try install("dev.example.f", preferences: [["id": "dir", "type": "folder", "title": "upper", "default": "~/\(name)"]], js: js)
        let specs = try #require(registry.installed.first?.manifest?.preferences)
        let service = service()
        #expect(try await text(service, "dev.example.f") == "true|badResult|false")
        _ = settings.setFolder("dev.example.f", "dir", home.path, specs: specs)
        #expect(try await text(service, "dev.example.f") == "true|read|true")
    }

    @Test func uninstallingAlwaysClearsSecrets() throws {
        try install("dev.example.s", preferences: Self.tokenPreference, js: "exports.actions = {};")
        try settings.setSecret("sk-synthetic-1", "dev.example.s", "token")
        try registry.uninstall("dev.example.s")
        #expect(secrets.accounts.filter { $0.hasPrefix("dev.example.s/") && secrets.read("dev.example.s", "token") != nil }.isEmpty)
        #expect(secrets.read("dev.example.s", "token") == nil)
    }

    @Test func aFolderDefaultWithATildeIsExpanded() throws {
        try install("dev.example.f", preferences: [["id": "dir", "type": "folder", "title": "upper", "default": "~/Downloads"]], js: "exports.actions = {};")
        let specs = try #require(registry.installed.first?.manifest?.preferences)
        #expect(settings.preferences("dev.example.f", specs: specs)["dir"] == .string(NSHomeDirectory() + "/Downloads"))
        _ = settings.setFolder("dev.example.f", "dir", "~/Desktop", specs: specs)
        #expect(settings.preferences("dev.example.f", specs: specs)["dir"] == .string(NSHomeDirectory() + "/Desktop"))
        #expect(settings.chosenFolders("dev.example.f", specs: specs) == [NSHomeDirectory() + "/Desktop"])
        // Cleared, the default is back in `ctx.preferences`, and nothing is chosen.
        _ = settings.setFolder("dev.example.f", "dir", nil, specs: specs)
        #expect(settings.preferences("dev.example.f", specs: specs)["dir"] == .string(NSHomeDirectory() + "/Downloads"))
        #expect(settings.chosenFolders("dev.example.f", specs: specs).isEmpty)
    }

    static func specs(_ list: [[String: Any]]) throws -> [PreferenceSpec] {
        try JSONDecoder().decode([PreferenceSpec].self, from: JSONSerialization.data(withJSONObject: list))
    }

    /// Whether `text` is anywhere in the defaults suite, in a string or in stored bytes (preferences are JSON data).
    func defaultsHold(_ text: String) -> Bool {
        func holds(_ value: Any) -> Bool {
            switch value {
            case let data as Data: data.range(of: Data(text.utf8)) != nil
            case let dictionary as [String: Any]: dictionary.values.contains(where: holds)
            case let array as [Any]: array.contains(where: holds)
            default: "\(value)".contains(text)
            }
        }
        return (defaults.persistentDomain(forName: suiteName) ?? [:]).values.contains(where: holds)
    }

    /// An update that turns a text preference into a folder does not make the path typed into it
    /// readable, nor the folder's value.
    @Test func aPathTypedBeforeAnUpdateIsNotAChosenFolder() async throws {
        let typed = RegistryFixture.temporary("typed")
        try "inside".write(to: typed.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let js = #"""
        exports.actions = { a: { run: (item, ctx) => {
          let read = "read";
          try { yab.files.read(\#(jsString(typed.path)) + "/a.txt"); } catch (e) { read = e.code; }
          return { text: [String(ctx.preferences.dir), read].join("|") };
        } } };
        """#
        // Version 1 took a text, and the person typed a path there.
        let before = try Self.specs([["id": "dir", "type": "text", "title": "upper"]])
        #expect(settings.setPreference("dev.example.f", "dir", .string(typed.path), specs: before))
        // Version 2 makes it a folder.
        try install("dev.example.f", preferences: [["id": "dir", "type": "folder", "title": "upper"]], js: js)
        let after = try #require(registry.installed.first?.manifest?.preferences)
        #expect(settings.chosenFolders("dev.example.f", specs: after).isEmpty)
        let service = service()
        #expect(try await text(service, "dev.example.f") == "null|badResult")
        // Nor does a value typed now.
        #expect(!settings.setPreference("dev.example.f", "dir", .string(typed.path), specs: after))
        #expect(settings.chosenFolders("dev.example.f", specs: after).isEmpty)
        // Picked in Settings, it is both.
        #expect(settings.setFolder("dev.example.f", "dir", typed.path, specs: after))
        #expect(settings.chosenFolders("dev.example.f", specs: after) == [typed.path])
        #expect(try await text(service, "dev.example.f") == "\(typed.path)|read")
        // The picker takes folder preferences only.
        #expect(!settings.setFolder("dev.example.f", "other", typed.path, specs: after))
        #expect(!settings.setFolder("dev.example.f", "dir", typed.path, specs: before))
    }

    /// An update that turns a text preference into a secret leaves nothing of what was typed in
    /// UserDefaults once the preferences are read, and hands it to nobody.
    @Test func aTextTurnedSecretLeavesNoPlaintextBehind() throws {
        let before = try Self.specs([["id": "token", "type": "text", "title": "upper"], ["id": "name", "type": "text", "title": "upper"]])
        #expect(settings.setPreference("dev.example.s", "token", .string("sk-synthetic-typed"), specs: before))
        #expect(settings.setPreference("dev.example.s", "name", .string("kept"), specs: before))
        #expect(defaultsHold("sk-synthetic-typed"))
        let after = try Self.specs([["id": "token", "type": "secret", "title": "upper"], ["id": "name", "type": "text", "title": "upper"]])
        #expect(settings.preferences("dev.example.s", specs: after) == ["name": .string("kept")])
        #expect(!defaultsHold("sk-synthetic-typed"))
        #expect(settings.secrets("dev.example.s", specs: after).isEmpty)
        // What else was stored stays.
        #expect(settings.preferences("dev.example.s", specs: before) == ["token": .null, "name": .string("kept")])
    }

    @Test func theRealKeychainRoundTrips() throws {
        let store = KeychainSecretStore(service: "dev.yabbistir.test.\(UUID().uuidString)")
        defer { try? store.write(nil, "dev.example.k", "token") }
        #expect(store.read("dev.example.k", "token") == nil)
        try store.write("synthetic-value", "dev.example.k", "token")
        #expect(store.read("dev.example.k", "token") == "synthetic-value")
        try store.write("synthetic-other", "dev.example.k", "token")
        #expect(store.read("dev.example.k", "token") == "synthetic-other")
        try store.write(nil, "dev.example.k", "token")
        #expect(store.read("dev.example.k", "token") == nil)
    }

    private func jsString(_ text: String) -> String {
        String(data: (try? JSONEncoder().encode(text)) ?? Data(), encoding: .utf8) ?? "\"\""
    }
}

import Foundation
import Testing
import YabCore
import YabExtensionKit
import YabLocalization
import YabPasteboard
import YabTestSupport
@testable import YabExtensions

/// A variant that names one of its extension's toggle preferences is offered only while that toggle is on, read from
/// Settings at every call: the ⇧ panel, ⌘K and ⇧↵ (all from `transforms`) and search (`commands(matching:)`).
@MainActor @Suite struct VariantPreferenceTests {
    static let id = "dev.example.send"
    let library: Library
    let settings = ExtensionSettings(defaults: TestScratch.defaults("yab-variant"))
    let registry: ExtensionRegistry
    let service: ExtensionService

    /// "send" has a variant per app, each shown by its toggle, plus one tied to a text preference, one to a preference
    /// that doesn't exist and one tied to nothing; "pin" has two variants, both tied to toggles; "upper" has none.
    static var manifest: [String: Any] {
        func toggle(_ id: String, _ on: Bool) -> [String: Any] { ["id": id, "type": "toggle", "title": "name", "default": on] }
        func variant(_ id: String, _ preference: String? = nil) -> [String: Any] {
            var variant: [String: Any] = ["id": id, "title": "name"]
            if let preference { variant["preference"] = preference }
            return variant
        }
        func action(_ id: String, output: String = "text", variants: [[String: Any]] = []) -> [String: Any] {
            ["id": id, "title": "name", "keywords": "keywords", "input": "item", "accepts": ["kinds": ["text"]], "output": output,
             "variants": variants]
        }
        var manifest = RegistryFixture.manifest(id: id)
        manifest["preferences"] = [toggle("things", true), toggle("bear", true), toggle("notes", false),
                                   ["id": "vault", "type": "text", "title": "name"]]
        manifest["contributes"] = ["actions": [
            action("send", output: "none", variants: [variant("things", "things"), variant("bear", "bear"), variant("notes", "notes"),
                                                      variant("vault", "vault"), variant("missing", "nowhere"), variant("plain")]),
            action("pin", variants: [variant("a", "bear"), variant("b", "notes")]),
            action("upper"),
        ]]
        return manifest
    }

    init() throws {
        library = try Library(store: ItemStore(directory: TestScratch.url("items")))
        registry = ExtensionRegistry(builtInRoot: RegistryFixture.temporary("BuiltinExtensions"), userRoot: RegistryFixture.temporary("Extensions"),
                                     dataRoot: RegistryFixture.temporary("Data"), settings: settings)
        let language = LanguageStore(defaults: TestScratch.defaults("yab-variant-lang"), preferredLanguages: ["en"])
        language.language = .english
        service = ExtensionService(registry: registry, client: ExtensionHostClient(transport: PipeTransport()) { _, _ in },
                                   library: library, settings: settings, language: language)
        let folder = try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: Self.id, manifest: Self.manifest)
        try JSONSerialization.data(withJSONObject: ["name": "Send", "keywords": ["send"]])
            .write(to: folder.appendingPathComponent("locales/en.json"))
        try registry.install(folder: folder)
    }

    func ingest(_ text: String) throws -> Int64 {
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(text.utf8))]],
                                source: nil, device: .local, capturedAt: Date())
        let item = try #require(try library.store.ingest(clip)).item
        library.didIngest(item)
        return try #require(item.id)
    }

    /// What the ⇧ panel lists for the item, without the built-ins: "send#things" for "dev.example.send/send#things".
    func offered(_ item: Int64) -> [String] {
        service.transforms(forItemID: item).filter { $0.extensionID == Self.id }.map { String($0.id.dropFirst(Self.id.count + 1)) }
    }

    func searched(_ query: String, on item: Int64) -> [String] {
        service.commands(matching: query, subjectID: item).filter { $0.extensionID == Self.id }.map { String($0.id.dropFirst(Self.id.count + 1)) }
    }

    func set(_ key: String, _ on: Bool) throws {
        let specs = try #require(registry.installed.first { $0.id == Self.id }?.manifest?.preferences)
        #expect(settings.setPreference(Self.id, key, .bool(on), specs: specs))
    }

    @Test func aVariantShowsWhileItsToggleIsOn() throws {
        let item = try ingest("buy oat milk")
        // "notes" is off by default: its "send" variant and "pin#b" are not offered.
        #expect(offered(item) == ["send#things", "send#bear", "send#vault", "send#missing", "send#plain", "pin#a", "upper"])
        // Read at every call: switched in Settings, the very next list follows.
        try set("things", false)
        try set("notes", true)
        #expect(offered(item) == ["send#bear", "send#notes", "send#vault", "send#missing", "send#plain", "pin#a", "pin#b", "upper"])
    }

    @Test func anActionWhoseVariantsAreAllOffIsGone() throws {
        let item = try ingest("buy oat milk")
        try set("bear", false)
        #expect(!offered(item).contains { $0.hasPrefix("pin") })
        try set("notes", true)
        #expect(offered(item).filter { $0.hasPrefix("pin") } == ["pin#b"])
    }

    /// A preference that doesn't exist, or isn't a toggle, never hides its variant; nor does a variant tied to nothing.
    @Test func aVariantWhosePreferenceIsNoToggleStaysOffered() throws {
        let item = try ingest("buy oat milk")
        for key in ["things", "bear"] { try set(key, false) }
        #expect(offered(item) == ["send#vault", "send#missing", "send#plain", "upper"])
        let commands = service.catalog.commands.filter { $0.extensionID == Self.id }
        #expect(commands.first { $0.variant == "vault" }?.preference == nil)
        #expect(commands.first { $0.variant == "missing" }?.preference == nil)
        #expect(commands.first { $0.variant == "bear" }?.preference == "bear")
    }

    /// Search by keyword offers what the ⇧ panel does, and no more.
    @Test func searchLeavesHiddenVariantsOut() throws {
        let item = try ingest("note to self")
        // Search orders by priority and title, all alike here: compared as sets.
        #expect(Set(searched("send", on: item)) == ["send#things", "send#bear", "send#vault", "send#missing", "send#plain", "pin#a", "upper"])
        try set("bear", false)
        #expect(Set(searched("send", on: item)) == ["send#things", "send#vault", "send#missing", "send#plain", "upper"])
    }

    /// One that names no toggle reaches Settings → Extensions → Development as a warning, once, and keeps nothing off.
    @Test func aPreferenceThatNamesNoToggleIsLogged() throws {
        let user = RegistryFixture.temporary("Extensions")
        try RegistryFixture.write(in: user, id: Self.id, manifest: Self.manifest)
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let lines = Lines()
        let registry = ExtensionRegistry(builtInRoot: RegistryFixture.temporary("BuiltinExtensions"), userRoot: user,
                                         dataRoot: RegistryFixture.temporary("Data"), settings: settings) { _, line in lines.all.append(line) }
        #expect(lines.all == [
            "\(Self.id): contributes.actions[0].variants[3].preference: \"vault\" is a text preference, not a toggle; this variant is always offered",
            "\(Self.id): contributes.actions[0].variants[4].preference: there is no preference \"nowhere\"; this variant is always offered",
        ])
        #expect(try #require(registry.installed.first { $0.id == Self.id }).isUsable)
    }

    /// Actions without variants, and the built-ins' variants (tied to nothing), are offered as before.
    @Test func everythingElseIsAsBefore() throws {
        let builtIns = ExtensionRegistry(builtInRoot: BuiltinFolder.root, userRoot: RegistryFixture.temporary("Extensions"),
                                         dataRoot: RegistryFixture.temporary("Data"), settings: settings)
        let catalog = CommandCatalog(installed: builtIns.installed, language: "en")
        #expect(!catalog.commands.isEmpty)
        #expect(catalog.commands.allSatisfy { $0.preference == nil })
        #expect(CommandCatalog.offered(catalog.commands) { _ in [:] } == catalog.commands)
    }

    /// The pure rule: on is `true`; off, missing or anything else hides; each extension's values are read once.
    @Test func offeredReadsEachExtensionOnce() {
        func command(_ id: String, _ preference: String?) -> ExtensionCommand {
            ExtensionCommand(id: "dev.example.a/send#\(id)", extensionID: "dev.example.a", extensionName: "A", icon: "sf:paperplane", title: id,
                             subtitle: nil, keywords: [], input: .item, output: .none, hint: false, priority: 0, actionID: "send", variant: id,
                             source: .local, accepts: nil, preference: preference)
        }
        let commands = [command("on", "on"), command("off", "off"), command("unset", "unset"), command("text", "text"), command("free", nil)]
        var reads = 0
        let offered = CommandCatalog.offered(commands) { _ in
            reads += 1
            return ["on": .bool(true), "off": .bool(false), "text": .string("true")]
        }
        #expect(offered.map(\.title) == ["on", "free"])
        #expect(reads == 1)
    }
}

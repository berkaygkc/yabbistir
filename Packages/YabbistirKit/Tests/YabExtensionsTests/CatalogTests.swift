import Foundation
import Testing
import YabCore
import YabExtensionKit
import YabPasteboard
import YabTestSupport
@testable import YabExtensions

/// The built-ins as built by `make extensions`.
enum BuiltinFolder {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Extensions/BuiltinExtensions")
}

@MainActor @Suite struct CatalogTests {
    let settings = ExtensionSettings(defaults: TestScratch.defaults("yab-cat"))
    let registry: ExtensionRegistry

    init() {
        registry = ExtensionRegistry(builtInRoot: BuiltinFolder.root, userRoot: RegistryFixture.temporary("Extensions"),
                                     dataRoot: RegistryFixture.temporary("Data"), settings: settings)
    }

    func catalog(_ language: String = "tr") -> CommandCatalog { CommandCatalog(installed: registry.installed, language: language) }

    func text(_ text: String, tags: [String] = []) -> ExtensionItem {
        ExtensionItem(id: 1, kind: "text", text: text, tags: tags, copiedAt: Date())
    }

    var base64Item: ExtensionItem { text("SGVsbG8sIGTDvG55YQ==", tags: ["dev.yabbistir.base64:base64"]) }

    @Test func twoLettersFindCommandsByKeywordPrefix() {
        let catalog = catalog("en")
        #expect(catalog.commands(matching: "uu", subject: nil).map(\.id) == ["dev.yabbistir.uuid/v4", "dev.yabbistir.uuid/v7"])
        #expect(catalog.commands(matching: "u", subject: nil).isEmpty)
        #expect(catalog.commands(matching: "uuid v7", subject: nil).map(\.id).contains("dev.yabbistir.uuid/v7"))
    }

    /// Turkish keywords match however they are typed.
    @Test func turkishKeywordsMatchFolded() {
        for query in ["ÇÖZ", "çöz", "coz"] {
            #expect(catalog("tr").commands(matching: query, subject: base64Item).map(\.id).contains("dev.yabbistir.base64/decode"), "\(query)")
        }
    }

    @Test func transformsNeedAnAcceptedSubject() {
        #expect(!catalog().transforms(for: text("merhaba dünya")).map(\.id).contains("dev.yabbistir.base64/decode"))
        #expect(catalog().transforms(for: text("merhaba dünya")).map(\.id).contains("dev.yabbistir.base64/encode"))
        #expect(catalog().transforms(for: base64Item).map(\.id).contains("dev.yabbistir.base64/decode"))
    }

    @Test func imageActionsTakeOneImageFileButNotOtherFiles() {
        func file(_ name: String, _ uti: String) -> ExtensionItem.FilePayload { .init(path: "/tmp/\(name)", name: name, size: 1, uti: uti) }
        let picture = ExtensionItem(id: 3, kind: "file", files: [file("a.png", "public.png")], copiedAt: Date())
        let heic = ExtensionItem(id: 4, kind: "file", files: [file("b.heic", "public.heic")], copiedAt: Date())
        let pdf = ExtensionItem(id: 5, kind: "file", files: [file("c.pdf", "com.adobe.pdf")], copiedAt: Date())
        let two = ExtensionItem(id: 6, kind: "file", files: [file("a.png", "public.png"), file("d.png", "public.png")], copiedAt: Date())
        #expect(catalog().transforms(for: picture).map(\.id).contains("dev.yabbistir.convert/ocr"))
        #expect(catalog().transforms(for: heic).map(\.id).contains("dev.yabbistir.convert/image#png"))
        #expect(!catalog().transforms(for: pdf).contains { $0.extensionID == "dev.yabbistir.convert" })
        #expect(!catalog().transforms(for: two).contains { $0.extensionID == "dev.yabbistir.convert" })
    }

    /// Whatever slips past validation, building the catalog and reading preferences never trap.
    @Test func duplicateIDsNeverTrap() throws {
        let json = """
        {"id":"dev.example.dup","version":"1.0.0","apiVersion":1,"defaultLocale":"en","name":"n","description":"n","icon":"sf:number",
         "author":"a","license":"MIT","categories":[],"permissions":[],
         "preferences":[{"id":"p","type":"toggle","title":"n","default":false},{"id":"p","type":"toggle","title":"n","default":true}],
         "contributes":{"actions":[{"id":"a","title":"n","keywords":"k","input":"none","output":"text",
                                    "variants":[{"id":"v","title":"n"},{"id":"v","title":"n"}]}]}}
        """
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
        let localization = ExtensionLocalization(tables: ["en": ["n": .string("N"), "k": .array([.string("dup")])]], defaultLocale: "en")
        let entry = InstalledExtension(id: manifest.id, folder: URL(fileURLWithPath: "/tmp/dup"), source: .local, manifest: manifest,
                                       localization: localization, issues: [], isEnabled: true)
        #expect(CommandCatalog(installed: [entry], language: "en").commands.count == 2)
        #expect(settings.preferences(manifest.id, specs: manifest.preferences)["p"] == .bool(false))
    }

    /// A failed job's title comes from the manifest in the catalog's language; a variant's own wins.
    @Test func aFailTitleIsTranslatedAndAVariantsOwnWins() throws {
        let json = """
        {"id":"dev.example.video","version":"1.0.0","apiVersion":1,"defaultLocale":"en","name":"n","description":"n","icon":"sf:film",
         "author":"a","license":"MIT","categories":[],"permissions":[],
         "contributes":{"actions":[
           {"id":"download","title":"video","keywords":"k","input":"none","output":"file","job":true,"failTitle":"video.failed",
            "variants":[{"id":"audio","title":"audio","failTitle":"audio.failed"},{"id":"video","title":"video"}]},
           {"id":"plain","title":"video","keywords":"k","input":"none","output":"text"}]}}
        """
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
        let localization = ExtensionLocalization(tables: [
            "en": ["n": .string("N"), "k": .array([.string("video")]), "video": .string("Download as Video"), "audio": .string("Download Audio"),
                   "video.failed": .string("Couldn’t download the video"), "audio.failed": .string("Couldn’t download the audio")],
            "tr": ["video": .string("Video olarak indir"), "audio": .string("Sesi indir"),
                   "video.failed": .string("Video indirilemedi"), "audio.failed": .string("Ses indirilemedi")],
        ], defaultLocale: "en")
        let entry = InstalledExtension(id: manifest.id, folder: URL(fileURLWithPath: "/tmp/video"), source: .local, manifest: manifest,
                                       localization: localization, issues: [], isEnabled: true)
        let turkish = Dictionary(uniqueKeysWithValues: CommandCatalog(installed: [entry], language: "tr").commands.map { ($0.id, $0) })
        #expect(turkish["dev.example.video/download#audio"]?.failTitle == "Ses indirilemedi")
        #expect(turkish["dev.example.video/download#video"]?.failTitle == "Video indirilemedi")
        #expect(turkish["dev.example.video/plain"].map { $0.failTitle == nil } == true)
        let english = CommandCatalog(installed: [entry], language: "en").commands.first { $0.id == "dev.example.video/download#audio" }
        #expect(english?.failTitle == "Couldn’t download the audio")
    }

    @Test func aFileIconBecomesItsPathAndASymbolStays() {
        let folder = URL(fileURLWithPath: "/tmp/ext")
        #expect(CommandCatalog.icon("icon.png", in: folder) == "/tmp/ext/icon.png")
        #expect(CommandCatalog.icon("sf:number", in: folder) == "sf:number")
        #expect(catalog().commands.first { $0.extensionID == "dev.yabbistir.uuid" }?.icon.hasPrefix("sf:") == true)
    }

    @Test func decodeOutranksEncodeOnBase64() {
        #expect(Array(catalog().transforms(for: base64Item).map(\.id).prefix(2)) == ["dev.yabbistir.base64/decode", "dev.yabbistir.base64/encode"])
    }

    static let finder = TargetInfo(bundleID: "com.apple.finder", name: "Finder", kind: .finder)
    static let editor = TargetInfo(bundleID: "dev.zed.Zed", name: "Zed", kind: .editor)

    /// A synthetic downloader made for Finder, beside the built-ins.
    func installDownloader() throws {
        var manifest = RegistryFixture.manifest(id: "dev.example.download")
        manifest["contributes"] = ["actions": [["id": "video", "title": "name", "keywords": "keywords", "input": "item",
                                                "accepts": ["kinds": ["link"]], "output": "file", "targets": ["finder"], "job": true]]]
        try registry.install(folder: try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: "dev.example.download", manifest: manifest))
    }

    var link: ExtensionItem {
        ExtensionItem(id: 7, kind: "link", text: "https://www.video.example/watch?v=yab-142", url: "https://www.video.example/watch?v=yab-142",
                      copiedAt: Date())
    }

    @Test func targetsComeFirstInFinder() throws {
        try installDownloader()
        let normal = catalog().transforms(for: link).map(\.id)
        #expect(normal.first == "dev.yabbistir.base64/encode")
        #expect(normal.contains("dev.example.download/video"))
        let inFinder = catalog().transforms(for: link, target: Self.finder).map(\.id)
        #expect(inFinder.first == "dev.example.download/video")
        #expect(Array(inFinder.prefix(2)) == ["dev.example.download/video", "dev.yabbistir.finderfile/file"])
        #expect(catalog().transforms(for: link, target: Self.editor).map(\.id) == normal)
        // Search leads with them too ("kodla" also reaches the downloader's keyword "k").
        #expect(catalog().commands(matching: "kodla", subject: link).map(\.id) == ["dev.yabbistir.base64/encode", "dev.example.download/video"])
        #expect(catalog().commands(matching: "kodla", subject: link, target: Self.finder).map(\.id)
            == ["dev.example.download/video", "dev.yabbistir.base64/encode"])
        // The rest keep their order: decode before encode on base64.
        #expect(catalog().transforms(for: base64Item, target: Self.finder).filter { $0.extensionID == "dev.yabbistir.base64" }.map(\.id)
            == ["dev.yabbistir.base64/decode", "dev.yabbistir.base64/encode"])
    }

    @Test func targetsOnlyHidesOutsideTheTarget() {
        let note = text("Toplantı notları")
        let isFinderFile = { (command: ExtensionCommand) in command.extensionID == "dev.yabbistir.finderfile" }
        #expect(catalog().transforms(for: note, target: Self.finder).contains(where: isFinderFile))
        #expect(!catalog().transforms(for: note, target: Self.editor).contains(where: isFinderFile))
        #expect(!catalog().transforms(for: note).contains(where: isFinderFile))
        #expect(catalog("en").commands(matching: "finder", subject: note, target: Self.finder).contains(where: isFinderFile))
        #expect(!catalog("en").commands(matching: "finder", subject: note, target: Self.editor).contains(where: isFinderFile))
        let command = catalog("tr").commands.first(where: isFinderFile)
        #expect(command?.title == "Finder’a dosya olarak yapıştır")
        #expect(command?.targets == [.finder])
        #expect(command?.targetsOnly == true)
    }

    @Test func variantsBecomeCommands() {
        let color = ExtensionItem(id: 2, kind: "color", color: .init(hex: "#6E56CF", r: 110, g: 86, b: 207, a: 1), copiedAt: Date())
        let commands = catalog("tr").transforms(for: color)
        #expect(commands.map(\.title) == ["RGB olarak", "HSL olarak", "OKLCH olarak", "SwiftUI Color olarak", "NSColor olarak"])
        #expect(commands.first?.id == "dev.yabbistir.convert/color#rgb")
        #expect(commands.first?.variant == "rgb")
    }

    @Test func disabledExtensionsOfferNothing() {
        registry.setEnabled("dev.yabbistir.base64", false)
        #expect(!catalog().transforms(for: base64Item).contains { $0.extensionID == "dev.yabbistir.base64" })
    }

    @Test func resultsBecomeRepresentations() {
        func types(_ result: ExtensionResult) -> [String] { ResultRepresentations.make(result).flatMap { $0.map(\.type) } }
        #expect(ResultRepresentations.make(.text("a")) == [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data("a".utf8))]])
        #expect(types(.html(html: "<b>a</b>", text: "a")) == ["public.html", TypeIdentifiers.plainText])
        #expect(types(.link(url: "https://yabbistir.dev", title: "yabbistir")) == [TypeIdentifiers.url, TypeIdentifiers.plainText, TypeIdentifiers.urlName])
        #expect(types(.image(data: Data([1]), uti: TypeIdentifiers.png, width: 1, height: 1)) == [TypeIdentifiers.png])
        #expect(types(.none(message: nil)).isEmpty)
    }

    /// A rule that takes a link, or a text that is one address and nothing else, decides it from its manifest alone:
    /// any other text never reaches its JavaScript, so a long one costs it nothing.
    @Test func anAddressPatternTakesOnlyASingleAddress() throws {
        let json = #"{ "kinds": ["link", "text"], "pattern": "(?i)^\\s*https?://\\S+\\s*$" }"#
        let accepts = try JSONDecoder().decode(AcceptSpec.self, from: Data(json.utf8))
        let catalog = CommandCatalog(installed: [], language: "en")
        let link = ExtensionItem(id: 1, kind: "link", text: "https://a.example/x?utm_source=y", url: "https://a.example/x?utm_source=y", copiedAt: Date())
        #expect(catalog.accepts(accepts, link))
        #expect(catalog.accepts(accepts, text("  https://a.example/x?fbclid=1 \n")))
        #expect(catalog.accepts(accepts, text("http://a.example")))
        #expect(catalog.accepts(accepts, text("HTTPS://WWW.EXAMPLE.COM/watch?v=a&si=x")))
        for other in ["merhaba dünya", "see https://a.example/x?fbclid=1 now", "https://a.example/?a=1 https://b.example/?b=2", "ftp://a.example/x"] {
            #expect(!catalog.accepts(accepts, text(other)), "\(other)")
        }
    }
}

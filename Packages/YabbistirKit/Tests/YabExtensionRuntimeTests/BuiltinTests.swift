import Foundation
import ImageIO
import Testing
import YabExtensionKit
import YabTestSupport
@testable import YabExtensionRuntime

/// The built-in extensions as the app ships them: Extensions/BuiltinExtensions, built by `make extensions`.
enum Builtins {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Extensions/BuiltinExtensions")

    static func load(_ id: String) throws -> ExtensionRuntime {
        let folder = root.appendingPathComponent(id)
        guard case .valid(let manifest, let localization) = ManifestValidator.validate(folder: folder) else {
            throw ExtensionError(.notFound, "\(id): \(ManifestValidator.validate(folder: folder).issues)")
        }
        return try ExtensionRuntime(folder: folder, manifest: manifest, localization: localization,
                                    dataFolder: TestScratch.url("yab-data")) { _ in }
    }
}

@Suite struct BuiltinTests {
    static let v4 = "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    static let v7 = "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"

    func text(_ runtime: ExtensionRuntime, _ action: String, item: ExtensionItem? = nil, language: String = "tr",
              variant: String? = nil, preferences: [String: JSONValue] = [:]) async throws -> String? {
        let output = try await runtime.invoke(.run, name: action, item: item,
                                              context: ExtensionContext(language: language, preferences: preferences, trigger: .search, variant: variant))
        if case .result(.text(let text)) = output { return text }
        return nil
    }

    func textItem(_ text: String, tags: [String] = []) -> ExtensionItem {
        ExtensionItem(id: 1, kind: "text", text: text, tags: tags, copiedAt: Date())
    }

    @Test func uuidV4MatchesTheFormat() async throws {
        let uuid = try #require(try await text(Builtins.load("dev.yabbistir.uuid"), "v4"))
        #expect(uuid.range(of: Self.v4, options: .regularExpression) != nil)
    }

    @Test func uuidV7IsTimeOrdered() async throws {
        let runtime = try Builtins.load("dev.yabbistir.uuid")
        let first = try #require(try await text(runtime, "v7"))
        let second = try #require(try await text(runtime, "v7"))
        #expect(first.range(of: Self.v7, options: .regularExpression) != nil)
        let milliseconds = Double(UInt64(first.replacingOccurrences(of: "-", with: "").prefix(12), radix: 16)!)
        #expect(abs(milliseconds / 1000 - Date().timeIntervalSince1970) < 2)
        #expect(first < second)
    }

    @Test func uuidHonoursUppercase() async throws {
        let uuid = try #require(try await text(Builtins.load("dev.yabbistir.uuid"), "v4", preferences: ["uppercase": .bool(true)]))
        #expect(uuid == uuid.uppercased())
    }

    @Test func base64EncodesUTF8() async throws {
        #expect(try await text(Builtins.load("dev.yabbistir.base64"), "encode", item: textItem("Perşembe")) == "UGVyxZ9lbWJl")
    }

    @Test func base64Decodes() async throws {
        #expect(try await text(Builtins.load("dev.yabbistir.base64"), "decode", item: textItem("SGVsbG8sIGTDvG55YQ==")) == "Hello, dünya")
    }

    @Test func base64DetectsAndPreviews() async throws {
        let runtime = try Builtins.load("dev.yabbistir.base64")
        let item = textItem("SGVsbG8sIGTDvG55YQ==")
        let context = ExtensionContext(language: "tr", trigger: .preview)
        #expect(try await runtime.invoke(.validate, name: "base64", item: item, context: context) == .valid(true))
        #expect(try await runtime.invoke(.preview, name: "base64", item: item, context: context)
            == .sections([.code(title: "Çözülmüş hali", code: "Hello, dünya", language: nil)]))
    }

    /// Ordinary words and ids are not base64.
    @Test func ordinaryWordsAreNotBase64() async throws {
        let runtime = try Builtins.load("dev.yabbistir.base64")
        for word in ["deadbeef", "Kubernetes", "password", "2026-10-28", "abcdefgh", "yabbistir"] {
            let verdict = try await runtime.invoke(.validate, name: "base64", item: textItem(word), context: ExtensionContext(language: "en", trigger: .detect))
            #expect(verdict == .valid(false), "\(word) was taken for base64")
        }
    }

    @Test func colorsConvert() async throws {
        let runtime = try Builtins.load("dev.yabbistir.convert")
        func convert(_ hex: String, _ r: Int, _ g: Int, _ b: Int, _ variant: String) async throws -> String? {
            let item = ExtensionItem(id: 1, kind: "color", color: .init(hex: hex, r: r, g: g, b: b, a: 1), copiedAt: Date())
            return try await text(runtime, "color", item: item, variant: variant)
        }
        #expect(try await convert("#6E56CF", 110, 86, 207, "rgb") == "rgb(110, 86, 207)")
        #expect(try await convert("#6E56CF", 110, 86, 207, "hsl") == "hsl(252, 56%, 57%)")
        #expect(try await convert("#6E56CF", 110, 86, 207, "swiftui") == "Color(red: 0.431, green: 0.337, blue: 0.812)")
        #expect(try await convert("#6E56CF", 110, 86, 207, "nscolor") == "NSColor(srgbRed: 0.431, green: 0.337, blue: 0.812, alpha: 1)")
        #expect(try await convert("#FF0000", 255, 0, 0, "oklch") == "oklch(62.8% 0.258 29.2)")
    }

    @Test func imagesConvertAndHalve() async throws {
        let runtime = try Builtins.load("dev.yabbistir.convert")
        let item = TestImages.item(TestImages.photo())
        let context = { (variant: String) in ExtensionContext(language: "tr", trigger: .shiftPanel, variant: variant) }
        guard case .result(.image(_, let uti, _, _)) = try await runtime.invoke(.run, name: "image", item: item, context: context("jpeg")) else {
            Issue.record("no jpeg"); return
        }
        #expect(uti == "public.jpeg")
        guard case .result(.image(_, _, let width, let height)) = try await runtime.invoke(.run, name: "image", item: item, context: context("half")) else {
            Issue.record("no half"); return
        }
        #expect((width, height) == (200, 150))
    }

    // MARK: Paste to Finder as a File

    /// The file "Paste to Finder as a File" makes for an item, read back; its work folder goes afterwards.
    func finderFile(_ item: ExtensionItem, language: String = "tr") async throws -> (name: String, data: Data) {
        let runtime = try Builtins.load("dev.yabbistir.finderfile")
        let finder = TargetInfo(bundleID: "com.apple.finder", name: "Finder", kind: .finder)
        let output = try await runtime.invoke(.run, name: "file", item: item,
                                              context: ExtensionContext(language: language, trigger: .shiftPanel, target: finder), effects: true)
        guard case .result(.file(let path)) = output else { throw ExtensionError(.badResult, "expected a file, got \(output)") }
        let url = URL(fileURLWithPath: path)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return (url.lastPathComponent, try Data(contentsOf: url))
    }

    @Test func textBecomesATxtNamedAfterItsFirstLine() async throws {
        let notes = "Toplantı notları\nPerşembe 14:00, iade akışı demosu."
        let file = try await finderFile(textItem(notes))
        #expect(file.name == "Toplantı notları.txt")
        #expect(String(decoding: file.data, as: UTF8.self) == notes)
        // Cleaned: slashes and colons become dashes, spaces trimmed, at most 40 characters.
        #expect(try await finderFile(textItem("  Rapor 2026/10: taslak  \nikinci satır")).name == "Rapor 2026-10- taslak.txt")
        // The cut falls between characters as people count them: a flag is one.
        let long = String(repeating: "ğ", count: 39) + "🇹🇷 son"
        #expect(try await finderFile(textItem(long)).name == String(repeating: "ğ", count: 39) + "🇹🇷.txt")
        // Nothing to name it after: the extension's own word.
        #expect(try await finderFile(textItem("   \n")).name == "Metin.txt")
        #expect(try await finderFile(textItem("/:"), language: "en").name == "--.txt")
        #expect(try await finderFile(textItem(""), language: "en").name == "Text.txt")
        // Code stays text, even when it looks like Markdown (its name loses the marker all the same).
        let code = ExtensionItem(id: 2, kind: "code", text: "# build\n```\nmake test\n```", copiedAt: Date())
        #expect(try await finderFile(code).name == "build.txt")
    }

    @Test func markdownBecomesMd() async throws {
        #expect(try await finderFile(textItem("# Sürüm notları\nYeni panel.")).name == "Sürüm notları.md")
        #expect(try await finderFile(textItem("Örnek\n```swift\nlet a = 1\n```")).name == "Örnek.md")
        #expect(try await finderFile(textItem("Alınacaklar\n- süt\n- ekmek")).name == "Alınacaklar.md")
        #expect(try await finderFile(textItem("#hashtag ve - tire")).name == "#hashtag ve - tire.txt")
    }

    /// A name Finder shows as it is: no hidden dot file, no invisible or reordering characters, no
    /// heading marker, and short enough for the disk however many marks a letter carries.
    @Test func namesAreSafeForFinder() async throws {
        #expect(try await finderFile(textItem(".NET 9 sürüm notları\nikinci satır")).name == "NET 9 sürüm notları.txt")
        #expect(try await finderFile(textItem(". . .gizli")).name == "gizli.txt")
        #expect(try await finderFile(textItem("...")).name == "Metin.txt")
        #expect(try await finderFile(textItem("..."), language: "en").name == "Text.txt")
        #expect(try await finderFile(textItem("Rapor\t2026 \u{202E}fdp.exe\u{200B} son\u{0}")).name == "Rapor2026 fdp.exe son.txt")
        #expect(try await finderFile(textItem("\u{200B}\u{202E}\u{FEFF}")).name == "Metin.txt")
        // Markdown's heading marker is not part of the name; the type still comes from the text.
        #expect(try await finderFile(textItem("## Heading\n- item")).name == "Heading.md")
        #expect(try await finderFile(textItem("# .env örneği")).name == "env örneği.md")
        #expect(try await finderFile(textItem("#")).name == "Metin.txt")
        #expect(try await finderFile(textItem("# ")).name == "Metin.md")
        // A letter heavy with combining marks: at most 200 bytes of name, cut between characters, and it is written.
        let zalgo = String(repeating: "z" + String(repeating: "\u{0301}", count: 30), count: 40)
        let heavy = try await finderFile(textItem(zalgo))
        let base = String(heavy.name.dropLast(4))
        #expect(heavy.name.hasSuffix(".txt"))
        #expect(base.utf8.count <= 200)
        #expect(base == String(zalgo.prefix(base.count)))
        #expect(base.count == 3)
        #expect(String(decoding: heavy.data, as: UTF8.self) == zalgo)
    }

    @Test func aLinkBecomesAWebloc() async throws {
        let link = ExtensionItem(id: 3, kind: "link", text: "https://tracker.example/x", url: "https://tracker.example/x", copiedAt: Date())
        let file = try await finderFile(link)
        #expect(file.name == "tracker.example.webloc")
        let content = String(decoding: file.data, as: UTF8.self)
        #expect(content.contains("<key>URL</key>"))
        #expect(content.contains("<string>https://tracker.example/x</string>"))
        let plist = try PropertyListSerialization.propertyList(from: file.data, format: nil) as? [String: String]
        #expect(plist == ["URL": "https://tracker.example/x"])
        // Characters XML gives a meaning to are escaped.
        let query = ExtensionItem(id: 4, kind: "link", url: "https://ornek.dev/a?b=1&c=<2>", copiedAt: Date())
        let escaped = try await finderFile(query)
        #expect(escaped.name == "ornek.dev.webloc")
        #expect(try PropertyListSerialization.propertyList(from: escaped.data, format: nil) as? [String: String] == ["URL": "https://ornek.dev/a?b=1&c=<2>"])
    }

    @Test func anImageBecomesAPng() async throws {
        let file = try await finderFile(TestImages.item(TestImages.photo(width: 40, height: 30)))
        #expect(file.name == "Görsel.png")
        let source = try #require(CGImageSourceCreateWithData(file.data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect((image.width, image.height) == (40, 30))
    }

    @Test func ocrReturnsText() async throws {
        let item = TestImages.item(TestImages.text("yabbistir 2026"))
        let text = try await text(Builtins.load("dev.yabbistir.convert"), "ocr", item: item)
        #expect(text?.contains("yabbistir 2026") == true)
    }

    @Test func convertOffersRemoveBackgroundForImages() throws {
        let folder = Builtins.root.appendingPathComponent("dev.yabbistir.convert")
        guard case .valid(let manifest, _) = ManifestValidator.validate(folder: folder) else { Issue.record("invalid manifest"); return }
        let action = try #require(manifest.contributes.actions.first { $0.id == "bgremove" })
        #expect(action.output == .image)
        #expect(action.accepts?.kinds.contains("image") == true)
    }
}

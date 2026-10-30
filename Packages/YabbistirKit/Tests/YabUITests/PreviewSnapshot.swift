import AppKit
import SwiftUI
import Testing
import YabCore
import YabExtensionKit
import YabExtensions
import YabLocalization
import YabPasteboard
import YabStack
@testable import YabUI

/// Renders preview variants (synthetic content) to PNG for visual review. Off by default; run with
/// `TEST_RUNNER_YAB_SNAPSHOT_DIR=/some/dir make test ONLY=YabUITests/PreviewSnapshot`.
@MainActor @Suite struct PreviewSnapshot {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderPreviews() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"]!)
        let info = [
            PreviewInfoRow(label: "Uygulama", value: "TextEdit"),
            PreviewInfoRow(label: "İçerik", value: "Metin"),
            PreviewInfoRow(label: "Karakter", value: "62"),
            PreviewInfoRow(label: "Kopyalandı", value: "2 dk"),
            PreviewInfoRow(label: "Kategori", value: "Kod, Bağlantılar", categoryColors: [.slate, .sage]),
        ]
        let context = CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.35, green: 0.45, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
        let image = context.makeImage()!
        let samples: [(String, PreviewContent.Body)] = [
            ("text", .text("Perşembe 14:00 — iade akışı demosu, Elif ve Mert de katılacak.", hiddenCharacters: 0)),
            ("color", .color(ColorValue(hex: "#6E56CF")!)),
            ("image", .image(image, pixelSize: CGSize(width: 2880, height: 1800))),
            ("files", .files([URL(fileURLWithPath: "/Users/me/Desktop/Ekran Resmi.png")], thumbnail: image)),
            ("command-generator", .command(CommandPreview(input: nil, output: .text("0192f5c1-7b2e-7c3a-9f1e-4b8d2a6c1e93"),
                                                          extensionName: "UUID", icon: "sf:number"))),
            ("command-transformer", .command(CommandPreview(input: .text("SGVsbG8sIGTDvG55YSEgQnUgYmlyIGRlbmVtZSBtZXRuaWRpci4="),
                                                            output: .text("Hello, dünya! Bu bir deneme metnidir."),
                                                            extensionName: "Base64", icon: "sf:number"))),
            ("command-color", .command(CommandPreview(input: .color(ColorValue(hex: "#6E56CF")!), output: .text("rgb(110 86 207)"),
                                                      extensionName: "Renk", icon: "sf:paintpalette"))),
            ("command-pending", .command(CommandPreview(input: nil, output: .pending, extensionName: "UUID", icon: "sf:number"))),
        ]
        let commandInfo = [
            PreviewInfoRow(label: "Uzantı", value: "Base64 · Yerleşik"),
            PreviewInfoRow(label: "Tür", value: "Dönüştürücü · seçili öğeye uygulanır"),
            PreviewInfoRow(label: "Anahtar kelimeler", value: "", chips: ["base64", "b64", "çöz", "decode", "kod çöz", "metin"]),
            PreviewInfoRow(label: "Uzunluk", value: "52 → 37 karakter"),
        ]
        for (name, body) in samples {
            let info = name.hasPrefix("command") ? commandInfo : info
            let view = PreviewView(content: PreviewContent(itemID: 1, body: body, info: info), language: .turkish,
                                   showsHints: true, measuring: true)
                .padding(30)
                .background(Color(red: 0.12, green: 0.16, blue: 0.35))
                .environment(\.colorScheme, .dark)
            // The live variant (scroll view, as in the window), drawn through AppKit.
            let live = PreviewView(content: PreviewContent(itemID: 1, body: body, info: info), language: .turkish, showsHints: true)
                .frame(height: 420)
                .background(Color(red: 0.12, green: 0.16, blue: 0.35))
                .environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: live)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("preview-live-\(name).png"))
            }
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                let rendered = renderer.nsImage!
                let rep = NSBitmapImageRep(data: rendered.tiffRepresentation!)!
                try? rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("preview-\(name).png"))
            }
        }
    }

    /// The category editor in both languages (labels must never truncate).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderEditor() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"]!)
        let library = try Library(store: ItemStore.temporary())
        for name in ["Kod parçaları", "Bağlantılar", "Toplantı notları"] { _ = try library.createCategory(name: name) }
        for language in [AppLanguage.english, .turkish] {
            let languageStore = LanguageStore(defaults: UserDefaults(suiteName: "snap-editor-\(UUID())")!)
            languageStore.language = language
            let editor = CategoryEditorModel(library: library, language: languageStore)
            let host = NSHostingView(rootView: CategoryEditorView(model: editor) {}
                .background(Color(red: 0.12, green: 0.16, blue: 0.35)).environment(\.colorScheme, .dark))
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("editor-\(language.rawValue).png"))
            }
        }
    }

    /// The Sıra panel: three items with the new-copy rail, and the empty state, in both languages.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderStack() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"]!)
        let library = try Library(store: ItemStore.temporary())
        let samples: [(String, SourceApp?)] = [
            ("Perşembe 14:00 — iade akışı demosu", SourceApp(bundleID: "com.apple.TextEdit", name: "TextEdit")),
            ("let total = items.reduce(0, +)", SourceApp(bundleID: "com.apple.dt.Xcode", name: "Xcode")),
            ("https://example.com/docs/stack", SourceApp(bundleID: "com.apple.Safari", name: "Safari")),
        ]
        var ids: [Int64] = []
        for (offset, (text, source)) in samples.enumerated() {
            let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(text.utf8))]],
                                    source: source, device: .local, capturedAt: Date().addingTimeInterval(Double(offset)))
            let item = try #require(try library.store.ingest(clip)).item
            library.didIngest(item)
            ids.append(item.id!)
        }
        for language in [AppLanguage.english, .turkish] {
            for filled in [true, false] {
                let session = StackSession(library: library, writer: SnapshotWriter(), didWrite: { _ in })
                if filled { ids.forEach(session.append) }
                let host = NSHostingView(rootView: StackPanelView(session: session, library: library, language: language)
                    .padding(24)
                    .background(Color(red: 0.12, green: 0.16, blue: 0.35))
                    .environment(\.colorScheme, .dark))
                let size = host.fittingSize
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?
                        .write(to: dir.appendingPathComponent("stack-\(filled ? "filled" : "empty")-\(language.rawValue).png"))
                }
                session.finish()
            }
        }
    }

    /// Settings → Extensions in both languages, both tabs (labels must never truncate).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderSettings() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"]!)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snap-settings-\(UUID())")
        let builtIns = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Extensions/BuiltinExtensions")
        let settings = ExtensionSettings(defaults: UserDefaults(suiteName: "snap-settings-\(UUID())")!)
        let registry = ExtensionRegistry(builtInRoot: builtIns, userRoot: root.appendingPathComponent("Extensions"),
                                         dataRoot: root.appendingPathComponent("Data"), settings: settings)
        let logs = ExtensionLogBuffer()
        logs.append("dev.yabbistir.base64", "decoded 20 characters")
        logs.append("dev.yabbistir.convert", "TypeError: undefined is not an object (evaluating 'item.color.r')")
        for language in [AppLanguage.english, .turkish] {
            for tab in [ExtensionsSettingsView.Tab.installed, .development] {
                let languageStore = LanguageStore(defaults: UserDefaults(suiteName: "snap-settings-lang-\(UUID())")!)
                languageStore.language = language
                let model = ExtensionsSettingsModel(registry: registry, settings: settings, language: languageStore, logs: logs)
                model.selectedID = "dev.yabbistir.uuid"
                let host = NSHostingView(rootView: ExtensionsSettingsView(model: model, tab: tab)
                    .frame(width: 680, height: 560)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let name = "settings-\(tab == .installed ? "installed" : "development")-\(language.rawValue).png"
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
                }
            }
        }
    }

    /// An extension's details with a secret (empty and saved) and a folder preference, in both languages.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderSecretPreferences() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"]!)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snap-secret-\(UUID())")
        let builtIns = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Extensions/BuiltinExtensions")
        let source = root.appendingPathComponent("keys-source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: builtIns.appendingPathComponent("dev.yabbistir.uuid"), to: source)
        let manifestURL = source.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifest["id"] = "dev.example.keys"
        manifest["preferences"] = [["id": "token", "type": "secret", "title": "uppercase"],
                                   ["id": "dir", "type": "folder", "title": "uppercase", "default": "~/Documents/Projects/Archive/2026/Receipts"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let secrets = InMemorySecretStore()
        let settings = ExtensionSettings(defaults: UserDefaults(suiteName: "snap-secret-\(UUID())")!, secrets: secrets)
        let registry = ExtensionRegistry(builtInRoot: builtIns, userRoot: root.appendingPathComponent("Extensions"),
                                         dataRoot: root.appendingPathComponent("Data"), settings: settings)
        for language in [AppLanguage.english, .turkish] {
            let languageStore = LanguageStore(defaults: UserDefaults(suiteName: "snap-secret-lang-\(UUID())")!)
            languageStore.language = language
            let model = ExtensionsSettingsModel(registry: registry, settings: settings, language: languageStore, logs: ExtensionLogBuffer())
            if registry.installed.first(where: { $0.id == "dev.example.keys" }) == nil { model.installFolder(source) }
            model.selectedID = "dev.example.keys"
            for saved in [false, true] {
                try secrets.write(saved ? "sk-synthetic-1" : nil, "dev.example.keys", "token")
                model.setSecret("dev.example.keys", "token", saved ? "sk-synthetic-1" : nil)
                for scheme in [NSAppearance.Name.darkAqua, .aqua] {
                    let host = NSHostingView(rootView: ExtensionsSettingsView(model: model, tab: .installed)
                        .frame(width: 760, height: 620).background(Color(nsColor: .windowBackgroundColor)))
                    host.frame = NSRect(x: 0, y: 0, width: 760, height: 620)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: scheme)
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let name = "secret-\(saved ? "saved" : "empty")-\(scheme == .darkAqua ? "dark" : "light")-\(language.rawValue).png"
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
                    }
                }
            }
        }
    }

    /// An extension's details with its copy rules (one switched off) beside a preference, in both languages
    /// and both appearances.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderCaptureRules() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"]!)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snap-rules-\(UUID())")
        let builtIns = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Extensions/BuiltinExtensions")
        let source = root.appendingPathComponent("link-clean-source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: builtIns.appendingPathComponent("dev.yabbistir.uuid"), to: source)
        let manifestURL = source.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifest["id"] = "dev.example.link-clean"
        manifest["icon"] = "sf:link"
        manifest["permissions"] = ["capture"]
        manifest["preferences"] = [["id": "keepFragment", "type": "toggle", "title": "keepFragment", "default": false]]
        manifest["contributes"] = ["captureRules": [
            ["id": "tracking", "title": "tracking.title", "description": "tracking.description", "accepts": ["kinds": ["link"]]],
            ["id": "amp", "title": "amp.title", "description": "amp.description", "accepts": ["kinds": ["link"]]],
        ]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let tables: [String: [String: String]] = [
            "en": ["name": "Link Cleaner", "description": "Removes tracking from the links you copy.",
                   "tracking.title": "Remove tracking parameters", "tracking.description": "Drops utm_, fbclid and the like from copied links.",
                   "amp.title": "Original page instead of mobile", "amp.description": "Swaps mobile-only links for the publisher's own page.",
                   "keepFragment": "Keep #fragments"],
            "tr": ["name": "Link Temizle", "description": "Kopyaladığın linklerdeki izleme parçalarını siler.",
                   "tracking.title": "İzleme parametrelerini sil", "tracking.description": "Kopyalanan linklerden utm_, fbclid ve benzerlerini atar.",
                   "amp.title": "Mobil yerine asıl sayfa", "amp.description": "Yalnızca mobil linkleri yayıncının kendi sayfasıyla değiştirir.",
                   "keepFragment": "#parçaları koru"],
        ]
        for (language, table) in tables {
            try JSONSerialization.data(withJSONObject: table).write(to: source.appendingPathComponent("locales/\(language).json"))
        }
        let settings = ExtensionSettings(defaults: UserDefaults(suiteName: "snap-rules-\(UUID())")!)
        let registry = ExtensionRegistry(builtInRoot: builtIns, userRoot: root.appendingPathComponent("Extensions"),
                                         dataRoot: root.appendingPathComponent("Data"), settings: settings)
        for language in [AppLanguage.english, .turkish] {
            let languageStore = LanguageStore(defaults: UserDefaults(suiteName: "snap-rules-lang-\(UUID())")!)
            languageStore.language = language
            let model = ExtensionsSettingsModel(registry: registry, settings: settings, language: languageStore, logs: ExtensionLogBuffer())
            if registry.installed.first(where: { $0.id == "dev.example.link-clean" }) == nil {
                model.installFolder(source)
                model.approveConsent()
            }
            model.selectedID = "dev.example.link-clean"
            model.setRuleEnabled("dev.example.link-clean", "amp", false)
            for scheme in [NSAppearance.Name.darkAqua, .aqua] {
                let host = NSHostingView(rootView: ExtensionsSettingsView(model: model, tab: .installed)
                    .frame(width: 760, height: 620).background(Color(nsColor: .windowBackgroundColor)))
                host.frame = NSRect(x: 0, y: 0, width: 760, height: 620)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: scheme)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let name = "rules-\(scheme == .darkAqua ? "dark" : "light")-\(language.rawValue).png"
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
                }
            }
        }
    }

    /// The consent sheet (new install and review) and an extension's details with permissions, a
    /// missing tool and the waiting state, in both languages.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderConsent() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"]!)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snap-consent-\(UUID())")
        let builtIns = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Extensions/BuiltinExtensions")
        let source = root.appendingPathComponent("video-source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: builtIns.appendingPathComponent("dev.yabbistir.uuid"), to: source)
        let manifestURL = source.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifest["id"] = "dev.example.video"
        manifest["permissions"] = ["network", "exec"]
        manifest["network"] = ["domains": ["video.example", "vid.example"]]
        manifest["requires"] = ["tools": [["name": "yt-dlp", "install": "brew install yt-dlp"],
                                          ["name": "ffmpeg", "install": "brew install ffmpeg"]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        for (language, name, description) in [("en", "Video Downloader", "Downloads a video from a link as a file."),
                                              ("tr", "Video İndir", "Bir bağlantıdaki videoyu dosya olarak indirir.")] {
            let url = source.appendingPathComponent("locales/\(language).json")
            var table = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            table["name"] = name
            table["description"] = description
            try JSONSerialization.data(withJSONObject: table).write(to: url)
        }
        let settings = ExtensionSettings(defaults: UserDefaults(suiteName: "snap-consent-\(UUID())")!)
        let registry = ExtensionRegistry(builtInRoot: builtIns, userRoot: root.appendingPathComponent("Extensions"),
                                         dataRoot: root.appendingPathComponent("Data"), settings: settings)
        let empty = root.appendingPathComponent("no-tools")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        func render<V: View>(_ view: V, size: NSSize?, name: String, scheme: NSAppearance.Name = .darkAqua) {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            let fitted = size ?? host.fittingSize
            host.frame = NSRect(origin: .zero, size: fitted)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: fitted), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
            }
        }
        for language in [AppLanguage.english, .turkish] {
            let languageStore = LanguageStore(defaults: UserDefaults(suiteName: "snap-consent-lang-\(UUID())")!)
            languageStore.language = language
            let model = ExtensionsSettingsModel(registry: registry, settings: settings, language: languageStore, logs: ExtensionLogBuffer(),
                                                toolLocator: ToolLocator(searchPath: [empty.path]))
            model.installFolder(source)
            let request = try #require(model.pendingConsent)
            model.pendingConsent = nil
            for isNew in [true, false] {
                var request = request
                request.isNewInstall = isNew
                render(ExtensionConsentSheet(request: request, language: language, onAllow: {}, onDecline: {}),
                       size: nil, name: "consent-\(isNew ? "new" : "existing")-\(language.rawValue).png")
            }
            model.selectedID = "dev.example.video"
            render(ExtensionsSettingsView(model: model, tab: .installed).frame(width: 760, height: 620),
                   size: NSSize(width: 760, height: 620), name: "detail-waiting-\(language.rawValue).png")
            model.thirdPartyDisabled = true
            render(ExtensionsSettingsView(model: model, tab: .installed).frame(width: 760, height: 620),
                   size: NSSize(width: 760, height: 620), name: "detail-master-off-\(language.rawValue).png")
            model.thirdPartyDisabled = false
        }
    }

    /// The language-pack notice beside the Accessibility one (whose button it matches), in both
    /// languages and both appearances, over a desktop-like backdrop.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderNotices() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"]!)
        for language in [AppLanguage.english, .turkish] {
            for (scheme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
                    NoticeView(language: language, kind: .translationNeeded(from: "en", to: "tr")) {}
                    NoticeView(language: language, kind: .accessibility) {}
                    NoticeView(language: language, kind: .copiedOnly) {}
                }
                .padding(24)
                .background(scheme == "dark" ? Color(red: 0.12, green: 0.16, blue: 0.35) : Color(red: 0.86, green: 0.89, blue: 0.97))
                .environment(\.colorScheme, scheme == "dark" ? .dark : .light))
                let size = host.fittingSize
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?
                        .write(to: dir.appendingPathComponent("notice-translation-\(scheme)-\(language.rawValue).png"))
                }
            }
        }
    }
}


private final class SnapshotWriter: PasteboardWriting {
    func write(_ items: [[PasteboardRepresentation]], plainTextOnly: Bool) -> Int { 0 }
}

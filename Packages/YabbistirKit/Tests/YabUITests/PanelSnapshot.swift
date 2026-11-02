import AppKit
import SwiftUI
import Testing
import YabCore
import YabExtensionKit
import YabExtensions
import YabLocalization
@testable import YabUI

/// Renders the panel to PNG for visual review. Off by default; run with
/// `TEST_RUNNER_YAB_SNAPSHOT_DIR=/some/dir make test ONLY=YabUITests/PanelSnapshot`.
@MainActor @Suite struct PanelSnapshot {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderPanel() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"]!)
        let store = try ItemStore.temporary()
        let now = Date()
        let samples: [(String, String, Double, DeviceKind)] = [
            ("public.utf8-plain-text", "UPDATE users SET status = 'refunded' WHERE id = 4821;", 1, .local),
            ("public.utf8-plain-text", "https://tracker.example/yabbistir/issue/YAB-142", 4, .local),
            ("public.utf8-plain-text", "Perşembe 14:00 — iade akışı demosu, Elif ve Mert de katılacak.", 9, .remote),
            ("public.utf8-plain-text", "#6E56CF", 16, .local),
            ("public.utf8-plain-text", "git rebase -i HEAD~3", 22, .local),
            ("public.utf8-plain-text", "Merhaba, iadeniz onaylandı. Tutar 3–5 iş günü içinde yansıyacaktır.", 47, .local),
            ("public.utf8-plain-text", "ops@ornek.dev", 1600, .local),
            ("public.utf8-plain-text", "docker compose up -d db", 4000, .local),
        ]
        var ids: [Int64] = []
        for (type, text, minutes, device) in samples {
            ids.append(try #require(try store.ingest(CapturedClip(items: [[PasteboardRepresentation(type: type, data: Data(text.utf8))]],
                                                                  source: nil, device: device,
                                                                  capturedAt: now.addingTimeInterval(-minutes * 60)))).item.id!)
        }
        // Extension commands and a tag (synthetic): the third row carries a "base64" tag.
        let tag = StoredTag(extensionID: "dev.yabbistir.base64", tag: "base64")
        try store.setTags([tag], for: ids[2], extensionID: tag.extensionID)
        let fake = FakeCommands()
        fake.labels[tag] = "base64"
        fake.generators = [FakeCommands.command("dev.yabbistir.uuid/v4", title: "UUID oluştur", keywords: ["uuid"], input: .none,
                                                extensionName: "UUID"),
                           FakeCommands.command("dev.yabbistir.uuid/v7", title: "UUID oluştur (v7)", keywords: ["uuid"], input: .none,
                                                extensionName: "UUID")]
        fake.hints = ["dev.yabbistir.uuid/v4": "Rastgele, v4", "dev.yabbistir.uuid/v7": "Zamana göre sıralı",
                      "dev.yabbistir.base64/encode": "VVBEQVRFIHVzZXJzIFNFVCBzdGF0dXMgPSAncmVmdW5kZWQn",
                      "dev.yabbistir.url/encode": "UPDATE%20users%20SET%20status%20%3D%20%27refunded%27"]
        fake.transformsByItem[ids[0]] = [FakeCommands.command("dev.yabbistir.base64/encode", title: "Base64 kodla", keywords: ["kodla"]),
                                         FakeCommands.command("dev.yabbistir.url/encode", title: "URL kodla", keywords: ["kodla"],
                                                              extensionName: "URL")]
        for (name, appearance, language, query) in [("dark-tr", NSAppearance.Name.darkAqua, AppLanguage.turkish, ""),
                                                    ("light-en", .aqua, .english, ""),
                                                    ("dark-search", .darkAqua, .turkish, "iade"),
                                                    ("dark-commands", .darkAqua, .turkish, "uu"),
                                                    ("light-transforms", .aqua, .turkish, "kod")] {
            let languageStore = LanguageStore(defaults: UserDefaults(suiteName: "snap-\(UUID())")!)
            languageStore.language = language
            let model = PanelViewModel(library: try Library(store: store), language: languageStore, extensions: fake, now: { now })
            model.reset()
            model.isPresented = true
            for character in query { _ = model.handle(.type(String(character))) }
            _ = model.handle(.move(1))
            var panel = PanelView(model: model, material: .tunedEffect)
            panel.snapshot = true
            let view = panel
                .padding(30)
                .background(appearance == .darkAqua ? Color(red: 0.12, green: 0.16, blue: 0.35) : Color(red: 0.86, green: 0.89, blue: 0.97))
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                let image = renderer.nsImage!
                let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
                try? rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("panel-\(name).png"))
            }
        }
    }

    /// Finder in front: the ⇧ panel on a video link leads with "Finder’a" (a synthetic download job,
    /// its footer naming the verb), then the same with "Paste to Finder as a File" highlighted, and
    /// ⌘K's first group; last, TextEdit in front.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderFinderTarget() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"]!)
        let store = try ItemStore.temporary()
        let now = Date()
        let link = try #require(try store.ingest(CapturedClip(
            items: [[PasteboardRepresentation(type: TypeIdentifiers.url, data: Data("https://www.video.example/watch?v=yab-142".utf8)),
                     PasteboardRepresentation(type: TypeIdentifiers.urlName, data: Data("SwiftUI ile Liquid Glass — tam rehber".utf8))]],
            source: SourceApp(bundleID: "com.apple.Safari", name: "Safari"), device: .local, capturedAt: now.addingTimeInterval(-360)))).item.id!
        let fake = FakeCommands()
        /// The commands as the catalog would give them in each language (the download is synthetic).
        func offer(_ language: AppLanguage) {
            let tr = language == .turkish
            let verb = tr ? "İndir" : "Download"
            fake.transformsByItem[link] = [
                FakeCommands.command("dev.example.video/video", title: tr ? "Video olarak indir" : "Download as Video", keywords: ["indir"],
                                     extensionName: tr ? "Video İndir" : "Video Download", hint: false, icon: "sf:film", subtitle: "MP4 · 1080p",
                                     output: .file, targets: [.finder], isJob: true, verb: verb),
                FakeCommands.command("dev.example.video/audio", title: tr ? "Sesi indir" : "Download Audio", keywords: ["ses"],
                                     extensionName: tr ? "Video İndir" : "Video Download", hint: false, icon: "sf:waveform",
                                     subtitle: tr ? "M4A · yalnızca ses" : "M4A · audio only", output: .file, targets: [.finder], isJob: true,
                                     verb: verb),
                FakeCommands.command("dev.yabbistir.finderfile/file", title: tr ? "Finder’a dosya olarak yapıştır" : "Paste to Finder as a File",
                                     keywords: ["finder"], extensionName: tr ? "Finder’a dosya olarak yapıştır" : "Paste to Finder as a File",
                                     hint: false, icon: "sf:arrow.down.doc", output: .file, targets: [.finder]),
                FakeCommands.command("dev.yabbistir.base64/encode", title: tr ? "Base64 kodla" : "Encode Base64", keywords: ["kodla"],
                                     icon: "sf:arrow.left.arrow.right"),
            ]
            fake.hints = ["dev.example.video/video": "MP4 · 1080p", "dev.example.video/audio": tr ? "M4A · yalnızca ses" : "M4A · audio only",
                          "dev.yabbistir.finderfile/file": "", "dev.yabbistir.base64/encode": "aHR0cHM6Ly93d3cudmlkZW8uZXhhbXBsZS93YXRjaD92PXlhYi0xNDI="]
        }
        for (name, appearance, language, moves, actions) in [("dark", NSAppearance.Name.darkAqua, AppLanguage.turkish, 0, false),
                                                             ("light", .aqua, .turkish, 0, false),
                                                             ("dark-en", .darkAqua, .english, 0, false),
                                                             ("dark-file", .darkAqua, .turkish, 2, false),
                                                             ("light-file-en", .aqua, .english, 2, false),
                                                             ("dark-actions", .darkAqua, .turkish, 0, true),
                                                             ("light-actions-en", .aqua, .english, 0, true),
                                                             ("dark-editor", .darkAqua, .turkish, 0, false)] {
            offer(language)
            // Another app in front: its own actions lead under its name and icon.
            let editor = name == "dark-editor"
            fake.target = editor ? TargetInfo(bundleID: "com.apple.TextEdit", name: "TextEdit", kind: .editor)
                : TargetInfo(bundleID: "com.apple.finder", name: "Finder", kind: .finder)
            if editor {
                // "Paste to Finder as a File" is Finder's only; the encoding is on its way.
                fake.transformsByItem[link] = [FakeCommands.command("dev.yabbistir.base64/encode", title: "Base64 kodla", keywords: ["kodla"],
                                                                    icon: "sf:arrow.left.arrow.right", targets: [.editor])]
                    + (fake.transformsByItem[link] ?? []).prefix(2)
                fake.outputs["dev.yabbistir.base64/encode"] = .text("aHR0cHM6Ly93d3cudmlkZW8uZXhhbXBsZS93YXRjaD92PXlhYi0xNDI=")
            }
            let languageStore = LanguageStore(defaults: UserDefaults(suiteName: "snap-f-\(UUID())")!)
            languageStore.language = language
            let model = PanelViewModel(library: try Library(store: store), language: languageStore, extensions: fake, now: { now })
            model.reset()
            model.select(link, in: .history)
            _ = model.handle(actions ? .toggleActions : .toggleTransforms)
            for _ in 0..<moves { _ = model.handle(.move(1)) }
            let content: AnyView = actions ? AnyView(ActionMenuView(model: model) { _ in }) : AnyView(TransformPanelView(model: model) { _ in })
            let view = content
                .padding(30)
                .background(appearance == .darkAqua ? Color(red: 0.12, green: 0.16, blue: 0.35) : Color(red: 0.86, green: 0.89, blue: 0.97))
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
                .environment(\.locale, language.locale)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                let rendered = renderer.nsImage!
                let rep = NSBitmapImageRep(data: rendered.tiffRepresentation!)!
                try? rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("finder-\(name).png"))
            }
        }
    }

    /// The ⇧ panel on a text, a color and an image item (synthetic).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderTransformPanel() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"]!)
        let store = try ItemStore.temporary()
        let now = Date()
        let context = CGContext(data: nil, width: 1200, height: 760, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.35, green: 0.45, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 760))
        context.setFillColor(CGColor(red: 0.95, green: 0.7, blue: 0.3, alpha: 1))
        context.fillEllipse(in: CGRect(x: 700, y: 300, width: 300, height: 300))
        let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
        func ingest(_ type: String, _ data: Data, minutes: Double) throws -> Int64 {
            try #require(try store.ingest(CapturedClip(items: [[PasteboardRepresentation(type: type, data: data)]],
                                                       source: SourceApp(bundleID: "com.apple.TextEdit", name: "TextEdit"),
                                                       device: .local, capturedAt: now.addingTimeInterval(-minutes * 60)))).item.id!
        }
        let imageID = try ingest("public.png", png, minutes: 3)
        let colorID = try ingest("public.utf8-plain-text", Data("#6E56CF".utf8), minutes: 2)
        let textID = try ingest("public.utf8-plain-text", Data("SGVsbG8sIGTDvG55YSEgQnUgYmlyIGRlbmVtZS4=".utf8), minutes: 1)
        let fake = FakeCommands()
        fake.transformsByItem[textID] = [
            FakeCommands.command("dev.yabbistir.base64/decode", title: "Base64 çöz", keywords: ["çöz"]),
            FakeCommands.command("dev.yabbistir.base64/encode", title: "Base64 kodla", keywords: ["kodla"]),
            FakeCommands.command("dev.yabbistir.convert/case#upper", title: "BÜYÜK HARF", keywords: ["büyük"], extensionName: "Metin"),
            FakeCommands.command("dev.yabbistir.convert/case#slug", title: "slug-olarak", keywords: ["slug"], extensionName: "Metin"),
        ]
        fake.outputs["dev.yabbistir.base64/decode"] = .text("Hello, dünya! Bu bir deneme.")
        fake.hints = ["dev.yabbistir.base64/decode": "Hello, dünya! Bu bir deneme.", "dev.yabbistir.base64/encode": "U0dWc2JHOHNJR1JEW…",
                      "dev.yabbistir.convert/case#upper": "SGVSBG8SIGTDVG55…", "dev.yabbistir.convert/case#slug": "sgvsbg8sigtdvg55…"]
        let colors = [("rgb", "RGB olarak", "rgb(110 86 207)"), ("hsl", "HSL olarak", "hsl(252 55% 57%)"),
                      ("swiftui", "SwiftUI Color olarak", "Color(red: 0.431, green: 0.337, blue: 0.812)")]
        fake.transformsByItem[colorID] = colors.map {
            FakeCommands.command("dev.yabbistir.convert/color#\($0.0)", title: $0.1, keywords: [$0.0], extensionName: "Dönüştür")
        }
        for (id, _, value) in colors {
            fake.outputs["dev.yabbistir.convert/color#\(id)"] = .text(value)
            fake.hints["dev.yabbistir.convert/color#\(id)"] = value
        }
        fake.transformsByItem[imageID] = [
            FakeCommands.command("dev.yabbistir.convert/image#jpeg", title: "JPEG olarak", keywords: ["jpeg"], extensionName: "Dönüştür"),
            FakeCommands.command("dev.yabbistir.convert/ocr", title: "Metni oku (OCR)", keywords: ["ocr"], extensionName: "Dönüştür"),
        ]
        fake.outputs["dev.yabbistir.convert/image#jpeg"] = .image(data: png, uti: "public.jpeg", width: 1200, height: 760)
        for (name, id, query) in [("text", textID, ""), ("color", colorID, ""), ("image", imageID, ""), ("empty", textID, "zz")] {
            let languageStore = LanguageStore(defaults: UserDefaults(suiteName: "snap-x-\(UUID())")!)
            languageStore.language = .turkish
            let model = PanelViewModel(library: try Library(store: store), language: languageStore, extensions: fake, now: { now })
            model.reset()
            model.select(id, in: .history)
            _ = model.handle(.toggleTransforms)
            for character in query { _ = model.handle(.type(String(character))) }
            let view = TransformPanelView(model: model) { _ in }
                .padding(30)
                .background(Color(red: 0.12, green: 0.16, blue: 0.35))
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                let rendered = renderer.nsImage!
                let rep = NSBitmapImageRep(data: rendered.tiffRepresentation!)!
                try? rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("transforms-\(name).png"))
            }
        }
    }

    /// A source's column beside History (a synthetic vault): its rows, a search on a username, a long username, the
    /// locked row, and a source still loading; dark Turkish and light English.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderSources() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"]!)
        let store = try ItemStore.temporary()
        let now = Date()
        for (text, minutes) in [("UPDATE users SET status = 'refunded' WHERE id = 4821;", 1.0), ("https://ornek.dev/giris", 4),
                                ("Perşembe 14:00 — iade akışı demosu", 9), ("git rebase -i HEAD~3", 22), ("ops@ornek.dev", 1600)] {
            _ = try store.ingest(CapturedClip(items: [[PasteboardRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8))]],
                                              source: nil, device: .local, capturedAt: now.addingTimeInterval(-minutes * 60)))
        }
        let library = try Library(store: store)
        let key = "dev.example.kasa/vault"
        try library.syncSourceCategories([SourceCategorySeed(key: key, name: "Kasa")])
        let vault = try #require(try store.categories().first { $0.source == key })
        let rows = [("Bulut konsolu", "ops@ornek.dev"), ("Eskiz", "melike@ornek.dev"), ("Kodhane", "melike@ornek.dev"), ("Kodhane", "deniz.k"),
                    ("Grafikler", "ops@ornek.dev"), ("İş Portalı", "deniz.k"), ("ornek.dev", "melike@ornek.dev"), ("Veritabanı prod", "app_rw"),
                    ("Nöbetçi", "melike.sahin.uzun-bir-ad-soyad@ornek.dev"), ("staging.ornek.dev", "ops@ornek.dev"), ("Yayınevi", nil)]
            .enumerated().map { SourceRow(id: "\($0.offset)", title: $0.element.0, subtitle: $0.element.1) }
        for (name, appearance, language, state, query) in [
            ("dark", NSAppearance.Name.darkAqua, AppLanguage.turkish, SourceCenter.State.rows(rows), ""),
            ("light-en", .aqua, .english, .rows(rows), ""),
            ("dark-search", .darkAqua, .turkish, .rows(rows), "deniz"),
            // A subtitle far past 170 pt, alone at the top: it ends in "…".
            ("dark-long", .darkAqua, .turkish, .rows(rows), "sentry"),
            ("dark-locked", .darkAqua, .turkish, .locked(message: "Kasa kilitli", command: "kasa login --trust <e-posta>"), ""),
            ("light-locked-en", .aqua, .english, .locked(message: "Vault is locked", command: "kasa login --trust <email>"), ""),
            ("dark-locked-plain", .darkAqua, .turkish, .locked(message: "Kasa kilitli", command: nil), ""),
            ("dark-loading", .darkAqua, .turkish, .loading, ""),
        ] {
            let languageStore = LanguageStore(defaults: UserDefaults(suiteName: "snap-s-\(UUID())")!)
            languageStore.language = language
            let sources = FakeSources()
            sources.descriptors = [FakeSources.vault()]
            sources.states[key] = state
            let model = PanelViewModel(library: library, language: languageStore, sources: sources, now: { now })
            model.reset()
            model.isPresented = true
            model.toggleShown(vault.id!)
            for character in query { _ = model.handle(.type(String(character))) }
            if query.isEmpty { _ = model.handle(.move(2)) }
            var panel = PanelView(model: model, material: .tunedEffect)
            panel.snapshot = true
            let view = panel
                .padding(30)
                .background(appearance == .darkAqua ? Color(red: 0.12, green: 0.16, blue: 0.35) : Color(red: 0.86, green: 0.89, blue: 0.97))
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                let image = renderer.nsImage!
                let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
                try? rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("sources-\(name).png"))
            }
        }
    }

    /// A source row's actions (a synthetic vault): the bar on an entry, with ⌘ and with ⇧ held; ⌘K; the ⇧ list (its copy
    /// row highlighted too); the locked row's bar and ⌘K; and the source's notices. Dark Turkish, then light English.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderSourceActions() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"]!)
        let store = try ItemStore.temporary()
        let now = Date()
        for (text, minutes) in [("UPDATE users SET status = 'refunded' WHERE id = 4821;", 1.0), ("https://ornek.dev/giris", 4),
                                ("Perşembe 14:00 — iade akışı demosu", 9), ("git rebase -i HEAD~3", 22)] {
            _ = try store.ingest(CapturedClip(items: [[PasteboardRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8))]],
                                              source: nil, device: .local, capturedAt: now.addingTimeInterval(-minutes * 60)))
        }
        let library = try Library(store: store)
        let key = "dev.example.kasa/vault"
        try library.syncSourceCategories([SourceCategorySeed(key: key, name: "Kasa")])
        let vault = try #require(try store.categories().first { $0.source == key })
        let rows = [("Bulut konsolu", "ops@ornek.dev"), ("Eskiz", "melike@ornek.dev"), ("Kodhane", "melike@ornek.dev"), ("Kodhane", "deniz.k"),
                    ("Grafikler", "ops@ornek.dev"), ("İş Portalı", "deniz.k"), ("ornek.dev", "melike@ornek.dev")]
            .enumerated().map { SourceRow(id: "\($0.offset)", title: $0.element.0, subtitle: $0.element.1) }
        func vaultDescriptor(_ language: AppLanguage) -> SourceDescriptor {
            guard language == .english else { return FakeSources.vault() }
            return SourceDescriptor(extensionID: "dev.example.kasa", extensionName: "Vault", sourceID: "vault", title: "Vault", sensitive: true, actions: [
                SourceActionDescriptor(id: "password", kind: .secret, title: "Paste password", label: "Password"),
                SourceActionDescriptor(id: "username", kind: .text, title: "Paste username", label: "Username", copyTitle: "Copy username",
                                       copied: "Username copied."),
            ])
        }
        func write(_ view: some View, _ name: String, dark: Bool) {
            let framed = view
                .padding(30)
                .background(dark ? Color(red: 0.12, green: 0.16, blue: 0.35) : Color(red: 0.86, green: 0.89, blue: 0.97))
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: framed)
            renderer.scale = 2
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                let image = renderer.nsImage!
                let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
                try? rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("source-actions-\(name).png"))
            }
        }
        for (suffix, language, dark) in [("dark", AppLanguage.turkish, true), ("light-en", .english, false)] {
            func model(_ state: SourceCenter.State) -> PanelViewModel {
                let languageStore = LanguageStore(defaults: UserDefaults(suiteName: "snap-sa-\(UUID())")!)
                languageStore.language = language
                let sources = FakeSources()
                sources.descriptors = [vaultDescriptor(language)]
                sources.states[key] = state
                let model = PanelViewModel(library: library, language: languageStore, sources: sources, now: { now }, shiftHintDelay: .zero)
                model.reset()
                model.isPresented = true
                model.toggleShown(vault.id!)
                return model
            }
            func panel(_ model: PanelViewModel) -> some View {
                var panel = PanelView(model: model, material: .tunedEffect)
                panel.snapshot = true
                return panel
            }
            let entry = model(.rows(rows))
            _ = entry.handle(.move(2))
            write(panel(entry), "bar-\(suffix)", dark: dark)
            _ = entry.handle(.shiftHeld(true))
            write(panel(entry), "shift-\(suffix)", dark: dark)
            _ = entry.handle(.shiftHeld(false))
            _ = entry.handle(.commandHeld(true))
            let start = ContinuousClock.now
            while !entry.showsIndexKeys, ContinuousClock.now - start < .seconds(5) { try await Task.sleep(for: .milliseconds(20)) }
            write(panel(entry), "command-\(suffix)", dark: dark)
            _ = entry.handle(.commandHeld(false))
            _ = entry.handle(.toggleActions)
            write(panel(entry), "menu-\(suffix)", dark: dark)
            // The menu alone over the panel's solid surface: ImageRenderer draws its glass see-through.
            write(ActionMenuView(model: entry) { _ in }
                .background(Tokens.Colors.surfaceSolid, in: RoundedRectangle(cornerRadius: Tokens.Metrics.menuRadius, style: .continuous)),
                  "menu-alone-\(suffix)", dark: dark)
            _ = entry.handle(.escape)
            _ = entry.handle(.toggleTransforms)
            write(TransformPanelView(model: entry) { _ in }, "list-\(suffix)", dark: dark)
            _ = entry.handle(.move(2))
            write(TransformPanelView(model: entry) { _ in }, "list-copy-\(suffix)", dark: dark)
            let locked = model(.locked(message: language == .english ? "Vault is locked" : "Kasa kilitli",
                                       command: "kasa login --trust <e-posta>"))
            write(panel(locked), "locked-\(suffix)", dark: dark)
            _ = locked.handle(.toggleActions)
            write(ActionMenuView(model: locked) { _ in }
                .background(Tokens.Colors.surfaceSolid, in: RoundedRectangle(cornerRadius: Tokens.Metrics.menuRadius, style: .continuous)),
                  "locked-menu-\(suffix)", dark: dark)
            let notices: [NoticeKind] = [.sourcePasted, .sourceCopied(message: vaultDescriptor(language).copyAction?.copied), .secretCopiedOnly,
                                         .sourceNotPasted, .sourceEmpty, .sourceCommandCopied]
            write(VStack(alignment: .leading, spacing: 16) { ForEach(Array(notices.enumerated()), id: \.offset) { NoticeView(language: language, kind: $0.element) {} } },
                  "notices-\(suffix)", dark: dark)
        }
    }

    /// The job card (synthetic jobs) in both themes: running with a fraction, an indeterminate
    /// state word, queued, and finished (ready, done in Finder, a missing tool); then a
    /// mix of them in English, and the status item's ring.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderJobCard() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"]!)
        let finder = TargetInfo(bundleID: "com.apple.finder", name: "Finder", kind: .finder)
        let subject = "SwiftUI ile Liquid Glass — tam rehber"
        func command(_ action: String, _ language: AppLanguage) -> ExtensionCommand {
            let tr = language == .turkish
            return action == "video"
                ? FakeCommands.command("dev.example.video/video", title: tr ? "Video olarak indir" : "Download as Video", keywords: ["indir"],
                                       extensionName: "Video İndir", hint: false, icon: "sf:film", output: .file, targets: [.finder], isJob: true,
                                       failTitle: tr ? "Video indirilemedi" : "Couldn’t download the video")
                : FakeCommands.command("dev.example.video/audio", title: tr ? "Sesi indir" : "Download Audio", keywords: ["ses"],
                                       extensionName: "Video İndir", hint: false, icon: "sf:waveform", output: .file, targets: [.finder], isJob: true,
                                       failTitle: tr ? "Ses indirilemedi" : "Couldn’t download the audio")
        }
        func job(_ id: Int, _ action: String, _ phase: JobCenter.Job.Phase, _ language: AppLanguage = .turkish, subject: String = subject,
                 delivery: JobCenter.Job.Delivery? = nil, fraction: Double? = nil, message: String? = nil, result: String? = nil,
                 error: String? = nil, code: ExtensionError.Code? = nil) -> JobCenter.Job {
            JobCenter.Job(id: id, command: command(action, language), subjectTitle: subject, target: finder, toClipboard: false, phase: phase,
                          delivery: delivery, fraction: fraction, message: message, resultName: result, errorMessage: error, errorCode: code)
        }
        let photos = "Photos · @ornek.studio gönderisi"
        let wwdc = "WWDC26 · Tasarımda yenilikler"
        let states: [(String, AppLanguage, [JobCenter.Job])] = [
            ("running", .turkish, [job(1, "video", .running, fraction: 0.42, message: "18,4 / 43,7 MB · 1 dk kaldı")]),
            ("indeterminate", .turkish, [job(1, "video", .running, message: "Birleştiriliyor")]),
            ("queued", .turkish, [job(1, "audio", .queued)]),
            ("finished", .turkish, [job(1, "video", .ready, result: "\(subject).mp4"),
                                    job(2, "audio", .done, delivery: .pasted, result: "\(subject).m4a"),
                                    job(3, "video", .failed, error: "yt-dlp is not installed. Install it with: brew install yt-dlp",
                                        code: .toolMissing)]),
            ("scene", .turkish, [job(1, "video", .running, fraction: 0.15, message: "6,6 / 43,7 MB · 7 sn kaldı"),
                                 job(2, "audio", .running, fraction: 0.17, message: "2,9 / 17,2 MB · 4 sn kaldı"),
                                 job(3, "video", .running, subject: photos, message: "Bağlanıyor"),
                                 job(4, "video", .queued, subject: wwdc)]),
            ("scene-later", .turkish, [job(1, "video", .running, fraction: 0.78, message: "34,2 / 43,7 MB · 2 sn kaldı"),
                                       job(2, "audio", .running, message: "Ses ayrılıyor"),
                                       job(3, "video", .failed, subject: photos,
                                           error: "bu gönderi giriş istiyor. Ayarlar’da Video İndir için tarayıcı çerezlerini açabilirsin.",
                                           code: .script),
                                       job(4, "video", .running, subject: wwdc, fraction: 0.21, message: "9,0 / 43,7 MB · 6 sn kaldı")]),
            ("finished-en", .english, [job(1, "video", .ready, .english, result: "\(subject).mp4"),
                                       job(2, "audio", .done, .english, delivery: .stacked, result: "\(subject).m4a"),
                                       job(3, "video", .failed, .english, error: "yt-dlp is not installed", code: .toolMissing)]),
            ("running-en", .english, [job(1, "video", .running, .english, fraction: 0.42, message: "18.4 / 43.7 MB · 1 min left"),
                                      job(2, "audio", .running, .english, message: "Merging"),
                                      job(3, "audio", .queued, .english)]),
        ]
        for (name, language, jobs) in states {
            for (theme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                var card = JobCardView(jobs: jobs, language: language, onCancel: { _ in }, onDismiss: { _ in })
                card.snapshot = true
                let view = card
                    .padding(30)
                    .background(appearance == .darkAqua ? Color(red: 0.12, green: 0.16, blue: 0.35) : Color(red: 0.86, green: 0.89, blue: 0.97))
                    .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    let rendered = renderer.nsImage!
                    let rep = NSBitmapImageRep(data: rendered.tiffRepresentation!)!
                    try? rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("jobs-\(name)-\(theme).png"))
                }
            }
        }

        // The ring at a few fractions and while unknown, tinted as the menu bar would: white on a
        // dark bar, black on a light one, at 6× for a close look.
        let rings: [(Double?, Double)] = [(0, 0), (0.15, 0), (0.42, 0), (0.78, 0), (1, 0), (nil, 0), (nil, 0.35)]
        let scale: CGFloat = 6, cell: CGFloat = 34
        for (theme, background, tint) in [("dark", NSColor(red: 0.2, green: 0.17, blue: 0.4, alpha: 1), NSColor.white),
                                          ("light", NSColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1), NSColor.black)] {
            let width = Int(cell * CGFloat(rings.count) * scale), height = Int(cell * scale)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            background.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            for (index, ring) in rings.enumerated() {
                let template = StatusRingImage.image(fraction: ring.0, spinPhase: ring.1)
                let tinted = NSImage(size: template.size, flipped: false) { bounds in
                    template.draw(in: bounds)
                    tint.setFill()
                    bounds.fill(using: .sourceAtop)
                    return true
                }
                let side = template.size.width * scale
                tinted.draw(in: NSRect(x: (CGFloat(index) * cell + (cell - template.size.width) / 2) * scale, y: (cell * scale - side) / 2,
                                       width: side, height: side))
            }
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("ring-\(theme).png"))
        }
    }
}

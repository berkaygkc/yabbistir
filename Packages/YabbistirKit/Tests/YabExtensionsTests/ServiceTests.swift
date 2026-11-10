import CoreGraphics
import Foundation
import ImageIO
import Testing
import YabCore
import YabExtensionKit
import YabLocalization
import YabPasteboard
@testable import YabExtensions

@MainActor @Suite struct ServiceTests {
    let library: Library
    let registry: ExtensionRegistry
    let service: ExtensionService

    init() throws {
        library = try Library(store: ItemStore.temporary())
        let settings = ExtensionSettings(defaults: UserDefaults(suiteName: "yab-svc-\(UUID().uuidString)")!)
        registry = ExtensionRegistry(builtInRoot: BuiltinFolder.root, userRoot: RegistryFixture.temporary("Extensions"),
                                     dataRoot: RegistryFixture.temporary("Data"), settings: settings)
        let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-svc-lang-\(UUID().uuidString)")!, preferredLanguages: ["en"])
        language.language = .turkish
        service = ExtensionService(registry: registry, client: ExtensionHostClient(transport: PipeTransport()) { _, _ in },
                                   library: library, settings: settings, language: language)
    }

    func ingest(_ text: String) throws -> Int64 {
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(text.utf8))]],
                                source: nil, device: .local, capturedAt: Date())
        let item = try #require(try library.store.ingest(clip)).item
        library.didIngest(item)
        return item.id!
    }

    /// A service whose Outputs hold `limit` bytes, and the results in it.
    @MainActor final class Outputs {
        let files = ResultFiles(root: RegistryFixture.temporary("Outputs"))
        let library: Library
        let service: ExtensionService

        init(limit: Int, library: Library, registry: ExtensionRegistry) {
            let defaults = UserDefaults(suiteName: "yab-svc-outputs-\(UUID().uuidString)")!
            defaults.set(limit, forKey: "outputsLimitBytes")
            self.library = library
            service = ExtensionService(registry: registry, client: ExtensionHostClient(transport: PipeTransport()) { _, _ in }, library: library,
                                       settings: ExtensionSettings(defaults: defaults),
                                       language: LanguageStore(defaults: UserDefaults(suiteName: "yab-svc-lang-\(UUID().uuidString)")!, preferredLanguages: ["en"]),
                                       resultFiles: files)
        }

        /// A result joining history now, as the panel and jobs add theirs.
        func result(_ name: String, bytes: Int) throws -> Int64 {
            let file = try files.write(Data(count: bytes), named: name)
            return try #require(service.ingestResult(ResultRepresentations.make(.file(path: file.path)), from: "Test")?.id)
        }

        /// A result that joined history `ago` seconds back.
        func older(_ name: String, bytes: Int, ago: TimeInterval) throws -> Int64 {
            let file = try files.write(Data(count: bytes), named: name)
            let clip = CapturedClip(items: ResultRepresentations.make(.file(path: file.path)),
                                    source: SourceApp(bundleID: "dev.yabbistir.app", name: "yabbistir · Test"), device: .local,
                                    capturedAt: Date().addingTimeInterval(-ago))
            let item = try #require(try library.store.ingest(clip)).item
            library.didIngest(item)
            return try #require(item.id)
        }

        func inHistory(_ id: Int64) -> Bool { (try? library.store.item(id: id)) != nil }
    }

    /// A result's files count toward the Outputs limit as soon as the result joins history, not only at
    /// the next purge: the oldest results in no category leave history (their folders go with the next clean). Results
    /// from the last minute stay, even over the limit: the person is about to use them.
    @Test func aResultOverTheOutputsLimitTrimsTheOldestAtOnce() async throws {
        let outputs = Outputs(limit: 10, library: library, registry: registry)
        let oldest = try outputs.older("a.bin", bytes: 8, ago: 180)
        let older = try outputs.older("b.bin", bytes: 8, ago: 120)
        // Nothing trims until a result joins: 16 bytes against 10 for now.
        #expect(outputs.inHistory(oldest) && outputs.inHistory(older))
        // 18 bytes: the oldest goes, and that is enough.
        let fresh = try outputs.result("c.bin", bytes: 2)
        try await eventually { !outputs.inHistory(oldest) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(outputs.inHistory(older) && outputs.inHistory(fresh))
        // 30 bytes: the older one goes; the two fresh ones stay, still over the limit.
        let big = try outputs.result("d.bin", bytes: 20)
        try await eventually { !outputs.inHistory(older) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(outputs.inHistory(fresh) && outputs.inHistory(big))
    }

    /// Every trim spares every result from the last minute, not only the one it was started for. Two
    /// results back to back, over the limit together, both stay; an older one goes.
    @Test func resultsBackToBackAreBothSpared() async throws {
        let outputs = Outputs(limit: 10, library: library, registry: registry)
        let older = try outputs.older("a.bin", bytes: 8, ago: 120)
        let first = try outputs.result("b.bin", bytes: 8)
        let second = try outputs.result("c.bin", bytes: 8)
        try await eventually { !outputs.inHistory(older) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(outputs.inHistory(first))
        #expect(outputs.inHistory(second))
    }

    /// The UUID the preview shows is the UUID that gets pasted.
    @Test func aGeneratorPastesTheValueItShowed() async throws {
        let v4 = try #require(service.commands(matching: "uuid", subjectID: nil).first { $0.actionID == "v4" })
        service.requestHints(for: [v4], subjectID: nil)
        try await eventually { service.cachedOutput(of: v4, subjectID: nil) != nil }
        let shown = service.cachedOutput(of: v4, subjectID: nil)
        #expect(try await service.output(of: v4, subjectID: nil) == shown)
        #expect(try await service.output(of: v4, subjectID: nil) != shown)
    }

    /// An extension that never answers costs its own hint, not the others.
    @Test func aFailingExtensionDoesNotHideOthers() async throws {
        var manifest = RegistryFixture.manifest(id: "dev.example.hang")
        manifest["contributes"] = ["actions": [["id": "a", "title": "name", "keywords": "keywords", "input": "item",
                                                "accepts": ["kinds": ["text"]], "output": "text", "hint": true]]]
        let folder = try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: "dev.example.hang", manifest: manifest)
        try "exports.actions = { a: { run: () => new Promise(() => {}) } };".write(to: folder.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        try registry.install(folder: folder)
        let id = try ingest("merhaba dünya")
        let hang = try #require(service.transforms(forItemID: id).first { $0.extensionID == "dev.example.hang" })
        service.requestHints(for: [hang], subjectID: id)
        try await Task.sleep(for: .milliseconds(900))
        #expect(service.cachedOutput(of: hang, subjectID: id) == nil)
        let encode = try #require(service.transforms(forItemID: id).first { $0.actionID == "encode" })
        #expect(try await service.output(of: encode, subjectID: id) == .text("bWVyaGFiYSBkw7xueWE="))
    }

    /// A PNG copied in Finder is a file item; image actions still take it, with its pixels.
    @Test func aCopiedImageFileGetsImageTransforms() async throws {
        let folder = RegistryFixture.temporary("files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = folder.appendingPathComponent("Ekran Resmi.png")
        let context = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        let destination = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.fileURL, data: Data(png.absoluteString.utf8))]],
                                source: nil, device: .local, capturedAt: Date())
        let item = try #require(try library.store.ingest(clip)).item
        library.didIngest(item)
        #expect(item.kind == .file)
        let id = try #require(item.id)

        let ids = service.transforms(forItemID: id).map(\.id)
        #expect(ids.contains("dev.yabbistir.convert/ocr"))
        #expect(ids.contains("dev.yabbistir.convert/image#jpeg"))
        #expect(service.item(for: id, includeImage: true)?.image?.width == 64)
        #expect(service.item(for: id, includeImage: false)?.kind == "file")

        let jpeg = try #require(service.transforms(forItemID: id).first { $0.id == "dev.yabbistir.convert/image#jpeg" })
        guard case .image(_, let uti, let width, let height) = try await service.output(of: jpeg, subjectID: id) else {
            Issue.record("not an image")
            return
        }
        #expect(uti == "public.jpeg")
        #expect((width, height) == (64, 40))
    }

    /// A huge subject gets no speculative calls (hints, validation, preview sections).
    @Test func bigItemsGetNoSpeculativeCalls() async throws {
        let big = try ingest(String(repeating: "QUJD", count: 80_000))
        let encode = try #require(service.transforms(forItemID: big).first { $0.actionID == "encode" })
        service.requestHints(for: [encode], subjectID: big)
        try await Task.sleep(for: .milliseconds(300))
        #expect(service.speculativeCalls == 0)
        #expect(service.cachedOutput(of: encode, subjectID: big) == nil)
        #expect(service.hint(for: encode, subjectID: big) == encode.subtitle)
        let calls = service.validateCalls
        await service.detect(itemID: big)
        #expect(service.validateCalls == calls)
        #expect(try library.store.tags(ofItem: big).isEmpty)
    }

    @Test func bigRichTextStaysBehind() throws {
        let html = "<p>" + String(repeating: "a", count: 300_000) + "</p>"
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: ResultRepresentations.html, data: Data(html.utf8)),
                                         PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data("a".utf8))]],
                                source: nil, device: .local, capturedAt: Date())
        let item = try #require(try library.store.ingest(clip)).item
        #expect(service.item(for: item.id!, includeImage: false)?.richText == nil)
        let small = try ingest("<b>x</b>")
        _ = small
    }

    /// The launch scan gives the main actor room between items.
    @Test func backfillLetsTheMainActorBreathe() async throws {
        for index in 0..<300 { _ = try ingest("satır \(index) merhaba dünya") }
        let state = BackfillState()
        let backfill = Task { @MainActor in
            await service.backfill()
            state.done = true
        }
        await Task.yield()
        // Queued behind the scan: it runs mid-scan only if the scan steps aside.
        let ranDuringScan = await Task { @MainActor in !state.done }.value
        await backfill.value
        #expect(ranDuringScan)
    }

    /// "Turned off after repeated errors" is off everywhere, and turning it back on works.
    @Test func anExtensionTurnedOffByErrorsIsOffEverywhere() async throws {
        let settings = ExtensionSettings(defaults: UserDefaults(suiteName: "yab-svc-off-\(UUID().uuidString)")!)
        let registry = ExtensionRegistry(builtInRoot: BuiltinFolder.root, userRoot: RegistryFixture.temporary("Extensions"),
                                         dataRoot: RegistryFixture.temporary("Data"), settings: settings)
        let transport = FakeTransport { request in
            request.load != nil ? HostMessage(id: request.id, done: true) : HostClientTests.failing(request.id)
        }
        let client = ExtensionHostClient(transport: transport) { _, _ in }
        let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-svc-off-lang-\(UUID().uuidString)")!, preferredLanguages: ["en"])
        let service = ExtensionService(registry: registry, client: client, library: library, settings: settings, language: language)
        var turnedOff: [String] = []
        service.onExtensionTurnedOff = { turnedOff.append($0) }
        let v4 = try #require(service.commands(matching: "uuid", subjectID: nil).first { $0.actionID == "v4" })
        for _ in 0..<3 { _ = try? await service.output(of: v4, subjectID: nil) }
        #expect(turnedOff == ["dev.yabbistir.uuid"])
        #expect(!settings.isEnabled("dev.yabbistir.uuid"))
        #expect(service.commands(matching: "uuid", subjectID: nil).isEmpty)
        registry.setEnabled("dev.yabbistir.uuid", true)
        #expect(!client.isDisabled("dev.yabbistir.uuid"))
        #expect(!service.commands(matching: "uuid", subjectID: nil).isEmpty)
    }

    /// Turning an extension off, removing it or the master switch stops its jobs, running
    /// or waiting; an extension still usable keeps its own.
    @Test func aRegistryChangeCancelsTheJobsOfExtensionsThatCanNoLongerRun() async throws {
        let folder = try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: "dev.example.thirdparty")
        try registry.install(folder: folder)
        let runner = FakeRunner()
        let center = JobCenter(runner: runner, environment: FakeJobEnvironment())
        service.jobs = center
        func command(_ query: String, _ extensionID: String) throws -> ExtensionCommand {
            try #require(service.commands(matching: query, subjectID: nil).first { $0.extensionID == extensionID })
        }
        let uuid = center.start(try command("uuid", "dev.yabbistir.uuid"), subjectID: nil, subjectTitle: "a", target: nil, toClipboard: false)
        let thirdParty = center.start(try command("kx", "dev.example.thirdparty"), subjectID: nil, subjectTitle: "b", target: nil, toClipboard: false)
        let id = try ingest("merhaba")
        let encode = try #require(service.transforms(forItemID: id).first { $0.actionID == "encode" })
        let kept = center.start(encode, subjectID: id, subjectTitle: "c", target: nil, toClipboard: false)
        try await eventually { runner.calls.count == 3 }

        registry.setEnabled("dev.yabbistir.uuid", false)
        #expect(center.jobs.map(\.id) == [thirdParty, kept])
        registry.settings.thirdPartyDisabled = true
        registry.reload()
        #expect(center.jobs.map(\.id) == [kept])
        try await eventually { runner.cancelled == [0, 1] }
        _ = uuid
    }

    /// An extension whose index.js throws leaves the panel until its files change, and says why in the log.
    @Test func aFailingLoadHidesItsCommandsUntilItsFilesChange() async throws {
        let folder = try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: "dev.example.throws")
        try "throw new Error('boom');".write(to: folder.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        try registry.install(folder: folder)
        let command = try #require(service.commands(matching: "kx", subjectID: nil).first { $0.extensionID == "dev.example.throws" })
        await #expect(throws: ExtensionError.self) { _ = try await service.output(of: command, subjectID: nil) }
        #expect(!service.commands(matching: "kx", subjectID: nil).contains { $0.extensionID == "dev.example.throws" })
        registry.reload()
        #expect(service.commands(matching: "kx", subjectID: nil).contains { $0.extensionID == "dev.example.throws" })
    }

    /// A hint runs without network and programs, the run the person starts
    /// gets them, and the host learns what the manifest asks for and where tools are.
    @Test func onlyARunThePersonStartedGetsEffects() async throws {
        let settings = ExtensionSettings(defaults: UserDefaults(suiteName: "yab-svc-fx-\(UUID().uuidString)")!)
        let registry = ExtensionRegistry(builtInRoot: RegistryFixture.temporary("BuiltinExtensions"), userRoot: RegistryFixture.temporary("Extensions"),
                                         dataRoot: RegistryFixture.temporary("Data"), settings: settings)
        let id = "dev.example.net"
        var manifest = RegistryFixture.manifest(id: id, permissions: ["network"])
        manifest["network"] = ["domains": ["video.example"]]
        manifest["contributes"] = ["actions": [["id": "a", "title": "name", "keywords": "keywords", "input": "none", "output": "text", "hint": true]]]
        try registry.install(folder: try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: id, manifest: manifest))
        registry.approveRequested(id)
        let transport = FakeTransport { request in
            request.load != nil ? HostMessage(id: request.id, done: true) : HostMessage(id: request.id, ok: .result(.text("ok")))
        }
        let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-svc-fx-lang-\(UUID().uuidString)")!, preferredLanguages: ["en"])
        let service = ExtensionService(registry: registry, client: ExtensionHostClient(transport: transport) { _, _ in }, library: library,
                                       settings: settings, language: language, toolSearchPath: ["/opt/tools/bin"])
        let command = try #require(service.commands(matching: "kx", subjectID: nil).first { $0.extensionID == id })
        service.requestHints(for: [command], subjectID: nil)
        try await eventually { service.cachedOutput(of: command, subjectID: nil) != nil }
        service.resetSession()
        _ = try await service.output(of: command, subjectID: nil)
        #expect(transport.requests.compactMap(\.invoke).map(\.effects) == [false, true])
        let load = try #require(transport.requests.compactMap(\.load).first)
        #expect(load.grant == PermissionGrant(permissions: ["network"], domains: ["video.example"], tools: []))
        #expect(load.toolSearchPath == ["/opt/tools/bin"])
    }

    @Test func itemsCarryTheirText() throws {
        let id = try ingest("merhaba dünya")
        #expect(service.item(for: id, includeImage: false)?.text == "merhaba dünya")
        #expect(service.item(for: id, includeImage: false)?.kind == "text")
    }

    // MARK: yab.history

    /// A 64 × 40 PNG.
    static func png() -> Data {
        let context = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    func ingest(_ representation: PasteboardRepresentation) throws -> Int64 {
        let clip = CapturedClip(items: [[representation]], source: nil, device: .local, capturedAt: Date())
        let item = try #require(try library.store.ingest(clip)).item
        library.didIngest(item)
        return item.id!
    }

    /// `yab.history` hands out items built as any extension item, newest first, but never with an image's pixels: not a
    /// copied image's, not a picture copied as a file's. Texts and files keep what they say.
    @Test func historyItemsCarryNoPixels() async throws {
        let text = try ingest("merhaba dünya")
        let image = try ingest(PasteboardRepresentation(type: TypeIdentifiers.png, data: Self.png()))
        let folder = RegistryFixture.temporary("history")
        let png = folder.appendingPathComponent("Ekran Resmi.png")
        try Self.png().write(to: png)
        let file = try ingest(PasteboardRepresentation(type: TypeIdentifiers.fileURL, data: Data(png.absoluteString.utf8)))
        // Read with pixels, they are there to leave out.
        #expect(service.item(for: image, includeImage: true)?.image?.width == 64)
        #expect(service.item(for: file, includeImage: true)?.image?.width == 64)

        let recent = await service.historyItems(recent: 20)
        #expect(recent.map(\.id) == [file, image, text])
        #expect(recent.allSatisfy { $0.image == nil })
        #expect(recent.map(\.kind) == ["file", "image", "text"])
        #expect(recent[0].files?.map(\.name) == ["Ekran Resmi.png"])
        #expect(recent[2].text == "merhaba dünya")
        let found = await service.historyItems(matching: "dünya", limit: 20)
        #expect(found.map(\.id) == [text])
        #expect(found.first?.text == "merhaba dünya")
        #expect(await service.historyItems(matching: "Ekran", limit: 20).map(\.image) == [nil])
    }

    /// At most `limit` items, the newest, and never more than the router's 50 however many are asked for. Search finds what
    /// the panel's history search finds; an item taken out of history (kept in a category) is no longer history.
    @Test func historyGivesAtMostItsLimitNewestFirst() async throws {
        let ids = try (0..<60).map { try ingest("not \($0)") }
        #expect(await service.historyItems(recent: 5).map(\.id) == Array(ids.reversed().prefix(5)))
        #expect(await service.historyItems(recent: 5).map(\.text) == ["not 59", "not 58", "not 57", "not 56", "not 55"])
        #expect(await service.historyItems(recent: 500).count == 50)
        #expect(await service.historyItems(recent: 0).isEmpty)
        // "not 1", "not 10" … "not 19": eleven matches, the newest first.
        #expect(await service.historyItems(matching: "not 1", limit: 3).map(\.text) == ["not 19", "not 18", "not 17"])
        #expect(await service.historyItems(matching: "not 1", limit: 50).count == 11)
        #expect(await service.historyItems(matching: "nothing like it", limit: 50).isEmpty)

        let category = try library.createCategory(name: "Saklı")
        try library.add(ids[59], toCategory: category.id!)
        try library.deleteFromHistory(ids[59])
        #expect(await service.historyItems(recent: 1).map(\.text) == ["not 58"])
        #expect(await service.historyItems(matching: "not 59", limit: 50).isEmpty)
    }

    /// A command that makes files never runs ahead (it would litter work folders and Outputs); when it is used, the
    /// service adopts its files into Outputs and answers with those paths.
    @Test func aFileCommandNeverRunsAheadAndItsFilesAreAdopted() async throws {
        let settings = ExtensionSettings(defaults: UserDefaults(suiteName: "yab-svc-file-\(UUID().uuidString)")!)
        let registry = ExtensionRegistry(builtInRoot: RegistryFixture.temporary("BuiltinExtensions"), userRoot: RegistryFixture.temporary("Extensions"),
                                         dataRoot: RegistryFixture.temporary("Data"), settings: settings)
        let id = "dev.example.files"
        var manifest = RegistryFixture.manifest(id: id)
        manifest["contributes"] = ["actions": [["id": "a", "title": "name", "keywords": "keywords", "input": "none", "output": "file", "hint": true]]]
        try registry.install(folder: try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: id, manifest: manifest))
        let work = RegistryFixture.temporary("work")
        let folder = work.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "merhaba".write(to: folder.appendingPathComponent("not.txt"), atomically: true, encoding: .utf8)
        let path = folder.appendingPathComponent("not.txt").path
        let transport = FakeTransport { request in
            request.load != nil ? HostMessage(id: request.id, done: true) : HostMessage(id: request.id, ok: .result(.file(path: path)))
        }
        let outputs = RegistryFixture.temporary("Outputs")
        let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-svc-file-lang-\(UUID().uuidString)")!, preferredLanguages: ["en"])
        let service = ExtensionService(registry: registry, client: ExtensionHostClient(transport: transport) { _, _ in }, library: library,
                                       settings: settings, language: language, resultFiles: ResultFiles(root: outputs, workRoot: work))
        let command = try #require(service.commands(matching: "kx", subjectID: nil).first { $0.extensionID == id })
        #expect(!service.runsAhead(command, subjectID: nil))
        service.requestHints(for: [command], subjectID: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.speculativeCalls == 0)
        #expect(transport.requests.compactMap(\.invoke).isEmpty)

        guard case .files(let adopted) = try await service.output(of: command, subjectID: nil) else { Issue.record("expected files"); return }
        #expect(adopted.count == 1)
        #expect(try String(contentsOfFile: adopted[0], encoding: .utf8) == "merhaba")
        #expect(URL(fileURLWithPath: adopted[0]).resolvingSymlinksInPath().path.hasPrefix(outputs.resolvingSymlinksInPath().path))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
    /// A file result that cannot be adopted (no ResultFiles, or a refused path) does not leave its work folder for the 24 h purge.
    @Test func aFailedAdoptionRemovesTheWorkFolder() async throws {
        let settings = ExtensionSettings(defaults: UserDefaults(suiteName: "yab-svc-fail-\(UUID().uuidString)")!)
        let registry = ExtensionRegistry(builtInRoot: RegistryFixture.temporary("BuiltinExtensions"), userRoot: RegistryFixture.temporary("Extensions"),
                                         dataRoot: RegistryFixture.temporary("Data"), settings: settings)
        let id = "dev.example.failfiles"
        var manifest = RegistryFixture.manifest(id: id)
        manifest["contributes"] = ["actions": [["id": "a", "title": "name", "keywords": "keywords", "input": "none", "output": "file"]]]
        try registry.install(folder: try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: id, manifest: manifest))
        let work = RegistryFixture.temporary("work")
        let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-svc-fail-lang-\(UUID().uuidString)")!, preferredLanguages: ["en"])

        func service(returning path: String, files: ResultFiles?) -> ExtensionService {
            let transport = FakeTransport { request in
                request.load != nil ? HostMessage(id: request.id, done: true) : HostMessage(id: request.id, ok: .result(.file(path: path)))
            }
            return ExtensionService(registry: registry, client: ExtensionHostClient(transport: transport) { _, _ in }, library: library,
                                    settings: settings, language: language, resultFiles: files)
        }
        // No ResultFiles: the folder is in the real work root.
        let shared = try WorkFolders.make()
        try "x".write(to: shared.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let first = service(returning: shared.appendingPathComponent("a.txt").path, files: nil)
        let command = try #require(first.commands(matching: "kx", subjectID: nil).first { $0.extensionID == id })
        await #expect(throws: ExtensionError.self) { _ = try await first.output(of: command, subjectID: nil) }
        #expect(!FileManager.default.fileExists(atPath: shared.path))

        // A refused path (a directory) inside a work folder: that folder goes; a folder outside the work root stays.
        let folder = work.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let outside = RegistryFixture.temporary("outside")
        let second = service(returning: folder.appendingPathComponent("sub").path, files: ResultFiles(root: RegistryFixture.temporary("Outputs"), workRoot: work))
        await #expect(throws: ExtensionError.self) { _ = try await second.output(of: command, subjectID: nil) }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let third = service(returning: outside.path, files: ResultFiles(root: RegistryFixture.temporary("Outputs"), workRoot: work))
        await #expect(throws: ExtensionError.self) { _ = try await third.output(of: command, subjectID: nil) }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    /// A service over one synthetic extension whose action is `action`; a call answers with the name
    /// of the target it was given ("ok" without one), and `slowLoad` keeps each load 200 ms on its way.
    /// The extension is in place before the registry starts watching, so no reload drops a session's outputs.
    func service(action: [String: Any], slowLoad: Bool = false) throws -> (ExtensionService, FakeTransport, ExtensionCommand) {
        let settings = ExtensionSettings(defaults: UserDefaults(suiteName: "yab-svc-one-\(UUID().uuidString)")!)
        let id = "dev.example.one"
        var manifest = RegistryFixture.manifest(id: id)
        manifest["contributes"] = ["actions": [action]]
        let user = RegistryFixture.temporary("Extensions")
        try RegistryFixture.write(in: user, id: id, manifest: manifest)
        let registry = ExtensionRegistry(builtInRoot: RegistryFixture.temporary("BuiltinExtensions"), userRoot: user,
                                         dataRoot: RegistryFixture.temporary("Data"), settings: settings)
        let transport = FakeTransport { request in
            guard let invoke = request.invoke else {
                if slowLoad, request.load != nil { Thread.sleep(forTimeInterval: 0.2) }
                return HostMessage(id: request.id, done: true)
            }
            return HostMessage(id: request.id, ok: .result(.text(invoke.context.target?.name ?? "ok")))
        }
        let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-svc-one-lang-\(UUID().uuidString)")!, preferredLanguages: ["en"])
        let service = ExtensionService(registry: registry, client: ExtensionHostClient(transport: transport) { _, _ in }, library: library,
                                       settings: settings, language: language)
        let command = try #require(service.commands(matching: "kx", subjectID: nil).first { $0.extensionID == id })
        return (service, transport, command)
    }

    /// A job never runs ahead, even when its manifest asks for a hint; it runs only when the person starts it.
    @Test func aJobNeverRunsAhead() async throws {
        let (service, transport, command) = try service(action: ["id": "a", "title": "name", "keywords": "keywords", "input": "none",
                                                                 "output": "text", "hint": true, "job": true])
        #expect(command.isJob)
        #expect(!service.runsAhead(command, subjectID: nil))
        service.requestHints(for: [command], subjectID: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.speculativeCalls == 0)
        #expect(transport.requests.compactMap(\.invoke).isEmpty)
    }

    /// The paste target the panel opened for reaches every call: hints and runs alike.
    @Test func theTargetTravelsWithEveryCall() async throws {
        let (service, transport, command) = try service(action: ["id": "a", "title": "name", "keywords": "keywords", "input": "none",
                                                                 "output": "text", "hint": true])
        let finder = TargetInfo(bundleID: "com.apple.finder", name: "Finder", kind: .finder)
        service.target = finder
        service.requestHints(for: [command], subjectID: nil)
        // The hint's request is what counts (the registry's own reload may drop its answer).
        try await eventually { transport.requests.contains { $0.invoke != nil } }
        service.resetSession()
        _ = try await service.output(of: command, subjectID: nil)
        let contexts = transport.requests.compactMap(\.invoke).map(\.context)
        #expect(contexts.count == 2)
        #expect(contexts.allSatisfy { $0.target == finder })
    }

    static let finder = TargetInfo(bundleID: "com.apple.finder", name: "Finder", kind: .finder)
    static let editor = TargetInfo(bundleID: "dev.zed.Zed", name: "Zed", kind: .editor)

    /// The panel can close (and the target change) while a run is loading: the run still goes where it started for.
    @Test func aCallKeepsTheTargetItStartedWith() async throws {
        let (service, transport, command) = try service(action: ["id": "a", "title": "name", "keywords": "keywords", "input": "none",
                                                                 "output": "text"], slowLoad: true)
        service.target = Self.finder
        let run = Task { try await service.output(of: command, subjectID: nil) }
        try await eventually { transport.requests.contains { $0.load != nil } }
        service.target = Self.editor
        #expect(try await run.value == .text("Finder"))
        #expect(transport.requests.compactMap(\.invoke).map(\.context.target) == [Self.finder])
    }

    /// The panel closes (and lets its target go) before the command it closed for runs: the run is
    /// given the panel's target and pastes the value its row showed, not a new one.
    @Test func aShownValueIsPastedEvenAfterTheTargetClears() async throws {
        let v4 = try #require(service.commands(matching: "uuid", subjectID: nil).first { $0.actionID == "v4" })
        service.target = Self.finder
        service.requestHints(for: [v4], subjectID: nil)
        try await eventually { service.cachedOutput(of: v4, subjectID: nil) != nil }
        let shown = try #require(service.cachedOutput(of: v4, subjectID: nil))
        service.target = nil
        #expect(try await service.output(of: v4, subjectID: nil, target: Self.finder) == shown)
        // A generator's value is used once; the next run makes a new one.
        #expect(try await service.output(of: v4, subjectID: nil, target: Self.finder) != shown)
    }

    /// The panel closes and opens again for the same app while a hint is on its way: the hint is
    /// that session's (its request was not sent twice, so dropping it would leave the row empty).
    @Test func aHintOnItsWayIsKeptWhenThePanelReopensForTheSameApp() async throws {
        let (service, transport, command) = try service(action: ["id": "a", "title": "name", "keywords": "keywords", "input": "none",
                                                                 "output": "text", "hint": true], slowLoad: true)
        service.target = Self.finder
        service.requestHints(for: [command], subjectID: nil)
        try await eventually { transport.requests.contains { $0.load != nil } }
        service.target = nil
        service.target = Self.finder
        service.requestHints(for: [command], subjectID: nil)
        try await eventually { service.cachedOutput(of: command, subjectID: nil) != nil }
        #expect(service.cachedOutput(of: command, subjectID: nil) == .text("Finder"))
        #expect(transport.requests.compactMap(\.invoke).count == 1)
    }

    /// A run goes to the target it is given, whatever the service's current one is.
    @Test func aCallUsesTheTargetItWasGiven() async throws {
        let (service, transport, command) = try service(action: ["id": "a", "title": "name", "keywords": "keywords", "input": "none",
                                                                 "output": "text"])
        service.target = Self.editor
        #expect(try await service.output(of: command, subjectID: nil, target: Self.finder) == .text("Finder"))
        service.target = nil
        #expect(try await service.output(of: command, subjectID: nil, target: Self.editor) == .text("Zed"))
        #expect(transport.requests.compactMap(\.invoke).map(\.context.target) == [Self.finder, Self.editor])
    }

    /// A hint still on its way when the target changes is not the new target's: it is dropped, and
    /// the new target gets its own at once.
    @Test func aHintMadeForAnEarlierTargetIsDropped() async throws {
        let (service, transport, command) = try service(action: ["id": "a", "title": "name", "keywords": "keywords", "input": "none",
                                                                 "output": "text", "hint": true], slowLoad: true)
        service.target = Self.finder
        service.requestHints(for: [command], subjectID: nil)
        try await eventually { transport.requests.contains { $0.load != nil } }
        service.target = Self.editor
        service.requestHints(for: [command], subjectID: nil)
        try await eventually { transport.requests.compactMap(\.invoke).count == 2 }
        try await eventually { service.cachedOutput(of: command, subjectID: nil) != nil }
        try await Task.sleep(for: .milliseconds(200))
        // One call each, each with its own target. Both wait for the same load and go on together: which reaches the
        // host first is the main actor's choice, not the order they were asked in.
        let targets = transport.requests.compactMap(\.invoke).map(\.context.target)
        #expect(targets.count == 2 && targets.contains(Self.finder) && targets.contains(Self.editor))
        #expect(service.cachedOutput(of: command, subjectID: nil) == .text("Zed"))
    }

    /// A job, or a run the person started, of an extension whose
    /// second required tool is missing fails before the host with `toolMissing` naming that tool, in
    /// exec's words (so the card says "ffmpeg bulunamadı").
    @Test func aMissingRequiredToolFailsTheRunBeforeTheHost() async throws {
        let settings = ExtensionSettings(defaults: UserDefaults(suiteName: "yab-svc-tools-\(UUID().uuidString)")!)
        let id = "dev.example.tools"
        var manifest = RegistryFixture.manifest(id: id, permissions: ["exec"])
        manifest["requires"] = ["tools": [["name": "yt-dlp", "install": "brew install yt-dlp"], ["name": "ffmpeg", "install": "brew install ffmpeg"]]]
        manifest["contributes"] = ["actions": [
            ["id": "download", "title": "name", "keywords": "keywords", "input": "none", "output": "file", "job": true],
            ["id": "a", "title": "name", "keywords": "keywords", "input": "none", "output": "text"],
        ]]
        let user = RegistryFixture.temporary("Extensions")
        try RegistryFixture.write(in: user, id: id, manifest: manifest)
        let registry = ExtensionRegistry(builtInRoot: RegistryFixture.temporary("BuiltinExtensions"), userRoot: user,
                                         dataRoot: RegistryFixture.temporary("Data"), settings: settings)
        registry.approveRequested(id)
        // yt-dlp is there; ffmpeg is not.
        let tools = RegistryFixture.temporary("tools")
        let ytdlp = tools.appendingPathComponent("yt-dlp")
        try "#!/bin/sh\n".write(to: ytdlp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ytdlp.path)
        let main = FakeTransport { request in HostMessage(id: request.id, done: true) }
        let jobs = FakeTransport { request in HostMessage(id: request.id, done: true) }
        let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-svc-tools-lang-\(UUID().uuidString)")!, preferredLanguages: ["en"])
        let service = ExtensionService(registry: registry, client: ExtensionHostClient(transport: main) { _, _ in },
                                       jobClient: ExtensionHostClient(transport: jobs) { _, _ in }, library: library, settings: settings,
                                       language: language, toolSearchPath: [tools.path])
        let commands = service.commands(matching: "kx", subjectID: nil).filter { $0.extensionID == id }
        let job = try #require(commands.first { $0.actionID == "download" })
        let run = try #require(commands.first { $0.actionID == "a" })

        let missing = ExtensionError(.toolMissing, "ffmpeg is not installed. Install it with: brew install ffmpeg")
        await #expect(throws: missing) { _ = try await service.runJob(job, subjectID: nil, target: nil) { _, _ in } }
        await #expect(throws: missing) { _ = try await service.output(of: run, subjectID: nil) }
        #expect(jobs.requests.compactMap(\.invoke).isEmpty)
        #expect(main.requests.compactMap(\.invoke).isEmpty)
    }

    /// Jobs run in a host of their own, so a hint that runs out of time (and restarts its
    /// host) never cuts a download short. The job gets effects, no clock, the target it started
    /// with and its files adopted into Outputs.
    @Test func aSlowHintDoesNotInterruptAJob() async throws {
        let settings = ExtensionSettings(defaults: UserDefaults(suiteName: "yab-svc-job-\(UUID().uuidString)")!)
        let id = "dev.example.job"
        var manifest = RegistryFixture.manifest(id: id)
        manifest["contributes"] = ["actions": [
            ["id": "hint", "title": "name", "keywords": "keywords", "input": "none", "output": "text", "hint": true],
            ["id": "download", "title": "name", "keywords": "keywords", "input": "none", "output": "file", "job": true],
        ]]
        let user = RegistryFixture.temporary("Extensions")
        try RegistryFixture.write(in: user, id: id, manifest: manifest)
        let registry = ExtensionRegistry(builtInRoot: RegistryFixture.temporary("BuiltinExtensions"), userRoot: user,
                                         dataRoot: RegistryFixture.temporary("Data"), settings: settings)
        let work = RegistryFixture.temporary("work")
        let folder = work.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("Liquid Glass.mp4").path
        try Data("mp4".utf8).write(to: URL(fileURLWithPath: path))

        // The hint's host never answers; the job's answers once the test lets it.
        let main = FakeTransport { request in request.load != nil ? HostMessage(id: request.id, done: true) : nil }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let jobs = FakeTransport { request in
            guard request.invoke != nil else { return HostMessage(id: request.id, done: true) }
            gate.wait()
            return HostMessage(id: request.id, ok: .result(.file(path: path)))
        }
        let outputs = RegistryFixture.temporary("Outputs")
        let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-svc-job-lang-\(UUID().uuidString)")!, preferredLanguages: ["en"])
        let service = ExtensionService(registry: registry, client: ExtensionHostClient(transport: main) { _, _ in },
                                       jobClient: ExtensionHostClient(transport: jobs) { _, _ in }, library: library, settings: settings,
                                       language: language, toolSearchPath: ["/opt/tools/bin"], resultFiles: ResultFiles(root: outputs, workRoot: work))
        let commands = service.commands(matching: "kx", subjectID: nil).filter { $0.extensionID == id }
        let hint = try #require(commands.first { $0.actionID == "hint" })
        let job = try #require(commands.first { $0.actionID == "download" })
        service.target = Self.editor

        let runner: JobRunning = service
        let download = Task { try await runner.run(job, subjectID: nil, target: Self.finder) { _, _ in } }
        try await eventually { jobs.requests.contains { $0.invoke != nil } }
        service.requestHints(for: [hint], subjectID: nil)
        // The hint ran out of time and its host restarted.
        try await eventually { main.restarts == 1 }
        gate.signal()

        guard case .files(let adopted) = try await download.value else { Issue.record("expected files"); return }
        #expect(adopted.map { URL(fileURLWithPath: $0).lastPathComponent } == ["Liquid Glass.mp4"])
        #expect(URL(fileURLWithPath: adopted[0]).resolvingSymlinksInPath().path.hasPrefix(outputs.resolvingSymlinksInPath().path))
        #expect(jobs.restarts == 0)
        let invoke = try #require(jobs.requests.compactMap(\.invoke).first)
        #expect(invoke.name == "download")
        #expect(invoke.effects)
        #expect(invoke.context.target == Self.finder)
        #expect(jobs.requests.compactMap(\.load).first?.toolSearchPath == ["/opt/tools/bin"])
        #expect(main.requests.compactMap(\.invoke).map(\.name) == ["hint"])
    }
}

@MainActor final class BackfillState {
    var done = false

}

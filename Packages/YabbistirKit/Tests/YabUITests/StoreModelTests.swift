import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing
import YabExtensionKit
import YabExtensions
import YabLocalization
import YabPlatform
@testable import YabUI

/// Answers store requests from a table keyed by host, so suites running side by side never see each other's requests.
final class StoreTabMockProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: [String: Result<Data, URLError>]] = [:]
    nonisolated(unsafe) private static var seen: [String: [String]] = [:]

    static func serve(host: String, _ paths: [String: Result<Data, URLError>]) { lock.withLock { answers[host] = paths } }
    static func paths(host: String) -> [String] { lock.withLock { seen[host] ?? [] } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StoreTabMockProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let host = url.host ?? ""
        let answer: Result<Data, URLError>? = Self.lock.withLock {
            Self.seen[host, default: []].append(url.path)
            return Self.answers[host]?[url.path]
        }
        switch answer {
        case .success(let data):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case nil:
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

/// A synthetic store: catalog entries, the extension folders behind them, and their packages.
@MainActor struct StoreFixture {
    struct Entry {
        var id: String
        var version = "1.0.0"
        var apiVersion = 1
        var minApp: String?
        var name: [String: String]
        var description: [String: String]
        var categories = ["text"]
        var icon = "sf:number"
        var permissions: [String] = []
        var hosts: [String] = []
        var tools: [String] = []
    }

    static let builtIns = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Extensions/BuiltinExtensions")

    /// The shapes of the store's first extensions.
    static let video = Entry(id: "dev.example.video-download", name: ["en": "Download Video", "tr": "Video İndir"],
                             description: ["en": "Downloads video links as an MP4 video or M4A audio with yt-dlp.",
                                           "tr": "Video linklerini yt-dlp ile MP4 video ya da M4A ses olarak indirir."],
                             categories: ["files"], icon: "sf:arrow.down.circle", permissions: ["network", "exec"],
                             hosts: ["video.example", "vid.example", "clips.example"], tools: ["yt-dlp", "ffmpeg", "deno"])
    static let linkClean = Entry(id: "dev.example.link-clean", name: ["en": "Link Cleaner", "tr": "Link Temizle"],
                                 description: ["en": "Strips tracking parameters from the links you copy.",
                                               "tr": "Kopyaladığın linklerden izleme parametrelerini siler."],
                                 categories: ["links"], icon: "sf:link.badge.plus", permissions: ["capture"])
    static let translate = Entry(id: "dev.example.translate", name: ["en": "Translate", "tr": "Çevir"],
                                 description: ["en": "Translates text on this Mac and summarizes it.",
                                               "tr": "Metni bu Mac’te çevirir ve özetler."],
                                 categories: ["text", "ai"], icon: "sf:character.bubble")
    static let jwt = Entry(id: "dev.example.jwt", name: ["en": "JWT", "tr": "JWT"],
                           description: ["en": "Recognizes copied JSON Web Tokens and shows what is inside.",
                                         "tr": "Kopyalanan JSON Web Token'ları tanır ve içini gösterir."],
                           categories: ["developer"], icon: "sf:key.horizontal")

    let host = "store-tab-\(UUID().uuidString.lowercased()).test"
    let key = Curve25519.Signing.PrivateKey()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("yab-store-tab-\(UUID().uuidString)")
    let settings = ExtensionSettings(defaults: UserDefaults(suiteName: "yab-store-tab-\(UUID().uuidString)")!)
    let languageStore = LanguageStore(defaults: UserDefaults(suiteName: "yab-store-tab-lang-\(UUID().uuidString)")!)
    let registry: ExtensionRegistry

    init(language: AppLanguage = .english) {
        registry = ExtensionRegistry(builtInRoot: Self.builtIns, userRoot: root.appendingPathComponent("Extensions"),
                                     dataRoot: root.appendingPathComponent("Data"), settings: settings)
        languageStore.language = language
    }

    var cache: URL { root.appendingPathComponent("Store") }
    var catalogURL: URL { URL(string: "https://\(host)/v1/catalog.json")! }

    func client(app: String = "1.0.0") -> StoreClient {
        StoreClient(catalogURL: catalogURL, keys: [key.publicKey], cacheFolder: cache, registry: registry,
                    appVersion: SemanticVersion(app)!, session: StoreTabMockProtocol.session())
    }

    func model(app: String = "1.0.0") -> StoreModel {
        StoreModel(client: client(app: app), registry: registry, language: languageStore)
    }

    var requests: [String] { StoreTabMockProtocol.paths(host: host) }
    var catalogRequests: Int { requests.filter { $0 == "/v1/catalog.json" }.count }
    var packageRequests: Int { requests.filter { $0.hasPrefix("/v1/packages/") }.count }

    // MARK: Folders and packages

    /// A valid extension folder for `entry`, in a scratch folder.
    func folder(_ entry: Entry) throws -> URL {
        let folder = root.appendingPathComponent("source-\(UUID().uuidString)/\(entry.id)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("locales"), withIntermediateDirectories: true)
        var manifest: [String: Any] = [
            "id": entry.id, "version": entry.version, "apiVersion": 1, "defaultLocale": "en", "name": "name", "description": "description",
            "icon": entry.icon, "author": "Berkay Gökçe", "license": "MIT", "permissions": entry.permissions, "categories": entry.categories,
            "contributes": ["actions": [["id": "a", "title": "name", "keywords": "keywords", "input": "none", "output": "text"]]],
        ]
        if !entry.hosts.isEmpty { manifest["network"] = ["domains": entry.hosts] }
        if !entry.tools.isEmpty { manifest["requires"] = ["tools": entry.tools.map { ["name": $0, "install": "brew install \($0)"] }] }
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        for language in ["en", "tr"] {
            let table: [String: Any] = ["name": entry.name[language] ?? entry.id, "description": entry.description[language] ?? "", "keywords": ["k"]]
            try JSONSerialization.data(withJSONObject: table).write(to: folder.appendingPathComponent("locales/\(language).json"))
        }
        try "exports.actions = { a: { run: () => ({ text: 'ok' }) } };"
            .write(to: folder.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        return folder
    }

    /// Installs `entry` as a local copy and approves what it asks for.
    func installLocally(_ entry: Entry) throws {
        let id = try registry.install(folder: folder(entry))
        guard let manifest = registry.installed.first(where: { $0.id == id })?.manifest else { return }
        registry.approve(id, grant: PermissionGrant.requested(by: manifest))
    }

    func package(_ entry: Entry) throws -> Data {
        let folder = try folder(entry)
        let archive = folder.deletingLastPathComponent().appendingPathComponent("out.yabext")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", folder.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()
        return try Data(contentsOf: archive)
    }

    // MARK: Catalog

    func catalog(_ entries: [Entry], packages: [String: Data] = [:]) throws -> Data {
        let list: [[String: Any]] = entries.map { entry in
            let bytes = packages[entry.id]
            var json: [String: Any] = [
                "id": entry.id, "version": entry.version, "apiVersion": entry.apiVersion, "name": entry.name, "description": entry.description,
                "author": "Berkay Gökçe", "categories": entry.categories, "icon": entry.icon, "permissions": entry.permissions,
                "networkHosts": entry.hosts, "tools": entry.tools,
                "sha256": bytes.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? String(repeating: "a", count: 64),
                "size": bytes?.count ?? 1, "updatedAt": "2026-10-30T12:00:00Z", "readme": "https://\(host)/readme/\(entry.id)",
                "package": "https://\(host)/v1/packages/\(entry.id).yabext",
            ]
            json["minAppVersion"] = entry.minApp ?? NSNull()
            return json
        }
        let catalog: [String: Any] = ["formatVersion": 1, "generatedAt": "2026-10-31T09:30:00Z", "extensions": list]
        return try JSONSerialization.data(withJSONObject: catalog)
    }

    func signature(_ catalog: Data) throws -> Data {
        Data(try key.signature(for: catalog).base64EncodedString().utf8)
    }

    /// Serves a signed catalog of `entries` and, for those in `packaged`, a package each.
    func serve(_ entries: [Entry], packaged: [Entry] = []) throws {
        var packages: [String: Data] = [:]
        for entry in packaged { packages[entry.id] = try package(entry) }
        let catalog = try catalog(entries, packages: packages)
        var paths: [String: Result<Data, URLError>] = ["/v1/catalog.json": .success(catalog),
                                                       "/v1/catalog.json.sig": .success(try signature(catalog))]
        for (id, bytes) in packages { paths["/v1/packages/\(id).yabext"] = .success(bytes) }
        StoreTabMockProtocol.serve(host: host, paths)
    }

    func serveOffline() {
        StoreTabMockProtocol.serve(host: host, ["/v1/catalog.json": .failure(URLError(.notConnectedToInternet)),
                                                "/v1/catalog.json.sig": .failure(URLError(.notConnectedToInternet))])
    }

    /// Puts `view` in a window and lets it appear and settle, as the Settings window would.
    func host<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view.frame(width: 660, height: 540))
        host.frame = NSRect(x: 0, y: 0, width: 660, height: 540)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView = nil
    }
}

@MainActor @Suite(.serialized) struct StoreModelTests {
    typealias F = StoreFixture

    // MARK: Network

    @Test func openingTheTabRefreshesOnce() async throws {
        let fixture = StoreFixture()
        try fixture.serve([F.video, F.jwt])
        let model = fixture.model()
        #expect(fixture.requests.isEmpty)
        model.appeared()
        model.appeared()
        await model.refreshTask?.value
        model.appeared()
        await model.refreshTask?.value
        #expect(fixture.catalogRequests == 1)
        #expect(Set(model.rows.map(\.id)) == [F.video.id, F.jwt.id])
        // From then on only "Refresh" goes out again.
        model.refresh()
        await model.refreshTask?.value
        #expect(fixture.catalogRequests == 2)
        // A new Settings session: the first look at the tab refreshes once more.
        model.disappeared()
        model.beginSession()
        #expect(fixture.catalogRequests == 2)
        model.appeared()
        model.appeared()
        await model.refreshTask?.value
        #expect(fixture.catalogRequests == 3)
    }

    @Test func otherTabsNeverTouchTheNetwork() async throws {
        let fixture = StoreFixture()
        try fixture.serve([F.video])
        let settingsModel = ExtensionsSettingsModel(registry: fixture.registry, settings: fixture.settings, language: fixture.languageStore,
                                                    logs: ExtensionLogBuffer())
        let store = fixture.model()
        // A cache from an earlier session is read without the network.
        let earlier = fixture.model()
        earlier.appeared()
        await earlier.refreshTask?.value
        let afterEarlier = fixture.requests.count
        for tab in [ExtensionsSettingsView.Tab.installed, .development] {
            fixture.host(ExtensionsSettingsView(model: settingsModel, store: store, tab: tab))
        }
        #expect(fixture.requests.count == afterEarlier)
        #expect(store.refreshTask == nil)
        // The Store tab is the one place that asks.
        fixture.host(ExtensionsSettingsView(model: settingsModel, store: store, tab: .store))
        await store.refreshTask?.value
        #expect(fixture.catalogRequests == 2)
        #expect(store.rows.map(\.id) == [F.video.id])
    }

    @Test func theCachedListStaysWhenTheStoreCannotBeReached() async throws {
        let fixture = StoreFixture()
        try fixture.serve([F.video, F.jwt])
        let first = fixture.model()
        first.appeared()
        await first.refreshTask?.value
        fixture.serveOffline()
        let model = fixture.model()
        model.appeared()
        // The cache is on screen before the network answers.
        #expect(model.rows.count == 2)
        await model.refreshTask?.value
        #expect(model.rows.count == 2)
        #expect(model.notice?.text == "Couldn’t reach the store. Showing the saved list.")
        fixture.languageStore.language = .turkish
        #expect(model.notice?.text == "Mağazaya ulaşılamadı. Önbellekteki liste gösteriliyor.")
        // Without a cache the same failure fills the tab instead.
        let bare = StoreFixture(language: .turkish)
        bare.serveOffline()
        let empty = bare.model()
        empty.appeared()
        await empty.refreshTask?.value
        #expect(empty.rows.isEmpty)
        #expect(empty.unavailable?.title == "Mağazaya ulaşılamadı.")
    }

    @Test func anUnverifiedCatalogSaysSoCalmly() async throws {
        let fixture = StoreFixture(language: .turkish)
        let catalog = try fixture.catalog([F.video])
        let stranger = Curve25519.Signing.PrivateKey()
        StoreTabMockProtocol.serve(host: fixture.host, ["/v1/catalog.json": .success(catalog),
                                                        "/v1/catalog.json.sig": .success(Data(try stranger.signature(for: catalog).base64EncodedString().utf8))])
        let model = fixture.model()
        model.appeared()
        await model.refreshTask?.value
        #expect(model.rows.isEmpty)
        #expect(model.unavailable?.title == "Katalog doğrulanamadı; hiçbir şey kurulmadı.")
    }

    // MARK: Selecting

    @Test func incompatibleRowsCannotBeSelected() async throws {
        let fixture = StoreFixture()
        var newer = F.translate
        newer.minApp = "9.0.0"
        var futureAPI = F.linkClean
        futureAPI.apiVersion = 2
        let builtIn = StoreFixture.Entry(id: "dev.yabbistir.uuid", name: ["en": "UUID"], description: ["en": "Makes UUIDs."])
        try fixture.serve([F.video, newer, futureAPI, builtIn])
        let model = fixture.model()
        model.appeared()
        await model.refreshTask?.value

        for id in [newer.id, futureAPI.id, builtIn.id] {
            model.setSelected(id, true)
            #expect(model.row(id)?.isSelectable == false)
        }
        #expect(model.selectedCount == 0)
        #expect(model.row(newer.id)?.statusLabel == "Requires a newer yabbistir")
        #expect(model.row(futureAPI.id)?.statusLabel == "Requires a newer yabbistir")
        #expect(model.row(builtIn.id)?.statusLabel == "Built-in")

        model.setSelected(F.video.id, true)
        #expect(model.selectedCount == 1)
        #expect(model.installTitle == "Install (1)")
        // Even a selection made around the checkboxes installs only what can be installed.
        model.selection.formUnion([newer.id, builtIn.id])
        #expect(model.selectedCount == 1)
        model.installSelected()
        #expect(model.pendingConsent?.items.map(\.id) == [F.video.id])
    }

    @Test func oneConsentListsEverySelectedExtension() async throws {
        let fixture = StoreFixture()
        try fixture.serve([F.video, F.linkClean, F.jwt], packaged: [F.video, F.linkClean, F.jwt])
        let model = fixture.model()
        model.appeared()
        await model.refreshTask?.value
        for id in [F.video.id, F.linkClean.id, F.jwt.id] { model.setSelected(id, true) }
        #expect(model.installTitle == "Install (3)")
        model.installSelected()

        let consent = try #require(model.pendingConsent)
        #expect(consent.kind == .install)
        #expect(Set(consent.items.map(\.id)) == [F.video.id, F.linkClean.id, F.jwt.id])
        let video = try #require(consent.items.first { $0.id == F.video.id })
        #expect(video.sentences == ConsentText.sentences(permissions: F.video.permissions, domains: F.video.hosts, tools: F.video.tools,
                                                         language: .english))
        #expect(video.sentences.count == 2)
        #expect(consent.items.first { $0.id == F.linkClean.id }?.sentences == [L10n.string("permissions.capture", .english)])
        #expect(consent.items.first { $0.id == F.jwt.id }?.sentences == [])
        // Asking downloads nothing.
        #expect(fixture.packageRequests == 0)

        model.confirmConsent()
        #expect(model.pendingConsent == nil)
        await model.installTask?.value
        #expect(model.failures.isEmpty)
        for item in consent.items {
            let installed = try #require(fixture.registry.installed.first { $0.id == item.id })
            // Exactly what the sheet showed is what was approved.
            #expect(installed.grant == item.grant)
            #expect(!installed.needsConsent)
        }
        #expect(model.row(F.video.id)?.statusLabel == "Installed")
        #expect(model.selectedCount == 0)
    }

    @Test func cancellingTheConsentInstallsNothing() async throws {
        let fixture = StoreFixture()
        try fixture.serve([F.video], packaged: [F.video])
        let model = fixture.model()
        model.appeared()
        await model.refreshTask?.value
        model.setSelected(F.video.id, true)
        model.installSelected()
        model.cancelConsent()
        #expect(model.pendingConsent == nil)
        #expect(model.installTask == nil)
        #expect(fixture.packageRequests == 0)
        #expect(!fixture.registry.installed.contains { $0.id == F.video.id })
        #expect(model.selectedCount == 1)
    }

    @Test func aFailedInstallIsShownOnItsRow() async throws {
        let fixture = StoreFixture(language: .turkish)
        // Listed, but its package is missing.
        try fixture.serve([F.video, F.jwt], packaged: [F.jwt])
        let model = fixture.model()
        model.appeared()
        await model.refreshTask?.value
        model.setSelected(F.video.id, true)
        model.setSelected(F.jwt.id, true)
        model.installSelected()
        model.confirmConsent()
        await model.installTask?.value
        #expect(model.row(F.jwt.id)?.failure == nil)
        #expect(model.row(F.jwt.id)?.statusLabel == "Kurulu")
        #expect(model.row(F.video.id)?.failure == "İndirilen paket katalogla uyuşmadı; kurulmadı.")
        #expect(fixture.registry.installed.first { $0.id == F.video.id } == nil)
        #expect(model.selection == [F.video.id])
    }

    // MARK: Updates

    @Test func updateAllSkipsIncompatibleAndAsksForNewPermissions() async throws {
        let fixture = StoreFixture()
        let quietOld = F.jwt, askingOld = F.linkClean
        var tooNewOld = F.translate
        tooNewOld.version = "1.0.0"
        for entry in [quietOld, askingOld, tooNewOld] { try fixture.installLocally(entry) }
        var quiet = quietOld, asking = askingOld, tooNew = tooNewOld
        quiet.version = "1.1.0"
        asking.version = "1.1.0"
        asking.permissions = ["capture", "history"]
        tooNew.version = "2.0.0"
        tooNew.minApp = "9.0.0"
        try fixture.serve([quiet, asking, tooNew], packaged: [quiet, asking])
        let model = fixture.model()
        model.appeared()
        await model.refreshTask?.value

        #expect(model.updateCount == 2)
        #expect(model.updatesTitle == "2 updates")
        #expect(model.row(tooNew.id)?.statusLabel == "Requires a newer yabbistir")
        #expect(model.row(asking.id)?.statusLabel == "Update available")
        model.updateAll()
        let consent = try #require(model.pendingConsent)
        #expect(consent.kind == .update)
        #expect(consent.items.map(\.id) == [asking.id])
        // Only what is new is asked for.
        #expect(consent.items.first?.sentences == [L10n.string("permissions.history", .english)])
        #expect(consent.items.first?.fromVersion == "1.0.0")
        #expect(consent.quietUpdates.map(\.id) == [quiet.id])
        #expect(!consent.items.contains { $0.id == tooNew.id } && !consent.quietUpdates.contains { $0.id == tooNew.id })
        #expect(fixture.packageRequests == 0)

        let jwtGrantBefore = fixture.registry.installed.first { $0.id == quiet.id }?.grant
        model.confirmConsent()
        await model.installTask?.value
        #expect(model.failures.isEmpty)
        let updated = try #require(fixture.registry.installed.first { $0.id == asking.id })
        #expect(updated.manifest?.version == "1.1.0")
        #expect(updated.grant == PermissionGrant(permissions: ["capture", "history"], domains: [], tools: []))
        #expect(fixture.registry.installed.first { $0.id == quiet.id }?.manifest?.version == "1.1.0")
        #expect(fixture.registry.installed.first { $0.id == quiet.id }?.grant == jwtGrantBefore)
        #expect(fixture.registry.installed.first { $0.id == tooNew.id }?.manifest?.version == "1.0.0")
        #expect(!fixture.requests.contains("/v1/packages/\(tooNew.id).yabext"))
        #expect(model.updateCount == 0)
    }

    @Test func updatesThatAskForNothingNewInstallWithoutAsking() async throws {
        let fixture = StoreFixture()
        try fixture.installLocally(F.linkClean)
        var newer = F.linkClean
        newer.version = "1.2.0"
        try fixture.serve([newer], packaged: [newer])
        let model = fixture.model()
        model.appeared()
        await model.refreshTask?.value
        model.updateAll()
        #expect(model.pendingConsent == nil)
        await model.installTask?.value
        #expect(fixture.registry.installed.first { $0.id == newer.id }?.manifest?.version == "1.2.0")
        #expect(fixture.registry.installed.first { $0.id == newer.id }?.needsConsent == false)
    }

    // MARK: Search

    @Test func searchMatchesNameAndDescriptionInBothLanguages() async throws {
        let fixture = StoreFixture()
        try fixture.serve([F.video, F.translate, F.jwt, F.linkClean])
        let model = fixture.model()
        model.appeared()
        await model.refreshTask?.value
        #expect(model.rows.count == 4)

        func ids(_ query: String) -> [String] {
            model.query = query
            return model.rows.map(\.id)
        }
        // The Turkish name and description match while the app speaks English, and the other way round.
        #expect(ids("indir") == [F.video.id])
        #expect(ids("cevir") == [F.translate.id])
        #expect(ids("tokens") == [F.jwt.id])
        #expect(ids("izleme") == [F.linkClean.id])
        fixture.languageStore.language = .turkish
        #expect(ids("download") == [F.video.id])
        #expect(ids("TRACKING") == [F.linkClean.id])
        #expect(ids("çevir") == [F.translate.id])
        #expect(ids("nothing-like-this").isEmpty)
        #expect(model.emptyMessage == "“nothing-like-this” için uzantı yok")

        model.query = ""
        model.category = .developer
        #expect(model.rows.map(\.id) == [F.jwt.id])
        model.category = .text
        #expect(model.rows.map(\.id) == [F.translate.id])
        #expect(model.categories.contains(.files) && !model.categories.contains(.images))
    }

    @Test func rowsSummarizeWhatEachExtensionMayDo() async throws {
        let fixture = StoreFixture()
        var anywhere = F.linkClean
        anywhere.id = "dev.example.anywhere"
        anywhere.permissions = ["network", "history"]
        try fixture.serve([F.video, F.jwt, anywhere])
        let model = fixture.model()
        model.appeared()
        await model.refreshTask?.value
        #expect(model.row(F.video.id)?.permissionSummary == "Network: 3 sites · Runs: yt-dlp, ffmpeg, deno")
        #expect(model.row(F.jwt.id)?.permissionSummary == "")
        #expect(model.row(anywhere.id)?.permissionSummary == "Network: any site · Reads your history")
        fixture.languageStore.language = .turkish
        #expect(model.row(F.video.id)?.permissionSummary == "Ağ: 3 site · Program: yt-dlp, ffmpeg, deno")
        #expect(model.row(F.video.id)?.author == "Berkay Gökçe")
    }
}

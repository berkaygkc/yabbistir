import CryptoKit
import Foundation
import Testing
import YabExtensionKit
import YabPlatform
@testable import YabExtensions

/// A URLProtocol that answers from a table keyed by host, so tests running in parallel never see each other's requests.
final class MockStoreProtocol: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable { let path: String; let cookies: Bool; let cachePolicy: URLRequest.CachePolicy; let headers: [String: String] }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: [String: Result<Data, URLError>]] = [:]
    nonisolated(unsafe) private static var seen: [String: [Seen]] = [:]

    static func serve(host: String, _ paths: [String: Result<Data, URLError>]) { lock.withLock { answers[host] = paths } }
    static func requests(host: String) -> [Seen] { lock.withLock { seen[host] ?? [] } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockStoreProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let host = url.host ?? "", path = url.path
        let answer: Result<Data, URLError>? = Self.lock.withLock {
            Self.seen[host, default: []].append(Seen(path: path, cookies: request.httpShouldHandleCookies, cachePolicy: request.cachePolicy,
                                                headers: request.allHTTPHeaderFields ?? [:]))
            return Self.answers[host]?[path]
        }
        switch answer {
        case .success(let data):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case nil:
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

@MainActor @Suite(.serialized) struct StoreClientTests {
    let host = "store-\(UUID().uuidString.lowercased()).test"
    let key = Curve25519.Signing.PrivateKey()
    let builtIn = RegistryFixture.temporary("BuiltinExtensions")
    let user = RegistryFixture.temporary("Extensions")
    let data = RegistryFixture.temporary("ExtensionData")
    let cache = RegistryFixture.temporary("Store")
    let settings = ExtensionSettings(defaults: UserDefaults(suiteName: "yab-store-\(UUID().uuidString)")!)

    var catalogURL: URL { URL(string: "https://\(host)/v1/catalog.json")! }
    var requestCount: Int { MockStoreProtocol.requests(host: host).count }

    func registry() -> ExtensionRegistry {
        ExtensionRegistry(builtInRoot: builtIn, userRoot: user, dataRoot: data, settings: settings)
    }

    func client(_ registry: ExtensionRegistry, app: String = "1.0.0", keys: [Curve25519.Signing.PublicKey]? = nil) -> StoreClient {
        StoreClient(catalogURL: catalogURL, keys: keys ?? [key.publicKey], cacheFolder: cache, registry: registry,
                    appVersion: SemanticVersion(app)!, session: MockStoreProtocol.session())
    }

    // MARK: Fixtures

    struct Package { let data: Data; let sha: String }

    /// A .yabext whose folder is `folder` and whose manifest says `manifestID`.
    func package(id: String, version: String = "1.0.0", folder: String? = nil, manifestID: String? = nil, permissions: [String] = []) throws -> Package {
        let source = RegistryFixture.temporary("pkg")
        let manifest = RegistryFixture.manifest(id: manifestID ?? id, version: version, permissions: permissions)
        let folderURL = try RegistryFixture.write(in: source, id: manifestID ?? id, folderName: folder ?? id, manifest: manifest)
        let archive = source.appendingPathComponent("out.yabext")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", folderURL.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()
        let bytes = try Data(contentsOf: archive)
        return Package(data: bytes, sha: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    func entryJSON(id: String, version: String = "1.0.0", sha: String = String(repeating: "a", count: 64), apiVersion: Int = 1,
                   minApp: String? = nil, permissions: [String] = [], hosts: [String] = []) -> String {
        func list(_ items: [String]) -> String { "[" + items.map { "\"\($0)\"" }.joined(separator: ",") + "]" }
        return """
        {"id":"\(id)","version":"\(version)","apiVersion":\(apiVersion),"minAppVersion":\(minApp.map { "\"\($0)\"" } ?? "null"),
         "name":{"en":"\(id)"},"description":{"en":"d"},"author":"a","categories":["text"],"icon":"sf:number",
         "permissions":\(list(permissions)),"networkHosts":\(list(hosts)),"tools":[],"sha256":"\(sha)","size":1,
         "updatedAt":"2026-10-30T12:00:00Z","readme":"https://\(host)/r","package":"https://\(host)/v1/packages/\(id).yabext"}
        """
    }

    func catalogData(_ entries: [String]) -> Data { StoreCatalogTests.catalogJSON(entries: entries) }

    func sign(_ catalog: Data, with signer: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        Data(try (signer ?? key).signature(for: catalog).base64EncodedString().utf8)
    }

    func serve(_ entries: [String], packages: [String: Data] = [:]) throws {
        let catalog = catalogData(entries)
        var paths: [String: Result<Data, URLError>] = [
            "/v1/catalog.json": .success(catalog), "/v1/catalog.json.sig": .success(try sign(catalog)),
        ]
        for (id, bytes) in packages { paths["/v1/packages/\(id).yabext"] = .success(bytes) }
        MockStoreProtocol.serve(host: host, paths)
    }

    func entry(_ client: StoreClient, _ id: String) throws -> StoreEntry { try #require(client.catalog?.extensions.first { $0.id == id }) }

    // MARK: Network rule

    @Test func creatingTheClientTouchesNoNetwork() throws {
        try serve([entryJSON(id: "dev.example.a")])
        let client = client(registry())
        #expect(client.catalog == nil)
        #expect(client.lastRefresh == .never)
        #expect(requestCount == 0)
    }

    @Test func loadingTheCacheTouchesNoNetwork() async throws {
        try serve([entryJSON(id: "dev.example.a")])
        let first = client(registry())
        await first.refresh()
        let afterRefresh = requestCount
        let second = client(registry())
        second.loadCache()
        _ = second.updates
        if let e = second.catalog?.extensions.first { _ = second.status(of: e); _ = second.newPermissions(for: e) }
        #expect(second.catalog?.extensions.count == 1)
        #expect(requestCount == afterRefresh)
    }

    @Test func refreshSendsNoIdentifyingRequestParts() async throws {
        try serve([entryJSON(id: "dev.example.a")])
        await client(registry()).refresh()
        let seen = MockStoreProtocol.requests(host: host)
        #expect(Set(seen.map(\.path)) == ["/v1/catalog.json", "/v1/catalog.json.sig"])
        for request in seen {
            #expect(!request.cookies)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.headers.isEmpty)
        }
    }

    // MARK: Refresh and cache

    @Test func refreshReplacesTheCacheOnlyWhenVerified() async throws {
        try serve([entryJSON(id: "dev.example.a")])
        let client = client(registry())
        await client.refresh()
        guard case .ok = client.lastRefresh else { Issue.record("expected ok, got \(client.lastRefresh)"); return }
        #expect(client.catalog?.extensions.map(\.id) == ["dev.example.a"])
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("catalog.json").path))
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("catalog.json.sig").path))
        // A new catalog signed by the right key replaces it.
        try serve([entryJSON(id: "dev.example.a"), entryJSON(id: "dev.example.b")])
        await client.refresh()
        #expect(client.catalog?.extensions.count == 2)
        let reloaded = self.client(registry())
        reloaded.loadCache()
        #expect(reloaded.catalog?.extensions.count == 2)
    }

    @Test func aBadRefreshKeepsTheGoodCache() async throws {
        try serve([entryJSON(id: "dev.example.a")])
        let client = client(registry())
        await client.refresh()
        let cachedCatalog = try Data(contentsOf: cache.appendingPathComponent("catalog.json"))
        let cachedSignature = try Data(contentsOf: cache.appendingPathComponent("catalog.json.sig"))

        // Signed by a stranger.
        let forged = catalogData([entryJSON(id: "dev.example.evil")])
        MockStoreProtocol.serve(host: host, ["/v1/catalog.json": .success(forged),
                                             "/v1/catalog.json.sig": .success(try sign(forged, with: Curve25519.Signing.PrivateKey()))])
        await client.refresh()
        #expect(client.lastRefresh == .failed(.badSignature))
        // Tampered after signing.
        let honest = catalogData([entryJSON(id: "dev.example.b")])
        var tampered = honest
        tampered[tampered.startIndex + 20] ^= 1
        MockStoreProtocol.serve(host: host, ["/v1/catalog.json": .success(tampered), "/v1/catalog.json.sig": .success(try sign(honest))])
        await client.refresh()
        #expect(client.lastRefresh == .failed(.badSignature))
        // Signed but not a catalog.
        let junk = Data("not json".utf8)
        MockStoreProtocol.serve(host: host, ["/v1/catalog.json": .success(junk), "/v1/catalog.json.sig": .success(try sign(junk))])
        await client.refresh()
        #expect(client.lastRefresh == .failed(.badSignature))

        #expect(client.catalog?.extensions.map(\.id) == ["dev.example.a"])
        #expect(try Data(contentsOf: cache.appendingPathComponent("catalog.json")) == cachedCatalog)
        #expect(try Data(contentsOf: cache.appendingPathComponent("catalog.json.sig")) == cachedSignature)
    }

    @Test func offlineIsReportedCalmly() async throws {
        try serve([entryJSON(id: "dev.example.a")])
        let client = client(registry())
        await client.refresh()
        for code in [URLError.notConnectedToInternet, .timedOut, .cannotFindHost] {
            MockStoreProtocol.serve(host: host, ["/v1/catalog.json": .failure(URLError(code)), "/v1/catalog.json.sig": .failure(URLError(code))])
            await client.refresh()
            #expect(client.lastRefresh == .failed(.offline))
        }
        #expect(client.catalog?.extensions.count == 1)
    }

    @Test func aCachedPairIsVerifiedAgainstTheCurrentKeys() async throws {
        try serve([entryJSON(id: "dev.example.a")])
        await client(registry()).refresh()
        let rotated = client(registry(), keys: [Curve25519.Signing.PrivateKey().publicKey])
        rotated.loadCache()
        #expect(rotated.catalog == nil)
        // A mismatched pair (one half replaced) is not used either.
        try Data(catalogData([entryJSON(id: "dev.example.other")])).write(to: cache.appendingPathComponent("catalog.json"))
        let mismatched = client(registry())
        mismatched.loadCache()
        #expect(mismatched.catalog == nil)
    }

    // MARK: Install

    @Test func installVerifiesTheHashBeforeTheRegistry() async throws {
        let pkg = try package(id: "dev.example.a")
        try serve([entryJSON(id: "dev.example.a", sha: String(repeating: "0", count: 64))], packages: ["dev.example.a": pkg.data])
        let registry = registry()
        let client = client(registry)
        await client.refresh()
        let result = await client.install([try entry(client, "dev.example.a")])
        #expect(result["dev.example.a"] == .some(.badPackage(id: "dev.example.a")))
        #expect(!registry.installed.contains { $0.id == "dev.example.a" })
        #expect(!FileManager.default.fileExists(atPath: user.appendingPathComponent("dev.example.a").path))
    }

    @Test func aGoodPackageInstallsAndReportsNil() async throws {
        let pkg = try package(id: "dev.example.a")
        try serve([entryJSON(id: "dev.example.a", sha: pkg.sha)], packages: ["dev.example.a": pkg.data])
        let registry = registry()
        let client = client(registry)
        await client.refresh()
        let result = await client.install([try entry(client, "dev.example.a")])
        #expect(result == ["dev.example.a": Optional<StoreFailure>.none])
        #expect(registry.installed.contains { $0.id == "dev.example.a" })
        #expect(client.status(of: try entry(client, "dev.example.a")) == .installed)
    }

    @Test func aPackageWhoseManifestIdDiffersIsRejected() async throws {
        // The folder carries the catalog id, the manifest another.
        let mismatchedManifest = try package(id: "dev.example.a", folder: "dev.example.a", manifestID: "dev.example.b")
        // The manifest carries the catalog id, the folder another.
        let mismatchedFolder = try package(id: "dev.example.c", folder: "dev.example.other")
        try serve([entryJSON(id: "dev.example.a", sha: mismatchedManifest.sha), entryJSON(id: "dev.example.c", sha: mismatchedFolder.sha)],
                  packages: ["dev.example.a": mismatchedManifest.data, "dev.example.c": mismatchedFolder.data])
        let registry = registry()
        let client = client(registry)
        await client.refresh()
        let result = await client.install([try entry(client, "dev.example.a"), try entry(client, "dev.example.c")])
        #expect(result["dev.example.a"] == .some(.badPackage(id: "dev.example.a")))
        #expect(result["dev.example.c"] == .some(.badPackage(id: "dev.example.c")))
        #expect(registry.installed.isEmpty)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: user.path))?.isEmpty ?? true)
    }

    @Test func installNeverApprovesPermissions() async throws {
        let pkg = try package(id: "dev.example.a", permissions: ["history"])
        try serve([entryJSON(id: "dev.example.a", sha: pkg.sha, permissions: ["history"])], packages: ["dev.example.a": pkg.data])
        let registry = registry()
        let client = client(registry)
        await client.refresh()
        let result = await client.install([try entry(client, "dev.example.a")])
        #expect(result == ["dev.example.a": Optional<StoreFailure>.none])
        let installed = try #require(registry.installed.first { $0.id == "dev.example.a" })
        #expect(installed.grant == nil)
        #expect(installed.needsConsent)
        #expect(!installed.isUsable)
    }

    @Test func incompatibleEntriesAreNeverInstalled() async throws {
        let pkg = try package(id: "dev.example.a")
        try serve([entryJSON(id: "dev.example.a", sha: pkg.sha, minApp: "9.0.0")], packages: ["dev.example.a": pkg.data])
        let registry = registry()
        let client = client(registry)
        await client.refresh()
        let before = requestCount
        let result = await client.install([try entry(client, "dev.example.a")])
        #expect(result["dev.example.a"] == .some(.incompatible(id: "dev.example.a")))
        #expect(requestCount == before)
        #expect(registry.installed.isEmpty)
    }

    // MARK: Status

    @Test func builtInIdsShowAsBuiltIn() async throws {
        try RegistryFixture.write(in: builtIn, id: "dev.example.core")
        try serve([entryJSON(id: "dev.example.core", version: "9.0.0")])
        let client = client(registry())
        await client.refresh()
        let core = try entry(client, "dev.example.core")
        #expect(client.status(of: core) == .builtIn)
        #expect(client.updates.isEmpty)
    }

    @Test func anUpdateThatAddsPermissionsListsThem() async throws {
        let registry = registry()
        let source = try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: "dev.example.a",
                                               manifest: RegistryFixture.manifest(id: "dev.example.a", version: "1.0.0", permissions: ["history"]))
        try registry.install(folder: source)
        registry.approveRequested("dev.example.a")
        try serve([entryJSON(id: "dev.example.a", version: "1.1.0", permissions: ["history"]),
                   entryJSON(id: "dev.example.b", version: "1.1.0", permissions: ["history", "exec"], hosts: ["example.com"])])
        let client = client(registry)
        await client.refresh()
        let same = try entry(client, "dev.example.a")
        #expect(client.status(of: same) == .updateAvailable(from: "1.0.0"))
        #expect(client.newPermissions(for: same).isEmpty)
        // An update asking for more than the approved grant lists exactly the difference.
        let grown = StoreCatalogTests.catalogJSON(entries: [entryJSON(id: "dev.example.a", version: "1.1.0", permissions: ["history", "exec", "network"], hosts: ["example.com"])])
        MockStoreProtocol.serve(host: host, ["/v1/catalog.json": .success(grown), "/v1/catalog.json.sig": .success(try sign(grown))])
        await client.refresh()
        #expect(Set(client.newPermissions(for: try entry(client, "dev.example.a"))) == ["exec", "network", "example.com"])
    }

    @Test func updatesSkipIncompatibleOnes() async throws {
        let registry = registry()
        try registry.install(folder: try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: "dev.example.a"))
        try registry.install(folder: try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: "dev.example.b"))
        try registry.install(folder: try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: "dev.example.c"))
        try serve([entryJSON(id: "dev.example.a", version: "1.1.0"),
                   entryJSON(id: "dev.example.b", version: "1.1.0", minApp: "9.0.0"),
                   entryJSON(id: "dev.example.c", version: "1.0.0"),
                   entryJSON(id: "dev.example.d", version: "1.0.0")])
        let client = client(registry)
        await client.refresh()
        #expect(client.updates.map(\.id) == ["dev.example.a"])
        #expect(client.status(of: try entry(client, "dev.example.b")) == .incompatible(.needsNewerApp(minimum: "9.0.0")))
        #expect(client.status(of: try entry(client, "dev.example.c")) == .installed)
        #expect(client.status(of: try entry(client, "dev.example.d")) == .notInstalled)
    }
}

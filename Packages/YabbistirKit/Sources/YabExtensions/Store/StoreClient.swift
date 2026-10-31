import CryptoKit
import Foundation
import Observation
import YabExtensionKit
import YabPlatform

public enum StoreFailure: Error, Equatable, Sendable {
    /// The store could not be reached.
    case offline
    /// The catalog is not signed by a known key, or is not a catalog this app can read.
    case badSignature
    /// The download does not match the catalog (hash, folder name or manifest id).
    case badPackage(id: String)
    case incompatible(id: String)
    /// The registry refused the package.
    case registry(String)
}

public enum RefreshState: Equatable, Sendable {
    case never
    case refreshing
    case ok(Date)
    case failed(StoreFailure)
}

public enum EntryStatus: Equatable, Sendable {
    case notInstalled
    case installed
    /// A newer version exists; `from` is the installed one.
    case updateAvailable(from: String)
    case incompatible(StoreCompatibility)
    case builtIn
}

/// Reads the store's catalog and installs from it. It reaches the network only inside `refresh()` and `install(_:)`,
/// and it never approves a permission: that stays with the person, through the registry.
@MainActor @Observable
public final class StoreClient {
    public private(set) var catalog: StoreCatalog?
    public private(set) var lastRefresh: RefreshState = .never

    @ObservationIgnored private let catalogURL: URL
    @ObservationIgnored private let keys: [Curve25519.Signing.PublicKey]
    @ObservationIgnored private let cacheFolder: URL
    @ObservationIgnored private let registry: ExtensionRegistry
    @ObservationIgnored private let appVersion: SemanticVersion
    @ObservationIgnored private let session: URLSession

    public init(catalogURL: URL = StoreConfiguration.catalogURL, keys: [Curve25519.Signing.PublicKey] = StoreConfiguration.publicKeys,
                cacheFolder: URL, registry: ExtensionRegistry, appVersion: SemanticVersion, session: URLSession = .shared) {
        self.catalogURL = catalogURL
        self.keys = keys
        self.cacheFolder = cacheFolder
        self.registry = registry
        self.appVersion = appVersion
        self.session = session
    }

    private var cachedCatalogFile: URL { cacheFolder.appendingPathComponent("catalog.json") }
    private var cachedSignatureFile: URL { cacheFolder.appendingPathComponent("catalog.json.sig") }
    private var signatureURL: URL { catalogURL.appendingPathExtension("sig") }

    // MARK: Catalog

    /// Reads the cached pair, checking it again against the current keys. No network.
    public func loadCache() {
        guard let bytes = try? Data(contentsOf: cachedCatalogFile), let signature = try? Data(contentsOf: cachedSignatureFile),
              let cached = try? CatalogVerifier.verifyAndDecode(catalog: bytes, signatureBase64: signature, keys: keys) else { return }
        catalog = cached
    }

    /// Fetches the catalog and its signature. Only a verified pair replaces the cache and `catalog`; any failure
    /// leaves both as they were.
    public func refresh() async {
        guard lastRefresh != .refreshing else { return }
        lastRefresh = .refreshing
        do {
            let bytes = try await fetch(catalogURL)
            let signature = try await fetch(signatureURL)
            let fresh: StoreCatalog
            do {
                fresh = try CatalogVerifier.verifyAndDecode(catalog: bytes, signatureBase64: signature, keys: keys)
            } catch {
                // A catalog that is signed but unreadable is reported like a bad one.
                throw StoreFailure.badSignature
            }
            writeCache(catalog: bytes, signature: signature)
            catalog = fresh
            lastRefresh = .ok(Date())
        } catch {
            lastRefresh = .failed((error as? StoreFailure) ?? .offline)
        }
    }

    /// Writes both files to temporary names first, then moves them into place, so a failure while writing never
    /// damages the previous pair. A crash between the two moves leaves a pair that fails verification and is ignored.
    private func writeCache(catalog: Data, signature: Data) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
            let token = UUID().uuidString
            let catalogTemp = cacheFolder.appendingPathComponent("catalog.json.\(token).tmp")
            let signatureTemp = cacheFolder.appendingPathComponent("catalog.json.sig.\(token).tmp")
            defer { try? fileManager.removeItem(at: catalogTemp); try? fileManager.removeItem(at: signatureTemp) }
            try catalog.write(to: catalogTemp)
            try signature.write(to: signatureTemp)
            _ = try fileManager.replaceItemAt(cachedCatalogFile, withItemAt: catalogTemp)
            _ = try fileManager.replaceItemAt(cachedSignatureFile, withItemAt: signatureTemp)
        } catch {
            // The cache is a convenience; the fresh catalog is still used in memory.
        }
    }

    private func fetch(_ url: URL) async throws(StoreFailure) -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw StoreFailure.offline }
            return data
        } catch {
            throw .offline
        }
    }

    // MARK: Status

    public func status(of entry: StoreEntry) -> EntryStatus {
        guard let installed = registry.installed.first(where: { $0.id == entry.id }) else {
            let compatibility = entry.compatibility(appVersion: appVersion)
            return compatibility == .compatible ? .notInstalled : .incompatible(compatibility)
        }
        if installed.source == .builtIn { return .builtIn }
        guard let have = installed.manifest?.version, have != entry.version,
              let haveVersion = SemanticVersion(have), let offered = SemanticVersion(entry.version), haveVersion < offered else { return .installed }
        let compatibility = entry.compatibility(appVersion: appVersion)
        return compatibility == .compatible ? .updateAvailable(from: have) : .incompatible(compatibility)
    }

    /// Compatible entries whose installed copy is older. Built-ins are never included.
    public var updates: [StoreEntry] {
        (catalog?.extensions ?? []).filter {
            if case .updateAvailable = status(of: $0) { return true }
            return false
        }
    }

    /// What `entry` asks for beyond the installed copy's approved grant: permissions, network hosts and tools, as the
    /// registry would count them. Empty means the update runs on the existing grant.
    public func newPermissions(for entry: StoreEntry) -> [String] {
        let grant = registry.installed.first { $0.id == entry.id }?.grant ?? .empty
        let requested = PermissionGrant(permissions: entry.permissions, domains: entry.networkHosts, tools: entry.tools)
        if grant.covers(requested) { return [] }
        var missing = requested.permissions.filter { !grant.permissions.contains($0) }
        let grantReachesAnyWebsite = grant.permissions.contains("network") && grant.domains.isEmpty
        let requestReachesAnyWebsite = requested.permissions.contains("network") && requested.domains.isEmpty
        if !grantReachesAnyWebsite {
            missing += requested.domains.filter { !grant.domains.contains($0) }
            // Any website is more than a list of sites, even when "network" itself was approved.
            if requestReachesAnyWebsite && !missing.contains("network") { missing.append("network") }
        }
        missing += requested.tools.filter { !grant.tools.contains($0) }
        return missing
    }

    // MARK: Installing

    /// Downloads, checks and installs each entry. The value is nil on success. Nothing is approved here.
    public func install(_ entries: [StoreEntry]) async -> [String: StoreFailure?] {
        var results: [String: StoreFailure?] = [:]
        for entry in entries {
            results.updateValue(await install(entry), forKey: entry.id)
        }
        return results
    }

    private func install(_ entry: StoreEntry) async -> StoreFailure? {
        guard entry.compatibility(appVersion: appVersion) == .compatible else { return .incompatible(id: entry.id) }
        let bytes: Data
        do { bytes = try await fetch(entry.package) } catch { return .offline }
        guard CatalogVerifier.packageMatches(bytes, sha256: entry.sha256) else { return .badPackage(id: entry.id) }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("yabbistir-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appendingPathComponent("\(UUID().uuidString).yabext")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try bytes.write(to: archive)
        } catch {
            return .registry("could not save the download: \(error.localizedDescription)")
        }
        guard packageIdentity(of: archive, in: work) == entry.id else { return .badPackage(id: entry.id) }
        do {
            try registry.install(archive: archive)
            return nil
        } catch {
            return .registry(error.message)
        }
    }

    /// Unpacks into a scratch folder and returns the id only when the package's single root folder and the `id` in its
    /// manifest agree. Nothing reaches the registry before this.
    private func packageIdentity(of archive: URL, in work: URL) -> String? {
        let scratch = work.appendingPathComponent("peek", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, scratch.path]
        guard (try? ditto.run()) != nil else { return nil }
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0,
              let roots = try? FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: [.isDirectoryKey],
                                                                       options: [.skipsHiddenFiles]).filter({ $0.lastPathComponent != "__MACOSX" }),
              roots.count == 1, let root = roots.first,
              (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let manifest = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let id = (try? JSONDecoder().decode(JSONValue.self, from: manifest))?["id"]?.stringValue,
              id == root.lastPathComponent else { return nil }
        return id
    }
}

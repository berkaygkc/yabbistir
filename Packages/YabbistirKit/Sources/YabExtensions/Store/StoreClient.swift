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
    /// The catalog is genuine but in a format only a newer yabbistir reads.
    case needsNewerApp
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
                cacheFolder: URL, registry: ExtensionRegistry, appVersion: SemanticVersion, session: URLSession = URLSession(configuration: .ephemeral)) {
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
            let bytes = try await fetch(catalogURL, limit: Limits.catalog, deadline: Limits.catalogDeadline)
            let signature = try await fetch(signatureURL, limit: Limits.signature, deadline: Limits.catalogDeadline)
            let fresh: StoreCatalog
            do {
                fresh = try CatalogVerifier.verifyAndDecode(catalog: bytes, signatureBase64: signature, keys: keys)
            } catch .needsNewerApp {
                throw StoreFailure.needsNewerApp
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

    /// Size and time limits for what the store sends.
    private enum Limits {
        static let catalog = 2_000_000
        static let signature = 1_000
        static let package = 5_000_000
        /// Seconds without any data before a request gives up.
        static let idleTimeout: TimeInterval = 30
        static let catalogDeadline: TimeInterval = 30
        /// A package gets 30 s plus time for its size at 50 KB/s: 130 s at the 5 MB cap.
        static func packageDeadline(size: Int) -> TimeInterval { 30 + Double(size) / 50_000 }
    }

    private enum FetchError: Error { case network, status, size }

    /// Reads at most `limit` bytes (exactly `exactly`, when given) before `deadline` seconds have passed.
    /// A response that announces more than the limit is dropped before its body is read.
    private func fetch(_ url: URL, limit: Int, exactly: Int? = nil, deadline: TimeInterval,
                       badResponse: StoreFailure = .offline) async throws(StoreFailure) -> Data {
        do {
            return try await Self.download(session: session, url: url, limit: limit, exactly: exactly, deadline: deadline)
        } catch FetchError.network {
            throw .offline
        } catch FetchError.status {
            throw badResponse
        } catch {
            throw .badSignature
        }
    }

    nonisolated private static func download(session: URLSession, url: URL, limit: Int, exactly: Int?, deadline: TimeInterval) async throws -> Data {
        let request: URLRequest = {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Limits.idleTimeout)
            request.httpShouldHandleCookies = false
            return request
        }()
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let bytes: URLSession.AsyncBytes, response: URLResponse
                do { (bytes, response) = try await session.bytes(for: request) } catch { throw FetchError.network }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw FetchError.status }
                if response.expectedContentLength > Int64(limit) { throw FetchError.size }
                var data = Data()
                do {
                    for try await byte in bytes {
                        data.append(byte)
                        if data.count > limit { throw FetchError.size }
                    }
                } catch let error as FetchError { throw error } catch { throw FetchError.network }
                if let exactly, data.count != exactly { throw FetchError.size }
                return data
            }
            group.addTask {
                try await Task.sleep(for: .seconds(deadline))
                throw FetchError.network
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: Status

    public func status(of entry: StoreEntry) -> EntryStatus {
        guard let installed = registry.installed.first(where: { $0.id == entry.id }) else {
            let compatibility = entry.compatibility(appVersion: appVersion)
            return compatibility == .compatible ? .notInstalled : .incompatible(compatibility)
        }
        if installed.source == .builtIn { return .builtIn }
        // A linked development folder is the developer's own; the store never offers to replace it.
        if installed.source == .development { return .installed }
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
        for requested in entries {
            // Only what the verified catalog lists is installed, whatever the caller passes.
            guard let entry = catalog?.extensions.first(where: { $0.id == requested.id }) else {
                results.updateValue(.badPackage(id: requested.id), forKey: requested.id)
                continue
            }
            results.updateValue(await install(entry), forKey: entry.id)
        }
        return results
    }

    private func install(_ entry: StoreEntry) async -> StoreFailure? {
        if let existing = registry.installed.first(where: { $0.id == entry.id }), existing.source != .local {
            return .incompatible(id: entry.id)
        }
        guard entry.compatibility(appVersion: appVersion) == .compatible else { return .incompatible(id: entry.id) }
        guard entry.size > 0, entry.size <= Limits.package else { return .badPackage(id: entry.id) }
        let bytes: Data
        do {
            bytes = try await fetch(entry.package, limit: entry.size, exactly: entry.size, deadline: Limits.packageDeadline(size: entry.size),
                              badResponse: .badPackage(id: entry.id))
        } catch .offline {
            return .offline
        } catch {
            return .badPackage(id: entry.id)
        }
        guard CatalogVerifier.packageMatches(bytes, sha256: entry.sha256) else { return .badPackage(id: entry.id) }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("yabbistir-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appendingPathComponent("package.yabext")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try bytes.write(to: archive)
        } catch {
            return .registry("could not save the download: \(error.localizedDescription)")
        }
        // The folder that was checked is the folder that gets installed.
        guard let folder = checkedFolder(of: archive, in: work, id: entry.id) else { return .badPackage(id: entry.id) }
        do {
            try registry.install(folder: folder)
            return nil
        } catch {
            return .registry(error.message)
        }
    }

    /// Unpacks into a scratch folder and returns the package's folder only when it is the single entry at the root
    /// (hidden files and resource-fork folders count), is named `id`, and its manifest says the same `id`.
    private func checkedFolder(of archive: URL, in work: URL, id: String) -> URL? {
        let scratch = work.appendingPathComponent("unpacked", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, scratch.path]
        guard (try? ditto.run()) != nil else { return nil }
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0,
              let roots = try? FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: [.isDirectoryKey]),
              roots.count == 1, let root = roots.first, root.lastPathComponent == id,
              (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let manifest = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              (try? JSONDecoder().decode(JSONValue.self, from: manifest))?["id"]?.stringValue == id else { return nil }
        return root
    }
}

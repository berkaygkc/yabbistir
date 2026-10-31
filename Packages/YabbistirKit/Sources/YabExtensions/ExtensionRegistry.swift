import CoreServices
import Foundation
import Observation
import YabExtensionKit

public enum ExtensionSource: String, Sendable {
    /// Ships inside the app; can be turned off, not removed.
    case builtIn
    /// Installed from a folder or a .yabext file (a copy).
    case local
    /// A link to a folder the developer edits; reloads on every change.
    case development
}

public struct InstalledExtension: Identifiable, Sendable {
    public let id: String
    /// Where it lives: the copy, or the link in the extensions folder.
    public let folder: URL
    public let source: ExtensionSource
    public let manifest: ExtensionManifest?
    public let localization: ExtensionLocalization?
    public let issues: [ManifestIssue]
    public let isEnabled: Bool
    /// What the person approved; nil until they approve.
    public let grant: PermissionGrant?
    /// The master switch for third-party extensions is on.
    public let thirdPartyDisabled: Bool

    public init(id: String, folder: URL, source: ExtensionSource, manifest: ExtensionManifest?, localization: ExtensionLocalization?,
                issues: [ManifestIssue], isEnabled: Bool, grant: PermissionGrant? = nil, thirdPartyDisabled: Bool = false) {
        self.id = id
        self.folder = folder
        self.source = source
        self.manifest = manifest
        self.localization = localization
        self.issues = issues
        self.isEnabled = isEnabled
        self.grant = grant
        self.thirdPartyDisabled = thirdPartyDisabled
    }

    /// It asks for something the person has not approved yet.
    public var needsConsent: Bool {
        guard let manifest else { return false }
        let requested = PermissionGrant.requested(by: manifest)
        return !requested.isEmpty && !(grant?.covers(requested) ?? false)
    }

    /// Valid, approved and switched on: its commands may appear.
    public var isUsable: Bool {
        manifest != nil && issues.isEmpty && isEnabled && !needsConsent && (source == .builtIn || !thirdPartyDisabled)
    }

    public func name(language: String) -> String {
        guard let manifest, let localization else { return id }
        return localization.string(manifest.name, language: language)
    }
}

public enum RegistryError: Error, Equatable, Sendable {
    case invalid([ManifestIssue])
    case builtIn(String)
    case notFound(String)
    case failed(String)

    public var message: String {
        switch self {
        case .invalid(let issues): issues.map(\.description).joined(separator: "\n")
        case .builtIn(let id): "\(id) ships with yabbistir and cannot be removed; turn it off instead."
        case .notFound(let id): "\(id) is not installed."
        case .failed(let reason): reason
        }
    }
}

/// The installed extensions: built-ins from the app, copies and development links from the user's
/// extensions folder, which is watched so edits show up on their own.
@MainActor @Observable
public final class ExtensionRegistry {
    public private(set) var installed: [InstalledExtension] = []
    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored public let builtInRoot: URL
    @ObservationIgnored public let userRoot: URL
    @ObservationIgnored public let dataRoot: URL
    @ObservationIgnored public let settings: ExtensionSettings
    @ObservationIgnored private var watcher: FolderWatcher?
    /// Hears each warning of a loadable manifest as (extension id, line) on every load and reload; the app writes
    /// it to the Development log. Warnings never enter `InstalledExtension.issues`: those keep an extension off.
    @ObservationIgnored private let onWarning: ((String, String) -> Void)?

    public init(builtInRoot: URL, userRoot: URL, dataRoot: URL, settings: ExtensionSettings,
                onWarning: ((String, String) -> Void)? = nil) {
        self.onWarning = onWarning
        self.builtInRoot = builtInRoot
        self.userRoot = userRoot
        self.dataRoot = dataRoot
        self.settings = settings
        try? FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
        reload()
    }

    public func dataFolder(for id: String) -> URL { dataRoot.appendingPathComponent(id, isDirectory: true) }

    public func reload() {
        let builtIns = scan(builtInRoot, source: .builtIn)
        let users = scan(userRoot, source: .local)
        // A user copy with a built-in's id replaces the built-in.
        let userIDs = Set(users.map(\.id))
        func name(_ entry: InstalledExtension) -> String { entry.name(language: entry.localization?.defaultLocale ?? "en").lowercased() }
        installed = builtIns.filter { !userIDs.contains($0.id) }.sorted { name($0) < name($1) } + users.sorted { name($0) < name($1) }
        watch()
        onChange?()
    }

    // MARK: Installing

    /// Validates a folder and copies it in, replacing an installed copy with the same id.
    @discardableResult
    public func install(folder: URL) throws(RegistryError) -> String {
        let staged = try stage(folder)
        let destination = userRoot.appendingPathComponent(staged.lastPathComponent)
        guard isDirectChild(destination, of: userRoot) else { throw .failed("\(staged.lastPathComponent) is not a usable extension id") }
        do {
            if (try? destination.checkResourceIsReachable()) == true || isSymbolicLink(destination) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: staged, to: destination)
        } catch {
            throw .failed("could not copy the extension: \(error.localizedDescription)")
        }
        reload()
        return destination.lastPathComponent
    }

    /// Unpacks a .yabext (a zip of one extension folder) and installs it.
    @discardableResult
    public func install(archive: URL) throws(RegistryError) -> String {
        let unpacked = temporaryFolder()
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, unpacked.path]
        do {
            try ditto.run()
            ditto.waitUntilExit()
        } catch {
            throw .failed("could not unpack \(archive.lastPathComponent): \(error.localizedDescription)")
        }
        guard ditto.terminationStatus == 0 else { throw .failed("\(archive.lastPathComponent) is not a valid .yabext file") }
        let candidates = [unpacked] + ((try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? [])
        guard let folder = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }) else {
            throw .failed("\(archive.lastPathComponent) holds no manifest.json")
        }
        return try install(folder: folder)
    }

    /// Links a folder the developer keeps editing; problems are listed rather than refused.
    @discardableResult
    public func linkDevelopmentFolder(_ folder: URL) throws(RegistryError) -> String {
        let id = try manifestID(in: folder)
        let link = userRoot.appendingPathComponent(id)
        guard isDirectChild(link, of: userRoot) else { throw .failed("\(id) is not a usable extension id") }
        do {
            if (try? link.checkResourceIsReachable()) == true || isSymbolicLink(link) { try FileManager.default.removeItem(at: link) }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.resolvingSymlinksInPath())
        } catch {
            throw .failed("could not link the folder: \(error.localizedDescription)")
        }
        reload()
        return id
    }

    /// Removes a copy or a development link (never the developer's folder), with its data.
    public func uninstall(_ id: String) throws(RegistryError) {
        guard let entry = installed.first(where: { $0.id == id }) else { throw .notFound(id) }
        guard entry.source != .builtIn else { throw .builtIn(id) }
        guard isDirectChild(entry.folder, of: userRoot), isDirectChild(dataFolder(for: id), of: dataRoot) else {
            throw .failed("\(id) is not inside the extensions folder")
        }
        do {
            try FileManager.default.removeItem(at: entry.folder)
            if FileManager.default.fileExists(atPath: dataFolder(for: id).path) { try FileManager.default.removeItem(at: dataFolder(for: id)) }
        } catch {
            throw .failed("could not remove \(id): \(error.localizedDescription)")
        }
        settings.remove(id, specs: entry.manifest?.preferences ?? [])
        reload()
    }

    /// Records exactly `grant`, what the person was shown, as approved. A manifest that asks for more
    /// by now is not covered: the extension keeps waiting until that is shown and approved too.
    public func approve(_ id: String, grant: PermissionGrant) {
        guard installed.contains(where: { $0.id == id }) else { return }
        settings.setGrant(id, grant)
        reload()
    }

    public func setEnabled(_ id: String, _ on: Bool) {
        settings.setEnabled(id, on)
        reload()
    }

    // MARK: Scanning

    private func scan(_ root: URL, source: ExtensionSource) -> [InstalledExtension] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        return entries.compactMap { folder in
            let isLink = isSymbolicLink(folder)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let entrySource: ExtensionSource = isLink && source == .local ? .development : source
            switch ManifestValidator.validate(folder: folder) {
            case .valid(let manifest, let localization):
                // A syntax error is found by parsing, never by running: listed with its line.
                let issues = SyntaxCheck.problem(in: folder).map { [$0] } ?? []
                for warning in ManifestValidator.warnings(folder: folder) {
                    onWarning?(manifest.id, "\(manifest.id): \(warning.path): \(warning.message)")
                }
                return InstalledExtension(id: manifest.id, folder: folder, source: entrySource, manifest: manifest, localization: localization,
                                          issues: issues, isEnabled: settings.isEnabled(manifest.id),
                                          grant: settings.grant(manifest.id), thirdPartyDisabled: settings.thirdPartyDisabled)
            case .invalid(let issues):
                let id = folder.lastPathComponent
                return InstalledExtension(id: id, folder: folder, source: entrySource, manifest: nil, localization: nil,
                                          issues: issues, isEnabled: settings.isEnabled(id),
                                          grant: settings.grant(id), thirdPartyDisabled: settings.thirdPartyDisabled)
            }
        }
    }

    /// Whether `url` sits directly in `root`; nothing outside the registry's folders is ever removed.
    private func isDirectChild(_ url: URL, of root: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == root.standardizedFileURL.path
            && !["", ".", ".."].contains(url.standardizedFileURL.lastPathComponent)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// A copy of the folder named after its id, checked before anything is installed: the source
    /// folder may carry any name.
    private func stage(_ folder: URL) throws(RegistryError) -> URL {
        let id = try manifestID(in: folder)
        let staged = temporaryFolder().appendingPathComponent(id)
        do {
            try FileManager.default.copyItem(at: folder.resolvingSymlinksInPath(), to: staged)
        } catch {
            throw .failed("could not read the folder: \(error.localizedDescription)")
        }
        if case .invalid(let issues) = ManifestValidator.validate(folder: staged) { throw .invalid(issues) }
        return staged
    }

    private func manifestID(in folder: URL) throws(RegistryError) -> String {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let id = (try? JSONDecoder().decode(JSONValue.self, from: data))?["id"]?.stringValue else {
            throw .invalid([ManifestIssue("id", "manifest.json has no usable \"id\"", fix: "Add an \"id\" such as \"dev.yourname.tool\".")])
        }
        // The id becomes a folder name: checked before it touches the file system.
        guard ManifestValidator.isValidID(id) else {
            throw .invalid([ManifestIssue("id", "\"\(id)\" is not a reverse-domain id", expected: "lowercase reverse-domain, e.g. dev.yourname.tool",
                                          fix: "Use lowercase letters, digits and dashes separated by dots, e.g. \"dev.yourname.tool\".")])
        }
        return id
    }

    private func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yabbistir-install-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Watching

    /// FSEvents on the extensions folder and every linked folder (FSEvents does not follow links);
    /// its 0.3 s latency batches a burst of saves into one reload.
    private func watch() {
        let targets = installed.filter { $0.source == .development }.map { $0.folder.resolvingSymlinksInPath().path }
        let paths = [userRoot.path] + targets
        guard watcher?.paths != paths else { return }
        watcher = FolderWatcher(paths: paths) { [weak self] in self?.reload() }
    }
}

/// A file-level FSEvents stream delivered on the main queue.
@MainActor
final class FolderWatcher {
    let paths: [String]
    private var stream: FSEventStreamRef?
    private let handler: Handler

    final class Handler {
        let fire: @MainActor () -> Void
        init(_ fire: @escaping @MainActor () -> Void) { self.fire = fire }
    }

    init(paths: [String], fire: @escaping @MainActor () -> Void) {
        self.paths = paths
        handler = Handler(fire)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(handler).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { handler.fire() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    isolated deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

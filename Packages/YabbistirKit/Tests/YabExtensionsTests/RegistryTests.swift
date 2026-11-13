import Foundation
import Testing
import YabExtensionKit
import YabTestSupport
@testable import YabExtensions

/// Extension folders written straight into a root.
enum RegistryFixture {
    static func manifest(id: String, version: String = "1.0.0", permissions: [String] = []) -> [String: Any] {
        [
            "id": id, "version": version, "apiVersion": 1, "defaultLocale": "en", "name": "name", "description": "name",
            "icon": "sf:number", "author": "berkaygkc", "license": "MIT", "permissions": permissions,
            "preferences": [["id": "upper", "type": "toggle", "title": "upper", "default": false]],
            "contributes": ["actions": [["id": "a", "title": "name", "keywords": "keywords", "input": "none", "output": "text"]]],
        ]
    }

    @discardableResult
    static func write(in root: URL, id: String, folderName: String? = nil, manifest: [String: Any]? = nil) throws -> URL {
        let folder = root.appendingPathComponent(folderName ?? id)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("locales"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest ?? self.manifest(id: id)).write(to: folder.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: ["name": id, "keywords": ["k"], "upper": "Uppercase"])
            .write(to: folder.appendingPathComponent("locales/en.json"))
        try "exports.actions = { a: { run: () => ({ text: 'ok' }) } };".write(to: folder.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        return folder
    }

    static func temporary(_ name: String) -> URL {
        let url = TestScratch.url("yab-reg").appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension ExtensionRegistry {
    /// Approves what the extension asks for now, as the consent sheet would have shown it.
    func approveRequested(_ id: String) {
        guard let manifest = installed.first(where: { $0.id == id })?.manifest else { return }
        approve(id, grant: PermissionGrant.requested(by: manifest))
    }
}

@MainActor @Suite struct RegistryTests {
    let builtIn = RegistryFixture.temporary("BuiltinExtensions")
    let user = RegistryFixture.temporary("Extensions")
    let data = RegistryFixture.temporary("ExtensionData")
    let staging = TestScratch.url("yab-staging")
    let settings = ExtensionSettings(defaults: TestScratch.defaults("yab-ext"))

    func registry() -> ExtensionRegistry {
        ExtensionRegistry(builtInRoot: builtIn, userRoot: user, dataRoot: data, settings: settings, stagingRoot: staging)
    }

    /// What installs left in the staging folder: an install cleans up after itself, whether it succeeds or not.
    func leftInStaging() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
    }

    @Test func aCaptureRuleTagsWarningReachesTheDevelopmentLog() throws {
        let id = "dev.example.tags"
        var manifest = RegistryFixture.manifest(id: id, permissions: ["capture"])
        manifest["contributes"] = ["captureRules": [["id": "r", "title": "name", "accepts": ["kinds": ["text"], "tags": ["x"]]]]]
        try RegistryFixture.write(in: user, id: id, manifest: manifest)
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let lines = Lines()
        let registry = ExtensionRegistry(builtInRoot: builtIn, userRoot: user, dataRoot: data, settings: settings) { _, line in lines.all.append(line) }
        #expect(lines.all == ["\(id): contributes.captureRules[0].accepts.tags: capture rules never see tags; this rule would never run"])
        // A warning does not keep the extension off.
        #expect(try #require(registry.installed.first { $0.id == id }).issues.isEmpty)
    }

    /// A reload (every save in a linked folder is one) does not repeat a warning; a new version may say it again.
    @Test func aWarningIsLoggedOncePerVersion() throws {
        let id = "dev.example.tags"
        func write(version: String) throws {
            var manifest = RegistryFixture.manifest(id: id, version: version, permissions: ["capture"])
            manifest["contributes"] = ["captureRules": [["id": "r", "title": "name", "accepts": ["kinds": ["text"], "tags": ["x"]]]]]
            try RegistryFixture.write(in: user, id: id, manifest: manifest)
        }
        try write(version: "1.0.0")
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let lines = Lines()
        let registry = ExtensionRegistry(builtInRoot: builtIn, userRoot: user, dataRoot: data, settings: settings) { _, line in lines.all.append(line) }
        registry.reload()
        registry.reload()
        #expect(lines.all.count == 1)
        try write(version: "1.1.0")
        registry.reload()
        registry.reload()
        #expect(lines.all.count == 2)
    }

    @Test func builtInsAndLocalsAreListedWithTheirSource() throws {
        try RegistryFixture.write(in: user, id: "dev.example.b")
        try RegistryFixture.write(in: builtIn, id: "dev.yabbistir.a")
        let registry = registry()
        #expect(registry.installed.map(\.id) == ["dev.yabbistir.a", "dev.example.b"])
        #expect(registry.installed.map(\.source) == [.builtIn, .local])
    }

    /// A broken extension shows its problems; the others are untouched.
    @Test func aBrokenExtensionIsListedWithItsProblems() throws {
        try RegistryFixture.write(in: user, id: "dev.example.broken", manifest: RegistryFixture.manifest(id: "dev.example.broken", version: "1.0"))
        try RegistryFixture.write(in: user, id: "dev.example.good")
        let registry = registry()
        let broken = try #require(registry.installed.first { $0.id == "dev.example.broken" })
        let good = try #require(registry.installed.first { $0.id == "dev.example.good" })
        #expect(broken.manifest == nil)
        #expect(broken.issues.contains { $0.path == "version" })
        #expect(good.issues.isEmpty)
        #expect(good.isEnabled)
    }

    @Test func aLaterVersionPermissionIsStillNotInstalled() throws {
        let source = try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: "dev.example.net",
                                               manifest: RegistryFixture.manifest(id: "dev.example.net", permissions: ["teleport"]))
        let registry = registry()
        #expect(throws: (any Error).self) { try registry.install(folder: source) }
        #expect(!FileManager.default.fileExists(atPath: user.appendingPathComponent("dev.example.net").path))
    }

    @Test func installingAFolderCopiesIt() throws {
        let source = try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: "dev.example.copy")
        let registry = registry()
        #expect(try registry.install(folder: source) == "dev.example.copy")
        let installed = user.appendingPathComponent("dev.example.copy")
        #expect(try installed.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("index.js").path))
        #expect(registry.installed.first { $0.id == "dev.example.copy" }?.source == .local)
    }

    @Test func installingAnArchiveUnpacksIt() throws {
        let source = try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: "dev.example.zip")
        let archive = source.deletingLastPathComponent().appendingPathComponent("dev.example.zip.yabext")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", source.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()
        let registry = registry()
        #expect(try registry.install(archive: archive) == "dev.example.zip")
        #expect(registry.installed.contains { $0.id == "dev.example.zip" })
        #expect(leftInStaging().isEmpty)
    }

    @Test func installingAFolderLeavesNothingInStaging() throws {
        let source = try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: "dev.example.tidy")
        try registry().install(folder: source)
        #expect(leftInStaging().isEmpty)
    }

    @Test func aRejectedFolderLeavesNothingInStaging() throws {
        var manifest = RegistryFixture.manifest(id: "dev.example.rejected")
        manifest["version"] = "one"
        let source = try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: "dev.example.rejected", manifest: manifest)
        #expect(throws: RegistryError.self) { try registry().install(folder: source) }
        #expect(leftInStaging().isEmpty)
    }

    @Test func aLinkedFolderReloadsWhenItChanges() async throws {
        let source = try RegistryFixture.write(in: RegistryFixture.temporary("dev"), id: "dev.example.live")
        let registry = registry()
        #expect(try registry.linkDevelopmentFolder(source) == "dev.example.live")
        #expect(registry.installed.first { $0.id == "dev.example.live" }?.source == .development)
        try JSONSerialization.data(withJSONObject: RegistryFixture.manifest(id: "dev.example.live", version: "1.0.1"))
            .write(to: source.appendingPathComponent("manifest.json"))
        let start = ContinuousClock.now
        while registry.installed.first(where: { $0.id == "dev.example.live" })?.manifest?.version != "1.0.1",
              ContinuousClock.now - start < .seconds(2) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(registry.installed.first { $0.id == "dev.example.live" }?.manifest?.version == "1.0.1")
    }

    @Test func uninstallRemovesFilesAndData() throws {
        let source = try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: "dev.example.gone")
        let linked = try RegistryFixture.write(in: RegistryFixture.temporary("dev"), id: "dev.example.linked")
        let registry = registry()
        try registry.install(folder: source)
        try registry.linkDevelopmentFolder(linked)
        try FileManager.default.createDirectory(at: data.appendingPathComponent("dev.example.gone"), withIntermediateDirectories: true)
        try registry.uninstall("dev.example.gone")
        try registry.uninstall("dev.example.linked")
        #expect(!FileManager.default.fileExists(atPath: user.appendingPathComponent("dev.example.gone").path))
        #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent("dev.example.gone").path))
        #expect(registry.installed.isEmpty)
        // A development link goes; the developer's folder stays.
        #expect(FileManager.default.fileExists(atPath: linked.appendingPathComponent("manifest.json").path))
    }

    /// An id is a path component; ".." must never reach the file system.
    @Test func aLinkWhoseIDLeavesTheFolderTouchesNothing() throws {
        let appSupport = user.deletingLastPathComponent()
        let marker = appSupport.appendingPathComponent("db.sqlite")
        try Data([1]).write(to: marker)
        try RegistryFixture.write(in: user, id: "dev.example.kept")
        let registry = registry()
        for id in ["..", ".", "../Extensions", "dev..x"] {
            let folder = try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: "evil", manifest: RegistryFixture.manifest(id: id))
            #expect(throws: RegistryError.self) { try registry.linkDevelopmentFolder(folder) }
            #expect(throws: RegistryError.self) { try registry.install(folder: folder) }
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(registry.installed.contains { $0.id == "dev.example.kept" })
    }

    /// index.js that does not parse is a problem in Settings, found without running it.
    @Test func aSyntaxErrorIsAProblem() throws {
        let folder = try RegistryFixture.write(in: user, id: "dev.example.broken")
        try "exports.actions = {\n  a: { run() { return { text: 'x' } }\n".write(to: folder.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        let entry = try #require(registry().installed.first { $0.id == "dev.example.broken" })
        #expect(!entry.isUsable)
        let issue = try #require(entry.issues.first)
        #expect(issue.path == "index.js")
        #expect(issue.message.hasPrefix("line "))
        #expect(entry.manifest != nil)
    }

    @Test func builtInsCannotBeUninstalled() throws {
        try RegistryFixture.write(in: builtIn, id: "dev.yabbistir.a")
        let registry = registry()
        #expect(throws: (any Error).self) { try registry.uninstall("dev.yabbistir.a") }
        #expect(registry.installed.count == 1)
    }

    @Test func preferencesFallBackToManifestDefaults() throws {
        try RegistryFixture.write(in: user, id: "dev.example.prefs")
        let registry = registry()
        let specs = try #require(registry.installed.first?.manifest?.preferences)
        #expect(settings.preferences("dev.example.prefs", specs: specs) == ["upper": .bool(false)])
        settings.setPreference("dev.example.prefs", "upper", .bool(true), specs: specs)
        #expect(settings.preferences("dev.example.prefs", specs: specs) == ["upper": .bool(true)])
    }

    @Test func turningOffPersists() throws {
        try RegistryFixture.write(in: user, id: "dev.example.toggle")
        registry().setEnabled("dev.example.toggle", false)
        #expect(registry().installed.first?.isEnabled == false)
    }
}

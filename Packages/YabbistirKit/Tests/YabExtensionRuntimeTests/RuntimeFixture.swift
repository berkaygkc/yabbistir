import Foundation
import YabExtensionKit
import YabTestSupport
@testable import YabExtensionRuntime

/// Builds a throwaway extension around a piece of index.js and loads it.
enum RuntimeFixture {
    static var manifest: [String: Any] { [
        "id": "dev.example.fixture", "version": "1.0.0", "apiVersion": 1, "defaultLocale": "en", "name": "name",
        "description": "name", "icon": "sf:number", "author": "berkaygkc", "license": "MIT",
        "contributes": ["actions": [["id": "a", "title": "name", "keywords": "keywords", "input": "none", "output": "text"]]],
    ] }

    static func folder(js: String, locales: [String: [String: Any]] = ["en": ["name": "Fixture", "keywords": ["fixture"]]],
                       manifest: [String: Any] = manifest) throws -> URL {
        let folder = TestScratch.url("yab-rt").appendingPathComponent("dev.example.fixture")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("locales"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        for (language, table) in locales {
            try JSONSerialization.data(withJSONObject: table).write(to: folder.appendingPathComponent("locales/\(language).json"))
        }
        try js.write(to: folder.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        return folder
    }

    static func load(js: String, locales: [String: [String: Any]] = ["en": ["name": "Fixture", "keywords": ["fixture"]]],
                     dataFolder: URL? = nil, grant: PermissionGrant = .empty,
                     log: @escaping @Sendable (String) -> Void = { _ in }) throws -> ExtensionRuntime {
        try load(folder: folder(js: js, locales: locales), dataFolder: dataFolder, grant: grant, log: log)
    }

    static func load(folder: URL, dataFolder: URL? = nil, grant: PermissionGrant = .empty,
                     log: @escaping @Sendable (String) -> Void = { _ in }) throws -> ExtensionRuntime {
        guard case .valid(let manifest, let localization) = ManifestValidator.validate(folder: folder) else {
            fatalError("fixture manifest is invalid: \(ManifestValidator.validate(folder: folder).issues)")
        }
        let data = dataFolder ?? TestScratch.url("yab-data")
        return try ExtensionRuntime(folder: folder, manifest: manifest, localization: localization, dataFolder: data, grant: grant, log: log)
    }
}

/// Collects log lines from the runtime's thread.
final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var lines: [String] { lock.withLock { storage } }
    func append(_ line: String) { lock.withLock { storage.append(line) } }
}

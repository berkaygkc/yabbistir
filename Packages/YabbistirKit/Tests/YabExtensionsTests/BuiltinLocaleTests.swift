import Foundation
import Testing
import YabLocalization

/// Every built-in extension speaks every app language: a locale file per `AppLanguage`, with en.json's keys and
/// placeholders. A missing file or key falls back to English in the ⇧ panel, ⌘K and Settings; a lost `{name}` shows raw.
@Suite struct BuiltinLocaleTests {
    /// The built-ins as the app bundles them (`make extensions`), and their sources in Extensions/builtin.
    static let roots = [BuiltinFolder.root, BuiltinFolder.root.deletingLastPathComponent().appendingPathComponent("builtin")]

    static func extensions(in root: URL) -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// locales/<code>.json, or nil when the file is missing.
    static func table(_ folder: URL, _ code: String) throws -> [String: Any]? {
        let url = folder.appendingPathComponent("locales/\(code).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    }

    /// A string's `{name}` placeholders, sorted; none for keyword lists.
    static func placeholders(_ value: Any?) -> [String] {
        guard let text = value as? String else { return [] }
        return text.matches(of: /\{(\w+)\}/).map { String($0.1) }.sorted()
    }

    @Test(arguments: roots) func everyLanguageHasEnglishKeysAndPlaceholders(root: URL) throws {
        let folders = Self.extensions(in: root)
        #expect(!folders.isEmpty, "no built-in extensions in \(root.path)")
        for folder in folders {
            let id = folder.lastPathComponent
            let english = try #require(try Self.table(folder, "en"), "\(id): locales/en.json is missing")
            for language in AppLanguage.allCases {
                let code = language.rawValue
                guard let table = try Self.table(folder, code) else {
                    Issue.record("\(id): locales/\(code).json is missing")
                    continue
                }
                #expect(Set(table.keys) == Set(english.keys), "\(id): \(code).json keys differ from en.json")
                for (key, value) in english {
                    #expect(Self.placeholders(table[key]) == Self.placeholders(value),
                            "\(id): \(code).json \"\(key)\" placeholders differ from en.json")
                }
            }
        }
    }
}

import Foundation

/// An extension's own strings (locales/<language>.json). A lookup tries the app's language, then
/// the extension's default locale, then returns the key itself.
public struct ExtensionLocalization: Sendable {
    public let defaultLocale: String
    private let tables: [String: [String: JSONValue]]

    public init(tables: [String: [String: JSONValue]], defaultLocale: String) {
        self.tables = tables
        self.defaultLocale = defaultLocale
    }

    public init(folder: URL, defaultLocale: String) throws {
        var tables: [String: [String: JSONValue]] = [:]
        let localesFolder = folder.appendingPathComponent("locales")
        for file in (try? FileManager.default.contentsOfDirectory(at: localesFolder, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "json" {
            tables[file.deletingPathExtension().lastPathComponent] = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: file))
        }
        self.init(tables: tables, defaultLocale: defaultLocale)
    }

    public var languages: [String] { Array(tables.keys).sorted() }

    public func hasKey(_ key: String, in language: String) -> Bool { tables[language]?[key] != nil }

    public func string(_ key: String, language: String) -> String {
        for table in [tables[language], tables[defaultLocale]] {
            if let value = table?[key]?.stringValue { return value }
        }
        return key
    }

    /// The selected language's keywords, then the default locale's, without repeats: someone
    /// using Turkish still finds "decode".
    public func keywords(_ key: String, language: String) -> [String] {
        var seen = Set<String>()
        var words: [String] = []
        for table in [tables[language], tables[defaultLocale]] {
            for word in table?[key]?.arrayValue?.compactMap(\.stringValue) ?? [] where seen.insert(word).inserted {
                words.append(word)
            }
        }
        return words
    }
}

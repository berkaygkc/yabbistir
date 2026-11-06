import Foundation
import Testing
@testable import YabLocalization

/// The source catalogs, read as JSON: the shipped languages are complete, and no translation drops, adds or retypes a
/// placeholder.
@Suite struct CatalogTests {
    /// Every language the app ships. Each translation task appends its code.
    static let shippedLanguages = ["en", "tr"]

    /// Languages whose plural rules tell one from many.
    static let singularLanguages: Set<String> = ["en", "tr", "de", "fr", "es"]

    private static let sources: [URL] = {
        let kit = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repo = kit.deletingLastPathComponent().deletingLastPathComponent()
        return [
            kit.appendingPathComponent("Sources/YabLocalization/Localizable.xcstrings"),
            repo.appendingPathComponent("App/InfoPlist.xcstrings"),
        ]
    }()


    private static func catalogs() throws -> [(file: String, strings: [String: [String: Any]])] {
        try sources.map { url in
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let strings = object?["strings"] as? [String: [String: Any]]
            return (url.lastPathComponent, try #require(strings))
        }
    }

    /// A language's units for a key: `["": unit]` for a plain string, `["one": unit, "other": unit]` for a plural.
    private static func units(_ entry: [String: Any], _ code: String) -> [String: [String: Any]]? {
        guard let localization = (entry["localizations"] as? [String: Any])?[code] as? [String: Any] else { return nil }
        if let unit = localization["stringUnit"] as? [String: Any] { return ["": unit] }
        guard let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] else { return nil }
        var result: [String: [String: Any]] = [:]
        for (form, value) in plural {
            if let unit = (value as? [String: Any])?["stringUnit"] as? [String: Any] { result[form] = unit }
        }
        return result
    }

    private static func placeholders(_ value: String) -> [String] {
        value.matches(of: /%(?:\d+\$)?(?:@|lld|d|f|n)/).map { String($0.0) }.sorted()
    }

    @Test(arguments: shippedLanguages)
    func everyKeyIsTranslated(code: String) throws {
        var problems: [String] = []
        for (file, strings) in try Self.catalogs() {
            for (key, entry) in strings.sorted(by: { $0.key < $1.key }) {
                guard let units = Self.units(entry, code), !units.isEmpty else {
                    problems.append("\(file): \(key) has no \(code)")
                    continue
                }
                for (form, unit) in units where unit["state"] as? String != "translated" || (unit["value"] as? String ?? "").isEmpty {
                    problems.append("\(file): \(key) [\(form)] is not translated in \(code)")
                }
            }
        }
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test(arguments: shippedLanguages)
    func placeholdersMatchEnglish(code: String) throws {
        var problems: [String] = []
        for (file, strings) in try Self.catalogs() {
            for (key, entry) in strings.sorted(by: { $0.key < $1.key }) {
                guard let english = Self.units(entry, "en"), let units = Self.units(entry, code) else { continue }
                for (form, unit) in units {
                    // A language may have plural forms English lacks; they carry the same placeholders as English's "other".
                    guard let reference = english[form] ?? english["other"] ?? english[""] else { continue }
                    let expected = Self.placeholders(reference["value"] as? String ?? "")
                    let actual = Self.placeholders(unit["value"] as? String ?? "")
                    if expected != actual { problems.append("\(file): \(key) [\(form)] \(code) \(actual) != en \(expected)") }
                }
            }
        }
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test(arguments: shippedLanguages)
    func pluralFormsPresent(code: String) throws {
        let entry = try #require(try Self.catalogs()[0].strings["transforms.count"])
        let forms = try #require(Self.units(entry, code))
        #expect(forms["other"] != nil, "\(code) has no other form")
        if Self.singularLanguages.contains(code) { #expect(forms["one"] != nil, "\(code) has no one form") }
    }

    @Test func relativeTimeComesFromCatalog() throws {
        let strings = try Self.catalogs()[0].strings
        for key in ["time.now", "time.minutes", "time.hours", "time.yesterday", "time.days"] {
            let entry = try #require(strings[key], "\(key) is missing")
            for code in ["en", "tr"] { #expect(Self.units(entry, code) != nil, "\(key) has no \(code)") }
        }
    }
}

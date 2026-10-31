import Foundation
import Testing
@testable import YabExtensionKit

/// The store's validator (a separate repository) and this one must agree on every manifest. The corpus under
/// Fixtures/manifest-parity is a copy of the store's `schema/fixtures`: each fixture describes one extension
/// folder, and `expected.json` lists the sorted issue codes both validators report for it (errors and
/// warnings alike).
///
/// To refresh the corpus, copy `valid/`, `invalid/` and `expected.json` from the store repository's
/// `schema/fixtures` into this directory, replacing the old copies, then run this suite. A difference in codes
/// means one of the two validators needs to change; messages may differ, codes may not.
struct ManifestParityTests {
    static let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/manifest-parity")

    /// Writes the fixture's folder under a fresh temporary directory, as the store's tools do.
    static func materialize(_ fixture: [String: Any]) throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("yab-parity-\(UUID().uuidString)")
        let folder = parent.appendingPathComponent(fixture["folder"] as? String ?? "dev.example.sample")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let text = fixture["manifestText"] as? String {
            try text.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        } else if let manifest = fixture["manifest"] {
            try JSONSerialization.data(withJSONObject: manifest, options: [.fragmentsAllowed])
                .write(to: folder.appendingPathComponent("manifest.json"))
        }
        for (language, table) in (fixture["locales"] as? [String: Any]) ?? [:] {
            let directory = folder.appendingPathComponent("locales")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent("\(language).json")
            if let text = table as? String { try text.write(to: target, atomically: true, encoding: .utf8) }
            else { try JSONSerialization.data(withJSONObject: table).write(to: target) }
        }
        for file in (fixture["files"] as? [String]) ?? [] {
            let target = folder.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: target.path, contents: Data())
        }
        return folder
    }

    @Test func swiftValidatorAgreesWithTheStoreCorpus() throws {
        let expected = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: Self.corpus.appendingPathComponent("expected.json"))) as? [String: [String]])
        var checked = 0
        var disagreements: [String] = []
        for group in ["valid", "invalid"] {
            let names = try FileManager.default.contentsOfDirectory(atPath: Self.corpus.appendingPathComponent(group).path)
                .filter { $0.hasSuffix(".json") }.sorted()
            for name in names {
                let key = "\(group)/\(name)"
                let data = try Data(contentsOf: Self.corpus.appendingPathComponent(key))
                let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let folder = try Self.materialize(fixture)
                defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
                let issues = ManifestValidator.validate(folder: folder).issues + ManifestValidator.warnings(folder: folder)
                let codes = Set(issues.map { $0.code ?? "(no code)" }).sorted()
                if codes != (expected[key] ?? ["(not in expected.json)"]) { disagreements.append("\(key): swift \(codes), store \(expected[key] ?? [])") }
                checked += 1
            }
        }
        #expect(disagreements.isEmpty, "\(disagreements.joined(separator: "\n"))")
        #expect(checked == expected.count, "every fixture in expected.json has a file, and the other way round")
        #expect(checked > 0)
    }
}

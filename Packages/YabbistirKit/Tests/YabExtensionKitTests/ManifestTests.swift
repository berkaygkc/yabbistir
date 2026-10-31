import Foundation
import Testing
@testable import YabExtensionKit

@Suite struct ManifestTests {
    func issues(_ manifest: [String: Any], id: String = "dev.example.sample", folderName: String? = nil,
                indexJS: String? = "exports.actions = {};", locales: [String: [String: Any]] = Fixture.locales) throws -> [ManifestIssue] {
        let fixture = try Fixture(id: id, folderName: folderName, manifest: manifest, locales: locales, indexJS: indexJS)
        return ManifestValidator.validate(folder: fixture.root).issues
    }

    static var rule: [String: Any] { ["id": "clean", "title": "decode.title", "description": "encode.title", "accepts": ["kinds": ["link", "text"]]] }

    // MARK: Sources

    static var sourceLocales: [String: [String: Any]] {
        var en = Fixture.locales["en"] ?? [:]
        for (key, value) in ["source.title": "Vault", "password.title": "Paste password", "password.label": "Password",
                             "username.title": "Paste username", "username.label": "Username",
                             "username.copy": "Copy username", "username.copied": "Username copied."] { en[key] = value }
        return ["en": en]
    }
    static var secretAction: [String: Any] { ["id": "password", "kind": "secret", "title": "password.title", "label": "password.label"] }
    static var textAction: [String: Any] {
        ["id": "username", "kind": "text", "title": "username.title", "label": "username.label", "copyTitle": "username.copy", "copied": "username.copied"]
    }
    static func sourceManifest(_ source: [String: Any]) -> [String: Any] {
        Fixture.manifest(id: "dev.example.sample").setting("contributes.sources", [source])
    }
    static func vault(sensitive: Bool = true, actions: [[String: Any]]) -> [String: Any] {
        ["id": "vault", "title": "source.title", "sensitive": sensitive, "actions": actions]
    }
    func sourceCodes(_ manifest: [String: Any]) throws -> [String] {
        try issues(manifest, locales: Self.sourceLocales).compactMap(\.code)
    }

    @Test func aSourceDecodesWithItsActions() throws {
        let manifest = Self.sourceManifest(Self.vault(actions: [Self.secretAction, Self.textAction]))
        let fixture = try Fixture(manifest: manifest, locales: Self.sourceLocales)
        guard case .valid(let parsed, _) = ManifestValidator.validate(folder: fixture.root) else {
            Issue.record("expected a valid manifest: \(ManifestValidator.validate(folder: fixture.root).issues)"); return
        }
        let source = try #require(parsed.contributes.sources.first)
        #expect(source.id == "vault" && source.title == "source.title" && source.sensitive)
        #expect(source.actions.map(\.id) == ["password", "username"])
        #expect(source.actions.map(\.kind) == [.secret, .text])
        #expect(source.actions[0].label == "password.label" && source.actions[0].copyTitle == nil)
        #expect(source.actions[1].copyTitle == "username.copy" && source.actions[1].copied == "username.copied")
    }

    @Test func aSourceIsNotSensitiveUnlessItSaysSo() throws {
        let source: [String: Any] = ["id": "vault", "title": "source.title", "actions": [Self.textAction]]
        let fixture = try Fixture(manifest: Self.sourceManifest(source), locales: Self.sourceLocales)
        guard case .valid(let parsed, _) = ManifestValidator.validate(folder: fixture.root) else {
            Issue.record("expected a valid manifest: \(ManifestValidator.validate(folder: fixture.root).issues)"); return
        }
        #expect(parsed.contributes.sources.first?.sensitive == false)
    }

    @Test func contributionsWithoutSourcesStillDecode() throws {
        let fixture = try Fixture()
        guard case .valid(let parsed, _) = ManifestValidator.validate(folder: fixture.root) else {
            Issue.record("expected a valid manifest"); return
        }
        #expect(parsed.contributes.sources.isEmpty)
    }

    @Test func aSourceNeedsOneOrTwoActions() throws {
        #expect(try sourceCodes(Self.sourceManifest(Self.vault(sensitive: false, actions: []))) == ["sourceActionCount"])
        let extra = ["a", "b", "c"].map { ["id": $0, "kind": "text", "title": "username.title", "label": "username.label"] as [String: Any] }
        #expect(try sourceCodes(Self.sourceManifest(Self.vault(sensitive: false, actions: extra))) == ["sourceActionCount"])
    }

    @Test func aSourceActionKindIsSecretOrText() throws {
        let action = Self.secretAction.setting("kind", "bogus")
        #expect(try sourceCodes(Self.sourceManifest(Self.vault(actions: [action]))) == ["unknownSourceActionKind"])
    }

    @Test func aSecretActionNeedsASensitiveSource() throws {
        #expect(try sourceCodes(Self.sourceManifest(Self.vault(sensitive: false, actions: [Self.secretAction]))) == ["sourceSecretNeedsSensitive"])
        let omitted: [String: Any] = ["id": "vault", "title": "source.title", "actions": [Self.secretAction]]
        #expect(try sourceCodes(Self.sourceManifest(omitted)) == ["sourceSecretNeedsSensitive"])
    }

    @Test func aSecretActionRulesOutTheNetworkPermission() throws {
        let manifest = Self.sourceManifest(Self.vault(actions: [Self.secretAction]))
            .setting("permissions", ["network"]).setting("network", ["domains": ["ornek.dev"]])
        #expect(try sourceCodes(manifest) == ["sourceSecretWithNetwork"])
        // Text-only sources may reach the network.
        let text = Self.sourceManifest(Self.vault(sensitive: false, actions: [Self.textAction]))
            .setting("permissions", ["network"]).setting("network", ["domains": ["ornek.dev"]])
        #expect(try sourceCodes(text).isEmpty)
    }

    @Test func copyFieldsBelongToTextActions() throws {
        for key in ["copyTitle", "copied"] {
            let action = Self.secretAction.setting(key, key == "copyTitle" ? "username.copy" : "username.copied")
            #expect(try sourceCodes(Self.sourceManifest(Self.vault(actions: [action]))) == ["sourceCopyNeedsText"])
        }
    }

    @Test func sourceAndActionIDsAreUnique() throws {
        let twice = Self.sourceManifest(Self.vault(sensitive: false, actions: [Self.textAction, Self.textAction]))
        #expect(try sourceCodes(twice) == ["duplicateID"])
        let source = Self.vault(sensitive: false, actions: [Self.textAction])
        #expect(try sourceCodes(Fixture.manifest(id: "dev.example.sample").setting("contributes.sources", [source, source])) == ["duplicateID"])
        #expect(try sourceCodes(Self.sourceManifest(source.setting("id", "va ult"))) == ["invalidMemberID"])
    }

    @Test func sourceLocaleKeysMustExist() throws {
        let source = Self.vault(sensitive: false, actions: [Self.textAction])
        #expect(try sourceCodes(Self.sourceManifest(source.setting("title", "missing.key"))) == ["unknownLocaleKey"])
        let action = Self.textAction.setting("copied", "missing.key")
        #expect(try sourceCodes(Self.sourceManifest(Self.vault(sensitive: false, actions: [action]))) == ["unknownLocaleKey"])
        #expect(try sourceCodes(Self.sourceManifest(Self.vault(sensitive: false, actions: [Self.textAction.setting("label", nil)]))) == ["missingField"])
    }

    @Test func aWronglyTypedSensitiveFlagIsUnreadable() throws {
        let source = Self.vault(sensitive: false, actions: [Self.textAction]).setting("sensitive", "yes")
        #expect(try sourceCodes(Self.sourceManifest(source)) == ["manifestUnreadable"])
    }

    @Test func captureAndHistoryAreAccepted() throws {
        let found = try issues(Fixture.manifest(id: "dev.example.sample").setting("permissions", ["capture", "history"]))
        #expect(found.isEmpty, "\(found)")
    }

    @Test func captureRulesWithTagsWarn() throws {
        let rule = Self.rule.setting("accepts.tags", ["dev.example.sample:base64"])
        let manifest = Fixture.manifest(id: "dev.example.sample")
            .setting("permissions", ["capture"]).setting("contributes.captureRules", [rule])
        let fixture = try Fixture(manifest: manifest)
        // A warning is not an error: the manifest still loads.
        guard case .valid = ManifestValidator.validate(folder: fixture.root) else {
            Issue.record("expected a valid manifest: \(ManifestValidator.validate(folder: fixture.root).issues)"); return
        }
        let warnings = ManifestValidator.warnings(folder: fixture.root)
        #expect(warnings.count == 1)
        #expect(warnings.first?.code == "captureRuleTags")
        #expect(warnings.first?.severity == .warning)
        #expect(warnings.first?.path == "contributes.captureRules[0].accepts.tags")
        #expect(warnings.first?.message == "capture rules never see tags; this rule would never run")
        // The same rule without tags is clean, and an action with tags is fine.
        let clean = try Fixture(manifest: Fixture.manifest(id: "dev.example.sample")
            .setting("permissions", ["capture"]).setting("contributes.captureRules", [Self.rule]))
        #expect(ManifestValidator.warnings(folder: clean.root).isEmpty)
    }

    @Test func aRuleManifestParses() throws {
        let manifest = Fixture.manifest(id: "dev.example.sample")
            .setting("permissions", ["capture"]).setting("contributes.captureRules", [Self.rule])
        let fixture = try Fixture(manifest: manifest)
        guard case .valid(let parsed, _) = ManifestValidator.validate(folder: fixture.root) else {
            Issue.record("expected a valid manifest: \(ManifestValidator.validate(folder: fixture.root).issues)"); return
        }
        let rule = parsed.contributes.captureRules[0]
        #expect(rule.id == "clean")
        #expect(rule.title == "decode.title" && rule.description == "encode.title")
        #expect(rule.accepts.kinds == ["link", "text"])
        #expect(parsed.contributes.actions.count == 2)
    }

    @Test func secretAndFolderPreferencesParse() throws {
        let manifest = Fixture.manifest(id: "dev.example.sample").setting("preferences", [
            ["id": "token", "type": "secret", "title": "upper"],
            ["id": "dir", "type": "folder", "title": "upper", "default": "~/Downloads"],
            ["id": "bare", "type": "folder", "title": "upper"],
        ])
        let fixture = try Fixture(manifest: manifest)
        guard case .valid(let parsed, _) = ManifestValidator.validate(folder: fixture.root) else {
            Issue.record("expected a valid manifest: \(ManifestValidator.validate(folder: fixture.root).issues)"); return
        }
        #expect(parsed.preferences.map(\.type) == [.secret, .folder, .folder])
        #expect(parsed.preferences[0].default == .null)
        #expect(parsed.preferences[1].default == .string("~/Downloads"))
    }

    @Test func aValidManifestParses() throws {
        let fixture = try Fixture()
        guard case .valid(let manifest, _) = ManifestValidator.validate(folder: fixture.root) else {
            Issue.record("expected a valid manifest"); return
        }
        #expect(manifest.id == "dev.example.sample")
        #expect(manifest.contributes.actions.map(\.id) == ["decode", "encode"])
        #expect(manifest.contributes.actions[0].input == .item)
        #expect(manifest.contributes.actions[0].priority == 2)
        #expect(manifest.contributes.actions[1].hint == false)
        #expect(manifest.contributes.detectors.map(\.id) == ["base64"])
        #expect(manifest.preferences.map(\.id) == ["upper"])
        #expect(manifest.permissions.isEmpty)
        #expect(manifest.categories == [.text])
    }

    @Test func everyRuleReportsItsPath() throws {
        let base = Fixture.manifest(id: "dev.example.sample")
        let cases: [(String, [String: Any], String?, String?, Bool)] = [
            // (expected path, manifest, folder name, index.js, drop en locale)
            ("id", base.setting("id", "Base64"), "Base64", "x", false),
            ("id", base, "dev.example.other", "x", false),
            ("version", base.setting("version", "1.0"), nil, "x", false),
            ("apiVersion", base.setting("apiVersion", 2), nil, "x", false),
            ("defaultLocale", base.setting("defaultLocale", "de"), nil, "x", false),
            ("contributes.actions[0].title", base.setting("contributes.actions.0.title", "missing.key"), nil, "x", false),
            ("contributes.actions[1].id", base.setting("contributes.actions.1.id", "decode"), nil, "x", false),
            ("contributes.actions[0].accepts", base.setting("contributes.actions.0.accepts", nil), nil, "x", false),
            ("contributes.actions[0].accepts.pattern", base.setting("contributes.actions.0.accepts.pattern", "("), nil, "x", false),
            ("categories[0]", base.setting("categories", ["games"]), nil, "x", false),
            ("permissions", base.setting("permissions", ["teleport"]), nil, "x", false),
            ("contributes.captureRules", base.setting("contributes.captureRules", [Self.rule]), nil, "x", false),
            ("contributes.captureRules[0].accepts.kinds",
             base.setting("permissions", ["capture"]).setting("contributes.captureRules", [Self.rule.setting("accepts.kinds", [String]())]), nil, "x", false),
            ("contributes.captureRules[0].title",
             base.setting("permissions", ["capture"]).setting("contributes.captureRules", [Self.rule.setting("title", "missing.key")]), nil, "x", false),
            ("contributes.captureRules[1].id",
             base.setting("permissions", ["capture"]).setting("contributes.captureRules", [Self.rule, Self.rule]), nil, "x", false),
            ("preferences[0].default", base.setting("preferences", [["id": "token", "type": "secret", "title": "upper", "default": "x"]]), nil, "x", false),
            ("preferences[0].default", base.setting("preferences", [["id": "dir", "type": "folder", "title": "upper", "default": "/tmp"]]), nil, "x", false),
            ("requires.tools", base.setting("permissions", ["exec"]), nil, "x", false),
            ("network.domains[0]", base.setting("permissions", ["network"]).setting("network", ["domains": ["https://video.example"]]), nil, "x", false),
            ("contributes.actions[0].targets[0]", base.setting("contributes.actions.0.targets", ["desktop"]), nil, "x", false),
            ("contributes.actions[0].targetsOnly", base.setting("contributes.actions.0.targetsOnly", true), nil, "x", false),
            ("index.js", base, nil, nil, false),
            // What used to pass and then trap.
            ("apiVersion", base.setting("apiVersion", 1e20), nil, "x", false),
            ("preferences[1].id", base.setting("preferences", [["id": "upper", "type": "toggle", "title": "upper", "default": false],
                                                                ["id": "upper", "type": "toggle", "title": "upper", "default": true]]), nil, "x", false),
            ("contributes.actions[0].variants[1].id", base.setting("contributes.actions.0.variants",
                                                                   [["id": "a", "title": "decode.title"], ["id": "a", "title": "decode.title"]]), nil, "x", false),
            ("contributes.actions[0].id", base.setting("contributes.actions.0.id", "de#code"), nil, "x", false),
            ("contributes.actions[0].variants[0].id", base.setting("contributes.actions.0.variants", [["id": "a/b", "title": "decode.title"]]), nil, "x", false),
            ("preferences[0].id", base.setting("preferences.0.id", "up per"), nil, "x", false),
            ("contributes.detectors[0].id", base.setting("contributes.detectors.0.id", "base:64"), nil, "x", false),
        ]
        for (path, manifest, folder, index, _) in cases {
            let found = try issues(manifest, folderName: folder, indexJS: index)
            #expect(found.contains { $0.path == path }, "no issue at \(path): \(found.map(\.path))")
        }
    }

    @Test func issuesSayHowToFixThem() throws {
        let base = Fixture.manifest(id: "dev.example.sample")
        let found = try issues(base.setting("version", "1.0").setting("categories", ["games"]).setting("permissions", ["teleport"]))
        #expect(!found.isEmpty)
        #expect(found.allSatisfy { !($0.fix ?? "").isEmpty })
    }

    @Test func aDownloaderManifestParses() throws {
        var manifest = Fixture.manifest(id: "dev.example.sample")
            .setting("permissions", ["network", "exec"])
            .setting("network", ["domains": ["video.example", "cdn.example.org"]])
            .setting("requires", ["tools": [["name": "yt-dlp", "install": "brew install yt-dlp"]]])
            .setting("preferences.0", ["id": "upper", "type": "toggle", "title": "upper", "default": false, "confirm": "hello"])
        manifest = manifest
            .setting("contributes.actions.0.targets", ["finder"])
            .setting("contributes.actions.0.targetsOnly", true)
            .setting("contributes.actions.0.job", true)
            .setting("contributes.actions.0.verb", "hello")
            .setting("contributes.actions.0.output", "file")
        let fixture = try Fixture(manifest: manifest)
        guard case .valid(let parsed, _) = ManifestValidator.validate(folder: fixture.root) else {
            Issue.record("expected a valid manifest: \(ManifestValidator.validate(folder: fixture.root).issues)"); return
        }
        #expect(parsed.network?.domains == ["video.example", "cdn.example.org"])
        #expect(parsed.requires?.tools == [ToolSpec(name: "yt-dlp", install: "brew install yt-dlp")])
        let action = parsed.contributes.actions[0]
        #expect(action.targets == [.finder])
        #expect(action.targetsOnly && action.job)
        #expect(action.verb == "hello")
        #expect(action.output == .file)
        #expect(parsed.preferences[0].confirm == "hello")
        #expect(parsed.contributes.actions[1].targets.isEmpty)
    }

    /// `failTitle` names a failed job ("Video indirilemedi"); the action's and each variant's are
    /// locale keys like `verb`.
    @Test func aFailTitleIsALocaleKey() throws {
        let manifest = Fixture.manifest(id: "dev.example.sample")
            .setting("contributes.actions.0.failTitle", "hello")
            .setting("contributes.actions.0.variants", [["id": "a", "title": "decode.title", "failTitle": "encode.title"],
                                                         ["id": "b", "title": "decode.title"]])
        let fixture = try Fixture(manifest: manifest)
        guard case .valid(let parsed, _) = ManifestValidator.validate(folder: fixture.root) else {
            Issue.record("expected a valid manifest: \(ManifestValidator.validate(folder: fixture.root).issues)"); return
        }
        #expect(parsed.contributes.actions[0].failTitle == "hello")
        #expect(parsed.contributes.actions[0].variants.map(\.failTitle) == ["encode.title", nil])
        #expect(parsed.contributes.actions[1].failTitle == nil)

        let badAction = try issues(Fixture.manifest(id: "dev.example.sample").setting("contributes.actions.0.failTitle", "missing.key"))
        #expect(badAction.contains { $0.path == "contributes.actions[0].failTitle" }, "\(badAction.map(\.path))")
        let badVariant = try issues(Fixture.manifest(id: "dev.example.sample")
            .setting("contributes.actions.0.variants", [["id": "a", "title": "decode.title", "failTitle": "missing.key"]]))
        #expect(badVariant.contains { $0.path == "contributes.actions[0].variants[0].failTitle" }, "\(badVariant.map(\.path))")
    }

    @Test func fileResultsRoundTrip() throws {
        for result in [ExtensionResult.files(paths: ["/tmp/a.mp4", "/tmp/b.mp4"]), .file(path: "/tmp/a.mp4")] {
            let data = try JSONEncoder().encode(result)
            #expect(try JSONDecoder().decode(ExtensionResult.self, from: data) == result)
        }
    }

    /// `verb` is the job's ↵ label in the ⇧ panel ("İndir"), not something shown while
    /// it works; the schema extension authors read says so.
    @Test func theSchemaDescribesVerbAsTheReturnKeysLabel() throws {
        let schema = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Extensions/schema/manifest.schema.json")
        func verbDescriptions(_ value: Any) -> [String] {
            if let object = value as? [String: Any] {
                let own = ((object["properties"] as? [String: Any])?["verb"] as? [String: Any])?["description"] as? String
                return (own.map { [$0] } ?? []) + object.values.flatMap(verbDescriptions)
            }
            return (value as? [Any])?.flatMap(verbDescriptions) ?? []
        }
        let descriptions = verbDescriptions(try JSONSerialization.jsonObject(with: Data(contentsOf: schema)))
        #expect(!descriptions.isEmpty)
        for description in descriptions {
            #expect(description.contains("↵"))
            #expect(!description.contains("while the job works"))
        }
    }
}

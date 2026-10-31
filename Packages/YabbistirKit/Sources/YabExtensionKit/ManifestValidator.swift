import Foundation

/// One problem with an extension, written so a person or an agent can fix it: where, what,
/// what was expected and how to fix it.
public struct ManifestIssue: Equatable, Sendable, CustomStringConvertible {
    /// An error keeps an extension from loading; a warning is shown but the extension still loads.
    public enum Severity: Sendable { case error, warning }

    public let path: String
    public let message: String
    public let expected: String?
    public let fix: String?
    public let severity: Severity
    /// A stable name a tool may match on, the same one the store's checker reports ("invalidVersion",
    /// "captureRuleTags"). Every issue the validator finds has one; nil only for problems found elsewhere (the
    /// registry's id check before validating, a syntax error in index.js).
    public let code: String?

    public init(_ path: String, _ message: String, expected: String? = nil, fix: String, severity: Severity = .error, code: String? = nil) {
        self.severity = severity
        self.code = code
        self.path = path
        self.message = message
        self.expected = expected
        self.fix = fix
    }

    public var description: String { "\(path): \(message)" + (fix.map { " (\($0))" } ?? "") }
}

/// The outcome of checking an extension folder.
public enum ManifestValidation: Sendable {
    case valid(ExtensionManifest, ExtensionLocalization)
    case invalid([ManifestIssue])

    public var issues: [ManifestIssue] { if case .invalid(let issues) = self { issues } else { [] } }
}

/// Checks an extension folder against manifest v1. The raw JSON tree is checked first so every
/// problem is reported with its path; only a clean tree is decoded.
public enum ManifestValidator {
    /// Lowercase reverse-domain ("dev.yourname.tool"). Ids name folders, so this is also what
    /// keeps an id from ever meaning ".." or ".".
    public static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil
    }

    public static let supportedAPIVersions = 1...1

    /// Warnings about a manifest that loads: things that work but not as written. Empty when the manifest is not valid
    /// (its errors come first).
    public static func warnings(folder: URL) -> [ManifestIssue] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let tree = try? JSONDecoder().decode(JSONValue.self, from: data), let root = tree.objectValue else { return [] }
        var checker = Checker(root: root, folder: folder, localization: (try? ExtensionLocalization(folder: folder, defaultLocale: root["defaultLocale"]?.stringValue ?? "en"))
            ?? ExtensionLocalization(tables: [:], defaultLocale: "en"))
        checker.run()
        return checker.issues.contains { $0.severity == .error } ? [] : checker.issues
    }

    public static func validate(folder: URL) -> ManifestValidation {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return .invalid([ManifestIssue("manifest.json", "manifest.json is missing", fix: "Add manifest.json at the extension folder's root.", code: "manifestMissing")])
        }
        guard let tree = try? JSONDecoder().decode(JSONValue.self, from: data), let root = tree.objectValue else {
            return .invalid([ManifestIssue("manifest.json", "manifest.json is not a JSON object", fix: "Make manifest.json a valid JSON object.", code: "manifestNotObject")])
        }
        let defaultLocale = root["defaultLocale"]?.stringValue ?? "en"
        let localization = (try? ExtensionLocalization(folder: folder, defaultLocale: defaultLocale))
            ?? ExtensionLocalization(tables: [:], defaultLocale: defaultLocale)
        var checker = Checker(root: root, folder: folder, localization: localization)
        checker.run()
        guard !checker.issues.contains(where: { $0.severity == .error }) else { return .invalid(checker.issues) }
        do {
            return .valid(try JSONDecoder().decode(ExtensionManifest.self, from: data), localization)
        } catch {
            return .invalid([ManifestIssue("manifest.json", "manifest.json could not be read: \(error)", fix: "Compare it with schema/manifest.schema.json.", code: "manifestUnreadable")])
        }
    }

    private struct Checker {
        let root: [String: JSONValue]
        let folder: URL
        let localization: ExtensionLocalization
        var issues: [ManifestIssue] = []

        mutating func run() {
            let id = string("id", in: root, path: "id", fix: "Add an \"id\" such as \"dev.yourname.tool\".")
            if let id {
                if !ManifestValidator.isValidID(id) {
                    issue("id", "\"\(id)\" is not a reverse-domain id", expected: "lowercase reverse-domain, e.g. dev.yourname.tool",
                          fix: "Use lowercase letters, digits and dashes separated by dots, e.g. \"dev.yourname.tool\".", code: "invalidID")
                } else if id != folder.lastPathComponent {
                    issue("id", "the id \"\(id)\" does not match the folder name \"\(folder.lastPathComponent)\"",
                          fix: "Rename the folder to \"\(id)\" or change the id to match it.", code: "idFolderMismatch")
                }
            }
            if let version = string("version", in: root, path: "version", fix: "Add \"version\": \"1.0.0\"."),
               version.range(of: #"^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$"#, options: .regularExpression) == nil {
                issue("version", "\"\(version)\" is not semantic versioning", expected: "MAJOR.MINOR.PATCH", fix: "Write the version as \"1.0.0\".", code: "invalidVersion")
            }
            switch root["apiVersion"]?.numberValue {
            case let value? where Int(exactly: value).map(ManifestValidator.supportedAPIVersions.contains) == true: break
            case let value?:
                issue("apiVersion", "API version \(value.formatted()) is not supported", expected: "\(ManifestValidator.supportedAPIVersions)",
                      fix: "Set \"apiVersion\": 1.", code: "unsupportedAPIVersion")
            case nil: issue("apiVersion", "\"apiVersion\" is missing", expected: "1", fix: "Add \"apiVersion\": 1.", code: "missingField")
            }
            if let locale = string("defaultLocale", in: root, path: "defaultLocale", fix: "Add \"defaultLocale\": \"en\"."),
               !FileManager.default.fileExists(atPath: folder.appendingPathComponent("locales/\(locale).json").path) {
                issue("defaultLocale", "there is no locales/\(locale).json for the default locale",
                      fix: "Add locales/\(locale).json or set \"defaultLocale\" to a language you ship.", code: "defaultLocaleMissing")
            }
            localeKey("name", in: root, path: "name")
            localeKey("description", in: root, path: "description")
            _ = string("icon", in: root, path: "icon", fix: "Add \"icon\": \"sf:<SF Symbol name>\" or \"icon.png\".")
            _ = string("author", in: root, path: "author", fix: "Add \"author\" with your GitHub user name.")
            _ = string("license", in: root, path: "license", fix: "Add \"license\", e.g. \"MIT\".")
            for (index, category) in (root["categories"]?.arrayValue ?? []).enumerated()
            where !ExtensionCategory.allCases.map(\.rawValue).contains(category.stringValue ?? "") {
                issue("categories[\(index)]", "\(category.stringValue.map { "\"\($0)\"" } ?? "this") is not a category",
                      expected: ExtensionCategory.allCases.map(\.rawValue).joined(separator: ", "),
                      fix: "Use one of: \(ExtensionCategory.allCases.map(\.rawValue).joined(separator: ", ")).", code: "unknownCategory")
            }
            permissions()
            preferences()
            contributions()
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.js").path) {
                issue("index.js", "index.js is missing", fix: "Build the extension so index.js sits next to manifest.json.", code: "indexMissing")
            }
        }

        private static let grantable = ["network", "exec", "capture", "history"]

        private mutating func permissions() {
            var granted = Set<String>()
            for permission in root["permissions"]?.arrayValue ?? [] {
                let name = permission.stringValue ?? ""
                if Self.grantable.contains(name) { granted.insert(name) }
                else {
                    issue("permissions", "\(permission.stringValue.map { "\"\($0)\"" } ?? "this") is not a permission", expected: Self.grantable.joined(separator: ", "),
                          fix: "Use one of: \(Self.grantable.joined(separator: ", ")).", code: "unknownPermission")
                }
            }
            if !(root["contributes"]?["captureRules"]?.arrayValue ?? []).isEmpty, !granted.contains("capture") {
                issue("contributes.captureRules", "captureRules need the capture permission",
                      fix: "Add \"capture\" to \"permissions\" or remove \"captureRules\".", code: "captureRulesNeedCapture")
            }
            if let network = root["network"] {
                let domains = network["domains"]?.arrayValue ?? []
                if network.objectValue == nil || network["domains"]?.arrayValue == nil {
                    issue("network.domains", "\"network\" needs a list of domains", fix: "Write \"network\": {\"domains\": [\"example.com\"]}.", code: "networkNeedsDomains")
                }
                for (index, domain) in domains.enumerated() {
                    let host = #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$"#
                    if domain.stringValue?.range(of: host, options: .regularExpression) == nil {
                        issue("network.domains[\(index)]", "\(domain.stringValue.map { "\"\($0)\"" } ?? "this") is not a plain lowercase host name",
                              expected: "a lowercase host name such as video.example",
                              fix: "Write only the host: no https://, no path and no \"*\".", code: "invalidDomain")
                    }
                }
            }
            let tools = root["requires"]?["tools"]?.arrayValue ?? []
            if granted.contains("exec"), tools.isEmpty {
                issue("requires.tools", "\"exec\" needs the tools the extension runs", fix: "Add \"requires\": {\"tools\": [{\"name\": \"yt-dlp\", \"install\": \"brew install yt-dlp\"}]}.", code: "execNeedsTools")
            } else if !granted.contains("exec"), !tools.isEmpty {
                issue("requires.tools", "tools are listed but \"exec\" is not a permission", fix: "Add \"exec\" to \"permissions\" or remove \"requires\".", code: "toolsNeedExec")
            }
            for (index, tool) in tools.enumerated() {
                let path = "requires.tools[\(index)]"
                guard let object = tool.objectValue else { issue(path, "a tool must be an object", fix: "Write it as {\"name\", \"install\"}.", code: "notAnObject"); continue }
                if let name = string("name", in: object, path: "\(path).name", fix: "Give the tool a \"name\" such as \"yt-dlp\"."),
                   name.range(of: #"^[A-Za-z0-9._+-]+$"#, options: .regularExpression) == nil {
                    issue("\(path).name", "\"\(name)\" is not a usable tool name", expected: "letters, digits, \".\", \"_\", \"+\" and \"-\"",
                          fix: "Use the bare command name, not a path.", code: "invalidToolName")
                }
                _ = string("install", in: object, path: "\(path).install", fix: "Add \"install\" with the command that installs it, e.g. \"brew install yt-dlp\".")
            }
        }

        private mutating func preferences() {
            var ids = Set<String>()
            for (index, preference) in (root["preferences"]?.arrayValue ?? []).enumerated() {
                let path = "preferences[\(index)]"
                guard let object = preference.objectValue else { issue(path, "a preference must be an object", fix: "Write it as {\"id\", \"type\", \"title\", \"default\"}.", code: "notAnObject"); continue }
                memberID(in: object, path: "\(path).id", what: "preference", seen: &ids)
                if let type = string("type", in: object, path: "\(path).type", fix: "Add \"type\": \"toggle\", \"text\", \"choice\", \"secret\" or \"folder\"."),
                   PreferenceSpec.Kind(rawValue: type) == nil {
                    issue("\(path).type", "\"\(type)\" is not a preference type", expected: PreferenceSpec.Kind.allCases.map(\.rawValue).joined(separator: ", "),
                          fix: "Use \"text\", \"toggle\", \"choice\", \"secret\" or \"folder\".", code: "unknownPreferenceType")
                }
                localeKey("title", in: object, path: "\(path).title")
                let defaultValue = object["default"].flatMap { $0 == .null ? nil : $0 }
                if object["type"]?.stringValue == "secret", defaultValue != nil {
                    issue("\(path).default", "a secret cannot have a default", fix: "Remove \"default\"; the person types the secret in Settings.", code: "secretDefault")
                }
                if object["type"]?.stringValue == "folder", let defaultValue,
                   defaultValue.stringValue?.hasPrefix("~") != true {
                    issue("\(path).default", "a folder default must start with \"~\"", expected: "a path such as ~/Downloads",
                          fix: "Write the default as \"~/Downloads\" or remove it; the person chooses the folder in Settings.", code: "folderDefault")
                }
                if object["confirm"] != nil { localeKey("confirm", in: object, path: "\(path).confirm") }
                if object["type"]?.stringValue == "choice", (object["options"]?.arrayValue ?? []).isEmpty {
                    issue("\(path).options", "a choice needs options", fix: "Add \"options\": [{\"id\", \"title\"}].", code: "choiceNeedsOptions")
                }
            }
        }

        private mutating func contributions() {
            let contributes = root["contributes"]?.objectValue ?? [:]
            var actionIDs = Set<String>()
            for (index, action) in (contributes["actions"]?.arrayValue ?? []).enumerated() {
                let path = "contributes.actions[\(index)]"
                guard let object = action.objectValue else { issue(path, "an action must be an object", fix: "Write it as {\"id\", \"title\", …}.", code: "notAnObject"); continue }
                memberID(in: object, path: "\(path).id", what: "action", seen: &actionIDs)
                localeKey("title", in: object, path: "\(path).title")
                if object["subtitle"] != nil { localeKey("subtitle", in: object, path: "\(path).subtitle") }
                localeKey("keywords", in: object, path: "\(path).keywords", wantsList: true)
                let input = string("input", in: object, path: "\(path).input", fix: "Add \"input\": \"item\" or \"none\".")
                if let input, ActionInput(rawValue: input) == nil {
                    issue("\(path).input", "\"\(input)\" is not an input", expected: "item, none", fix: "Use \"item\" or \"none\".", code: "unknownInput")
                }
                if let output = string("output", in: object, path: "\(path).output", fix: "Add \"output\", e.g. \"text\"."),
                   ActionOutput(rawValue: output) == nil {
                    issue("\(path).output", "\"\(output)\" is not an output", expected: ActionOutput.allCases.map(\.rawValue).joined(separator: ", "),
                          fix: "Use one of: \(ActionOutput.allCases.map(\.rawValue).joined(separator: ", ")).", code: "unknownOutput")
                }
                if object["verb"] != nil { localeKey("verb", in: object, path: "\(path).verb") }
                if object["failTitle"] != nil { localeKey("failTitle", in: object, path: "\(path).failTitle") }
                let targetNames = TargetClass.allCases.map(\.rawValue).joined(separator: ", ")
                let targets = object["targets"]?.arrayValue ?? []
                for (targetIndex, target) in targets.enumerated() where TargetClass(rawValue: target.stringValue ?? "") == nil {
                    issue("\(path).targets[\(targetIndex)]", "\(target.stringValue.map { "\"\($0)\"" } ?? "this") is not a target",
                          expected: targetNames, fix: "Use one of: \(targetNames).", code: "unknownTarget")
                }
                if object["targetsOnly"]?.boolValue == true, targets.isEmpty {
                    issue("\(path).targetsOnly", "\"targetsOnly\" needs at least one entry in \"targets\"", fix: "Add \"targets\": [\"finder\"] or remove \"targetsOnly\".", code: "targetsOnlyNeedsTargets")
                }
                if input == "item" {
                    if let accepts = object["accepts"] { acceptSpec(accepts, path: "\(path).accepts") }
                    else { issue("\(path).accepts", "an action that takes an item needs \"accepts\"", fix: "Add \"accepts\": {\"kinds\": [\"text\"]}.", code: "acceptsMissing") }
                }
                var variantIDs = Set<String>()
                for (variantIndex, variant) in (object["variants"]?.arrayValue ?? []).enumerated() {
                    let variantPath = "\(path).variants[\(variantIndex)]"
                    guard let variantObject = variant.objectValue else { issue(variantPath, "a variant must be an object", fix: "Write it as {\"id\", \"title\"}.", code: "notAnObject"); continue }
                    memberID(in: variantObject, path: "\(variantPath).id", what: "variant", seen: &variantIDs)
                    localeKey("title", in: variantObject, path: "\(variantPath).title")
                    if variantObject["failTitle"] != nil { localeKey("failTitle", in: variantObject, path: "\(variantPath).failTitle") }
                }
            }
            var ruleIDs = Set<String>()
            for (index, rule) in (contributes["captureRules"]?.arrayValue ?? []).enumerated() {
                let path = "contributes.captureRules[\(index)]"
                guard let object = rule.objectValue else { issue(path, "a capture rule must be an object", fix: "Write it as {\"id\", \"title\", \"accepts\"}.", code: "notAnObject"); continue }
                memberID(in: object, path: "\(path).id", what: "capture rule", seen: &ruleIDs)
                localeKey("title", in: object, path: "\(path).title")
                if object["description"] != nil { localeKey("description", in: object, path: "\(path).description") }
                if let accepts = object["accepts"] {
                    acceptSpec(accepts, path: "\(path).accepts")
                    // Rules run before tags exist, so a tag filter would never match.
                    if !(accepts["tags"]?.arrayValue ?? []).isEmpty {
                        issues.append(ManifestIssue("\(path).accepts.tags", "capture rules never see tags; this rule would never run",
                                                    fix: "Remove \"tags\" from \"accepts\"; filter on \"kinds\" or \"pattern\" instead.",
                                                    severity: .warning, code: "captureRuleTags"))
                    }
                }
                else { issue("\(path).accepts", "a capture rule needs \"accepts\"", fix: "Add \"accepts\": {\"kinds\": [\"link\"]}.", code: "acceptsMissing") }
            }
            var detectorIDs = Set<String>()
            for (index, detector) in (contributes["detectors"]?.arrayValue ?? []).enumerated() {
                let path = "contributes.detectors[\(index)]"
                guard let object = detector.objectValue else { issue(path, "a detector must be an object", fix: "Write it as {\"id\", \"tag\", \"accepts\"}.", code: "notAnObject"); continue }
                memberID(in: object, path: "\(path).id", what: "detector", seen: &detectorIDs)
                localeKey("tag", in: object, path: "\(path).tag")
                if let accepts = object["accepts"] { acceptSpec(accepts, path: "\(path).accepts") }
                else { issue("\(path).accepts", "a detector needs \"accepts\"", fix: "Add \"accepts\": {\"kinds\": [\"text\"]}.", code: "acceptsMissing") }
            }
        }

        private mutating func acceptSpec(_ value: JSONValue, path: String) {
            guard let object = value.objectValue else { issue(path, "\"accepts\" must be an object", fix: "Write it as {\"kinds\": [\"text\"]}.", code: "notAnObject"); return }
            let kinds = object["kinds"]?.arrayValue ?? []
            if kinds.isEmpty { issue("\(path).kinds", "\"kinds\" is empty", expected: AcceptSpec.kindNames.joined(separator: ", "), fix: "List at least one kind, e.g. [\"text\"].", code: "kindsEmpty") }
            for (index, kind) in kinds.enumerated() where !AcceptSpec.kindNames.contains(kind.stringValue ?? "") {
                issue("\(path).kinds[\(index)]", "\(kind.stringValue.map { "\"\($0)\"" } ?? "this") is not a kind",
                      expected: AcceptSpec.kindNames.joined(separator: ", "), fix: "Use one of: \(AcceptSpec.kindNames.joined(separator: ", ")).", code: "unknownKind")
            }
            if let pattern = object["pattern"]?.stringValue, (try? NSRegularExpression(pattern: pattern)) == nil {
                issue("\(path).pattern", "\"\(pattern)\" is not a valid regular expression", fix: "Fix the pattern so it compiles as an ICU regular expression.", code: "invalidPattern")
            }
        }

        /// An action, variant, preference or detector id: present, once in its list, and made of
        /// letters, digits, ".", "_" and "-" (ids are joined with "/", "#" and ":" elsewhere).
        private mutating func memberID(in object: [String: JSONValue], path: String, what: String, seen: inout Set<String>) {
            guard let id = string("id", in: object, path: path, fix: "Give the \(what) an \"id\".") else { return }
            if id.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) == nil {
                issue(path, "\"\(id)\" is not a usable \(what) id", expected: "letters, digits, \".\", \"_\" and \"-\"",
                      fix: "Use only letters, digits, dots, underscores and dashes.", code: "invalidMemberID")
            } else if !seen.insert(id).inserted {
                issue(path, "the \(what) id \"\(id)\" is used twice", fix: "Give every \(what) its own id.", code: "duplicateID")
            }
        }

        private mutating func string(_ key: String, in object: [String: JSONValue], path: String, fix: String) -> String? {
            guard let value = object[key] else { issue(path, "\"\(key)\" is missing", fix: fix, code: "missingField"); return nil }
            guard let text = value.stringValue, !text.isEmpty else { issue(path, "\"\(key)\" must be a non-empty string", fix: fix, code: "notAString"); return nil }
            return text
        }

        private mutating func localeKey(_ key: String, in object: [String: JSONValue], path: String, wantsList: Bool = false) {
            let locale = localization.defaultLocale
            guard let name = string(key, in: object, path: path, fix: "Add \"\(key)\" with a key from locales/\(locale).json.") else { return }
            guard localization.hasKey(name, in: locale) else {
                issue(path, "the key \"\(name)\" is not in locales/\(locale).json",
                      fix: "Add \"\(name)\" to locales/\(locale).json" + (wantsList ? " as an array of keywords." : "."), code: "unknownLocaleKey")
                return
            }
        }

        private mutating func issue(_ path: String, _ message: String, expected: String? = nil, fix: String, code: String) {
            issues.append(ManifestIssue(path, message, expected: expected, fix: fix, code: code))
        }
    }
}

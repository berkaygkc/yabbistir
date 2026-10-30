import Foundation

/// manifest.json, API version 1. Human text fields hold locale keys.
public struct ExtensionManifest: Codable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var apiVersion: Int
    public var minAppVersion: String?
    public var defaultLocale: String
    public var name: String
    public var description: String
    /// "sf:<SF Symbol name>" or a file name in the extension folder ("icon.png").
    public var icon: String
    public var author: String
    public var license: String
    public var categories: [ExtensionCategory]
    public var permissions: [String]
    /// Hosts the extension may reach; needed (and only meaningful) with the "network" permission.
    public var network: NetworkSpec?
    /// Command-line tools the extension runs; required with the "exec" permission.
    public var requires: RequiresSpec?
    public var preferences: [PreferenceSpec]
    public var contributes: Contributions

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        version = try c.decode(String.self, forKey: .version)
        apiVersion = try c.decode(Int.self, forKey: .apiVersion)
        minAppVersion = try c.decodeIfPresent(String.self, forKey: .minAppVersion)
        defaultLocale = try c.decode(String.self, forKey: .defaultLocale)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        icon = try c.decode(String.self, forKey: .icon)
        author = try c.decode(String.self, forKey: .author)
        license = try c.decode(String.self, forKey: .license)
        categories = try c.decodeIfPresent([ExtensionCategory].self, forKey: .categories) ?? []
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        network = try c.decodeIfPresent(NetworkSpec.self, forKey: .network)
        requires = try c.decodeIfPresent(RequiresSpec.self, forKey: .requires)
        preferences = try c.decodeIfPresent([PreferenceSpec].self, forKey: .preferences) ?? []
        contributes = try c.decodeIfPresent(Contributions.self, forKey: .contributes) ?? Contributions()
    }
}

public struct NetworkSpec: Codable, Equatable, Sendable {
    /// Lowercase host names: no scheme, no path, no "*".
    public var domains: [String]

    public init(domains: [String]) { self.domains = domains }
}

public struct RequiresSpec: Codable, Equatable, Sendable {
    public var tools: [ToolSpec]

    public init(tools: [ToolSpec]) { self.tools = tools }
}

public struct ToolSpec: Codable, Equatable, Sendable {
    public var name: String
    /// How to get the tool, shown to the person when it is missing ("brew install yt-dlp").
    public var install: String

    public init(name: String, install: String) { (self.name, self.install) = (name, install) }
}

public enum ExtensionCategory: String, Codable, Sendable, CaseIterable {
    case text, links, images, files, developer, media, ai, productivity
}

public struct Contributions: Codable, Equatable, Sendable {
    public var actions: [ActionSpec]
    public var detectors: [DetectorSpec]
    /// Rules that run on every new copy before it reaches history; need the "capture" permission.
    public var captureRules: [CaptureRuleSpec]

    public init(actions: [ActionSpec] = [], detectors: [DetectorSpec] = [], captureRules: [CaptureRuleSpec] = []) {
        self.actions = actions
        self.detectors = detectors
        self.captureRules = captureRules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        actions = try c.decodeIfPresent([ActionSpec].self, forKey: .actions) ?? []
        detectors = try c.decodeIfPresent([DetectorSpec].self, forKey: .detectors) ?? []
        captureRules = try c.decodeIfPresent([CaptureRuleSpec].self, forKey: .captureRules) ?? []
    }
}

public struct CaptureRuleSpec: Codable, Equatable, Sendable {
    public var id: String
    /// Locale key of the rule's name in Settings.
    public var title: String
    /// Locale key of a one-line explanation.
    public var description: String?
    public var accepts: AcceptSpec

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        accepts = try c.decode(AcceptSpec.self, forKey: .accepts)
    }
}

public enum ActionInput: String, Codable, Sendable { case none, item }

public enum ActionOutput: String, Codable, Sendable, CaseIterable { case text, html, image, link, file, files, none }

public struct ActionSpec: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    /// Locale key whose value is an array of keywords.
    public var keywords: String
    public var input: ActionInput
    public var accepts: AcceptSpec?
    public var output: ActionOutput
    public var variants: [VariantSpec]
    public var hint: Bool
    public var priority: Int
    /// Apps this action is offered for first; empty means every app.
    public var targets: [TargetClass]
    /// Offered only when the paste target is one of `targets`.
    public var targetsOnly: Bool
    /// Runs as a long-running job instead of a quick call.
    public var job: Bool
    /// Locale key of a job's ↵ label in the ⇧ panel ("İndir"): "↵ <verb> · ⌘C <verb> ve kopyala".
    /// Without it a job says "Başlat".
    public var verb: String?
    /// Locale key of a failed job's title ("Video indirilemedi"); a variant's own wins.
    public var failTitle: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        keywords = try c.decode(String.self, forKey: .keywords)
        input = try c.decode(ActionInput.self, forKey: .input)
        accepts = try c.decodeIfPresent(AcceptSpec.self, forKey: .accepts)
        output = try c.decode(ActionOutput.self, forKey: .output)
        variants = try c.decodeIfPresent([VariantSpec].self, forKey: .variants) ?? []
        hint = try c.decodeIfPresent(Bool.self, forKey: .hint) ?? false
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        targets = try c.decodeIfPresent([TargetClass].self, forKey: .targets) ?? []
        targetsOnly = try c.decodeIfPresent(Bool.self, forKey: .targetsOnly) ?? false
        job = try c.decodeIfPresent(Bool.self, forKey: .job) ?? false
        verb = try c.decodeIfPresent(String.self, forKey: .verb)
        failTitle = try c.decodeIfPresent(String.self, forKey: .failTitle)
    }
}

public struct VariantSpec: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    /// Locale key of the variant's own failure title, in place of its action's.
    public var failTitle: String?
}

/// Which items an action or detector applies to; decided from the manifest alone (no JavaScript).
public struct AcceptSpec: Codable, Equatable, Sendable {
    public static let kindNames = ["text", "code", "link", "color", "image", "file"]

    public var kinds: [String]
    public var pattern: String?
    /// "tag" (the extension's own detector) or "extension.id:tag".
    public var tags: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kinds = try c.decode([String].self, forKey: .kinds)
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

public struct DetectorSpec: Codable, Equatable, Sendable {
    public var id: String
    /// Locale key of the short tag shown on rows.
    public var tag: String
    public var accepts: AcceptSpec
    public var validate: Bool
    public var preview: Bool
    public var suggests: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        tag = try c.decode(String.self, forKey: .tag)
        accepts = try c.decode(AcceptSpec.self, forKey: .accepts)
        validate = try c.decodeIfPresent(Bool.self, forKey: .validate) ?? false
        preview = try c.decodeIfPresent(Bool.self, forKey: .preview) ?? false
        suggests = try c.decodeIfPresent([String].self, forKey: .suggests) ?? []
    }
}

public struct PreferenceSpec: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case text, toggle, choice
        /// Kept only in the Keychain; never in preferences. Has no default.
        case secret
        /// An absolute folder path chosen by the person; a default may start with "~".
        case folder
    }

    public var id: String
    public var type: Kind
    public var title: String
    public var `default`: JSONValue
    public var options: [ChoiceOption]
    /// Locale key of a confirmation question asked before the preference is turned on.
    public var confirm: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(Kind.self, forKey: .type)
        title = try c.decode(String.self, forKey: .title)
        `default` = try c.decodeIfPresent(JSONValue.self, forKey: .default) ?? .null
        options = try c.decodeIfPresent([ChoiceOption].self, forKey: .options) ?? []
        confirm = try c.decodeIfPresent(String.self, forKey: .confirm)
    }
}

public struct ChoiceOption: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
}

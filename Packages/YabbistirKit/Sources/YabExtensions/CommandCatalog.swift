import Foundation
import YabCore
import YabExtensionKit

/// One thing an extension offers in the panel: an action, or one variant of it.
public struct ExtensionCommand: Identifiable, Hashable, Sendable {
    /// "extension.id/action" or "extension.id/action#variant".
    public let id: String
    public let extensionID: String
    public let extensionName: String
    public let icon: String
    public let title: String
    public let subtitle: String?
    public let keywords: [String]
    public let input: ActionInput
    public let output: ActionOutput
    public let hint: Bool
    public let priority: Int
    public let actionID: String
    public let variant: String?
    public let source: ExtensionSource
    /// Tags qualified with their extension ("extension.id:tag").
    public let accepts: AcceptSpec?
    /// Paste targets the command is made for: it leads the list there.
    public let targets: [TargetClass]
    /// Offered only when the paste target is one of `targets`.
    public let targetsOnly: Bool
    /// Runs as a long-running job, never ahead of use.
    public let isJob: Bool
    /// What ↵ does on a job's row ("İndir"), in the catalog's language.
    public let verb: String?
    /// A failed job's title ("Video indirilemedi"), in the catalog's language; nil keeps `title`.
    public let failTitle: String?

    public init(id: String, extensionID: String, extensionName: String, icon: String, title: String, subtitle: String?, keywords: [String],
                input: ActionInput, output: ActionOutput, hint: Bool, priority: Int, actionID: String, variant: String?,
                source: ExtensionSource, accepts: AcceptSpec?, targets: [TargetClass] = [], targetsOnly: Bool = false, isJob: Bool = false,
                verb: String? = nil, failTitle: String? = nil) {
        (self.id, self.extensionID, self.extensionName, self.icon, self.title, self.subtitle) = (id, extensionID, extensionName, icon, title, subtitle)
        (self.keywords, self.input, self.output, self.hint, self.priority) = (keywords, input, output, hint, priority)
        (self.actionID, self.variant, self.source, self.accepts) = (actionID, variant, source, accepts)
        (self.targets, self.targetsOnly, self.isJob, self.verb, self.failTitle) = (targets, targetsOnly, isJob, verb, failTitle)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle && lhs.extensionName == rhs.extensionName
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Whether the command needs the item's pixels (only image actions pay for decoding them).
    public var needsImage: Bool { accepts?.kinds.contains("image") == true }

    /// Whether the command is made for the app its result is pasted into.
    public func isFor(_ target: TargetInfo?) -> Bool {
        target.map { targets.contains($0.kind) } ?? false
    }
}

/// The commands of the usable extensions in one language, matched from manifests alone: no
/// JavaScript runs to decide what appears.
public struct CommandCatalog: Sendable {
    public let commands: [ExtensionCommand]
    private let folded: [String: [String]]
    private let patterns: PatternCache

    public init(installed: [InstalledExtension], language: String) {
        var commands: [ExtensionCommand] = []
        for entry in installed where entry.isUsable {
            guard let manifest = entry.manifest, let localization = entry.localization else { continue }
            let name = localization.string(manifest.name, language: language)
            for action in manifest.contributes.actions {
                let keywords = localization.keywords(action.keywords, language: language)
                let accepts = action.accepts.map { Self.qualified($0, extensionID: manifest.id) }
                let subtitle = action.subtitle.map { localization.string($0, language: language) }
                let verb = action.verb.map { localization.string($0, language: language) }
                let failTitle = action.failTitle.map { localization.string($0, language: language) }
                let variants: [(id: String?, title: String, subtitle: String?, failTitle: String?)] = action.variants.isEmpty
                    ? [(nil, localization.string(action.title, language: language), subtitle, failTitle)]
                    : action.variants.map { ($0.id, localization.string($0.title, language: language),
                                             $0.subtitle.map { localization.string($0, language: language) } ?? subtitle,
                                             $0.failTitle.map { localization.string($0, language: language) } ?? failTitle) }
                for variant in variants {
                    commands.append(ExtensionCommand(
                        id: "\(manifest.id)/\(action.id)" + (variant.id.map { "#\($0)" } ?? ""), extensionID: manifest.id, extensionName: name,
                        icon: Self.icon(manifest.icon, in: entry.folder), title: variant.title, subtitle: variant.subtitle, keywords: keywords, input: action.input,
                        output: action.output, hint: action.hint, priority: action.priority, actionID: action.id, variant: variant.id,
                        source: entry.source, accepts: accepts, targets: action.targets, targetsOnly: action.targetsOnly, isJob: action.job,
                        verb: verb, failTitle: variant.failTitle))
                }
            }
        }
        self.commands = commands
        folded = Dictionary(commands.map { ($0.id, $0.keywords.map(SearchNormalizer.normalize)) }) { first, _ in first }
        patterns = PatternCache()
    }

    /// "sf:<symbol>" as it is; a file name becomes its path, so the panel can draw it.
    static func icon(_ icon: String, in folder: URL) -> String {
        icon.hasPrefix("sf:") ? icon : folder.appendingPathComponent(icon).path
    }

    /// Search: two or more letters; a keyword that starts with the query, or a query that starts
    /// with a keyword ("uuid v7"). Generators always qualify; transforms need an accepted subject.
    /// The paste target's own commands lead.
    public func commands(matching query: String, subject: ExtensionItem?, target: TargetInfo? = nil) -> [ExtensionCommand] {
        let needle = SearchNormalizer.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard needle.count >= 2 else { return [] }
        return Self.leading(target, in: commands
            .filter { command in (folded[command.id] ?? []).contains { $0.hasPrefix(needle) || needle.hasPrefix($0) } }
            .filter { command in command.input == .none || subject.map { accepts(command.accepts, $0) } == true }
            .sorted { ($0.priority, $1.title) > ($1.priority, $0.title) })
    }

    /// Everything that applies to an item, an extension's commands together: the extension with
    /// the highest priority first, then by priority inside it, in manifest order otherwise. The
    /// paste target's own commands lead, in that same order.
    public func transforms(for item: ExtensionItem, target: TargetInfo? = nil) -> [ExtensionCommand] {
        Self.leading(target, in: ranked(for: item))
    }

    /// The target's commands first, each side in the order it had; a `targetsOnly` command
    /// anywhere else is left out.
    static func leading(_ target: TargetInfo?, in commands: [ExtensionCommand]) -> [ExtensionCommand] {
        let offered = commands.filter { !$0.targetsOnly || $0.isFor(target) }
        return offered.filter { $0.isFor(target) } + offered.filter { !$0.isFor(target) }
    }

    private func ranked(for item: ExtensionItem) -> [ExtensionCommand] {
        let matching = commands.enumerated().filter { $0.element.input == .item && accepts($0.element.accepts, item) }
        var best: [String: Int] = [:]
        for (_, command) in matching { best[command.extensionID] = max(best[command.extensionID] ?? .min, command.priority) }
        let firstSeen = Dictionary(matching.map { ($0.element.extensionID, $0.offset) }, uniquingKeysWith: min)
        return matching.sorted { lhs, rhs in
            let (a, b) = (lhs.element, rhs.element)
            if a.extensionID != b.extensionID {
                let (bestA, bestB) = (best[a.extensionID] ?? 0, best[b.extensionID] ?? 0)
                return bestA != bestB ? bestA > bestB : firstSeen[a.extensionID]! < firstSeen[b.extensionID]!
            }
            return a.priority != b.priority ? a.priority > b.priority : lhs.offset < rhs.offset
        }.map(\.element)
    }

    public func accepts(_ spec: AcceptSpec?, _ item: ExtensionItem) -> Bool {
        guard let spec else { return false }
        guard spec.kinds.contains(item.kind) || (spec.kinds.contains("image") && item.isImageFile) else { return false }
        if !spec.tags.isEmpty, !spec.tags.contains(where: item.tags.contains) { return false }
        if let pattern = spec.pattern {
            let text = String((item.text ?? item.url ?? "").prefix(1_000_000)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let regex = patterns.regex(pattern),
                  regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return false }
        }
        return true
    }

    /// Its tags as `accepts` matches them: an extension's own detector tag ("tag") gets its id ("extension.id:tag").
    static func qualified(_ spec: AcceptSpec, extensionID: String) -> AcceptSpec {
        var spec = spec
        spec.tags = spec.tags.map { $0.contains(":") ? $0 : "\(extensionID):\($0)" }
        return spec
    }
}

/// Compiled patterns, shared by copies of a catalog.
final class PatternCache: @unchecked Sendable {
    private let lock = NSLock()
    private var compiled: [String: NSRegularExpression] = [:]

    func regex(_ pattern: String) -> NSRegularExpression? {
        lock.withLock {
            if let regex = compiled[pattern] { return regex }
            let regex = try? NSRegularExpression(pattern: pattern)
            compiled[pattern] = regex
            return regex
        }
    }
}

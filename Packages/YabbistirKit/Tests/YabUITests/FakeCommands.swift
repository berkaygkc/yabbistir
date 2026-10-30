import Foundation
import YabCore
import YabExtensionKit
import YabExtensions

/// A scripted extension service for panel tests.
@MainActor
final class FakeCommands: ExtensionCommandsProviding {
    var generators: [ExtensionCommand] = []
    var transformsByItem: [Int64: [ExtensionCommand]] = [:]
    var sections: [PreviewSection] = []
    var labels: [StoredTag: String] = [:]
    var outputs: [String: ExtensionResult] = [:]
    /// Row hints by command id; "hint:<action>" otherwise.
    var hints: [String: String] = [:]
    private(set) var queries: [(query: String, subjectID: Int64?)] = []
    private(set) var hintRequests = 0
    private(set) var outputCalls = 0
    var onHintsChanged: (() -> Void)?
    var target: TargetInfo?

    static func command(_ id: String, title: String, keywords: [String], input: ActionInput = .item,
                        extensionName: String = "Base64", priority: Int = 0, hint: Bool = true, icon: String = "sf:number",
                        subtitle: String? = nil, output: ActionOutput = .text, targets: [TargetClass] = [], isJob: Bool = false,
                        verb: String? = nil, failTitle: String? = nil) -> ExtensionCommand {
        let parts = id.split(separator: "/").map(String.init)
        return ExtensionCommand(id: id, extensionID: parts[0], extensionName: extensionName, icon: icon, title: title, subtitle: subtitle,
                                keywords: keywords, input: input, output: output, hint: hint, priority: priority,
                                actionID: parts.count > 1 ? parts[1] : id, variant: nil, source: .builtIn, accepts: nil,
                                targets: targets, isJob: isJob, verb: verb, failTitle: failTitle)
    }

    func commands(matching query: String, subjectID: Int64?) -> [ExtensionCommand] {
        queries.append((query, subjectID))
        let needle = SearchNormalizer.normalize(query.trimmingCharacters(in: .whitespaces))
        guard needle.count >= 2 else { return [] }
        let candidates = generators + (subjectID.flatMap { transformsByItem[$0] } ?? [])
        return candidates.filter { $0.keywords.contains { SearchNormalizer.normalize($0).hasPrefix(needle) } }
    }

    func transforms(forItemID itemID: Int64) -> [ExtensionCommand] { transformsByItem[itemID] ?? [] }
    func hint(for command: ExtensionCommand, subjectID: Int64?) -> String? { hints[command.id] ?? "hint:\(command.actionID)" }
    func requestHints(for commands: [ExtensionCommand], subjectID: Int64?) { hintRequests += 1 }
    func runsAhead(_ command: ExtensionCommand, subjectID: Int64?) -> Bool { command.hint }
    func cachedOutput(of command: ExtensionCommand, subjectID: Int64?) -> ExtensionResult? { outputs[command.id] }
    func output(of command: ExtensionCommand, subjectID: Int64?) async throws(ExtensionError) -> ExtensionResult {
        outputCalls += 1
        return outputs[command.id] ?? .text("out")
    }
    func resetSession() {}
    func previewSections(itemID: Int64) async -> [PreviewSection] { sections }
    func tagLabels(_ tags: [StoredTag]) -> [String] { tags.compactMap { labels[$0] } }
}

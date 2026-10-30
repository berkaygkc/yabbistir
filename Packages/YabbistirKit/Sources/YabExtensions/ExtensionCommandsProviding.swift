import YabCore
import YabExtensionKit

/// What the panel asks of extensions. `ExtensionService` is the real one; panel tests use a fake.
@MainActor
public protocol ExtensionCommandsProviding: AnyObject {
    func commands(matching query: String, subjectID: Int64?) -> [ExtensionCommand]
    func transforms(forItemID itemID: Int64) -> [ExtensionCommand]
    /// One line for the row: the cached output (`hint: true`) or the subtitle; nil while pending.
    func hint(for command: ExtensionCommand, subjectID: Int64?) -> String?
    /// Runs `hint: true` commands early (500 ms each); `onHintsChanged` fires as answers arrive.
    func requestHints(for commands: [ExtensionCommand], subjectID: Int64?)
    /// Whether the command runs ahead of use (a hint) for this subject; otherwise it runs only
    /// when pasted or copied. Jobs and file results never do.
    func runsAhead(_ command: ExtensionCommand, subjectID: Int64?) -> Bool
    func cachedOutput(of command: ExtensionCommand, subjectID: Int64?) -> ExtensionResult?
    /// The cached output if there is one (a generator's is then spent), else a fresh run.
    func output(of command: ExtensionCommand, subjectID: Int64?) async throws(ExtensionError) -> ExtensionResult
    /// The panel closed: cached outputs are forgotten.
    func resetSession()
    /// Blocks the item's detectors add to its preview.
    func previewSections(itemID: Int64) async -> [PreviewSection]
    /// The tags' short texts, in the app's language (tags of removed extensions are left out).
    func tagLabels(_ tags: [StoredTag]) -> [String]
    var onHintsChanged: (() -> Void)? { get set }
    /// The app the panel's results go to; set when the panel opens. Its own commands lead, and
    /// every call learns it as `context.target`.
    var target: TargetInfo? { get set }
}

import Foundation
import YabExtensions

/// Extension commands in search: two or more letters list matching commands
/// above History, each with a one-line hint; ↵ runs the selected one on the subject.
extension PanelViewModel {
    /// The command under the focused selection; nil on item rows.
    public var selectedCommand: ExtensionCommand? {
        guard focusedSource == .history, let id = selectedID, id <= RowModel.commandIDBase else { return nil }
        let index = Int(RowModel.commandIDBase - id)
        return visibleCommands.indices.contains(index) ? visibleCommands[index] : nil
    }

    /// The commands for the query, remembered in row order, as rows.
    func matchCommands() -> [CommandRowInfo] {
        guard let extensions, query.trimmingCharacters(in: .whitespaces).count >= 2 else {
            visibleCommands = []
            return []
        }
        visibleCommands = extensions.commands(matching: query, subjectID: subjectID)
        return visibleCommands.map { command in
            CommandRowInfo(commandID: command.id, title: command.title, hint: extensions.hint(for: command, subjectID: subjectID),
                           hintIsMono: command.input == .item && command.hint && command.output != .image,
                           extensionName: command.extensionName, icon: command.icon)
        }
    }

    /// The focused selection's item, else History's first item.
    func currentSubject() -> Int64? {
        selectedItemID ?? columns.first { $0.id == .history }?.rows.first { $0.command == nil }?.itemID
    }
}

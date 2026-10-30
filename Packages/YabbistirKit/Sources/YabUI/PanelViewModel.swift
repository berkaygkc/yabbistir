import Foundation
import Observation
import SwiftUI
import YabCore
import YabExtensionKit
import YabExtensions
import YabLocalization
import YabStack

/// Asks a column to bring a row into view; the serial makes a repeat request for the same row count.
public struct ScrollRequest: Equatable, Sendable {
    public let column: PanelColumn.Source
    public let id: Int64
    let serial: Int
}

public enum PanelAction: Equatable, Sendable {
    case paste(itemID: Int64, plain: Bool), copy(itemID: Int64), close, openEditor, previewChanged
    /// ↵ or ⌘1–9 on a Sıra row: paste that entry now, out of order.
    case pasteFromStack(entryID: Int, itemID: Int64, plain: Bool)
    case addToStack(itemID: Int64)
    /// ↵, ⌘1–9 (copy: false) or ⌘C (copy: true) on a command row.
    case runCommand(commandID: String, subjectID: Int64?, copy: Bool)
}

public enum PanelActionItem: Hashable, Sendable {
    case paste, pastePlain, copy, addToStack
    /// A transform of the selected item, by command id.
    case transform(String)
    /// "All transforms (N)…": opens the ⇧ panel.
    case allTransforms
    case addToCategory, preview, editCategories, delete
}

public enum PreviewSource: Equatable, Sendable {
    case hover, keyboard
}

public enum PinOption: Equatable, Sendable {
    case category(ClipCategory, isMember: Bool), create(name: String)
}

public enum CategoryMenuOption: Equatable, Sendable {
    case category(ClipCategory, isShown: Bool), editCategories
}

/// A run of the ⇧ panel's rows under one header: the paste target's own actions ("Finder’a",
/// "Zed için"), or one extension's commands.
public struct TransformSection: Identifiable, Equatable, Sendable {
    public enum Mark: Equatable, Sendable {
        /// The kind of app the target is (Finder: a folder), as a grey glyph.
        case target(TargetClass)
        /// The extension's icon.
        case icon(String)
    }

    /// "target", or the extension's id.
    public let id: String
    public let title: String
    public let mark: Mark
    /// The section's rows in `transformCommands`.
    public let rows: Range<Int>
}

/// What sits on top of the list and takes the keyboard: the Kategoriler menu, ⌘K, ⌘P or the ⇧ panel.
public enum PanelLayer: Equatable, Sendable {
    case none, categoryMenu, actions, pin, transforms
}

/// State of the panel: the query, the columns (the Sıra while open, History, then categories), focus,
/// a remembered selection per column, and the open layer.
@MainActor @Observable
public final class PanelViewModel {
    public static let resultLimit = 200

    public private(set) var query = ""
    public private(set) var columns: [PanelColumn] = [] { didSet { updateStrip() } }
    public private(set) var focusedColumn = 0 { didSet { updateStrip() } }
    /// Each column keeps its own selection while focus moves between columns.
    public private(set) var selections: [PanelColumn.Source: Int64] = [:]
    /// Set by keyboard navigation and new results only: pointing at a row selects it but never scrolls.
    public private(set) var scrollRequest: ScrollRequest?
    /// ⌘A: the next keystroke replaces the query, ⌫ clears it.
    public private(set) var isQuerySelected = false
    /// "On select" categories opened from the Kategoriler menu; kept while the app runs.
    public private(set) var shownCategoryIDs: Set<Int64> = []
    public private(set) var layer: PanelLayer = .none
    /// Why the preview is open: a hover (closes when the pointer leaves) or the keyboard (stays
    /// for the session and follows the selection). Nil: closed.
    public private(set) var previewSource: PreviewSource?
    /// Space hid the preview; space brings it back.
    public private(set) var previewMuted = false
    /// The ⇧ panel hides the preview; it comes back when the panel closes.
    public var isPreviewVisible: Bool { previewSource != nil && !previewMuted && selectedID != nil && layer != .transforms }
    /// Bumped when ←/→ hits the first or last column; the view answers with a small nudge.
    public private(set) var edgeNudge = 0
    /// Highlighted row of the open menu.
    public private(set) var menuSelection = 0
    /// ⌘P search text.
    public private(set) var pinQuery = ""
    /// Categories the selected item belongs to, read when ⌘P opens and after each change.
    @ObservationIgnored private var pinMembership: Set<Int64> = []
    /// Bumped with membership so the popover redraws its checks.
    public private(set) var pinRevision = 0
    /// The focused column's selected row, in the panel's content coordinates (top-left origin);
    /// ⌘P and the preview anchor to it.
    public var selectedRowFrame: CGRect?
    /// The item commands work on: the selection when the query began, else History's first item.
    public private(set) var subjectID: Int64?

    /// ⌘P: categories whose name contains the query, with a check when the item is in them, then
    /// "New category: …" for a trimmed query that names no existing category.
    public var pinOptions: [PinOption] {
        _ = pinRevision
        let trimmed = pinQuery.trimmingCharacters(in: .whitespaces)
        let needle = SearchNormalizer.normalize(trimmed)
        var options: [PinOption] = categories
            .filter { needle.isEmpty || SearchNormalizer.normalize($0.name).contains(needle) }
            .map { .category($0, isMember: pinMembership.contains($0.id ?? -1)) }
        if !trimmed.isEmpty, !categories.contains(where: { SearchNormalizer.normalize($0.name) == needle }) {
            options.append(.create(name: trimmed))
        }
        return options
    }
    /// The ⌘K menu's search text.
    public private(set) var actionQuery = ""

    /// ⌘K: the paste target's own actions first, when it has any; paste, plain, copy, add to
    /// Sıra; the item's first three other transforms (and "All transforms" past three); then the
    /// rest. A query matches labels (Turkish-folded) and reaches every transform, by title or
    /// keyword prefix.
    public var actionItems: [PanelActionItem] {
        let needle = SearchNormalizer.normalize(actionQuery.trimmingCharacters(in: .whitespaces))
        let target = extensions?.target
        let lead = layerTransforms.filter { $0.isFor(target) }.map { PanelActionItem.transform($0.id) }
        let transforms = layerTransforms.filter { !$0.isFor(target) }.map { PanelActionItem.transform($0.id) }
        let more: [PanelActionItem] = transforms.count > 3 ? [.allTransforms] : []
        let head: [PanelActionItem] = [.paste, .pastePlain, .copy, .addToStack]
        let tail: [PanelActionItem] = [.addToCategory, .preview, .editCategories, .delete]
        guard !needle.isEmpty else { return lead + head + Array(transforms.prefix(3)) + more + tail }
        return (lead + head + transforms + more + tail).filter { item in
            if SearchNormalizer.normalize(actionLabel(item)).contains(needle) { return true }
            guard case .transform(let id) = item, let command = transformCommand(id) else { return false }
            return command.keywords.contains { SearchNormalizer.normalize($0).hasPrefix(needle) }
        }
    }

    /// One of the open layer's transforms (⌘K or ⇧), by id.
    public func transformCommand(_ id: String) -> ExtensionCommand? {
        layerTransforms.first { $0.id == id }
    }

    /// Whether a ⌘K row is one of the paste target's own actions (they lead, in a group of their own).
    public func isForTarget(_ item: PanelActionItem) -> Bool {
        guard case .transform(let id) = item else { return false }
        return transformCommand(id)?.isFor(extensions?.target) == true
    }

    /// ⇧ panel search text.
    public private(set) var transformQuery = ""
    /// The item the ⇧ panel transforms.
    public private(set) var transformSubjectID: Int64?
    /// The app it was copied from, for the ⇧ panel's header.
    public private(set) var transformSubjectApp: String?

    /// The transformed item's row, for the ⇧ panel's header.
    public var transformSubjectRow: RowModel? {
        guard let transformSubjectID else { return nil }
        return columns.lazy.flatMap(\.rows).first { $0.command == nil && $0.itemID == transformSubjectID }
    }
    /// Bumped as hints arrive, so command rows and the ⇧ panel redraw.
    public private(set) var hintRevision = 0

    /// The ⇧ panel's transforms, grouped by extension, filtered by title or extension name
    /// (contains) or keyword (prefix), Turkish-folded.
    public var transformCommands: [ExtensionCommand] {
        let needle = SearchNormalizer.normalize(transformQuery.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return layerTransforms }
        return layerTransforms.filter { command in
            SearchNormalizer.normalize(command.title).contains(needle) || SearchNormalizer.normalize(command.extensionName).contains(needle)
                || command.keywords.contains { SearchNormalizer.normalize($0).hasPrefix(needle) }
        }
    }

    /// The ⇧ panel's rows under their headers: the paste target's own actions first ("Finder’a"
    /// with a folder, "<app> için" with its kind's glyph), then each extension's.
    public var transformSections: [TransformSection] {
        let commands = transformCommands
        let target = extensions?.target
        // The target's actions share one section (nil); any other command is in its extension's.
        let section = { (command: ExtensionCommand) in command.isFor(target) ? nil : command.extensionID }
        var sections: [TransformSection] = []
        var start = 0
        while start < commands.count {
            let first = commands[start]
            var end = start + 1
            while end < commands.count, section(commands[end]) == section(first) { end += 1 }
            let rows = start..<end
            switch (section(first), target) {
            case (nil, let target?):
                let title = target.kind == .finder ? L10n.string("transforms.section.finder", language)
                    : L10n.string("transforms.section.app", language, target.name)
                sections.append(TransformSection(id: "target", title: title, mark: .target(target.kind), rows: rows))
            default:
                sections.append(TransformSection(id: first.extensionID, title: first.extensionName, mark: .icon(first.icon), rows: rows))
            }
            start = end
        }
        return sections
    }

    /// The ⇧ panel's words for ↵ and ⌘C on the highlighted row: a job says what it does ("İndir",
    /// "İndir ve kopyala"; "Başlat" without a verb), anything else pastes and copies.
    public var transformKeyLabels: (confirm: String, copy: String) {
        let commands = transformCommands
        guard commands.indices.contains(menuSelection), commands[menuSelection].isJob else {
            return (L10n.string("transforms.paste", language), L10n.string("transforms.copy", language))
        }
        let verb = commands[menuSelection].verb ?? L10n.string("transforms.start", language)
        return (verb, L10n.string("transforms.copyAfter", language, verb))
    }

    /// Where a file result goes, for the ⇧ panel's file strip: into the open Finder folder, or pasted
    /// as a file into any other app (↵ always pastes). Finder's folder is not named: reading it would
    /// take the Automation permission, which the app does not ask for.
    public var transformFileDestination: String {
        L10n.string(extensions?.target?.kind == .finder ? "transforms.result.toFinder" : "transforms.result.pasteAsFile", language)
    }

    /// A transform row's one-line output, once it has run (nil while pending).
    public func transformHint(_ command: ExtensionCommand) -> String? {
        _ = hintRevision
        return extensions?.hint(for: command, subjectID: transformSubjectID)
    }

    /// Whether the transform's output is on its way (a hint), or it runs only when used.
    public func transformRunsAhead(_ command: ExtensionCommand) -> Bool {
        extensions?.runsAhead(command, subjectID: transformSubjectID) ?? false
    }

    /// The highlighted transform's output for the ⇧ panel's result line, once it has run.
    public func transformOutput(_ command: ExtensionCommand) -> ExtensionResult? {
        _ = hintRevision
        return extensions?.cachedOutput(of: command, subjectID: transformSubjectID)
    }

    /// How many transforms the focused item has; the footer shows "Transform ⇧" when any.
    public var selectedTransformCount: Int {
        guard let id = selectedItemID, let extensions else { return 0 }
        if let cached = transformCountCache, cached.itemID == id { return cached.count }
        let count = extensions.transforms(forItemID: id).count
        transformCountCache = (id, count)
        return count
    }

    public func actionLabel(_ item: PanelActionItem) -> String {
        switch item {
        case .transform(let id): return transformCommand(id)?.title ?? id
        case .allTransforms:
            return L10n.string("actions.allTransforms", language, NumberFormatting.count(layerTransforms.count, language: language))
        default: break
        }
        let key = switch item {
        case .paste: "actions.paste"
        case .pastePlain: "actions.pastePlain"
        case .copy: "actions.copy"
        case .addToStack: "actions.addToStack"
        case .addToCategory: "actions.addToCategory"
        case .preview: "actions.preview"
        case .editCategories: "menu.categories.edit"
        case .transform, .allTransforms: ""
        case .delete:
            switch focusedSource {
            case .stack: "stack.remove"
            case .history: "actions.delete"
            case .category: "actions.removeFromCategory"
            }
        }
        return L10n.string(key, language)
    }
    /// All categories in column order (the editor's order).
    public private(set) var categories: [ClipCategory] = []

    /// The Kategoriler menu: "on select" categories with their checkmark, then "Edit categories".
    public var categoryMenu: [CategoryMenuOption] {
        categories.filter { $0.visibility == .onSelect }
            .map { .category($0, isShown: shownCategoryIDs.contains($0.id ?? -1)) } + [.editCategories]
    }
    /// −1 at the first column, +1 at the last.
    public private(set) var edgeNudgeDirection = 0
    /// ⌘ held for 200 ms: the focused column's first nine icons become 1–9 keycaps.
    public private(set) var showsIndexKeys = false
    /// Height the panel was placed at; the window controller sets it before showing.
    public var panelHeight: CGFloat = 476
    /// Drives the enter animation (grows out of the caret).
    public var isPresented = false
    public var growAnchor: UnitPoint = .topLeading
    /// Screen width the panel may use (visible frame minus margins); the controller sets it.
    public var availableWidth: CGFloat = .infinity { didSet { updateStrip() } }
    /// Leftmost column on screen when the columns do not all fit.
    public private(set) var firstVisibleColumn = 0

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let stack: StackSession?
    /// Small thumbnails for image rows.
    @ObservationIgnored public let thumbnails: RowThumbnails
    @ObservationIgnored private let languageStore: LanguageStore
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored let extensions: ExtensionCommandsProviding?
    /// The Komutlar section's commands, in row order.
    @ObservationIgnored var visibleCommands: [ExtensionCommand] = []
    /// The selected item's transforms while ⌘K or the ⇧ panel is open, grouped by extension.
    @ObservationIgnored private var layerTransforms: [ExtensionCommand] = []
    @ObservationIgnored private var transformCountCache: (itemID: Int64, count: Int)?
    @ObservationIgnored private var commandHold: Task<Void, Never>?
    @ObservationIgnored private var pointerTask: Task<Void, Never>?
    @ObservationIgnored private var pointerInPanel = false
    @ObservationIgnored private var pointerInPreview = false

    public init(library: Library, language: LanguageStore, stack: StackSession? = nil, extensions: ExtensionCommandsProviding? = nil,
                now: @escaping () -> Date = Date.init) {
        self.library = library
        self.stack = stack
        self.thumbnails = RowThumbnails(library: library)
        self.languageStore = language
        self.extensions = extensions
        self.now = now
        extensions?.onHintsChanged = { [weak self] in
            self?.hintRevision += 1
            self?.refresh()
        }
    }

    public var language: AppLanguage { languageStore.language }

    public var focusedSource: PanelColumn.Source { columns.indices.contains(focusedColumn) ? columns[focusedColumn].id : .history }

    /// The focused column's selection.
    public var selectedID: Int64? { selections[focusedSource] }

    public func selectedID(in source: PanelColumn.Source) -> Int64? { selections[source] }

    /// The item behind the focused selection (a Sıra row's id is not its item's): the preview,
    /// ⌘P, ⌘C and the actions work on this.
    public var selectedItemID: Int64? {
        guard let id = selectedID, id > RowModel.commandIDBase else { return nil }
        guard focusedSource == .stack else { return id }
        return focusedRows.first { $0.id == id }?.itemID
    }

    /// The focused column's sections and empty message (the single-column view until columns are drawn).
    public var sections: [RowSection] { columns.indices.contains(focusedColumn) ? columns[focusedColumn].sections : [] }
    public var emptyMessage: String? { columns.indices.contains(focusedColumn) ? columns[focusedColumn].emptyMessage : nil }

    public var resultCountText: String? {
        guard !query.isEmpty, columns.indices.contains(focusedColumn) else { return nil }
        let count = columns[focusedColumn].total
        return count == 1 ? L10n.string("panel.search.resultCount.one", language)
            : L10n.string("panel.search.resultCount", language, NumberFormatting.count(count, language: language))
    }

    /// A fresh panel: empty search, History focused (the Sıra sits to its left), first rows
    /// selected, no layer, no preview.
    public func reset() {
        query = ""
        subjectID = nil
        isQuerySelected = false
        selections = [:]
        layer = .none
        previewSource = nil
        previewMuted = false
        pointerTask?.cancel()
        commandHold?.cancel()
        showsIndexKeys = false
        rebuild()
        focusedColumn = columns.firstIndex { $0.id == .history } ?? 0
        revealSelection()
    }

    /// Re-reads the library after a change, keeping each column's selection (or its position).
    public func refresh() {
        let focused = focusedSource
        rebuild()
        if let index = columns.firstIndex(where: { $0.id == focused }) { focusedColumn = index }
        else { focusedColumn = max(0, min(focusedColumn, columns.count - 1)) }
    }

    public func handle(_ command: PanelCommand) -> PanelAction? {
        // A ⌘ shortcut while ⌘ is down means the user is not holding ⌘ to read the keycaps.
        if command.isCommandShortcut { commandHold?.cancel() }
        if layer == .categoryMenu, let consumed = handleCategoryMenu(command) { return consumed.action }
        if layer == .actions, let consumed = handleActions(command) { return consumed.action }
        if layer == .pin, let consumed = handlePin(command) { return consumed.action }
        if layer == .transforms, let consumed = handleTransforms(command) { return consumed.action }
        switch command {
        case .type(let text):
            setQuery(isQuerySelected ? text : query + text)
        case .deleteBackward:
            guard !query.isEmpty else { return nil }
            setQuery(isQuerySelected ? "" : String(query.dropLast()))
        case .move(let delta):
            moveSelection(by: delta)
            previewSource = .keyboard
        case .moveColumn(let delta):
            let target = max(0, min(columns.count - 1, focusedColumn + delta))
            if target == focusedColumn {
                edgeNudgeDirection = delta < 0 ? -1 : 1
                edgeNudge += 1
            } else {
                focusedColumn = target
                revealSelection()
            }
            previewSource = .keyboard
        case .pasteIndex(let number):
            let rows = focusedRows
            guard (1...9).contains(number), number <= rows.count else { return nil }
            selections[focusedSource] = rows[number - 1].id
            return pasteAction(rowID: rows[number - 1].id, plain: false)
        case .confirm(let plain):
            return selectedID.flatMap { pasteAction(rowID: $0, plain: plain) }
        case .copy:
            if let command = selectedCommand { return .runCommand(commandID: command.id, subjectID: subjectID, copy: true) }
            return selectedItemID.map { .copy(itemID: $0) }
        case .delete:
            deleteSelected()
        case .moveItem(let delta):
            moveStackItem(by: delta)
        case .toggleActions:
            layer = layer == .actions ? .none : .actions
            actionQuery = ""
            menuSelection = 0
            if layer == .actions { layerTransforms = selectedTransforms() }
        case .toggleTransforms:
            openTransforms()
        case .togglePin:
            if layer == .pin { layer = .none } else { openPin() }
        case .toggleCategoryMenu:
            layer = layer == .categoryMenu ? .none : .categoryMenu
            menuSelection = 0
        case .openEditor:
            layer = .none
            return .openEditor
        case .togglePreview:
            guard query.isEmpty, layer == .none else { return handle(.type(" ")) }
            if previewSource == nil { previewSource = .keyboard; previewMuted = false } else { previewMuted.toggle() }
            return .previewChanged
        case .escape:
            if layer != .none { layer = .none; return nil }
            guard !query.isEmpty else { return .close }
            setQuery("")
        case .selectAll:
            isQuerySelected = !query.isEmpty
        case .commandHeld(let held):
            commandHold?.cancel()
            if held {
                commandHold = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    self?.showsIndexKeys = true
                }
            } else {
                showsIndexKeys = false
            }
        case .swallow:
            break
        }
        return nil
    }

    /// ↵, ⌘1–9, a double click or the footer's Paste on a row of the focused column: a Sıra row
    /// pastes its entry out of order; a command row runs (⇧↵ too: its output is already plain).
    public func pasteAction(rowID: Int64, plain: Bool) -> PanelAction? {
        guard let row = focusedRows.first(where: { $0.id == rowID }) else { return nil }
        if let command = row.command { return .runCommand(commandID: command.commandID, subjectID: subjectID, copy: false) }
        guard focusedSource == .stack else { return .paste(itemID: row.itemID, plain: plain) }
        return .pasteFromStack(entryID: Int(-row.id), itemID: row.itemID, plain: plain)
    }

    /// The pointer rested ~380 ms on a row: open the hover preview (never downgrades a keyboard one).
    public func hoverIntent(_ id: Int64) {
        guard previewSource == nil, selectedID == id else { return }
        previewSource = .hover
    }

    /// The hover preview closes 240 ms after the pointer has left both the panel and the preview.
    public func pointer(inPanel: Bool) {
        pointerInPanel = inPanel
        schedulePointerCheck()
    }

    public func pointer(inPreview: Bool) {
        pointerInPreview = inPreview
        schedulePointerCheck()
    }

    private func schedulePointerCheck() {
        pointerTask?.cancel()
        guard !pointerInPanel, !pointerInPreview, previewSource == .hover else { return }
        pointerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(240))
            guard let self, !Task.isCancelled, !self.pointerInPanel, !self.pointerInPreview, self.previewSource == .hover else { return }
            self.previewSource = nil
        }
    }

    /// Pointer over a menu row.
    public func highlightMenuRow(_ index: Int) {
        menuSelection = index
    }

    /// Click on a menu row: the same as ↵ on it.
    public func activateMenuRow(_ index: Int) -> PanelAction? {
        menuSelection = index
        return handle(.confirm(plain: false))
    }

    /// Keys while the Kategoriler menu is open: ↑/↓ move, ↵ or space toggle (the menu stays),
    /// ⇥ and Esc close it, typing does nothing. Nil means the command is not the menu's.
    private func handleCategoryMenu(_ command: PanelCommand) -> Consumed? {
        let options = categoryMenu
        switch command {
        case .move(let delta):
            menuSelection = max(0, min(options.count - 1, menuSelection + delta))
        case .confirm, .togglePreview:
            guard options.indices.contains(menuSelection) else { return Consumed() }
            switch options[menuSelection] {
            case .category(let category, _): toggleShown(category.id ?? -1)
            case .editCategories:
                layer = .none
                return Consumed(action: .openEditor)
            }
        case .escape, .toggleCategoryMenu, .toggleActions, .togglePin, .openEditor, .commandHeld:
            return nil
        default:
            break
        }
        return Consumed()
    }

    /// Keys while ⌘K is open: typing searches the actions, ↑/↓ move, ↵ runs the highlighted one.
    private func handleActions(_ command: PanelCommand) -> Consumed? {
        switch command {
        case .type(let text):
            actionQuery += text
            menuSelection = 0
        case .togglePreview:
            actionQuery += " "
            menuSelection = 0
        case .deleteBackward:
            if !actionQuery.isEmpty { actionQuery.removeLast() }
            menuSelection = 0
        case .move(let delta):
            menuSelection = max(0, min(actionItems.count - 1, menuSelection + delta))
        case .confirm:
            let items = actionItems
            guard items.indices.contains(menuSelection) else { return Consumed() }
            layer = .none
            return Consumed(action: run(items[menuSelection]))
        case .delete:
            // ⌘⌫ in a search field clears it; it never deletes the item under the menu.
            actionQuery = ""
            menuSelection = 0
        case .escape, .toggleCategoryMenu, .toggleActions, .togglePin, .openEditor, .commandHeld:
            return nil
        default:
            break
        }
        return Consumed()
    }

    // MARK: ⇧ panel

    /// The paste target's own transforms first, as they came; the rest grouped by extension.
    private func selectedTransforms() -> [ExtensionCommand] {
        guard let id = selectedItemID, let extensions else { return [] }
        let transforms = extensions.transforms(forItemID: id), target = extensions.target
        return transforms.filter { $0.isFor(target) } + Self.groupedByExtension(transforms.filter { !$0.isFor(target) })
    }

    /// Each extension's commands together, extensions in order of their first command.
    static func groupedByExtension(_ commands: [ExtensionCommand]) -> [ExtensionCommand] {
        var order: [String] = []
        var groups: [String: [ExtensionCommand]] = [:]
        for command in commands {
            if groups[command.extensionID] == nil { order.append(command.extensionID) }
            groups[command.extensionID, default: []].append(command)
        }
        return order.flatMap { groups[$0] ?? [] }
    }

    /// Opens on an item with transforms; an item without any gets the edge nudge instead.
    private func openTransforms() {
        guard let id = selectedItemID, extensions != nil else { return }
        let commands = selectedTransforms()
        guard !commands.isEmpty else {
            edgeNudgeDirection = 1
            edgeNudge += 1
            return
        }
        layerTransforms = commands
        transformSubjectID = id
        transformSubjectApp = library.summaries(ids: [id]).first?.sourceName
        transformQuery = ""
        menuSelection = 0
        layer = .transforms
        extensions?.requestHints(for: commands, subjectID: id)
    }

    /// Keys while the ⇧ panel is open: typing searches, ↑/↓ move, ↵ pastes and ⌘C copies the
    /// highlighted result, ← / Esc / ⇧ close it.
    private func handleTransforms(_ command: PanelCommand) -> Consumed? {
        switch command {
        case .type(let text):
            transformQuery += text
            menuSelection = 0
        case .togglePreview:
            transformQuery += " "
            menuSelection = 0
        case .deleteBackward:
            if !transformQuery.isEmpty { transformQuery.removeLast() }
            menuSelection = 0
        case .delete:
            // ⌘⌫ in a search field clears it.
            transformQuery = ""
            menuSelection = 0
        case .move(let delta):
            menuSelection = max(0, min(transformCommands.count - 1, menuSelection + delta))
        case .confirm, .copy:
            let commands = transformCommands
            guard commands.indices.contains(menuSelection) else { return Consumed() }
            layer = .none
            return Consumed(action: .runCommand(commandID: commands[menuSelection].id, subjectID: transformSubjectID, copy: command == .copy))
        case .moveColumn(let delta) where delta < 0:
            layer = .none
        case .escape, .toggleTransforms:
            layer = .none
        case .toggleCategoryMenu, .toggleActions, .togglePin, .openEditor, .commandHeld:
            return nil
        default:
            // → and ⌘1–9 would act on the list under the panel.
            break
        }
        return Consumed()
    }

    private func openPin() {
        guard let id = selectedItemID else { return }
        layer = .pin
        pinQuery = ""
        menuSelection = 0
        pinMembership = Set((try? library.store.categoryIDs(ofItem: id)) ?? [])
        pinRevision += 1
    }

    /// Keys while ⌘P is open: typing searches, ↑/↓ move, ↵ toggles membership or creates the
    /// category (which then opens as a column); the popover stays open.
    private func handlePin(_ command: PanelCommand) -> Consumed? {
        switch command {
        case .type(let text):
            pinQuery += text
            menuSelection = 0
        case .togglePreview:
            pinQuery += " "
            menuSelection = 0
        case .deleteBackward:
            if !pinQuery.isEmpty { pinQuery.removeLast() }
            menuSelection = 0
        case .move(let delta):
            menuSelection = max(0, min(pinOptions.count - 1, menuSelection + delta))
        case .confirm:
            let options = pinOptions
            guard let item = selectedItemID, options.indices.contains(menuSelection) else { return Consumed() }
            switch options[menuSelection] {
            case .category(let category, _):
                try? library.toggle(item, inCategory: category.id ?? -1)
            case .create(let name):
                guard let created = try? library.createCategory(name: name), let id = created.id else { break }
                try? library.toggle(item, inCategory: id)
                shownCategoryIDs.insert(id)
                pinQuery = ""
                refresh()
            }
            pinMembership = Set((try? library.store.categoryIDs(ofItem: item)) ?? [])
            pinRevision += 1
        case .delete:
            // ⌘⌫ in a search field clears it; it never deletes the item being categorized.
            pinQuery = ""
            menuSelection = 0
        case .escape, .toggleCategoryMenu, .toggleActions, .togglePin, .openEditor, .commandHeld:
            return nil
        default:
            // Column moves, ⌘1–9 and ⌘C would change or act on the item under the popover.
            break
        }
        return Consumed()
    }

    private func run(_ item: PanelActionItem) -> PanelAction? {
        switch item {
        case .paste: return selectedID.flatMap { pasteAction(rowID: $0, plain: false) }
        case .pastePlain: return selectedID.flatMap { pasteAction(rowID: $0, plain: true) }
        case .copy: return selectedItemID.map { .copy(itemID: $0) }
        case .addToStack: return selectedItemID.map { .addToStack(itemID: $0) }
        case .transform(let id): return .runCommand(commandID: id, subjectID: selectedItemID, copy: false)
        case .allTransforms:
            openTransforms()
            return nil
        case .addToCategory:
            openPin()
            return nil
        case .preview:
            previewSource = .keyboard
            previewMuted = false
            return .previewChanged
        case .editCategories: return .openEditor
        case .delete:
            deleteSelected()
            return nil
        }
    }

    /// Hover or click in the focused column.
    public func select(_ id: Int64) {
        if focusedRows.contains(where: { $0.id == id }) { selections[focusedSource] = id }
    }

    /// Hover or click in any column: focuses that column (like a mouse move) without scrolling.
    public func select(_ id: Int64, in source: PanelColumn.Source) {
        guard let index = columns.firstIndex(where: { $0.id == source }), columns[index].rows.contains(where: { $0.id == id }) else { return }
        focusedColumn = index
        selections[source] = id
    }

    /// Whole columns that fit on screen; columns never shrink.
    public var visibleColumnCount: Int { ColumnStripLayout.visibleCount(total: columns.count, available: availableWidth) }

    /// The glass sheet's width: one column width per visible column.
    public var sheetWidth: CGFloat { CGFloat(visibleColumnCount) * ColumnStripLayout.columnWidth }

    /// Opens or closes an "on select" category column; opening focuses it.
    public func toggleShown(_ categoryID: Int64) {
        if shownCategoryIDs.remove(categoryID) == nil { shownCategoryIDs.insert(categoryID) }
        let focused = focusedSource
        rebuild()
        if shownCategoryIDs.contains(categoryID), let index = columns.firstIndex(where: { $0.id == .category(categoryID) }) {
            focusedColumn = index
        } else if let index = columns.firstIndex(where: { $0.id == focused }) {
            focusedColumn = index
        } else {
            focusedColumn = max(0, min(focusedColumn, columns.count - 1))
        }
    }

    private var focusedRows: [RowModel] { columns.indices.contains(focusedColumn) ? columns[focusedColumn].rows : [] }

    /// The subject is caught as the query begins, before the selection jumps to the first match.
    private func setQuery(_ text: String) {
        if query.isEmpty, !text.isEmpty { subjectID = currentSubject() }
        if text.isEmpty { subjectID = nil }
        query = text
        isQuerySelected = false
        searchChanged()
    }

    private func searchChanged() {
        rebuild()
        // A new query starts every column at its best match (the first command, when there are some).
        for column in columns { selections[column.id] = column.rows.first?.id }
        revealSelection()
        if !visibleCommands.isEmpty { extensions?.requestHints(for: visibleCommands, subjectID: subjectID) }
    }

    private func moveSelection(by delta: Int) {
        let rows = focusedRows
        guard let current = selectedID, let position = rows.firstIndex(where: { $0.id == current }) else { return }
        selections[focusedSource] = rows[max(0, min(rows.count - 1, position + delta))].id
        revealSelection()
    }

    private func deleteSelected() {
        guard let id = selectedID, id > RowModel.commandIDBase else { return }
        switch focusedSource {
        case .stack:
            // The item stays in history; it only leaves the stack.
            stack?.remove(entryID: Int(-id))
            refresh()
        case .history:
            if (try? library.deleteFromHistory(id)) == true { stack?.itemDeleted(id) }
        case .category(let categoryID):
            if (try? library.remove(id, fromCategory: categoryID)) == true { stack?.itemDeleted(id) }
        }
    }

    /// ⌥↑ / ⌥↓ in the Sıra column; the selection moves with the row.
    private func moveStackItem(by delta: Int) {
        guard focusedSource == .stack, let stack, let id = selectedID,
              let index = stack.entries.firstIndex(where: { $0.id == Int(-id) }) else { return }
        stack.move(entryID: Int(-id), to: index + delta)
        refresh()
        revealSelection()
    }

    /// Rebuilds every column and keeps each selection by id, or by position when its row left.
    private func rebuild() {
        transformCountCache = nil
        let previousRows = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, $0.rows.map(\.id)) })
        var builder = PanelColumnBuilder(library: library, query: query, language: language, now: now(), limit: Self.resultLimit)
        if let extensions { builder.tagLabels = { extensions.tagLabels($0) } }
        categories = (try? library.store.categories()) ?? []
        let stackColumn = stack.flatMap { $0.isOpen ? builder.stack($0) : nil }
        columns = (stackColumn.map { [$0] } ?? []) + [builder.history(commands: matchCommands())] + categories
            .filter { $0.visibility == .always || shownCategoryIDs.contains($0.id ?? -1) }
            .map(builder.category)
        var kept: [PanelColumn.Source: Int64] = [:]
        for column in columns {
            let ids = column.rows.map(\.id)
            guard !ids.isEmpty else { continue }
            if let selected = selections[column.id], ids.contains(selected) {
                kept[column.id] = selected
            } else if let selected = selections[column.id], let old = previousRows[column.id]?.firstIndex(of: selected) {
                kept[column.id] = ids[min(old, ids.count - 1)]
            } else {
                kept[column.id] = ids[0]
            }
        }
        selections = kept
    }

    private func updateStrip() {
        firstVisibleColumn = ColumnStripLayout.firstVisible(focus: focusedColumn, current: firstVisibleColumn,
                                                            visibleCount: visibleColumnCount, total: columns.count)
    }

    private func revealSelection() {
        guard let selectedID else { return }
        scrollRequest = ScrollRequest(column: focusedSource, id: selectedID, serial: (scrollRequest?.serial ?? 0) + 1)
    }

    /// Ranges in the original title whose folded form matches the folded query (İade ↔ iade).
    /// Called by the row view, so only rows on screen pay for it.
    static func highlights(in title: String, query: String) -> [Range<String.Index>] {
        let needle = Array(SearchNormalizer.normalize(query.trimmingCharacters(in: .whitespaces)))
        guard !needle.isEmpty else { return [] }
        let indices = Array(title.indices)
        let folded = title.map { SearchNormalizer.normalize(String($0)) }
        var ranges: [Range<String.Index>] = []
        var start = 0
        while start < indices.count {
            var matched = 0, position = start, offset = 0
            while position < indices.count, matched < needle.count {
                let piece = Array(folded[position])
                if piece.isEmpty { position += 1; continue }
                guard offset < piece.count, matched < needle.count, piece[offset] == needle[matched] else { break }
                matched += 1
                offset += 1
                if offset == piece.count { position += 1; offset = 0 }
            }
            if matched == needle.count, offset == 0 {
                ranges.append(indices[start]..<(position < indices.count ? indices[position] : title.endIndex))
                start = position
            } else {
                start += 1
            }
        }
        return ranges
    }
}

/// A command a layer took; its action, if any, goes to the window controller.
private struct Consumed {
    var action: PanelAction?
}

private extension PanelCommand {
    var isCommandShortcut: Bool {
        switch self {
        case .pasteIndex, .copy, .delete, .toggleActions, .togglePin, .openEditor, .selectAll, .swallow: true
        default: false
        }
    }
}

import AppKit
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
    /// ⌘C on the ⇧ panel's "Paste as plain text": the item's plain text alone to the clipboard.
    case copyPlain(itemID: Int64)
    /// A source row's action (`SourceDescriptor`), by the row's and the action's ids: ↵, ⌘1–9 and ⇧↵ paste its value
    /// (copy: false), ⌘C copies it (a text action's only).
    case runSource(key: String, row: String, action: String, copy: Bool)
    /// ↵ or ⌘C on a locked source's row: its unlock command to the clipboard.
    case copySourceCommand(String)
}

public enum PanelActionItem: Hashable, Sendable {
    case paste, pastePlain, copy, addToStack
    /// A transform of the selected item, by command id.
    case transform(String)
    /// "All transforms (N)…": opens the ⇧ panel.
    case allTransforms
    case addToCategory, preview, editCategories, delete
    /// A source row's own actions, for ⌘K and its ⇧ panel: the first (↵), the second (⇧↵), the text action's copy (⌘C).
    case sourcePrimary, sourceAlternate, sourceCopy
    /// The locked source row's unlock command, copied.
    case copySourceCommand
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

/// A row of the ⇧ panel: the app's own "Paste as plain text" (rich text only), or a transform.
public enum TransformRow: Equatable, Identifiable, Sendable {
    case plainText, command(ExtensionCommand)

    /// What a ⇧↵ default stores for the row.
    public var id: String {
        switch self {
        case .plainText: ShiftReturn.plainTextID
        case .command(let command): command.id
        }
    }
}

/// A run of the ⇧ panel's rows under one header: the item kind's ⇧↵ default ("Varsayılan"), the
/// app's own plain-text paste ("yabbistir"), the paste target's own actions ("Finder’a", "Zed için"),
/// or one extension's commands.
public struct TransformSection: Identifiable, Equatable, Sendable {
    public enum Mark: Equatable, Sendable {
        /// The kind of app the target is (Finder: a folder), as a grey glyph.
        case target(TargetClass)
        /// The extension's icon.
        case icon(String)
        /// The app's own glyph, grey like the others.
        case app
        /// No glyph: the default's header is its word alone.
        case pinned
    }

    /// "default", "yabbistir", "target", or the extension's id.
    public let id: String
    public let title: String
    public let mark: Mark
    /// The section's rows in `transformRows`.
    public let rows: Range<Int>
}

/// The ⇧ panel's ⌘K, for its highlighted row: make it what ⇧↵ runs for this kind of item (or stop
/// that), then the row's ↵ and ⌘C.
public enum TransformMenuItem: Hashable, Sendable {
    case setDefault, clearDefault, run, copy
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
    public private(set) var layer: PanelLayer = .none {
        // The ⇧ panel's ⌘K, and the source row it lists, leave with the panel.
        didSet {
            if layer != .transforms, transformMenuOpen { transformMenuOpen = false }
            if layer != .transforms, transformSource != nil { transformSource = nil }
        }
    }
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
    /// Bumped when the keyboard moves the highlight of the ⇧ panel or ⌘K (↑/↓, their search, a new ⇧↵ default): a list
    /// that scrolls brings the row into view. Pointing at a row highlights it but never scrolls.
    public private(set) var menuReveal = 0
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
    /// "New category: …" for a trimmed query that names no existing category. A source's category is never offered: its
    /// extension fills it, and its name is free for one of the person's own.
    public var pinOptions: [PinOption] {
        _ = pinRevision
        let trimmed = pinQuery.trimmingCharacters(in: .whitespaces)
        let needle = SearchNormalizer.normalize(trimmed)
        let own = categories.filter { !$0.isSource }
        var options: [PinOption] = own
            .filter { needle.isEmpty || SearchNormalizer.normalize($0.name).contains(needle) }
            .map { .category($0, isMember: pinMembership.contains($0.id ?? -1)) }
        if !trimmed.isEmpty, !own.contains(where: { SearchNormalizer.normalize($0.name) == needle }) {
            options.append(.create(name: trimmed))
        }
        return options
    }
    /// The ⌘K menu's search text.
    public private(set) var actionQuery = ""

    /// ⌘K: the paste target's own actions first, when it has any; paste, plain (rich text only),
    /// copy, add to Sıra; the item's first three other transforms, led by its ⇧↵ default (and "All
    /// transforms" past three); then the rest. A query matches labels (Turkish-folded) and reaches
    /// every transform, by title or keyword prefix.
    public var actionItems: [PanelActionItem] {
        let needle = SearchNormalizer.normalize(actionQuery.trimmingCharacters(in: .whitespaces))
        // A source's row: its own actions (`sourceMenuItems`).
        if let items = sourceMenuItems {
            return needle.isEmpty ? items : items.filter { SearchNormalizer.normalize(actionLabel($0)).contains(needle) }
        }
        let target = extensions?.target
        let lead = layerTransforms.filter { $0.isFor(target) }.map { PanelActionItem.transform($0.id) }
        var transforms = layerTransforms.filter { !$0.isFor(target) }.map { PanelActionItem.transform($0.id) }
        if case .command(let id)? = layerShiftReturn, let index = transforms.firstIndex(of: .transform(id)) {
            transforms.insert(transforms.remove(at: index), at: 0)
        }
        let more: [PanelActionItem] = transforms.count > 3 ? [.allTransforms] : []
        let head: [PanelActionItem] = [.paste] + (layerItem?.isRich == true ? [.pastePlain] : []) + [.copy, .addToStack]
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

    /// The ⌘K row ⇧↵ runs, which wears its keycaps: "Paste as plain text" or the default transform.
    /// Nil when ⇧↵ pastes like ↵.
    public var shiftReturnItem: PanelActionItem? {
        switch layerShiftReturn {
        case .plainText?: .pastePlain
        case .command(let id)?: .transform(id)
        case .paste?, nil: nil
        }
    }

    /// What ⇧↵ does on the selected item (`ShiftReturn.resolve`). Nil without one: no row, a
    /// command row, where ⇧↵ runs it like ↵, or a source's row, which is no item.
    public var shiftReturnAction: ShiftReturnAction? {
        guard let row = selectedRow, row.command == nil, row.source == nil else { return nil }
        return shiftReturn(itemID: row.itemID, kind: row.kind)
    }

    /// ⇧ held for `shiftHintDelay` with no layer open, on a row whose ⇧↵ does something ↵ does not:
    /// the bar becomes one button saying what (`shiftHintLabel`). A ⇧ released while it shows is no tap.
    public private(set) var showsShiftHint = false
    /// What the bar says while ⇧ is held: "Paste as plain text" or the default transform's title.
    /// Kept once the hint hides, so the button fades out with its words.
    public private(set) var shiftHintLabel: String?
    /// How long ⇧ is held before the hint shows: 200 ms, as ⌘ before its keycaps; tests pass zero.
    @ObservationIgnored public let shiftHintDelay: Duration

    /// ⇧ panel search text.
    public private(set) var transformQuery = ""
    /// The item the ⇧ panel transforms.
    public private(set) var transformSubjectID: Int64?
    /// The app it was copied from, for the ⇧ panel's header.
    public private(set) var transformSubjectApp: String?
    /// Its text, for the "Paste as plain text" row's preview.
    public private(set) var transformPlainText: String?
    /// The source row whose actions the ⇧ panel lists in place of transforms; nil while it lists an item's.
    public private(set) var transformSource: SourceSubject?
    /// ⌘K over the ⇧ panel's lower right; the panel stays its layer.
    public private(set) var transformMenuOpen = false
    /// That menu's search text.
    public private(set) var transformMenuQuery = ""
    /// Its highlighted item; the ⇧ panel's highlighted row (`menuSelection`), which it acts on, stays.
    public private(set) var transformMenuSelection = 0
    /// Bumped when a ⇧↵ default changes: the defaults live in UserDefaults, which nothing observes,
    /// and the ⇧ panel, ⌘K and the bar read them through this.
    private var defaultsRevision = 0

    /// The transformed item's row, for the ⇧ panel's header.
    public var transformSubjectRow: RowModel? {
        guard let transformSubjectID else { return nil }
        return columns.lazy.flatMap(\.rows).first { $0.command == nil && $0.itemID == transformSubjectID }
    }
    /// Bumped as hints arrive, so command rows and the ⇧ panel redraw.
    public private(set) var hintRevision = 0

    /// The ⇧ panel's rows, filtered by title or extension name (contains) or keyword (prefix),
    /// Turkish-folded; "Paste as plain text" by its title or "yabbistir".
    public var transformRows: [TransformRow] {
        let rows = layerRows
        let needle = SearchNormalizer.normalize(transformQuery.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in
            switch row {
            case .plainText:
                return [L10n.string("actions.pastePlain", language), L10n.string("transforms.section.yabbistir", language)]
                    .contains { SearchNormalizer.normalize($0).contains(needle) }
            case .command(let command):
                return SearchNormalizer.normalize(command.title).contains(needle) || SearchNormalizer.normalize(command.extensionName).contains(needle)
                    || command.keywords.contains { SearchNormalizer.normalize($0).hasPrefix(needle) }
            }
        }
    }

    /// The ⇧ panel's rows under their headers: the kind's ⇧↵ default under "Varsayılan", "Paste as
    /// plain text" under "yabbistir" with the app's glyph, the paste target's own actions ("Finder’a"
    /// with a folder, "<app> için" with its kind's glyph), then each extension's.
    public var transformSections: [TransformSection] {
        let rows = transformRows
        let target = extensions?.target
        let pinned = layerDefault
        func section(_ row: TransformRow) -> TransformSectionKey {
            if row.id == pinned { return .pinned }
            switch row {
            case .plainText: return .app
            case .command(let command): return command.isFor(target) ? .target : .extension(command.extensionID)
            }
        }
        var sections: [TransformSection] = []
        var start = 0
        while start < rows.count {
            let key = section(rows[start])
            var end = start + 1
            while end < rows.count, section(rows[end]) == key { end += 1 }
            let range = start..<end
            switch key {
            case .pinned:
                sections.append(TransformSection(id: "default", title: L10n.string("transforms.section.default", language), mark: .pinned, rows: range))
            case .app:
                sections.append(TransformSection(id: "yabbistir", title: L10n.string("transforms.section.yabbistir", language), mark: .app, rows: range))
            case .target:
                guard let target else { break }
                let title = target.kind == .finder ? L10n.string("transforms.section.finder", language)
                    : L10n.string("transforms.section.app", language, target.name)
                sections.append(TransformSection(id: "target", title: title, mark: .target(target.kind), rows: range))
            case .extension:
                guard case .command(let first) = rows[start] else { break }
                sections.append(TransformSection(id: first.extensionID, title: first.extensionName, mark: .icon(first.icon), rows: range))
            }
            start = end
        }
        return sections
    }

    /// The ⇧ panel's words for ↵ and ⌘C on the highlighted row: a job says what it does ("İndir",
    /// "İndir ve kopyala"; "Başlat" without a verb), anything else pastes and copies.
    public var transformKeyLabels: (confirm: String, copy: String) {
        let rows = transformRows
        guard rows.indices.contains(menuSelection), case .command(let command) = rows[menuSelection], command.isJob else {
            return (L10n.string("transforms.paste", language), L10n.string("transforms.copy", language))
        }
        let verb = command.verb ?? L10n.string("transforms.start", language)
        return (verb, L10n.string("transforms.copyAfter", language, verb))
    }

    /// The ⇧ panel's ⌘K for the highlighted row: "Make default for ⇧↵" ("Remove default" on the
    /// default), then ↵ and ⌘C in the footer's words; a search keeps the items whose words contain it.
    public var transformMenuItems: [TransformMenuItem] {
        let rows = transformRows
        guard rows.indices.contains(menuSelection) else { return [] }
        let items: [TransformMenuItem] = [rows[menuSelection].id == layerDefault ? .clearDefault : .setDefault, .run, .copy]
        let needle = SearchNormalizer.normalize(transformMenuQuery.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return items }
        return items.filter { SearchNormalizer.normalize(transformMenuLabel($0)).contains(needle) }
    }

    public func transformMenuLabel(_ item: TransformMenuItem) -> String {
        switch item {
        case .setDefault: L10n.string("transforms.menu.setDefault", language)
        case .clearDefault: L10n.string("transforms.menu.clearDefault", language)
        case .run: transformKeyLabels.confirm
        case .copy: transformKeyLabels.copy
        }
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

    /// How many rows the ⇧ panel has for the focused item (its transforms, and "Paste as plain text"
    /// for rich text); the footer shows "Transform ⇧" when any.
    public var selectedTransformCount: Int {
        guard let id = selectedItemID else { return 0 }
        if let cached = transformCountCache, cached.itemID == id { return cached.count }
        let count = (extensions?.transforms(forItemID: id).count ?? 0) + (library.isRichText(id) ? 1 : 0)
        transformCountCache = (id, count)
        return count
    }

    public func actionLabel(_ item: PanelActionItem) -> String {
        switch item {
        case .transform(let id): return transformCommand(id)?.title ?? id
        case .allTransforms:
            return L10n.string("actions.allTransforms", language, NumberFormatting.count(layerRows.count, language: language))
        case .sourcePrimary, .sourceAlternate, .sourceCopy, .copySourceCommand: return sourceActionLabel(item)
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
        case .transform, .allTransforms, .sourcePrimary, .sourceAlternate, .sourceCopy, .copySourceCommand: ""
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

    /// The Kategoriler menu: "on select" categories with their checkmark (a source's with its key), then "Edit
    /// categories".
    public var categoryMenu: [CategoryMenuOption] {
        categories.filter { $0.visibility == .onSelect }
            .map { .category($0, isShown: shownCategoryIDs.contains($0.id ?? -1)) } + [.editCategories]
    }

    /// The Kategoriler button's dots: the hues of up to three open "on select" categories; a source's has none.
    public var categoryButtonDots: [CategoryColor] {
        Array(shownOnSelectCategories.filter { !$0.isSource }.prefix(3).map(\.color))
    }

    /// Whether a source's category is open among them: the button then shows its key after the dots.
    public var categoryButtonMarksSource: Bool {
        shownOnSelectCategories.contains(where: \.isSource)
    }

    private var shownOnSelectCategories: [ClipCategory] {
        categories.filter { $0.visibility == .onSelect && shownCategoryIDs.contains($0.id ?? -1) }
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
    /// Extensions' sources: their columns' rows, kept in memory by the sources and read on every rebuild.
    @ObservationIgnored let sources: SourceProviding?
    @ObservationIgnored private let sourceIdentity = SourceRowIdentity()
    /// The Komutlar section's commands, in row order.
    @ObservationIgnored var visibleCommands: [ExtensionCommand] = []
    /// The selected item's transforms while ⌘K or the ⇧ panel is open, grouped by extension.
    @ObservationIgnored private var layerTransforms: [ExtensionCommand] = []
    /// That item's kind (whose ⇧↵ default applies) and whether it is rich text; nil without an item.
    @ObservationIgnored private var layerItem: (kind: ShiftKind, isRich: Bool)?
    /// The user's ⇧↵ default per item kind.
    @ObservationIgnored private let shiftDefaults: ShiftReturnDefaults
    @ObservationIgnored private var transformCountCache: (itemID: Int64, count: Int)?
    /// Keys own the highlight until the pointer moves (`acceptsHover`).
    @ObservationIgnored private var hoverGate = HoverGate()
    /// The pointer's place on screen; tests give their own.
    @ObservationIgnored public var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    @ObservationIgnored private var commandHold: Task<Void, Never>?
    /// ⇧ is down on its own and the hint's delay is running.
    @ObservationIgnored private var shiftHold: Task<Void, Never>?
    /// ⇧ has been held past the delay: the hint shows on any row that has one.
    @ObservationIgnored private var shiftHeldLong = false
    @ObservationIgnored private var pointerTask: Task<Void, Never>?
    @ObservationIgnored private var pointerInPanel = false
    @ObservationIgnored private var pointerInPreview = false

    public init(library: Library, language: LanguageStore, stack: StackSession? = nil, extensions: ExtensionCommandsProviding? = nil,
                sources: SourceProviding? = nil, now: @escaping () -> Date = Date.init, shiftDefaults: ShiftReturnDefaults = .init(),
                shiftHintDelay: Duration = .milliseconds(200)) {
        self.library = library
        self.stack = stack
        self.thumbnails = RowThumbnails(library: library)
        self.languageStore = language
        self.extensions = extensions
        self.sources = sources
        self.now = now
        self.shiftDefaults = shiftDefaults
        self.shiftHintDelay = shiftHintDelay
        extensions?.onHintsChanged = { [weak self] in
            self?.hintRevision += 1
            self?.refresh()
        }
        // A list came in, or rows were forgotten: it quietly takes the old one's place, the selection on the same row.
        sources?.onChange = { [weak self] in self?.refresh() }
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

    /// The focused selection when it is a source's row (or its locked row); such a row is no item.
    public var selectedSourceRow: SourceRowInfo? { selectedRow?.source }

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
    /// selected, no layer, no preview. The visible sources are asked for new lists; the panel opens on what they
    /// already have and never waits for them.
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
        endShiftHold()
        rebuild(refreshingSources: true)
        focusedColumn = columns.firstIndex { $0.id == .history } ?? 0
        revealSelection()
    }

    /// Re-reads the library after a change, keeping each column's selection (or its position).
    public func refresh() {
        let focused = focusedSource
        rebuild()
        if let index = columns.firstIndex(where: { $0.id == focused }) { focusedColumn = index }
        else { focusedColumn = max(0, min(focusedColumn, columns.count - 1)) }
        // A source's ⇧ list never outlives its row: the source answered locked, forgot its rows, or lists it no more.
        if let subject = transformSource, !stillLists(subject) { layer = .none }
    }

    public func handle(_ command: PanelCommand) -> PanelAction? {
        // A ⌘ shortcut while ⌘ is down means the user is not holding ⌘ to read the keycaps.
        if command.isCommandShortcut { commandHold?.cancel() }
        // Any key puts the bar back from the ⇧↵ hint; only ⇧ itself, held or let go, decides it.
        if !command.isModifierChange { endShiftHold() }
        // A key may scroll a list or change its rows under a resting pointer: the row that lands under it is not chosen.
        if !command.isModifierChange { hoverGate.keyboardActed(pointer: pointerLocation()) }
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
        case .confirm(let shift):
            guard let id = selectedID else { return nil }
            return shift ? shiftReturnAction(rowID: id) : pasteAction(rowID: id, plain: false)
        case .copy:
            if let command = selectedCommand { return .runCommand(commandID: command.id, subjectID: subjectID, copy: true) }
            if let source = selectedSourceRow { return sourceCopy(source) }
            return selectedItemID.map { .copy(itemID: $0) }
        case .delete:
            deleteSelected()
        case .moveItem(let delta):
            moveStackItem(by: delta)
        case .toggleActions:
            layer = layer == .actions ? .none : .actions
            actionQuery = ""
            menuSelection = 0
            if layer == .actions { loadLayer() }
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
        case .shiftHeld(let held):
            if held { holdShift() } else { endShiftHold() }
        case .swallow:
            break
        }
        return nil
    }

    /// ↵, ⌘1–9, a double click or the footer's Paste on a row of the focused column (`plain`: ⌘K's
    /// "Paste as plain text"): a Sıra row pastes its entry out of order; a command row runs. A source's row runs its
    /// first action; the locked one copies its command.
    public func pasteAction(rowID: Int64, plain: Bool) -> PanelAction? {
        guard let row = focusedRows.first(where: { $0.id == rowID }) else { return nil }
        if let source = row.source { return sourceReturn(source, shift: false) }
        if let command = row.command { return .runCommand(commandID: command.commandID, subjectID: subjectID, copy: false) }
        guard focusedSource == .stack else { return .paste(itemID: row.itemID, plain: plain) }
        return .pasteFromStack(entryID: Int(-row.id), itemID: row.itemID, plain: plain)
    }

    /// ⇧↵ on a row of the focused column: the item's default transform runs on it, rich text pastes
    /// as plain text, anything else pastes as it is (a Sıra row its entry, out of order). A command
    /// row runs, as with ↵: its output is already plain. A source's row runs its second action.
    func shiftReturnAction(rowID: Int64) -> PanelAction? {
        guard let row = focusedRows.first(where: { $0.id == rowID }) else { return nil }
        if let source = row.source { return sourceReturn(source, shift: true) }
        guard row.command == nil else { return pasteAction(rowID: rowID, plain: false) }
        let action = shiftReturn(itemID: row.itemID, kind: row.kind)
        if case .command(let id) = action { return .runCommand(commandID: id, subjectID: row.itemID, copy: false) }
        return pasteAction(rowID: rowID, plain: action == .plainText)
    }

    /// What ⇧↵ does with an item: its kind's pinned default while the item takes it, else plain
    /// text for rich text, else a paste as it is.
    private func shiftReturn(itemID: Int64, kind: ItemKind) -> ShiftReturnAction {
        _ = defaultsRevision
        return ShiftReturn.resolve(isRich: library.isRichText(itemID), transforms: transforms(of: itemID).map(\.id),
                                   pinned: shiftDefaults.pinned(for: ShiftKind(kind)))
    }

    // MARK: Holding ⇧

    /// ⇧ went down on its own: once it has been held for `shiftHintDelay`, the bar says what ⇧↵ does.
    /// The other ⇧, or the same one reported again, leaves a running hold as it is.
    private func holdShift() {
        guard shiftHold == nil, !shiftHeldLong else { return }
        guard shiftHintDelay > .zero else { return shiftHeldPastDelay() }
        let delay = shiftHintDelay
        shiftHold = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.shiftHeldPastDelay()
        }
    }

    private func shiftHeldPastDelay() {
        shiftHold = nil
        shiftHeldLong = true
        updateShiftHint()
    }

    /// ⇧ let go, another modifier joined it, or a key went down: no hint, and none coming.
    private func endShiftHold() {
        shiftHold?.cancel()
        shiftHold = nil
        shiftHeldLong = false
        if showsShiftHint { showsShiftHint = false }
    }

    /// Shown while ⇧ is held long, nothing is open over the list, and ⇧↵ on the selected row does
    /// something ↵ does not; it follows the pointer from row to row.
    private func updateShiftHint() {
        let label = shiftHeldLong && layer == .none ? currentShiftHintLabel : nil
        if let label, label != shiftHintLabel { shiftHintLabel = label }
        if showsShiftHint != (label != nil) { showsShiftHint = label != nil }
    }

    /// What ⇧↵ does on the selected row, in the bar's words; nil when it pastes like ↵. On a source's row, its second
    /// action ("Kullanıcı adını yapıştır"); nil with one action, or on the locked row.
    private var currentShiftHintLabel: String? {
        if case .entry? = selectedSourceRow { return selectedSourceDescriptor?.alternate?.title }
        return switch shiftReturnAction {
        case .plainText?: L10n.string("actions.pastePlain", language)
        case .command(let id)?: selectedRow.flatMap { row in transforms(of: row.itemID).first { $0.id == id }?.title }
        case .paste?, nil: nil
        }
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

    /// Whether the row the pointer just entered may take the highlight: every list and menu asks before a hover selects.
    /// After a key, not until the pointer moves; a list that scrolled under a resting pointer keeps the keyboard's row.
    public func acceptsHover() -> Bool {
        hoverGate.accepts(pointer: pointerLocation())
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
        case .escape, .toggleCategoryMenu, .toggleActions, .togglePin, .openEditor, .commandHeld, .shiftHeld:
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
            menuReveal += 1
        case .togglePreview:
            actionQuery += " "
            menuSelection = 0
            menuReveal += 1
        case .deleteBackward:
            if !actionQuery.isEmpty { actionQuery.removeLast() }
            menuSelection = 0
            menuReveal += 1
        case .move(let delta):
            menuSelection = max(0, min(actionItems.count - 1, menuSelection + delta))
            menuReveal += 1
        case .confirm:
            let items = actionItems
            guard items.indices.contains(menuSelection) else { return Consumed() }
            layer = .none
            return Consumed(action: run(items[menuSelection]))
        case .delete:
            // ⌘⌫ in a search field clears it; it never deletes the item under the menu.
            actionQuery = ""
            menuSelection = 0
            menuReveal += 1
        case .escape, .toggleCategoryMenu, .toggleActions, .togglePin, .openEditor, .commandHeld, .shiftHeld:
            return nil
        default:
            break
        }
        return Consumed()
    }

    // MARK: ⇧ panel

    /// The paste target's own transforms first, as they came; the rest grouped by extension.
    private func transforms(of itemID: Int64) -> [ExtensionCommand] {
        guard let extensions else { return [] }
        let transforms = extensions.transforms(forItemID: itemID), target = extensions.target
        return transforms.filter { $0.isFor(target) } + Self.groupedByExtension(transforms.filter { !$0.isFor(target) })
    }

    /// Reads the selected item for ⌘K or the ⇧ panel: its transforms, kind and whether it is rich text.
    private func loadLayer() {
        guard let row = selectedRow, row.command == nil, row.source == nil else {
            (layerTransforms, layerItem) = ([], nil)
            return
        }
        layerTransforms = transforms(of: row.itemID)
        layerItem = (ShiftKind(row.kind), library.isRichText(row.itemID))
    }

    /// What ⇧↵ does with the layer's item.
    private var layerShiftReturn: ShiftReturnAction? {
        _ = defaultsRevision
        guard let layerItem else { return nil }
        return ShiftReturn.resolve(isRich: layerItem.isRich, transforms: layerTransforms.map(\.id), pinned: shiftDefaults.pinned(for: layerItem.kind))
    }

    /// The row of the kind's pinned ⇧↵ default, while the layer's item takes it.
    private var layerDefault: String? {
        guard let layerItem else { return nil }
        switch layerShiftReturn {
        case .command(let id)?: return id
        case .plainText? where shiftDefaults.pinned(for: layerItem.kind) == ShiftReturn.plainTextID: return ShiftReturn.plainTextID
        default: return nil
        }
    }

    /// The ⇧ panel's rows in their fixed order: the pinned default, while it applies; "Paste as plain
    /// text" for rich text; then the transforms (the paste target's own first, the rest grouped by
    /// extension).
    private var layerRows: [TransformRow] {
        var rows = (layerItem?.isRich == true ? [TransformRow.plainText] : []) + layerTransforms.map(TransformRow.command)
        if let pinned = layerDefault, let index = rows.firstIndex(where: { $0.id == pinned }) {
            rows.insert(rows.remove(at: index), at: 0)
        }
        return rows
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

    /// Opens on an item with rows (transforms, or rich text's plain paste), or on a source's row with its
    /// actions; an item without any, or the locked row, gets the edge nudge instead.
    private func openTransforms() {
        if let source = selectedSourceRow { return openSourceList(source) }
        guard let id = selectedItemID else { return }
        loadLayer()
        guard !layerRows.isEmpty else {
            edgeNudgeDirection = 1
            edgeNudge += 1
            return
        }
        let summary = library.summaries(ids: [id]).first
        transformSubjectID = id
        transformSubjectApp = summary?.sourceName
        transformPlainText = summary?.previewText
        transformQuery = ""
        menuSelection = 0
        layer = .transforms
        if !layerTransforms.isEmpty { extensions?.requestHints(for: layerTransforms, subjectID: id) }
    }

    /// Keys while the ⇧ panel is open: typing searches, ↑/↓ move, ↵ (⇧↵ too) pastes and ⌘C copies
    /// the highlighted result, ⌘K opens the panel's own menu, ← / Esc / ⇧ close it.
    private func handleTransforms(_ command: PanelCommand) -> Consumed? {
        if transformSource != nil { return handleSourceList(command) }
        if transformMenuOpen, let consumed = handleTransformMenu(command) { return consumed }
        switch command {
        case .type(let text):
            transformQuery += text
            menuSelection = 0
            menuReveal += 1
        case .togglePreview:
            transformQuery += " "
            menuSelection = 0
            menuReveal += 1
        case .deleteBackward:
            if !transformQuery.isEmpty { transformQuery.removeLast() }
            menuSelection = 0
            menuReveal += 1
        case .delete:
            // ⌘⌫ in a search field clears it.
            transformQuery = ""
            menuSelection = 0
            menuReveal += 1
        case .move(let delta):
            menuSelection = max(0, min(transformRows.count - 1, menuSelection + delta))
            menuReveal += 1
        case .confirm, .copy:
            return Consumed(action: runTransformRow(copy: command == .copy))
        case .toggleActions:
            transformMenuOpen = true
            transformMenuQuery = ""
            transformMenuSelection = 0
        case .moveColumn(let delta) where delta < 0:
            layer = .none
        case .escape, .toggleTransforms:
            layer = .none
        case .toggleCategoryMenu, .togglePin, .openEditor, .commandHeld, .shiftHeld:
            return nil
        default:
            // → and ⌘1–9 would act on the list under the panel.
            break
        }
        return Consumed()
    }

    /// ↵ (or, with `copy`, ⌘C) on the ⇧ panel's highlighted row; the panel closes.
    private func runTransformRow(copy: Bool) -> PanelAction? {
        let rows = transformRows
        guard rows.indices.contains(menuSelection), let subject = transformSubjectID else { return nil }
        layer = .none
        switch rows[menuSelection] {
        case .plainText:
            return copy ? .copyPlain(itemID: subject) : .paste(itemID: subject, plain: true)
        case .command(let transform):
            return .runCommand(commandID: transform.id, subjectID: subject, copy: copy)
        }
    }

    /// Keys while the ⇧ panel's ⌘K is open: typing searches it, ↑/↓ move, ↵ runs the highlighted
    /// item; Esc and ⌘K close the menu alone. Nil: the panel's (a ⇧ tap closes both).
    private func handleTransformMenu(_ command: PanelCommand) -> Consumed? {
        switch command {
        case .type(let text):
            transformMenuQuery += text
            transformMenuSelection = 0
        case .togglePreview:
            transformMenuQuery += " "
            transformMenuSelection = 0
        case .deleteBackward:
            if !transformMenuQuery.isEmpty { transformMenuQuery.removeLast() }
            transformMenuSelection = 0
        case .delete:
            transformMenuQuery = ""
            transformMenuSelection = 0
        case .move(let delta):
            transformMenuSelection = max(0, min(transformMenuItems.count - 1, transformMenuSelection + delta))
        case .confirm:
            let items = transformMenuItems
            guard items.indices.contains(transformMenuSelection) else { return Consumed() }
            transformMenuOpen = false
            return Consumed(action: runTransformMenu(items[transformMenuSelection]))
        case .escape, .toggleActions:
            transformMenuOpen = false
        case .toggleTransforms, .commandHeld, .shiftHeld:
            return nil
        default:
            // ←, ⌘C and the rest would act on the panel under the menu.
            break
        }
        return Consumed()
    }

    private func runTransformMenu(_ item: TransformMenuItem) -> PanelAction? {
        switch item {
        case .setDefault: setShiftDefault(true)
        case .clearDefault: setShiftDefault(false)
        case .run: return runTransformRow(copy: false)
        case .copy: return runTransformRow(copy: true)
        }
        return nil
    }

    /// Makes the highlighted row ⇧↵'s default for this kind of item (`on`), or takes that back. The
    /// rows re-sort (the default leads them), the search clears so the whole list shows, and the
    /// highlight stays on the row wherever it went.
    private func setShiftDefault(_ on: Bool) {
        let rows = transformRows
        guard rows.indices.contains(menuSelection), let kind = layerItem?.kind else { return }
        let id = rows[menuSelection].id
        shiftDefaults.pin(on ? id : nil, for: kind)
        defaultsRevision += 1
        if !transformQuery.isEmpty { transformQuery = "" }
        menuSelection = transformRows.firstIndex { $0.id == id } ?? 0
        menuReveal += 1
    }

    /// Pointer over an item of the ⇧ panel's ⌘K.
    public func highlightTransformMenuItem(_ index: Int) {
        transformMenuSelection = index
    }

    /// Click on an item of the ⇧ panel's ⌘K: the same as ↵ on it.
    public func activateTransformMenuItem(_ index: Int) -> PanelAction? {
        guard transformMenuOpen else { return nil }
        transformMenuSelection = index
        return handle(.confirm(plain: false))
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
        case .escape, .toggleCategoryMenu, .toggleActions, .togglePin, .openEditor, .commandHeld, .shiftHeld:
            return nil
        default:
            // Column moves, ⌘1–9 and ⌘C would change or act on the item under the popover.
            break
        }
        return Consumed()
    }

    // MARK: A source row's ⇧ panel

    /// A source's row lists its actions, the first highlighted; the locked row has none and nudges.
    private func openSourceList(_ source: SourceRowInfo) {
        guard case .entry(let key, let row) = source, let descriptor = sourceDescriptor(key) else {
            edgeNudgeDirection = 1
            edgeNudge += 1
            return
        }
        transformSource = SourceSubject(descriptor: descriptor, row: row)
        transformQuery = ""
        menuSelection = 0
        layer = .transforms
    }

    /// Keys while the ⇧ panel lists a source row's actions: ↑/↓ move, ↵ runs the highlighted one; ⇧↵ and ⌘C do what
    /// they do on the row. ← / Esc / ⇧ close it. Nothing to search, and no ⌘K of its own.
    private func handleSourceList(_ command: PanelCommand) -> Consumed? {
        guard let subject = transformSource else { return nil }
        let items = sourceListItems
        switch command {
        case .move(let delta):
            menuSelection = max(0, min(items.count - 1, menuSelection + delta))
        case .confirm(let shift):
            let item = shift ? PanelActionItem.sourceAlternate : items.indices.contains(menuSelection) ? items[menuSelection] : .sourcePrimary
            layer = .none
            return Consumed(action: sourceRun(item, descriptor: subject.descriptor, row: subject.row))
        case .copy:
            guard items.contains(.sourceCopy) else { break }
            layer = .none
            return Consumed(action: sourceRun(.sourceCopy, descriptor: subject.descriptor, row: subject.row))
        case .moveColumn(let delta) where delta < 0:
            layer = .none
        case .escape, .toggleTransforms:
            layer = .none
        case .toggleCategoryMenu, .togglePin, .openEditor, .commandHeld, .shiftHeld:
            return nil
        default:
            // Typing, ⌘K, → and ⌘1–9 have nothing to do here.
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
        case .sourcePrimary, .sourceAlternate, .sourceCopy:
            guard case .entry(let key, let row)? = selectedSourceRow, let descriptor = sourceDescriptor(key) else { return nil }
            return sourceRun(item, descriptor: descriptor, row: row)
        case .copySourceCommand:
            return selectedSourceRow.flatMap(sourceCopy)
        }
    }

    /// Hover or click in the focused column.
    public func select(_ id: Int64) {
        if focusedRows.contains(where: { $0.id == id }) { selections[focusedSource] = id }
        if shiftHeldLong { updateShiftHint() }
    }

    /// Hover or click in any column: focuses that column (like a mouse move) without scrolling.
    public func select(_ id: Int64, in source: PanelColumn.Source) {
        guard let index = columns.firstIndex(where: { $0.id == source }), columns[index].rows.contains(where: { $0.id == id }) else { return }
        focusedColumn = index
        selections[source] = id
        if shiftHeldLong { updateShiftHint() }
    }

    /// Whole columns that fit on screen; columns never shrink.
    public var visibleColumnCount: Int { ColumnStripLayout.visibleCount(total: columns.count, available: availableWidth) }

    /// The glass sheet's width: one column width per visible column.
    public var sheetWidth: CGFloat { CGFloat(visibleColumnCount) * ColumnStripLayout.columnWidth }

    /// Opens or closes an "on select" category column; opening focuses it. A source's column asks for a new list as
    /// it opens, showing the last one (or that it is loading) meanwhile.
    public func toggleShown(_ categoryID: Int64) {
        if shownCategoryIDs.remove(categoryID) == nil { shownCategoryIDs.insert(categoryID) }
        if shownCategoryIDs.contains(categoryID), let sources, let key = categories.first(where: { $0.id == categoryID })?.source,
           sources.descriptors.contains(where: { $0.id == key }) {
            sources.refresh([key])
        }
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

    /// The focused column's selected row.
    private var selectedRow: RowModel? { selectedID.flatMap { id in focusedRows.first { $0.id == id } } }

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

    /// Rebuilds every column and keeps each selection by id, or by position when its row left. A source's category is
    /// a column only while its extension offers the source; `refreshingSources` (the panel opening) asks the visible
    /// ones for new lists first, which leaves what they have in place.
    private func rebuild(refreshingSources: Bool = false) {
        transformCountCache = nil
        let previousRows = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, $0.rows.map(\.id)) })
        var builder = PanelColumnBuilder(library: library, query: query, language: language, now: now(), limit: Self.resultLimit)
        if let extensions { builder.tagLabels = { extensions.tagLabels($0) } }
        categories = (try? library.store.categories()) ?? []
        let descriptors = Dictionary((sources?.descriptors ?? []).map { ($0.id, $0) }) { first, _ in first }
        let visible = categories.filter { category in
            guard category.visibility == .always || shownCategoryIDs.contains(category.id ?? -1) else { return false }
            return category.source.map { descriptors[$0] != nil } ?? true
        }
        let sourceKeys = visible.compactMap(\.source)
        if refreshingSources, let sources, !sourceKeys.isEmpty { sources.refresh(sourceKeys) }
        let stackColumn = stack.flatMap { $0.isOpen ? builder.stack($0) : nil }
        columns = (stackColumn.map { [$0] } ?? []) + [builder.history(commands: matchCommands())] + visible.map { category in
            guard let key = category.source, let sources, let descriptor = descriptors[key] else { return builder.category(category) }
            return builder.source(category, descriptor: descriptor, state: sources.state(of: key), identity: sourceIdentity)
        }
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

/// What groups the ⇧ panel's rows under one header.
private enum TransformSectionKey: Equatable {
    case pinned, app, target, `extension`(String)
}

private extension PanelCommand {
    /// ⌘ or ⇧ pressed or let go on its own: not a key.
    var isModifierChange: Bool {
        switch self {
        case .commandHeld, .shiftHeld: true
        default: false
        }
    }

    var isCommandShortcut: Bool {
        switch self {
        case .pasteIndex, .copy, .delete, .toggleActions, .togglePin, .openEditor, .selectAll, .swallow: true
        default: false
        }
    }
}

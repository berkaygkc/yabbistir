import Foundation
import YabExtensionKit
import YabExtensions
import YabLocalization

/// The source row the ⇧ panel lists the actions of (a vault's entry): its source, and the row as it was when the panel
/// opened.
public struct SourceSubject: Equatable, Sendable {
    public let descriptor: SourceDescriptor
    public let row: SourceRow
}

/// Words and the keys beside them: one of the bar's buttons, or one of its ⌘ hints.
public struct BarLabel: Hashable, Sendable {
    public let title: String
    public let keys: [String]

    public init(title: String, keys: [String]) {
        (self.title, self.keys) = (title, keys)
    }
}

/// The bar on a source's row, ahead of "Eylemler ⌘K": the first action's words with ↵, then the second's short name with
/// ⇧↵ ("Kullanıcı adı"). On the locked row, "Komutu kopyala ⌘C" alone (nil without a command).
public struct SourceBar: Hashable, Sendable {
    public let primary: BarLabel?
    public let alternate: BarLabel?

    public init(primary: BarLabel?, alternate: BarLabel?) {
        (self.primary, self.alternate) = (primary, alternate)
    }
}

extension SourceRowInfo {
    /// The source's key: "<extension id>/<source id>".
    var key: String {
        switch self {
        case .entry(let key, _), .locked(let key, _, _): key
        }
    }
}

/// A source's row is no item: its keys run its source's own actions. ↵ and ⌘1–9 run the first (a password, pasted), ⇧↵
/// the second (a username), ⌘C the text action that copies, never a secret; ⌘⌫, ⌘P and the transforms have nothing to
/// work on. The locked row's ↵ and ⌘C copy its unlock command.
extension PanelViewModel {
    /// The selected row's source; nil on any other row.
    public var selectedSourceDescriptor: SourceDescriptor? {
        selectedSourceRow.flatMap { sourceDescriptor($0.key) }
    }

    func sourceDescriptor(_ key: String) -> SourceDescriptor? {
        sources?.descriptors.first { $0.id == key }
    }

    /// ↵ (`shift`: ⇧↵) on a source's row: its first action, or its second when it has one; on the locked row, the
    /// command's copy.
    func sourceReturn(_ row: SourceRowInfo, shift: Bool) -> PanelAction? {
        switch row {
        case .entry(let key, let entry):
            sourceDescriptor(key).flatMap { sourceRun(shift ? .sourceAlternate : .sourcePrimary, descriptor: $0, row: entry) }
        case .locked(_, _, let command):
            command.map(PanelAction.copySourceCommand)
        }
    }

    /// ⌘C on a source's row: its text action's copy, nil when it has none; on the locked row, the command's.
    func sourceCopy(_ row: SourceRowInfo) -> PanelAction? {
        switch row {
        case .entry(let key, let entry): sourceDescriptor(key).flatMap { sourceRun(.sourceCopy, descriptor: $0, row: entry) }
        case .locked(_, _, let command): command.map(PanelAction.copySourceCommand)
        }
    }

    /// One of a source's items on one of its rows. ⇧↵ without a second action runs the first; a copy is always the text
    /// action's (`copyAction`), so a secret never reaches it.
    func sourceRun(_ item: PanelActionItem, descriptor: SourceDescriptor, row: SourceRow) -> PanelAction? {
        let action: SourceActionDescriptor? = switch item {
        case .sourcePrimary: descriptor.primary
        case .sourceAlternate: descriptor.alternate ?? descriptor.primary
        case .sourceCopy: descriptor.copyAction
        default: nil
        }
        guard let action else { return nil }
        return .runSource(key: descriptor.id, row: row.id, action: action.id, copy: item == .sourceCopy)
    }

    /// A source's own actions, in their keys' order: ↵, then ⇧↵ (a second action), then ⌘C (a text action that copies).
    func sourceActionItems(_ descriptor: SourceDescriptor) -> [PanelActionItem] {
        [.sourcePrimary] + (descriptor.alternate == nil ? [] : [.sourceAlternate]) + (descriptor.copyAction == nil ? [] : [.sourceCopy])
    }

    /// ⌘K on a source's row: its actions, then Preview and Edit categories; on the locked row, "Komutu kopyala" (when it
    /// gives a command), Preview and Edit categories. Never "Add to Sıra", a category or Delete: the row is no item. Nil
    /// on any other row.
    var sourceMenuItems: [PanelActionItem]? {
        switch selectedSourceRow {
        case .entry?: (selectedSourceDescriptor.map(sourceActionItems) ?? []) + [.preview, .editCategories]
        case .locked(_, _, let command)?: (command == nil ? [] : [.copySourceCommand]) + [.preview, .editCategories]
        case nil: nil
        }
    }

    /// The ⇧ panel's rows on a source's row (`transformSource`): its actions, each with its key.
    public var sourceListItems: [PanelActionItem] {
        transformSource.map { sourceActionItems($0.descriptor) } ?? []
    }

    /// The ⇧ panel's word for ↵ on a source's row: "Kopyala" on the copy row, "Yapıştır" on the others.
    public var sourceListConfirmLabel: String {
        let items = sourceListItems
        let copies = items.indices.contains(menuSelection) && items[menuSelection] == .sourceCopy
        return L10n.string(copies ? "transforms.copy" : "transforms.paste", language)
    }

    /// The action a source's item runs (its words, and a key glyph for a secret): the ⇧ panel's row's, else the
    /// selected row's.
    public func sourceAction(_ item: PanelActionItem) -> SourceActionDescriptor? {
        guard let descriptor = transformSource?.descriptor ?? selectedSourceDescriptor else { return nil }
        return switch item {
        case .sourcePrimary: descriptor.primary
        case .sourceAlternate: descriptor.alternate
        case .sourceCopy: descriptor.copyAction
        default: nil
        }
    }

    /// A source's item in words: what its action does ("Şifreyi yapıştır"), the copy's own ("Kullanıcı adını
    /// kopyala"), or the locked row's "Komutu kopyala".
    func sourceActionLabel(_ item: PanelActionItem) -> String {
        switch item {
        case .sourceCopy: sourceAction(item)?.copyTitle ?? ""
        case .copySourceCommand: L10n.string("panel.source.copyCommand", language)
        default: sourceAction(item)?.title ?? ""
        }
    }

    /// The bar on a source's row; nil on any other row, whose bar is an item's.
    public var sourceBar: SourceBar? {
        switch selectedSourceRow {
        case .entry?:
            guard let descriptor = selectedSourceDescriptor else { return nil }
            return SourceBar(primary: BarLabel(title: descriptor.primary.title, keys: ["↵"]),
                             alternate: descriptor.alternate.map { BarLabel(title: $0.label, keys: ["⇧", "↵"]) })
        case .locked(_, _, let command)?:
            return SourceBar(primary: command.map { _ in BarLabel(title: L10n.string("panel.source.copyCommand", language), keys: ["⌘", "C"]) },
                             alternate: nil)
        case nil:
            return nil
        }
    }

    /// The bar's ⌘ hints on a source's row: ⌘1–9 its first action, ⌘C its copy (when it has one), ⌘K; on the locked row
    /// "Komutu kopyala" (with a command) and ⌘K. Nil on any other row.
    public var sourceCommandHints: [BarLabel]? {
        let actions = BarLabel(title: L10n.string("panel.footer.actions", language), keys: ["⌘", "K"])
        switch selectedSourceRow {
        case .entry?:
            guard let descriptor = selectedSourceDescriptor else { return nil }
            let copy = descriptor.copyAction?.copyTitle.map { [BarLabel(title: $0, keys: ["⌘", "C"])] } ?? []
            return [BarLabel(title: descriptor.primary.title, keys: ["⌘", "1–9"])] + copy + [actions]
        case .locked(_, _, let command)?:
            let copy = command == nil ? [] : [BarLabel(title: L10n.string("panel.source.copyCommand", language), keys: ["⌘", "C"])]
            return copy + [actions]
        case nil:
            return nil
        }
    }
}

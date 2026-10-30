import Foundation
import YabCore
import YabLocalization
import YabStack

public struct RowModel: Identifiable, Equatable, Sendable {
    /// The item's id; a Sıra row uses −(entry id), since an item can be queued twice.
    public var id: Int64
    /// The item it pastes.
    public var itemID: Int64
    public var kind: ItemKind
    public var title: String
    public var time: String
    public var isRemote: Bool
    public var colorHex: String?
    public var linkHost: String?
    /// The Sıra position, from 1.
    public var stackNumber: Int? = nil
    /// An extension command in the Komutlar section; nil for items.
    public var command: CommandRowInfo? = nil
    /// Short texts of the tags extensions' detectors gave the item ("base64").
    public var tags: [String] = []

    /// Command rows count down from here, so they never meet an item's id or a Sıra row's.
    public static let commandIDBase: Int64 = -1_000_000_000
}

/// What a command row draws.
public struct CommandRowInfo: Equatable, Sendable {
    public var commandID: String
    public var title: String
    /// The cached output or the subtitle, one line; nil while pending.
    public var hint: String?
    /// A transformer's text output reads as code.
    public var hintIsMono: Bool
    public var extensionName: String
    /// "sf:<symbol>" or a PNG's path.
    public var icon: String
}

public struct RowSection: Identifiable, Equatable, Sendable {
    public var id: String { title }
    public var title: String
    public var rows: [RowModel]
}

/// One column of the panel: the Sıra while it is open, History, then each visible category.
public struct PanelColumn: Identifiable, Equatable, Sendable {
    public enum Source: Hashable, Sendable {
        case stack, history, category(Int64)
    }

    public var id: Source
    /// "History"/"Geçmiş", or the category's name.
    public var title: String
    /// Nil for History and the Sıra; categories show their dot.
    public var color: CategoryColor?
    /// History is grouped by day; a category is one untitled section.
    public var sections: [RowSection]
    /// Matches before the row limit, for the result count.
    public var total: Int
    public var emptyMessage: String?

    public var rows: [RowModel] { sections.flatMap(\.rows) }
}

/// Builds columns from the library for a query. Rows are capped at `limit`.
@MainActor
struct PanelColumnBuilder {
    /// Rows are one line wide; a longer title only costs highlighting and layout.
    static let titleLimit = 160

    let library: Library
    let query: String
    let language: AppLanguage
    let now: Date
    let limit: Int
    /// The tags' short texts; nil when no extensions are wired (no tag lookups at all).
    var tagLabels: (([StoredTag]) -> [String])? = nil

    func history() -> PanelColumn {
        let result = library.index.search(query, limit: limit)
        let items = library.summaries(ids: result.ids)
        let empty = items.isEmpty
            ? (query.isEmpty ? L10n.string("panel.empty.history", language) : L10n.string("panel.empty.noResults", language, query))
            : nil
        return PanelColumn(id: .history, title: L10n.string("panel.column.history", language), color: nil,
                           sections: groupByDay(items), total: result.total, emptyMessage: empty)
    }

    /// History under a "Komutlar" section, which takes the empty message's place.
    func history(commands: [CommandRowInfo]) -> PanelColumn {
        var column = history()
        guard !commands.isEmpty else { return column }
        let rows = commands.enumerated().map { index, command in
            RowModel(id: RowModel.commandIDBase - Int64(index), itemID: 0, kind: .text, title: command.title, time: "",
                     isRemote: false, colorHex: nil, linkHost: nil, command: command)
        }
        column.sections.insert(RowSection(title: L10n.string("panel.section.commands", language), rows: rows), at: 0)
        column.total += rows.count
        column.emptyMessage = nil
        return column
    }

    func category(_ category: ClipCategory) -> PanelColumn {
        let matches = library.index.filter(library.itemIDs(inCategory: category.id ?? -1), query: query)
        let items = library.summaries(ids: Array(matches.prefix(limit)))
        let empty = items.isEmpty
            ? (query.isEmpty ? L10n.string("panel.empty.category", language) : L10n.string("panel.empty.categoryNoResults", language, query))
            : nil
        let tags = tagsByItem(items)
        let rows = items.map { rowModel($0, tags: tags) }
        return PanelColumn(id: .category(category.id ?? -1), title: category.name, color: category.color,
                           sections: rows.isEmpty ? [] : [RowSection(title: "", rows: rows)],
                           total: matches.count, emptyMessage: empty)
    }

    /// The open stack in its order, numbered; a query filters it like a category.
    func stack(_ session: StackSession) -> PanelColumn {
        let entries = session.entries
        let itemIDs = entries.map(\.itemID)
        let matches = query.isEmpty ? nil : Set(library.index.filter(itemIDs, query: query))
        let summaries = Dictionary(library.summaries(ids: itemIDs).map { ($0.id, $0) }) { first, _ in first }
        let tags = tagsByItem(Array(summaries.values))
        var rows: [RowModel] = []
        for (index, entry) in entries.enumerated() {
            guard matches?.contains(entry.itemID) ?? true, let summary = summaries[entry.itemID] else { continue }
            var row = rowModel(summary, tags: tags)
            row.id = -Int64(entry.id)
            row.stackNumber = index + 1
            rows.append(row)
        }
        let empty = rows.isEmpty
            ? (query.isEmpty ? L10n.string("stack.emptyHint", language) : L10n.string("panel.empty.noResults", language, query))
            : nil
        return PanelColumn(id: .stack, title: L10n.string("panel.column.stack", language), color: nil,
                           sections: rows.isEmpty ? [] : [RowSection(title: "", rows: rows)], total: rows.count, emptyMessage: empty)
    }

    private func groupByDay(_ items: [ClipSummary]) -> [RowSection] {
        let calendar = Calendar.current
        var sections: [RowSection] = []
        let tags = tagsByItem(items)
        for item in items {
            let title = sectionTitle(for: item.lastCopiedAt, calendar: calendar)
            let row = rowModel(item, tags: tags)
            if sections.last?.title == title { sections[sections.count - 1].rows.append(row) }
            else { sections.append(RowSection(title: title, rows: [row])) }
        }
        return sections
    }

    private func sectionTitle(for date: Date, calendar: Calendar) -> String {
        let key: String
        if calendar.isDate(date, inSameDayAs: now) {
            key = "panel.section.today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            key = "panel.section.yesterday"
        } else if now.timeIntervalSince(date) < 7 * 86_400 {
            key = "panel.section.thisWeek"
        } else {
            key = "panel.section.older"
        }
        return L10n.string(key, language)
    }

    /// One query for the column's tags.
    private func tagsByItem(_ items: [ClipSummary]) -> [Int64: [String]] {
        guard let tagLabels, let stored = try? library.store.tags(of: items.map(\.id)) else { return [:] }
        return stored.mapValues(tagLabels)
    }

    private func rowModel(_ item: ClipSummary, tags: [Int64: [String]]) -> RowModel {
        RowModel(
            id: item.id, itemID: item.id, kind: item.kind,
            title: String(item.previewText.prefix(Self.titleLimit)).replacingOccurrences(of: "\n", with: " "),
            time: ShortRelativeTime.string(from: item.lastCopiedAt, now: now, language: language),
            isRemote: item.device == .remote,
            colorHex: item.kind == .color ? item.previewText : nil,
            linkHost: item.linkURL.flatMap { URL(string: $0)?.host },
            tags: tags[item.id] ?? [])
    }
}

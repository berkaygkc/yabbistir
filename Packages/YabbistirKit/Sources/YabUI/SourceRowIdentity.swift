import Foundation

/// Row ids for sources' rows, kept while the app runs: a row keeps its id when its source lists it again (in another
/// order, or renamed), so the selection stays on it. Ids count down from `RowModel.sourceIDBase`, below every item,
/// Sıra and command row. A source's locked row has an id of its own. Only the source's key and the row's id are kept,
/// never a title.
@MainActor
final class SourceRowIdentity {
    private enum Key: Hashable {
        case row(source: String, id: String)
        case locked(source: String)
    }

    private var ids: [Key: Int64] = [:]
    private var next = RowModel.sourceIDBase

    /// `key`: the source's; `row`: the id its extension gave the row, unique within one list.
    func id(key: String, row: String) -> Int64 {
        id(for: .row(source: key, id: row))
    }

    func lockedID(key: String) -> Int64 {
        id(for: .locked(source: key))
    }

    private func id(for key: Key) -> Int64 {
        if let id = ids[key] { return id }
        let id = next
        next -= 1
        ids[key] = id
        return id
    }
}

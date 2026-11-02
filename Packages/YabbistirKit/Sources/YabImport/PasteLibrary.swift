import Foundation
import GRDB
import YabCore

public struct PasteLibraryLocation: Sendable, Equatable {
    public let folder: URL
    /// "Setapp" for the Setapp distribution, nil otherwise.
    public let vendor: String?

    public init(folder: URL, vendor: String?) {
        self.folder = folder
        self.vendor = vendor
    }
}

public struct PasteBoard: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let name: String
    public let count: Int

    public init(id: Int64, name: String, count: Int) {
        self.id = id
        self.name = name
        self.count = count
    }
}

public struct PasteSummary: Sendable, Equatable {
    public let historyCount: Int
    public let boards: [PasteBoard]
    /// Sum of the logical sizes of the files in the library folder.
    public let totalBytes: Int64

    public init(historyCount: Int, boards: [PasteBoard], totalBytes: Int64) {
        self.historyCount = historyCount
        self.boards = boards
        self.totalBytes = totalBytes
    }
}

public struct PasteItem: Sendable {
    public let externalID: String
    public let boardID: Int64?
    public let boardOrder: Int64
    public let firstCopiedAt: Date
    public let lastCopiedAt: Date
    public let source: SourceApp?
    public let payload: Result<[[PasteboardRepresentation]], PasteImportError>
    public let title: String?
}

/// Reads another clipboard manager's library strictly read-only: the database and its log are copied to a
/// temporary folder and only the copy is opened. External data files are read in place.
public final class PasteLibrary: Sendable {
    private static let tables = ["ZITEMENTITY", "ZITEMDATAENTITY", "ZLISTENTITY", "ZAPPLICATIONENTITY"]
    /// The name every temporary copy starts with.
    private static let copyPrefix = "yab-library-"

    private let location: PasteLibraryLocation
    private let queue: DatabaseQueue
    private let copyFolder: URL
    private let externalDirectory: URL

    /// The temporary folder holding the database copy.
    public var temporaryFolder: URL? {
        FileManager.default.fileExists(atPath: copyFolder.path) ? copyFolder : nil
    }

    private init(location: PasteLibraryLocation, queue: DatabaseQueue, copyFolder: URL) {
        self.location = location
        self.queue = queue
        self.copyFolder = copyFolder
        self.externalDirectory = location.folder.appendingPathComponent(".db_SUPPORT/_EXTERNAL_DATA", isDirectory: true)
    }

    deinit { close() }

    /// Looks only outside app containers, so merely looking never triggers a cross-app data prompt.
    public static func find(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> PasteLibraryLocation? {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let candidates: [(String, String?)] = [("com.wiheads.paste-setapp", "Setapp"), ("com.wiheads.paste", nil)]
        for (name, vendor) in candidates {
            let folder = support.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("db.sqlite").path) {
                return PasteLibraryLocation(folder: folder, vendor: vendor)
            }
        }
        return nil
    }

    public static func open(_ location: PasteLibraryLocation) throws(PasteImportError) -> PasteLibrary {
        try open(location, afterCopy: { _ in })
    }

    /// `afterCopy` runs after each copy attempt (with the attempt number) and exists so tests can change the original mid-copy.
    static func open(_ location: PasteLibraryLocation, afterCopy: (Int) -> Void) throws(PasteImportError) -> PasteLibrary {
        let fm = FileManager.default
        let copy = fm.temporaryDirectory.appendingPathComponent(copyPrefix + UUID().uuidString, isDirectory: true)
        let names = ["db.sqlite", "db.sqlite-wal"]
        func stamp() -> [String: [Double]] {
            var result: [String: [Double]] = [:]
            for name in names {
                guard let attrs = try? fm.attributesOfItem(atPath: location.folder.appendingPathComponent(name).path) else { continue }
                result[name] = [Double((attrs[.size] as? Int) ?? 0), ((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)]
            }
            return result
        }
        // Recent rows may live only in the write-ahead log, so the database and log are copied as a pair and the
        // copy is kept only if the original did not change meanwhile. The shared-memory index is not copied:
        // SQLite rebuilds it from the copied log.
        var consistent = false
        for attempt in 1...3 {
            do {
                try? fm.removeItem(at: copy)
                try fm.createDirectory(at: copy, withIntermediateDirectories: true)
                let before = stamp()
                for name in names where before[name] != nil {
                    try fm.copyItem(at: location.folder.appendingPathComponent(name), to: copy.appendingPathComponent(name))
                }
                afterCopy(attempt)
                if before["db.sqlite"] != nil, stamp() == before { consistent = true; break }
            } catch {
                try? fm.removeItem(at: copy)
                throw .unavailable
            }
        }
        guard consistent else {
            try? fm.removeItem(at: copy)
            throw .unavailable
        }
        let queue: DatabaseQueue
        do {
            // The copy is ours, so it is opened normally (replaying the log needs write access); the original is never opened.
            queue = try DatabaseQueue(path: copy.appendingPathComponent("db.sqlite").path)
        } catch {
            try? fm.removeItem(at: copy)
            throw .unavailable
        }
        do {
            try queue.read { db in
                for table in tables where !(try db.tableExists(table)) { throw PasteImportError.unreadable }
            }
        } catch {
            try? fm.removeItem(at: copy)
            throw .unreadable
        }
        return PasteLibrary(location: location, queue: queue, copyFolder: copy)
    }

    /// Removes the temporary copies an earlier run left behind (a crash or a force quit never closed them). Call it at
    /// launch only, before any library is opened: a copy in use would go too.
    public static func removeStaleCopies(in directory: URL = FileManager.default.temporaryDirectory) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(copyPrefix) {
            try? fm.removeItem(at: directory.appendingPathComponent(name, isDirectory: true))
        }
    }

    public func summary() throws(PasteImportError) -> PasteSummary {
        do {
            let (history, boards) = try queue.read { db in
                let history = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ZITEMENTITY WHERE ZLIST IS NULL") ?? 0
                let rows = try Row.fetchAll(db, sql: """
                    SELECT l.Z_PK AS pk, l.ZNAME AS name, COUNT(i.Z_PK) AS n
                    FROM ZLISTENTITY l JOIN ZITEMENTITY i ON i.ZLIST = l.Z_PK
                    GROUP BY l.Z_PK ORDER BY l.Z_PK
                    """)
                let boards = rows.compactMap { row -> PasteBoard? in
                    guard let id: Int64 = row.lenient("pk") else { return nil }
                    let name = (row.lenient("name") as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return PasteBoard(id: id, name: name.isEmpty ? "Pinboard \(id)" : name, count: row.lenient("n") ?? 0)
                }
                return (history, boards)
            }
            return PasteSummary(historyCount: history, boards: boards, totalBytes: folderBytes())
        } catch {
            throw .unreadable
        }
    }

    /// History first (oldest to newest), then each requested pinboard from its last item up to its top one: a
    /// category lists its last-added item first, so filing them in this order keeps the pinboard's top item on top.
    public func items(history: Bool, boards: Set<Int64>, batch: Int = 200, _ body: ([PasteItem]) throws -> Void) throws {
        let size = max(batch, 1)
        if history {
            try page(where: "i.ZLIST IS NULL", arguments: [], order: "i.ZTIMESTAMP, i.Z_PK", size: size, body)
        }
        for board in boards.sorted() {
            try page(where: "i.ZLIST = ?", arguments: [board], order: "i.ZDISPLAYORDERINPINBOARD DESC, i.Z_PK DESC", size: size, body)
        }
    }

    public func close() {
        try? FileManager.default.removeItem(at: copyFolder)
    }

    private func page(where condition: String, arguments: StatementArguments, order: String, size: Int,
                      _ body: ([PasteItem]) throws -> Void) throws {
        var offset = 0
        while true {
            let rows: [Row]
            do {
                rows = try queue.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT i.Z_PK AS pk, i.ZIDENTIFIER AS id, i.ZLIST AS list, i.ZDISPLAYORDERINPINBOARD AS ord, i.ZCREATEDAT AS created,
                               i.ZTIMESTAMP AS ts, i.ZTITLE AS title, d.ZRAWPASTEBOARDITEMS AS blob,
                               a.ZBUNDLEIDENTIFIER AS bundle, a.ZNAME AS app
                        FROM ZITEMENTITY i
                        LEFT JOIN ZITEMDATAENTITY d ON d.Z_PK = i.ZDATA
                        LEFT JOIN ZAPPLICATIONENTITY a ON a.Z_PK = i.ZSOURCEAPPLICATION
                        WHERE \(condition) ORDER BY \(order) LIMIT ? OFFSET ?
                        """, arguments: arguments + [size, offset])
                }
            } catch {
                throw PasteImportError.unreadable
            }
            if rows.isEmpty { return }
            let readAt = Date()
            try body(rows.map { item(from: $0, readAt: readAt) })
            if rows.count < size { return }
            offset += size
        }
    }

    /// Every column is read leniently: the other app's types were never ours to check, so a value of an unexpected
    /// type reads as missing instead of trapping.
    private func item(from row: Row, readAt: Date) -> PasteItem {
        let payload: Result<[[PasteboardRepresentation]], PasteImportError>
        if let blob: Data = row.lenient("blob") {
            do {
                payload = .success(try PasteBlobDecoder.decode(blob, externalDataDirectory: externalDirectory))
            } catch let error as PasteImportError {
                payload = .failure(error)
            } catch {
                payload = .failure(.unknownFormat)
            }
        } else {
            payload = .failure(.unknownFormat)
        }
        var source: SourceApp?
        if let bundle: String = row.lenient("bundle"), !bundle.isEmpty {
            source = SourceApp(bundleID: bundle, name: row.lenient("app") ?? bundle)
        }
        // A missing date takes the other one; with neither, the item is dated when it is read (never 2001-01-01).
        let created: Double? = row.lenient("created")
        let stamp: Double? = row.lenient("ts")
        // A missing, empty or non-text identifier is made from the row's key, so such items never share one.
        let identifier = (row.lenient("id") as String?).flatMap { $0.isEmpty ? nil : $0 }
        let pk: Int64 = row.lenient("pk") ?? 0
        return PasteItem(externalID: identifier ?? "pk:\(pk)",
                         boardID: row.lenient("list"),
                         boardOrder: row.lenient("ord") ?? 0,
                         firstCopiedAt: (created ?? stamp).map(Date.init(timeIntervalSinceReferenceDate:)) ?? readAt,
                         lastCopiedAt: (stamp ?? created).map(Date.init(timeIntervalSinceReferenceDate:)) ?? readAt,
                         source: source,
                         payload: payload,
                         title: row.lenient("title"))
    }

    private func folderBytes() -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: location.folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

private extension Row {
    /// The column's value when it converts to `T`; nil when it is NULL or of another type. `row[column] as T?` would
    /// trap on a value that does not convert.
    func lenient<T: DatabaseValueConvertible>(_ column: String) -> T? {
        T.fromDatabaseValue(self[column] as DatabaseValue)
    }
}

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

/// Reads another clipboard manager's library strictly read-only: the database files are copied to a
/// temporary folder and only the copy is opened. External data files are read in place.
public final class PasteLibrary: Sendable {
    private static let tables = ["ZITEMENTITY", "ZITEMDATAENTITY", "ZLISTENTITY", "ZAPPLICATIONENTITY"]

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
        let fm = FileManager.default
        let copy = fm.temporaryDirectory.appendingPathComponent("yab-library-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: copy, withIntermediateDirectories: true)
            for name in ["db.sqlite", "db.sqlite-wal", "db.sqlite-shm"] {
                let source = location.folder.appendingPathComponent(name)
                if name == "db.sqlite" || fm.fileExists(atPath: source.path) {
                    try fm.copyItem(at: source, to: copy.appendingPathComponent(name))
                }
            }
        } catch {
            try? fm.removeItem(at: copy)
            throw .unavailable
        }
        let queue: DatabaseQueue
        do {
            var configuration = Configuration()
            configuration.readonly = true
            queue = try DatabaseQueue(path: copy.appendingPathComponent("db.sqlite").path, configuration: configuration)
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

    public func summary() throws(PasteImportError) -> PasteSummary {
        do {
            let (history, boards) = try queue.read { db in
                let history = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ZITEMENTITY WHERE ZLIST IS NULL") ?? 0
                let rows = try Row.fetchAll(db, sql: """
                    SELECT l.Z_PK AS pk, l.ZNAME AS name, COUNT(i.Z_PK) AS n
                    FROM ZLISTENTITY l JOIN ZITEMENTITY i ON i.ZLIST = l.Z_PK
                    GROUP BY l.Z_PK ORDER BY l.Z_PK
                    """)
                let boards = rows.map { row -> PasteBoard in
                    let id: Int64 = row["pk"]
                    let name = (row["name"] as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return PasteBoard(id: id, name: name.isEmpty ? "Pinboard \(id)" : name, count: row["n"])
                }
                return (history, boards)
            }
            return PasteSummary(historyCount: history, boards: boards, totalBytes: folderBytes())
        } catch {
            throw .unreadable
        }
    }

    /// History first (oldest to newest), then each requested pinboard in its display order.
    public func items(history: Bool, boards: Set<Int64>, batch: Int = 200, _ body: ([PasteItem]) throws -> Void) throws {
        let size = max(batch, 1)
        if history {
            try page(where: "i.ZLIST IS NULL", arguments: [], order: "i.ZTIMESTAMP, i.Z_PK", size: size, body)
        }
        for board in boards.sorted() {
            try page(where: "i.ZLIST = ?", arguments: [board], order: "i.ZDISPLAYORDERINPINBOARD, i.Z_PK", size: size, body)
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
                        SELECT i.ZIDENTIFIER AS id, i.ZLIST AS list, i.ZDISPLAYORDERINPINBOARD AS ord, i.ZCREATEDAT AS created,
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
            try body(rows.map(item(from:)))
            if rows.count < size { return }
            offset += size
        }
    }

    private func item(from row: Row) -> PasteItem {
        let payload: Result<[[PasteboardRepresentation]], PasteImportError>
        if let blob = row["blob"] as Data? {
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
        if let bundle = row["bundle"] as String?, !bundle.isEmpty {
            source = SourceApp(bundleID: bundle, name: (row["app"] as String?) ?? bundle)
        }
        let created = (row["created"] as Double?) ?? 0
        let stamp = (row["ts"] as Double?) ?? created
        return PasteItem(externalID: (row["id"] as String?) ?? "",
                         boardID: row["list"] as Int64?,
                         boardOrder: (row["ord"] as Int64?) ?? 0,
                         firstCopiedAt: Date(timeIntervalSinceReferenceDate: created),
                         lastCopiedAt: Date(timeIntervalSinceReferenceDate: stamp),
                         source: source,
                         payload: payload,
                         title: row["title"] as String?)
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

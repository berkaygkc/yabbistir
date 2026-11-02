import Foundation
import GRDB

/// Writes a synthetic library in another clipboard manager's Core Data layout (real table and column
/// names, including `Z_PK`) so readers are tested against the real shape. Contains no real content.
public enum SyntheticPasteLibrary {
    public enum Payload: Sendable {
        /// Inline marker 0x01 followed by an LZFSE-compressed plist.
        case compressed([[(String, String)]])
        /// Inline marker 0x01 followed by a raw binary plist.
        case plain([[(String, String)]])
        /// Marker 0x02 and a file written under `.db_SUPPORT/_EXTERNAL_DATA`.
        case external([[(String, String)]])
        /// Inline bytes no decoder understands.
        case garbage
        /// No data row at all.
        case none
    }

    public struct Item: Sendable {
        public var externalID: String
        public var title: String?
        /// Core Data seconds since 2001-01-01.
        public var createdAt: Double
        public var timestamp: Double
        /// `ZLISTENTITY.Z_PK`; nil for history.
        public var board: Int64?
        public var order: Int64
        /// `ZAPPLICATIONENTITY.Z_PK`.
        public var app: Int64?
        public var payload: Payload

        public init(externalID: String = UUID().uuidString, title: String? = nil, createdAt: Double, timestamp: Double,
                    board: Int64? = nil, order: Int64 = 0, app: Int64? = nil, payload: Payload) {
            self.externalID = externalID; self.title = title; self.createdAt = createdAt; self.timestamp = timestamp
            self.board = board; self.order = order; self.app = app; self.payload = payload
        }
    }

    public struct Board: Sendable {
        public var pk: Int64
        public var name: String
        public init(pk: Int64, name: String) { self.pk = pk; self.name = name }
    }

    public struct App: Sendable {
        public var pk: Int64
        public var bundleID: String
        public var name: String
        public init(pk: Int64, bundleID: String, name: String) { self.pk = pk; self.bundleID = bundleID; self.name = name }
    }

    /// Creates `db.sqlite` and `.db_SUPPORT/_EXTERNAL_DATA` inside `folder`.
    /// With `wal`, the database is in write-ahead-log mode with automatic checkpointing off, and the returned
    /// connection must be kept alive: while it is, every row exists only in `db.sqlite-wal`.
    @discardableResult
    public static func make(in folder: URL, items: [Item], boards: [Board] = [], apps: [App] = [], wal: Bool = false) throws -> DatabaseQueue {
        let fm = FileManager.default
        let external = folder.appendingPathComponent(".db_SUPPORT/_EXTERNAL_DATA", isDirectory: true)
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        var configuration = Configuration()
        if wal {
            configuration.prepareDatabase { db in
                _ = try String.fetchOne(db, sql: "PRAGMA journal_mode=WAL")
                try db.execute(sql: "PRAGMA wal_autocheckpoint=0")
            }
        }
        let queue = try DatabaseQueue(path: folder.appendingPathComponent("db.sqlite").path, configuration: configuration)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE ZITEMENTITY (Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER TEXT, ZCREATEDAT TIMESTAMP, ZTIMESTAMP TIMESTAMP,
                    ZTITLE VARCHAR, ZDATA INTEGER, ZLIST INTEGER, ZDISPLAYORDERINPINBOARD INTEGER, ZSOURCEAPPLICATION INTEGER, ZDEVICE INTEGER);
                CREATE TABLE ZITEMDATAENTITY (Z_PK INTEGER PRIMARY KEY, ZRAWPASTEBOARDITEMS BLOB);
                CREATE TABLE ZLISTENTITY (Z_PK INTEGER PRIMARY KEY, ZNAME VARCHAR, ZIDENTIFIER VARCHAR);
                CREATE TABLE ZAPPLICATIONENTITY (Z_PK INTEGER PRIMARY KEY, ZBUNDLEIDENTIFIER VARCHAR, ZNAME VARCHAR);
                """)
            for board in boards {
                try db.execute(sql: "INSERT INTO ZLISTENTITY (Z_PK, ZNAME, ZIDENTIFIER) VALUES (?, ?, ?)",
                               arguments: [board.pk, board.name, UUID().uuidString])
            }
            for app in apps {
                try db.execute(sql: "INSERT INTO ZAPPLICATIONENTITY (Z_PK, ZBUNDLEIDENTIFIER, ZNAME) VALUES (?, ?, ?)",
                               arguments: [app.pk, app.bundleID, app.name])
            }
            for (index, item) in items.enumerated() {
                var dataPK: Int64?
                if let blob = try blob(for: item.payload, externalFolder: external) {
                    dataPK = Int64(index + 1)
                    try db.execute(sql: "INSERT INTO ZITEMDATAENTITY (Z_PK, ZRAWPASTEBOARDITEMS) VALUES (?, ?)", arguments: [dataPK, blob])
                }
                try db.execute(sql: """
                    INSERT INTO ZITEMENTITY (Z_PK, ZIDENTIFIER, ZCREATEDAT, ZTIMESTAMP, ZTITLE, ZDATA, ZLIST, ZDISPLAYORDERINPINBOARD, ZSOURCEAPPLICATION)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [index + 1, item.externalID, item.createdAt, item.timestamp, item.title, dataPK, item.board, item.order, item.app])
            }
        }
        return queue
    }

    /// A SQLite file that lacks the expected tables.
    public static func makeUnrelated(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: folder.appendingPathComponent("db.sqlite").path)
        try queue.write { try $0.execute(sql: "CREATE TABLE other (id INTEGER PRIMARY KEY)") }
    }

    private static func blob(for payload: Payload, externalFolder: URL) throws -> Data? {
        switch payload {
        case .compressed(let items): return Data([0x01]) + (try lzfse(try pastePlist(items)))
        case .plain(let items): return Data([0x01]) + (try pastePlist(items))
        case .external(let items):
            let name = UUID().uuidString
            try lzfse(try pastePlist(items)).write(to: externalFolder.appendingPathComponent(name))
            return Data([0x02]) + Data(name.utf8) + Data([0x00])
        case .garbage: return Data([0x01, 0xDE, 0xAD, 0xBE, 0xEF])
        case .none: return nil
        }
    }
}

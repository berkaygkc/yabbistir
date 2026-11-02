import Foundation
import GRDB
import Testing
import YabCore
import YabImportTestSupport
@testable import YabImport

private func tempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func text(_ s: String) -> [[(String, String)]] { [[("public.utf8-plain-text", s)]] }

/// 3 history items (out of order in the table), a 2-item board, and an empty board.
@discardableResult
private func makeSample(in folder: URL, wal: Bool = false) throws -> DatabaseQueue {
    typealias L = SyntheticPasteLibrary
    return try L.make(in: folder, items: [
        L.Item(externalID: "h-new", createdAt: 300, timestamp: 400, app: 1, payload: .compressed(text("new"))),
        L.Item(externalID: "h-old", createdAt: 100, timestamp: 150, payload: .plain(text("old"))),
        L.Item(externalID: "h-ext", title: "ext", createdAt: 200, timestamp: 250, payload: .external(text("ext"))),
        L.Item(externalID: "b-2", createdAt: 10, timestamp: 20, board: 7, order: 2, payload: .plain(text("b2"))),
        L.Item(externalID: "b-1", createdAt: 30, timestamp: 40, board: 7, order: 1, payload: .plain(text("b1"))),
    ], boards: [.init(pk: 7, name: "ornek.dev links"), .init(pk: 8, name: "empty")],
       apps: [.init(pk: 1, bundleID: "dev.ornek.app", name: "Ornek")], wal: wal)
}

private func collect(_ library: PasteLibrary, history: Bool, boards: Set<Int64>) throws -> [PasteItem] {
    var all: [PasteItem] = []
    try library.items(history: history, boards: boards, batch: 2) { all += $0 }
    return all
}

@Suite struct PasteLibraryTests {
    @Test func findLooksOnlyOutsideContainers() throws {
        let home = try tempFolder()
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let subscription = support.appendingPathComponent("com.wiheads.paste-setapp", isDirectory: true)
        try SyntheticPasteLibrary.makeUnrelated(in: subscription)
        let found = try #require(PasteLibrary.find(home: home))
        #expect(found.vendor == "Setapp")
        #expect(found.folder.standardizedFileURL == subscription.standardizedFileURL)

        let other = try tempFolder()
        let container = other.appendingPathComponent("Library/Containers/com.wiheads.paste/Data/Library/Application Support/com.wiheads.paste", isDirectory: true)
        try SyntheticPasteLibrary.makeUnrelated(in: container)
        #expect(PasteLibrary.find(home: other) == nil)

        let direct = try tempFolder()
        let store = direct.appendingPathComponent("Library/Application Support/com.wiheads.paste", isDirectory: true)
        try SyntheticPasteLibrary.makeUnrelated(in: store)
        #expect(PasteLibrary.find(home: direct)?.vendor == nil)
    }

    @Test func summaryCountsHistoryAndNonEmptyBoards() throws {
        let folder = try tempFolder()
        try makeSample(in: folder)
        let library = try PasteLibrary.open(PasteLibraryLocation(folder: folder, vendor: nil))
        defer { library.close() }
        let summary = try library.summary()
        #expect(summary.historyCount == 3)
        #expect(summary.boards == [PasteBoard(id: 7, name: "ornek.dev links", count: 2)])
        #expect(summary.totalBytes > 0)
    }

    @Test func itemsComeInOrderWithTheirDates() throws {
        let folder = try tempFolder()
        try makeSample(in: folder)
        let library = try PasteLibrary.open(PasteLibraryLocation(folder: folder, vendor: nil))
        defer { library.close() }
        let items = try collect(library, history: true, boards: [7])
        #expect(items.map(\.externalID) == ["h-old", "h-ext", "h-new", "b-2", "b-1"])
        #expect(items[0].firstCopiedAt == Date(timeIntervalSinceReferenceDate: 100))
        #expect(items[0].lastCopiedAt == Date(timeIntervalSinceReferenceDate: 150))
        #expect(items[0].boardID == nil)
        #expect(items[4].boardID == 7 && items[4].boardOrder == 1)
        #expect(items[2].source == SourceApp(bundleID: "dev.ornek.app", name: "Ornek"))
        #expect(items[0].source == nil)
        #expect(try items[1].payload.get().first?.first?.data == Data("ext".utf8))
        #expect(try collect(library, history: false, boards: []).isEmpty)
    }

    @Test func anUndecodablePayloadKeepsItsTitle() throws {
        let folder = try tempFolder()
        try SyntheticPasteLibrary.make(in: folder, items: [
            SyntheticPasteLibrary.Item(externalID: "x", title: "ornek.dev note", createdAt: 1, timestamp: 2, payload: .garbage),
        ])
        let library = try PasteLibrary.open(PasteLibraryLocation(folder: folder, vendor: nil))
        defer { library.close() }
        let item = try #require(try collect(library, history: true, boards: []).first)
        #expect(throws: PasteImportError.unknownFormat) { try item.payload.get() }
        #expect(item.title == "ornek.dev note")
    }

    /// An identifier stored as raw bytes that are not text (as a UUID attribute would be) decodes without a crash.
    @Test func aRawByteIdentifierDecodesWithoutACrash() throws {
        let folder = try tempFolder()
        let bytes = Data([0xFF, 0xFE, 0x00, 0x80, 0xC3, 0x28, 0xA0, 0xA1, 0xE2, 0x28, 0xA1, 0xF0, 0x28, 0x8C, 0xBC, 0x9F])
        try SyntheticPasteLibrary.make(in: folder, items: [
            SyntheticPasteLibrary.Item(externalID: nil, identifierBytes: bytes, createdAt: 1, timestamp: 2, payload: .plain(text("raw"))),
        ])
        let library = try PasteLibrary.open(PasteLibraryLocation(folder: folder, vendor: nil))
        defer { library.close() }
        #expect(try collect(library, history: true, boards: []).map(\.externalID) == ["pk:1"])
    }

    /// Missing or empty identifiers are made from the row's key, so such items never collide.
    @Test func missingIdentifiersStayDistinct() throws {
        let folder = try tempFolder()
        try SyntheticPasteLibrary.make(in: folder, items: [
            SyntheticPasteLibrary.Item(externalID: nil, createdAt: 1, timestamp: 2, payload: .plain(text("one"))),
            SyntheticPasteLibrary.Item(externalID: nil, createdAt: 1, timestamp: 3, payload: .plain(text("two"))),
            SyntheticPasteLibrary.Item(externalID: "", createdAt: 1, timestamp: 4, payload: .plain(text("three"))),
            SyntheticPasteLibrary.Item(externalID: "kept", createdAt: 1, timestamp: 5, payload: .plain(text("four"))),
        ])
        let library = try PasteLibrary.open(PasteLibraryLocation(folder: folder, vendor: nil))
        defer { library.close() }
        #expect(try collect(library, history: true, boards: []).map(\.externalID) == ["pk:1", "pk:2", "pk:3", "kept"])
    }

    /// A missing creation date takes the last-copied one; with neither, the item is dated when it is read, never 2001.
    @Test func aMissingDateFallsBack() throws {
        let folder = try tempFolder()
        try SyntheticPasteLibrary.make(in: folder, items: [
            SyntheticPasteLibrary.Item(externalID: "undated", createdAt: nil, timestamp: nil, payload: .plain(text("one"))),
            SyntheticPasteLibrary.Item(externalID: "stamped", createdAt: nil, timestamp: 500, payload: .plain(text("two"))),
            SyntheticPasteLibrary.Item(externalID: "created", createdAt: 600, timestamp: nil, payload: .plain(text("three"))),
        ])
        let library = try PasteLibrary.open(PasteLibraryLocation(folder: folder, vendor: nil))
        defer { library.close() }
        let before = Date()
        let items = Dictionary(uniqueKeysWithValues: try collect(library, history: true, boards: []).map { ($0.externalID, $0) })
        let after = Date()
        let undated = try #require(items["undated"])
        #expect(undated.firstCopiedAt >= before && undated.firstCopiedAt <= after)
        #expect(undated.lastCopiedAt >= before && undated.lastCopiedAt <= after)
        #expect(items["stamped"]?.firstCopiedAt == Date(timeIntervalSinceReferenceDate: 500))
        #expect(items["stamped"]?.lastCopiedAt == Date(timeIntervalSinceReferenceDate: 500))
        #expect(items["created"]?.firstCopiedAt == Date(timeIntervalSinceReferenceDate: 600))
        #expect(items["created"]?.lastCopiedAt == Date(timeIntervalSinceReferenceDate: 600))
    }

    @Test func aMissingLibraryReportsUnavailable() throws {
        let folder = try tempFolder().appendingPathComponent("nope")
        #expect(throws: PasteImportError.unavailable) {
            _ = try PasteLibrary.open(PasteLibraryLocation(folder: folder, vendor: nil))
        }
    }

    @Test func anUnreadableCopyFailsCleanly() throws {
        let folder = try tempFolder()
        try SyntheticPasteLibrary.makeUnrelated(in: folder)
        #expect(throws: PasteImportError.unreadable) {
            let library = try PasteLibrary.open(PasteLibraryLocation(folder: folder, vendor: nil))
            _ = try library.summary()
        }
    }

    @Test func theOriginalIsNeverWritten() throws {
        let folder = try tempFolder()
        let writer = try makeSample(in: folder, wal: true)
        defer { _ = writer }
        let names = ["db.sqlite", "db.sqlite-wal", "db.sqlite-shm"]
        func snapshot() -> [String: [Double]] {
            Dictionary(uniqueKeysWithValues: names.compactMap { name in
                let attrs = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
                return attrs.map { (name, [($0[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, Double(($0[.size] as? Int) ?? 0)]) }
            })
        }
        let before = snapshot()
        #expect(before.count == 3)
        let library = try PasteLibrary.open(PasteLibraryLocation(folder: folder, vendor: nil))
        _ = try library.summary()
        _ = try collect(library, history: true, boards: [7])
        let copy = try #require(library.temporaryFolder)
        #expect(FileManager.default.fileExists(atPath: copy.path))
        library.close()
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(snapshot() == before)
    }

    @Test func rowsThatExistOnlyInTheLogAreRead() throws {
        let folder = try tempFolder()
        let writer = try makeSample(in: folder, wal: true)
        defer { _ = writer }
        let main = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("db.sqlite").path)[.size] as? Int
        #expect((main ?? 0) < 8192)  // the schema alone is not in the main file: everything is in the log
        let library = try PasteLibrary.open(PasteLibraryLocation(folder: folder, vendor: nil))
        defer { library.close() }
        #expect(try library.summary().historyCount == 3)
        #expect(try collect(library, history: true, boards: [7]).count == 5)
    }

    /// Copies a run left behind without closing its library (a crash, a force quit) are swept; nothing else is.
    @Test func staleCopiesAreRemoved() throws {
        let folder = try tempFolder()
        let fm = FileManager.default
        for name in ["yab-library-1", "yab-library-2", "yab-libraryX", "lib-other"] {
            try fm.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: folder.appendingPathComponent("yab-library-1/db.sqlite"))
        PasteLibrary.removeStaleCopies(in: folder)
        #expect(Set(try fm.contentsOfDirectory(atPath: folder.path)) == ["yab-libraryX", "lib-other"])
    }

    @Test func aChangingOriginalIsRetriedThenGivenUp() throws {
        let folder = try tempFolder()
        let writer = try makeSample(in: folder, wal: true)
        defer { _ = writer }
        let wal = folder.appendingPathComponent("db.sqlite-wal")
        func touch(_ attempt: Int) {
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(attempt) * 10)], ofItemAtPath: wal.path)
        }
        let location = PasteLibraryLocation(folder: folder, vendor: nil)

        var attempts = 0
        let library = try PasteLibrary.open(location) { attempt in
            attempts = attempt
            if attempt == 1 { touch(attempt) }
        }
        #expect(attempts == 2)
        #expect(try library.summary().historyCount == 3)
        library.close()

        var tries = 0
        #expect(throws: PasteImportError.unavailable) {
            _ = try PasteLibrary.open(location) { attempt in tries = attempt; touch(attempt + 10) }
        }
        #expect(tries == 3)
    }
}

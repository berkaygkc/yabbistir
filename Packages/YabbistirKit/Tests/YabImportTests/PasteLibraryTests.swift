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
        let setapp = support.appendingPathComponent("com.wiheads.paste-setapp", isDirectory: true)
        try SyntheticPasteLibrary.makeUnrelated(in: setapp)
        let found = try #require(PasteLibrary.find(home: home))
        #expect(found.vendor == "Setapp")
        #expect(found.folder.standardizedFileURL == setapp.standardizedFileURL)

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
        #expect(items.map(\.externalID) == ["h-old", "h-ext", "h-new", "b-1", "b-2"])
        #expect(items[0].firstCopiedAt == Date(timeIntervalSinceReferenceDate: 100))
        #expect(items[0].lastCopiedAt == Date(timeIntervalSinceReferenceDate: 150))
        #expect(items[0].boardID == nil)
        #expect(items[3].boardID == 7 && items[3].boardOrder == 1)
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

import Foundation
import GRDB
import Testing
import YabTestSupport
@testable import YabCore

let t0 = Date(timeIntervalSinceReferenceDate: 815_000_000)

func textClip(_ s: String, at date: Date = t0, source: SourceApp? = SourceApp(bundleID: "com.apple.TextEdit", name: "TextEdit")) -> CapturedClip {
    CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(s.utf8))]],
                 source: source, device: .local, capturedAt: date)
}

func randomData(_ count: Int) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: 0...255) })
}

func blobFileCount(_ store: ItemStore) throws -> Int {
    guard let enumerator = FileManager.default.enumerator(at: store.blobs.directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
    return enumerator.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.count
}

@Suite struct ItemStoreTests {
    @Test func ingestNewTextCreatesItem() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let result = try #require(try store.ingest(textClip("merhaba")))
        #expect(result.isNew)
        #expect(result.item.kind == .text)
        #expect(try store.history(limit: 10).count == 1)
    }

    @Test func ingestSameContentBumps() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let first = try #require(try store.ingest(textClip("merhaba", at: t0)))
        let later = t0.addingTimeInterval(60)
        let second = try #require(try store.ingest(textClip("merhaba", at: later)))
        #expect(!second.isNew)
        #expect(second.item.id == first.item.id)
        #expect(second.item.firstCopiedAt == t0)
        #expect(second.item.lastCopiedAt == later)
        #expect(second.item.lastUsedAt == later)
        #expect(try store.history(limit: 10).count == 1)
    }

    @Test func ingestUnclassifiableReturnsNil() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: "com.example.private", data: Data("x".utf8))]],
                                source: nil, device: .local, capturedAt: t0)
        #expect(try store.ingest(clip) == nil)
        #expect(try store.history(limit: 10).isEmpty)
    }

    @Test func largeRepresentationGoesToBlob() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let big = randomData(100 * 1024)
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.png, data: big)]],
                                source: nil, device: .local, capturedAt: t0)
        let result = try #require(try store.ingest(clip))
        let inlineIsNull = try store.dbPool.read { db in
            try Bool.fetchOne(db, sql: "SELECT inlineData IS NULL FROM representation WHERE itemID = ?", arguments: [result.item.id])
        }
        #expect(inlineIsNull == true)
        #expect(try blobFileCount(store) == 1)
        #expect(try store.representations(of: result.item.id!) == [[PasteboardRepresentation(type: TypeIdentifiers.png, data: big)]])
    }

    @Test func identicalBlobStoredOnce() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let big = randomData(100 * 1024)
        for marker in ["a", "b"] {
            let clip = CapturedClip(items: [[
                PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(marker.utf8)),
                PasteboardRepresentation(type: "public.html", data: big),
            ]], source: nil, device: .local, capturedAt: t0)
            _ = try store.ingest(clip)
        }
        #expect(try store.history(limit: 10).count == 2)
        #expect(try blobFileCount(store) == 1)
    }

    @Test func deleteRemovesUnreferencedBlob() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.png, data: randomData(100 * 1024))]],
                                source: nil, device: .local, capturedAt: t0)
        let result = try #require(try store.ingest(clip))
        try store.delete(result.item.id!)
        #expect(try store.history(limit: 10).isEmpty)
        #expect(try blobFileCount(store) == 0)
    }

    @Test func hugeTextIngestIsFast() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let huge = String(repeating: "a ", count: 5_000_000)
        let clock = ContinuousClock()
        let elapsed = try clock.measure { _ = try store.ingest(textClip(huge)) }
        #expect(elapsed < .milliseconds(500))
        #expect(try store.history(limit: 1).first?.previewText.count ?? 0 <= 500)
    }
}

@Suite struct ItemStoreBatchTests {
    @Test func summariesPreserveOrder() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let a = try #require(try store.ingest(textClip("a", at: t0)))
        let b = try #require(try store.ingest(textClip("b", at: t0.addingTimeInterval(1))))
        let c = try #require(try store.ingest(textClip("c", at: t0.addingTimeInterval(2))))
        let ids = [b.item.id!, c.item.id!, a.item.id!]
        #expect(try store.summaries(ids: ids).map(\.id) == ids)
    }
}

private func vsCodeClip(_ s: String, token: Data, at date: Date) -> CapturedClip {
    // VS Code adds per-copy editor data next to the text.
    CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(s.utf8)),
                          PasteboardRepresentation(type: "org.chromium.web-custom-data", data: token)]],
                 source: SourceApp(bundleID: "com.microsoft.VSCode", name: "Code"), device: .local, capturedAt: date)
}

@Suite struct ItemStoreIdentityTests {
    @Test func sameTextWithVolatileTypeIsOneItem() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let first = try #require(try store.ingest(vsCodeClip("merhaba", token: Data("a1".utf8), at: t0)))
        let second = try #require(try store.ingest(vsCodeClip("merhaba", token: Data("b2".utf8), at: t0.addingTimeInterval(5))))
        #expect(!second.isNew)
        #expect(second.item.id == first.item.id)
        #expect(try store.history(limit: 10).count == 1)
    }

    @Test func recopyKeepsLatestRepresentations() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        _ = try store.ingest(vsCodeClip("merhaba", token: Data("a1".utf8), at: t0))
        let latest = vsCodeClip("merhaba", token: Data("b2".utf8), at: t0.addingTimeInterval(5))
        let result = try #require(try store.ingest(latest))
        #expect(try store.representations(of: result.item.id!) == latest.items)
    }

    @Test func recopyReleasesBlobsOnlyTheOldCopyUsed() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        _ = try store.ingest(vsCodeClip("merhaba", token: randomData(100 * 1024), at: t0))
        _ = try store.ingest(vsCodeClip("merhaba", token: randomData(100 * 1024), at: t0.addingTimeInterval(5)))
        #expect(try blobFileCount(store) == 1)
    }

    @Test func upgradeMergesDuplicatesFromBeforeContentIdentity() throws {
        let directory = TestScratch.url("yab-upgrade")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            // A v1 library: the same text stored twice because the old hash covered every type.
            let queue = try DatabaseQueue(path: directory.appendingPathComponent("db.sqlite").path)
            try Schema.migrator(blobs: BlobStore(directory: directory.appendingPathComponent("Blobs"))).migrate(queue, upTo: "v1")
            try queue.write { db in
                for (id, token, date) in [(1, "a1", t0), (2, "b2", t0.addingTimeInterval(60))] {
                    try db.execute(sql: """
                        INSERT INTO item (id, kind, previewText, searchText, contentHash, device, firstCopiedAt, lastCopiedAt, lastUsedAt)
                        VALUES (?, 'text', 'merhaba', 'merhaba', ?, 'local', ?, ?, ?)
                        """, arguments: [id, "v1-\(id)", date, date, date])
                    try db.execute(sql: "INSERT INTO representation (itemID, itemIndex, position, type, inlineData, byteCount) VALUES (?, 0, 0, ?, ?, 7)",
                                   arguments: [id, TypeIdentifiers.plainText, Data("merhaba".utf8)])
                    try db.execute(sql: "INSERT INTO representation (itemID, itemIndex, position, type, inlineData, byteCount) VALUES (?, 0, 1, ?, ?, 2)",
                                   arguments: [id, "org.chromium.web-custom-data", Data(token.utf8)])
                }
            }
        }
        let store = try ItemStore(directory: directory)
        let history = try store.history(limit: 10)
        #expect(history.map(\.id) == [2])
        #expect(history.first?.firstCopiedAt == t0)
        // New copies of that text land on the merged item.
        let again = try #require(try store.ingest(vsCodeClip("merhaba", token: Data("c3".utf8), at: t0.addingTimeInterval(120))))
        #expect(!again.isNew)
    }

    /// Result files in Outputs live as long as some history item points at them.
    @Test func referencedFileURLsListEveryCopiedFile() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let url = "file:///Users/me/Library/Application%20Support/yabbistir/Outputs/A/Ekran%20Resmi.jpeg"
        _ = try store.ingest(CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.fileURL, data: Data(url.utf8))]],
                                          source: nil, device: .local, capturedAt: Date()))
        _ = try store.ingest(CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data("merhaba".utf8))]],
                                          source: nil, device: .local, capturedAt: Date()))
        #expect(try store.referencedFileURLs() == [url])
    }

    /// Reading an item's text never pulls its other payloads.
    @Test func representationsCanBeReadByType() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let big = Data(repeating: 7, count: 200_000)
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data("merhaba".utf8)),
                                         PasteboardRepresentation(type: TypeIdentifiers.tiff, data: big)]],
                                source: nil, device: .local, capturedAt: Date())
        let id = try #require(try store.ingest(clip)).item.id!
        #expect(try store.representations(of: id, types: [TypeIdentifiers.plainText]).flatMap { $0.map(\.type) } == [TypeIdentifiers.plainText])
        #expect(try store.representations(of: id, types: []).flatMap { $0 }.isEmpty)
    }
}

import Foundation
import GRDB
import Testing
import YabTestSupport
@testable import YabCore

@Suite struct TagStoreTests {
    let store: ItemStore

    init() throws {
        store = try ItemStore(directory: TestScratch.url("items"))
    }

    func ingest(_ text: String) throws -> Int64 {
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(text.utf8))]],
                                source: nil, device: .local, capturedAt: Date())
        return try #require(try store.ingest(clip)).item.id!
    }

    @Test func migrationAddsTheTagTable() throws {
        #expect(try store.dbPool.read { try $0.tableExists("itemTag") })
    }

    @Test func tagsGoWithTheirItem() throws {
        let id = try ingest("SGVsbG8sIGTDvG55YQ==")
        try store.setTags([StoredTag(extensionID: "dev.yabbistir.base64", tag: "base64")], for: id, extensionID: "dev.yabbistir.base64")
        #expect(try store.tags(ofItem: id) == [StoredTag(extensionID: "dev.yabbistir.base64", tag: "base64")])
        try store.delete(id)
        #expect(try store.tags(ofItem: id).isEmpty)
    }

    @Test func anExtensionReplacesOnlyItsOwnTags() throws {
        let id = try ingest("eyJhbGciOiJIUzI1NiJ9")
        try store.setTags([StoredTag(extensionID: "a", tag: "one")], for: id, extensionID: "a")
        try store.setTags([StoredTag(extensionID: "b", tag: "two")], for: id, extensionID: "b")
        try store.setTags([], for: id, extensionID: "a")
        #expect(try store.tags(of: [id]) == [id: [StoredTag(extensionID: "b", tag: "two")]])
    }
}

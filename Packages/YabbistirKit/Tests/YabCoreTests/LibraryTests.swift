import Foundation
import Testing
@testable import YabCore

@MainActor @Suite struct LibraryTests {
    @Test func deletingFromHistoryUpdatesIndexAndNotifies() throws {
        let library = try Library(store: ItemStore.temporary())
        var changes = 0
        library.onChange = { changes += 1 }
        let item = try #require(try library.store.ingest(textClip("sil", at: t0))).item
        library.didIngest(item)
        try library.deleteFromHistory(item.id!)
        #expect(library.index.search("", limit: 10).ids.isEmpty)
        #expect(changes == 2)
    }

    @Test func toggleAddsThenRemovesMembership() throws {
        let library = try Library(store: ItemStore.temporary())
        let cat = try library.createCategory(name: "Kod")
        let item = try #require(try library.store.ingest(textClip("x", at: t0))).item
        library.didIngest(item)
        try library.toggle(item.id!, inCategory: cat.id!)
        #expect(try library.store.itemIDs(inCategory: cat.id!) == [item.id!])
        try library.toggle(item.id!, inCategory: cat.id!)
        #expect(try library.store.itemIDs(inCategory: cat.id!).isEmpty)
    }

    @Test func richTextIsTextWithRTFOrHTML() throws {
        let library = try Library(store: ItemStore.temporary())
        func add(_ reps: [PasteboardRepresentation]) throws -> Int64 {
            let clip = CapturedClip(items: [reps], source: nil, device: .local, capturedAt: t0)
            let item = try #require(try library.store.ingest(clip)).item
            library.didIngest(item)
            return item.id!
        }
        let plain = PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data("merhaba".utf8))
        let rich = try add([plain, PasteboardRepresentation(type: "public.rtf", data: Data("{\\rtf1 merhaba}".utf8))])
        let onlyPlain = try add([PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data("düz".utf8))])
        let image = try add([PasteboardRepresentation(type: TypeIdentifiers.png, data: randomData(32)),
                             PasteboardRepresentation(type: "public.html", data: Data("<img>".utf8))])
        #expect(library.isRichText(rich))
        #expect(!library.isRichText(onlyPlain))
        #expect(!library.isRichText(image))
    }
}

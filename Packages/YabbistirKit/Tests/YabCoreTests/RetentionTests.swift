import Foundation
import Testing
@testable import YabCore

private let day: TimeInterval = 86_400

@Suite struct RetentionTests {
    let now = t0

    @Test func usedWithinYearIsKept() throws {
        let store = try ItemStore.temporary()
        _ = try store.ingest(textClip("eski ama kullanılmış", at: now.addingTimeInterval(-364 * day)))
        #expect(try store.purgeExpired(policy: .oneYear, now: now).isEmpty)
        #expect(try store.history(limit: 10).count == 1)
    }

    @Test func unusedForMoreThanYearIsPurged() throws {
        let store = try ItemStore.temporary()
        let result = try #require(try store.ingest(textClip("unutulmuş", at: now.addingTimeInterval(-366 * day))))
        #expect(try store.purgeExpired(policy: .oneYear, now: now) == [result.item.id!])
        #expect(try store.history(limit: 10).isEmpty)
    }

    @Test func recopyRenews() throws {
        let store = try ItemStore.temporary()
        _ = try store.ingest(textClip("tekrar", at: now.addingTimeInterval(-400 * day)))
        _ = try store.ingest(textClip("tekrar", at: now.addingTimeInterval(-1 * day)))
        #expect(try store.purgeExpired(policy: .oneYear, now: now).isEmpty)
    }

    @Test func markUsedRenews() throws {
        let store = try ItemStore.temporary()
        let result = try #require(try store.ingest(textClip("yapıştırıldı", at: now.addingTimeInterval(-400 * day))))
        let usedAt = now.addingTimeInterval(-1 * day)
        try store.markUsed(result.item.id!, at: usedAt)
        #expect(try store.purgeExpired(policy: .oneYear, now: now).isEmpty)
        let item = try #require(try store.item(id: result.item.id!))
        #expect(item.lastUsedAt == usedAt)
        #expect(item.lastCopiedAt == usedAt)
    }

    @Test func categorizedNeverPurged() throws {
        let store = try ItemStore.temporary()
        let result = try #require(try store.ingest(textClip("SELECT 1;", at: now.addingTimeInterval(-3 * 365 * day))))
        let category = try store.createCategory(name: "SQL", color: .slate)
        #expect(category.visibility == .onSelect)
        try store.add(itemID: result.item.id!, toCategory: category.id!)
        #expect(try store.purgeExpired(policy: .oneYear, now: now).isEmpty)
    }

    @Test func unlimitedPurgesNothing() throws {
        let store = try ItemStore.temporary()
        _ = try store.ingest(textClip("çok eski", at: now.addingTimeInterval(-10 * 365 * day)))
        #expect(try store.purgeExpired(policy: .unlimited, now: now).isEmpty)
    }

    @Test func purgeCollectsBlobs() throws {
        let store = try ItemStore.temporary()
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.png, data: randomData(100 * 1024))]],
                                source: nil, device: .local, capturedAt: now.addingTimeInterval(-500 * day))
        _ = try store.ingest(clip)
        #expect(try store.purgeExpired(policy: .oneYear, now: now).count == 1)
        #expect(try blobFileCount(store) == 0)
    }

    @Test func defaultPolicyIsOneYear() {
        #expect(RetentionPolicy.default == .oneYear)
    }
}

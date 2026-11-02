import Foundation
import Testing
@testable import YabCore

func clipItem(_ id: Int64, _ text: String, kind: ItemKind = .text, device: DeviceKind = .local, minutesAgo: Double) -> ClipItem {
    let date = t0.addingTimeInterval(-minutesAgo * 60)
    return ClipItem(id: id, kind: kind, previewText: text, searchText: SearchNormalizer.normalize(text),
                    contentHash: "h\(id)", sourceBundleID: nil, sourceName: nil, device: device,
                    firstCopiedAt: date, lastCopiedAt: date, lastUsedAt: date)
}

@Suite struct HistoryIndexTests {
    let sample: [ClipItem] = [
        clipItem(1, "UPDATE users SET status", kind: .code, minutesAgo: 1),
        clipItem(2, "İade akışı demosu", minutesAgo: 9),
        clipItem(3, "1440×900 PNG", kind: .image, minutesAgo: 31),
        clipItem(4, "Kargo takip", device: .remote, minutesAgo: 130),
    ]

    @Test func emptyQueryReturnsRecencyOrder() {
        let index = HistoryIndex(items: sample.reversed())
        #expect(index.search("", limit: 10).ids == [1, 2, 3, 4])
    }

    @Test func substringMatchesNormalized() {
        #expect(HistoryIndex(items: sample).search("iade", limit: 10).ids == [2])
    }

    @Test func selDoesNotMatchImageViaTypeWord() {
        #expect(HistoryIndex(items: sample).search("sel", limit: 10).ids.contains(3) == false)
    }

    @Test func typeWordPrefixMatches() {
        #expect(HistoryIndex(items: sample).search("gör", limit: 10).ids == [3])
    }

    @Test func iphonePrefixMatchesRemote() {
        #expect(HistoryIndex(items: sample).search("iph", limit: 10).ids == [4])
    }

    @Test func extensionOutputsCanBeHidden() {
        var output = clipItem(5, "Çeviri sonucu", minutesAgo: 0)
        output.sourceBundleID = "dev.yabbistir.app"
        var index = HistoryIndex(items: sample + [output])
        #expect(index.search("", limit: 10).ids.contains(5))
        index.hidesExtensionOutputs = true
        let hidden = index.search("", limit: 10)
        #expect(!hidden.ids.contains(5))
        #expect(hidden.total == 4)
        #expect(index.filter([5, 1], query: "") == [5, 1])
        #expect(index.filter([5, 1], query: "çeviri") == [5])
        index.hidesExtensionOutputs = false
        #expect(index.search("", limit: 10).ids.contains(5))
    }

    @Test func upsertMovesToFront() {
        var index = HistoryIndex(items: sample)
        var bumped = sample[3]
        bumped.lastCopiedAt = t0
        index.upsert(bumped)
        #expect(index.search("", limit: 10).ids == [4, 1, 2, 3])
        #expect(index.count == 4)
    }

    @Test func removeDropsEntry() {
        var index = HistoryIndex(items: sample)
        index.remove(id: 2)
        #expect(index.search("", limit: 10).ids == [1, 3, 4])
    }

    @Test func limitIsRespected() {
        #expect(HistoryIndex(items: sample).search("", limit: 2).ids == [1, 2])
    }

    @Test func searchIsFastAt20k() {
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 8)
        let items = (0..<20_000).map { clipItem(Int64($0), filler + "\($0)", minutesAgo: Double($0)) }
        let index = HistoryIndex(items: items)
        let elapsed = ContinuousClock().measure { _ = index.search("zzzq", limit: 200).ids }
        #expect(elapsed < .milliseconds(16))
    }

    @Test func totalCountsEveryMatchBeyondTheLimit() {
        let index = HistoryIndex(items: (0..<300).map { clipItem(Int64($0), "eşleşme \($0)", minutesAgo: Double($0)) })
        let result = index.search("eşleşme", limit: 200)
        #expect(result.ids.count == 200)
        #expect(result.total == 300)
    }

    @Test func historySearchSkipsItemsKeptOnlyInACategory() {
        var hidden = clipItem(2, "gizli", minutesAgo: 2)
        hidden.inHistory = false
        let index = HistoryIndex(items: [clipItem(1, "açık", minutesAgo: 1), hidden])
        #expect(index.search("", limit: 10).ids == [1])
        #expect(index.filter([2, 1], query: "gizli") == [2])
    }
}

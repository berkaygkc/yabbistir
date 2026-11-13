import Foundation
import os
import Testing
import YabTestSupport
@testable import YabCore

@MainActor private final class IngestedLog {
    var previews: [String] = []
    /// Each completion's id, and how many items `onIngested` had reported by then.
    var heard: [(id: Int64?, reported: Int)] = []
}

@MainActor @Suite struct IngestQueueTests {
    @Test func ingestsOffMainAndReportsInCaptureOrderOnMain() async throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let ranOnMain = OSAllocatedUnfairLock(initialState: [Bool]())
        let log = IngestedLog()
        let queue = IngestQueue(ingest: { clip in
            ranOnMain.withLock { $0.append(Thread.isMainThread) }
            return try store.ingest(clip)
        }, onIngested: { item in log.previews.append(item.previewText) })

        for (offset, text) in ["bir", "iki", "üç"].enumerated() {
            queue.submit(textClip(text, at: t0.addingTimeInterval(Double(offset))))
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while log.previews.count < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(log.previews == ["bir", "iki", "üç"])
        #expect(ranOnMain.withLock { $0 } == [false, false, false])
    }

    /// A clip's own completion hears its stored item's id after `onIngested` (nil when nothing was kept).
    @Test func eachClipHearsItsStoredID() async throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let log = IngestedLog()
        let queue = IngestQueue(store: store) { item in log.previews.append(item.previewText) }
        queue.submit(textClip("bir")) { id in log.heard.append((id, log.previews.count)) }
        queue.submit(textClip("   ")) { id in log.heard.append((id, log.previews.count)) }
        queue.submit(textClip("iki"))
        queue.submit(textClip("bir", at: t0.addingTimeInterval(5))) { id in log.heard.append((id, log.previews.count)) }
        let deadline = ContinuousClock.now + .seconds(5)
        while log.heard.count < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let first = try #require(try store.history(limit: 10).first { $0.previewText == "bir" }?.id)
        #expect(log.heard.map(\.id) == [first, nil, first])
        #expect(log.heard.map(\.reported) == [1, 1, 3])
        #expect(log.previews == ["bir", "iki", "bir"])
    }
}

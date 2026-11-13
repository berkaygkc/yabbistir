import Foundation
import Testing
import YabTestSupport
@testable import YabCore

@Suite struct HistoryStorageTests {
    @Test func countsOnlyHistoryFiles() throws {
        let dir = TestScratch.url("yab-storage")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("Blobs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("Extensions"), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: dir.appendingPathComponent("db.sqlite"))
        try Data(count: 2000).write(to: dir.appendingPathComponent("Blobs/a"))
        try Data(count: 5000).write(to: dir.appendingPathComponent("Extensions/x"))
        let size = HistoryStorage.size(of: dir)
        #expect(size >= 3000)
        #expect(size < 8000)
    }

    @Test func compactingAfterClearingGivesTheSpaceBack() throws {
        let dir = TestScratch.url("yab-compact")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ItemStore(directory: dir)
        for index in 0..<150 {
            let text = "\(index) " + String(repeating: "ornek \(index) ", count: 4_000)
            _ = try store.ingest(textClip(text, at: t0))
        }
        let full = HistoryStorage.size(of: dir)
        _ = try store.clearHistory()
        let cleared = HistoryStorage.size(of: dir)
        try store.compact()
        let compacted = HistoryStorage.size(of: dir)
        #expect(full > 1_000_000)
        #expect(compacted < cleared / 2)
    }
}

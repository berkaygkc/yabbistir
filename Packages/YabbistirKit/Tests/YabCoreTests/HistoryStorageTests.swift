import Foundation
import Testing
@testable import YabCore

@Suite struct HistoryStorageTests {
    @Test func countsOnlyHistoryFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yab-storage-\(UUID().uuidString)")
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
}

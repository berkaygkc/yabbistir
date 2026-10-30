import CoreGraphics
import Foundation
import ImageIO
import Testing
import YabCore
import YabExtensionKit
@testable import YabExtensions

@Suite struct ResultFilesTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("yab-outputs-\(UUID().uuidString)")

    @Test func aFormatChangeKeepsTheNameAndChangesTheExtension() {
        #expect(ResultFiles.fileName(base: "Ekran Resmi", sourceSize: CGSize(width: 1324, height: 789), width: 1324, height: 789,
                                     uti: "public.jpeg") == "Ekran Resmi.jpeg")
        #expect(ResultFiles.fileName(base: "Ekran Resmi", sourceSize: nil, width: 10, height: 10, uti: "public.png") == "Ekran Resmi.png")
    }

    @Test func aNewSizeIsInTheName() {
        #expect(ResultFiles.fileName(base: "Ekran Resmi", sourceSize: CGSize(width: 1324, height: 789), width: 662, height: 395,
                                     uti: "public.png") == "Ekran Resmi 662×395.png")
    }

    @Test func slashesNeverMakeFolders() {
        #expect(ResultFiles.fileName(base: "a/b:c", sourceSize: nil, width: 1, height: 1, uti: "public.png") == "a-b-c.png")
        #expect(ResultFiles.fileName(base: "  ", sourceSize: nil, width: 1, height: 1, uti: "public.png", fallback: "Görsel") == "Görsel.png")
    }

    @Test func eachResultHasItsOwnFolder() throws {
        let files = ResultFiles(root: root)
        let first = try files.write(Data([1, 2, 3]), named: "Ekran Resmi.jpeg")
        let second = try files.write(Data([4, 5]), named: "Ekran Resmi.jpeg")
        #expect(first != second)
        #expect(first.lastPathComponent == "Ekran Resmi.jpeg")
        #expect(try Data(contentsOf: first) == Data([1, 2, 3]))
        #expect(try Data(contentsOf: second) == Data([4, 5]))
    }

    @Test func cleaningRemovesFilesNoItemPointsAt() throws {
        let files = ResultFiles(root: root)
        let kept = try files.write(Data([1]), named: "kept.png")
        let dropped = try files.write(Data([2]), named: "dropped.png")
        files.clean(keeping: [kept.absoluteString], before: Date().addingTimeInterval(60))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(!FileManager.default.fileExists(atPath: dropped.path))
        #expect(!FileManager.default.fileExists(atPath: dropped.deletingLastPathComponent().path))
    }

    /// A result written a moment ago may not be in history yet: cleaning leaves it alone.
    @Test func cleaningSparesFreshResults() throws {
        let files = ResultFiles(root: root)
        let fresh = try files.write(Data([1]), named: "fresh.png")
        files.clean(keeping: [], before: Date().addingTimeInterval(-60))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    /// The person asked for a JPEG: no PNG copy rides along for the target to prefer.
    @Test func aJPEGResultIsOnlyJPEG() throws {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let jpeg = NSMutableData()
        let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        let result = ExtensionResult.image(data: jpeg as Data, uti: "public.jpeg", width: 8, height: 8)
        #expect(ResultRepresentations.make(result).first?.map(\.type) == ["public.jpeg"])
        #expect(ItemClassifier.classify(ResultRepresentations.make(result))?.previewText == "8×8 JPEG")
        let file = try ResultFiles(root: root).write(jpeg as Data, named: "Ekran Resmi.jpeg")
        #expect(ResultRepresentations.make(result, file: file).first?.map(\.type) == ["public.jpeg", TypeIdentifiers.fileURL])
        #expect(ItemClassifier.classify(ResultRepresentations.make(result, file: file))?.previewText == "Ekran Resmi.jpeg")
    }

    @Test func anImageResultWithAFileIsAFileItem() throws {
        let file = try ResultFiles(root: root).write(Data([1]), named: "Ekran Resmi.jpeg")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let representations = ResultRepresentations.make(.image(data: png, uti: "public.png", width: 1, height: 1), file: file)
        #expect(representations.first?.map(\.type) == ["public.png", TypeIdentifiers.fileURL])
        #expect(representations.first?.last?.data == Data(file.absoluteString.utf8))
        #expect(ItemClassifier.classify(representations)?.kind == .file)
    }

    // MARK: Size limit

    private func result(_ id: Int64, bytes: Int, daysAgo: Int, inCategory: Bool = false) throws -> (itemID: Int64, url: URL, date: Date, inCategory: Bool) {
        let url = try ResultFiles(root: root).write(Data(count: bytes), named: "r\(id).bin")
        return (id, url, Date(timeIntervalSince1970: 1_000_000 - Double(daysAgo) * 86_400), inCategory)
    }

    /// Three files of "2 GB" each (2 KB here, the limit scaled to 5 KB): the oldest goes.
    @Test func outputsOverTheLimitLoseTheOldestFirst() throws {
        let items = [try result(2, bytes: 2048, daysAgo: 1), try result(1, bytes: 2048, daysAgo: 5), try result(3, bytes: 2048, daysAgo: 0)]
        #expect(ResultFiles.overLimit(bytes: 5 * 1024, items: items) == [1])
        // Removing one is not always enough.
        #expect(ResultFiles.overLimit(bytes: 3 * 1024, items: items) == [1, 2])
    }

    @Test func categorizedResultsAreKept() throws {
        let items = [try result(1, bytes: 2048, daysAgo: 5, inCategory: true), try result(2, bytes: 2048, daysAgo: 1),
                     try result(3, bytes: 2048, daysAgo: 0)]
        #expect(ResultFiles.overLimit(bytes: 5 * 1024, items: items) == [2])
        // Only categorized ones left over the limit: nothing can go.
        #expect(ResultFiles.overLimit(bytes: 1, items: [items[0]]).isEmpty)
    }

    @Test func underTheLimitNothingGoes() throws {
        let items = [try result(1, bytes: 2048, daysAgo: 5), try result(2, bytes: 2048, daysAgo: 1)]
        #expect(ResultFiles.overLimit(bytes: 4 * 1024, items: items).isEmpty)
        #expect(ResultFiles.overLimit(bytes: 1, items: []).isEmpty)
    }
}

@Suite struct ResultFileAdoptionTests {
    let outputs = FileManager.default.temporaryDirectory.appendingPathComponent("yab-outputs-\(UUID().uuidString)")
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("yab-work-\(UUID().uuidString)")

    /// A call's work folder with files in it, as the helper leaves it.
    func workFolder(_ files: [String: String]) throws -> URL {
        let folder = work.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files { try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return folder
    }

    @Test func filesWrittenByAnExtensionComeBack() throws {
        let folder = try workFolder(["not.txt": "merhaba"])
        let results = ResultFiles(root: outputs, workRoot: work)
        let adopted = try results.adopt([folder.appendingPathComponent("not.txt").path])
        let file = try #require(adopted.first)
        #expect(file.path.hasPrefix(outputs.resolvingSymlinksInPath().path) || file.path.hasPrefix(outputs.path))
        #expect(file.lastPathComponent == "not.txt")
        #expect(try String(contentsOf: file, encoding: .utf8) == "merhaba")
    }

    @Test func workFoldersAreRemoved() throws {
        let folder = try workFolder(["a.txt": "a", "b.txt": "b"])
        let results = ResultFiles(root: outputs, workRoot: work)
        let adopted = try results.adopt(["a.txt", "b.txt"].map { folder.appendingPathComponent($0).path })
        #expect(adopted.count == 2)
        #expect(Set(adopted.map(\.lastPathComponent)) == ["a.txt", "b.txt"])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// A move that fails half way leaves nothing behind: no result folder in Outputs, no work folder.
    @Test func aFailedAdoptionLeavesNoFilesBehind() throws {
        let folder = try workFolder(["a.txt": "a", "b.txt": "b"])
        final class Counter: @unchecked Sendable { let lock = NSLock(); var moves = 0 }
        let counter = Counter()
        let results = ResultFiles(root: outputs, workRoot: work) { from, to in
            let move = counter.lock.withLock { counter.moves += 1; return counter.moves }
            if move == 2 { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: from, to: to)
        }
        #expect(throws: ExtensionError.self) { try results.adopt(["a.txt", "b.txt"].map { folder.appendingPathComponent($0).path }) }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: outputs.path))?.isEmpty ?? true)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aPathOutsideTheWorkFolderIsNotAdopted() throws {
        let folder = try workFolder(["a.txt": "a"])
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("yab-out-\(UUID().uuidString).txt")
        try "x".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = folder.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let results = ResultFiles(root: outputs, workRoot: work)
        for paths in [[outside.path], [folder.appendingPathComponent("a.txt").path, outside.path], [link.path],
                      [folder.appendingPathComponent("../../../etc/hosts").path], []] {
            #expect(throws: ExtensionError.self) { try results.adopt(paths) }
        }
        // Nothing was moved by the refused attempts.
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.txt").path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func oldWorkFoldersArePurgedAtLaunch() throws {
        let old = try workFolder(["a.txt": "a"]), fresh = try workFolder(["b.txt": "b"])
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-25 * 3600), .modificationDate: Date().addingTimeInterval(-25 * 3600)],
                                              ofItemAtPath: old.path)
        WorkFolders.purge(olderThan: Date().addingTimeInterval(-24 * 3600), in: work)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func fileResultsBecomeFileItems() throws {
        let one = ResultRepresentations.make(.file(path: "/tmp/yab/not defteri.txt"))
        #expect(one.count == 1)
        #expect(one.first?.map(\.type) == [TypeIdentifiers.fileURL])
        #expect(ItemClassifier.classify(one)?.kind == .file)
        let two = ResultRepresentations.make(.files(paths: ["/tmp/yab/a.txt", "/tmp/yab/b.txt"]))
        #expect(two.count == 2)
        #expect(two.allSatisfy { ItemClassifier.classify([$0])?.kind == .file })
        #expect(ItemClassifier.classify(two)?.previewText == "a.txt, b.txt")
    }
}

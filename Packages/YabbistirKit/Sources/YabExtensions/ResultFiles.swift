import Foundation
import UniformTypeIdentifiers
import YabExtensionKit

/// Image results are also kept as files, so pasting into Finder drops a real file (images only). Each result has a folder of its own: names never clash, and
/// the file keeps the name the person sees in Finder.
public struct ResultFiles: Sendable {
    public let root: URL
    /// Where calls' work folders are (`WorkFolders.root`; tests give their own).
    public let workRoot: URL

    /// How a file moves (tests make it fail).
    let move: @Sendable (URL, URL) throws -> Void

    public init(root: URL, workRoot: URL = WorkFolders.root) {
        self.init(root: root, workRoot: workRoot) { try FileManager.default.moveItem(at: $0, to: $1) }
    }

    init(root: URL, workRoot: URL, move: @escaping @Sendable (URL, URL) throws -> Void) {
        self.root = root
        self.workRoot = workRoot
        self.move = move
    }

    /// Takes the files a call left in its work folder: each moves into a result folder of its own
    /// (`Outputs/<uuid>/`) under the name it had, and the work folder goes. Nothing moves unless every
    /// path is a file inside a work folder (links and `..` resolved first).
    public func adopt(_ paths: [String]) throws(ExtensionError) -> [URL] {
        guard !paths.isEmpty else { throw ExtensionError(.badResult, "there are no files to adopt") }
        guard let base = WorkFolders.realPath(workRoot.path) else { throw ExtensionError(.badResult, "the work folder is gone") }
        var sources: [URL] = []
        var folders: Set<String> = []
        for path in paths {
            var isDirectory: ObjCBool = false
            guard let real = WorkFolders.contained(path, in: workRoot),
                  FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let first = real.dropFirst(base.count + 1).split(separator: "/").first, real.dropFirst(base.count + 1).contains("/")
            else { throw ExtensionError(.badResult, "a result file must be a file in a work folder") }
            sources.append(URL(fileURLWithPath: real))
            folders.insert(String(first))
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var adopted: [URL] = []
            for source in sources {
                var target = folder.appendingPathComponent(source.lastPathComponent)
                // Two files with one name (from different subfolders) keep both.
                var number = 2
                while FileManager.default.fileExists(atPath: target.path) {
                    let name = source.deletingPathExtension().lastPathComponent, ext = source.pathExtension
                    target = folder.appendingPathComponent("\(name) \(number)" + (ext.isEmpty ? "" : "." + ext))
                    number += 1
                }
                try move(source, target)
                adopted.append(target)
            }
            for name in folders { try? FileManager.default.removeItem(at: URL(fileURLWithPath: base).appendingPathComponent(name)) }
            return adopted
        } catch {
            // Half done is worse than not done: nothing stays in Outputs, and the work folders go too.
            try? FileManager.default.removeItem(at: folder)
            for name in folders { try? FileManager.default.removeItem(at: URL(fileURLWithPath: base).appendingPathComponent(name)) }
            throw ExtensionError(.unavailable, "the result files could not be kept: \(error.localizedDescription)")
        }
    }

    /// The subject's name with the new format's extension ("Ekran Resmi.jpeg"); the pixel size
    /// joins it when it changed ("Ekran Resmi 662×395.png").
    public static func fileName(base: String, sourceSize: CGSize?, width: Int, height: Int, uti: String,
                                fallback: String = "Image") -> String {
        var name = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = fallback }
        if let sourceSize, Int(sourceSize.width) != width || Int(sourceSize.height) != height { name += " \(width)×\(height)" }
        return name + "." + (UTType(uti)?.preferredFilenameExtension ?? "img")
    }

    public func write(_ data: Data, named name: String) throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try data.write(to: file, options: .atomic)
        return file
    }

    /// The result items to drop so the files fit `bytes`: the oldest first, never one that is in a
    /// category, until what is left is at most the limit. Sizes are the files' own (what Finder shows).
    /// Pure apart from reading sizes; it deletes nothing.
    public static func overLimit(bytes limit: Int64, items: [(itemID: Int64, url: URL, date: Date, inCategory: Bool)]) -> [Int64] {
        let sized = items.map { item in
            (item: item, size: Int64((try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
        var total = sized.reduce(Int64(0)) { $0 + $1.size }
        var chosen: [Int64] = []
        for entry in sized.sorted(by: { $0.item.date < $1.item.date }) where total > limit && !entry.item.inCategory {
            chosen.append(entry.item.itemID)
            total -= entry.size
        }
        return chosen
    }

    /// Removes the result folders made before `cutoff` that no history item points at any more
    /// (`referenced`: file URLs). Newer ones may still be on their way into history.
    public func clean(keeping referenced: Set<String>, before cutoff: Date) {
        let kept = Set(referenced.compactMap { URL(string: $0)?.resolvingSymlinksInPath().deletingLastPathComponent().path })
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders where !kept.contains(folder.resolvingSymlinksInPath().path) {
            guard let created = try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate, created < cutoff else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

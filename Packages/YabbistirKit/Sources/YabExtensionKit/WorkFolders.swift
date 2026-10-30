import Foundation

/// Where a call's work folder lives (`yab.files`): `<temporary folder>/yabbistir-work/<uuid>/`.
/// The app and its helper run as the same user, unsandboxed, so they share one temporary folder: the
/// helper makes the folder and the app adopts what a call left in it (`ResultFiles.adopt`).
public enum WorkFolders {
    public static var root: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("yabbistir-work", isDirectory: true)
    }

    /// A new, empty work folder.
    public static func make(in root: URL = WorkFolders.root) throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The real path of `path` (links and `..` resolved) when it exists and lies inside `folder`; nil otherwise.
    public static func contained(_ path: String, in folder: URL) -> String? {
        guard let real = realPath(path), let base = realPath(folder.path) else { return nil }
        return real.hasPrefix(base.hasSuffix("/") ? base : base + "/") ? real : nil
    }

    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Removes the work folders made before `cutoff` (left by a crash or a quit mid-call); the app calls it
    /// at launch with the launch time, before any helper runs.
    public static func purge(olderThan cutoff: Date, in root: URL = WorkFolders.root) {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders {
            guard let created = try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate, created < cutoff else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Removes the work folders that hold `paths`: only folders directly under `root` (links and `..` resolved
    /// first); a path elsewhere is left alone.
    public static func remove(holding paths: [String], in root: URL = WorkFolders.root) {
        guard let base = realPath(root.path) else { return }
        for path in paths {
            guard let real = contained(path, in: root),
                  let first = real.dropFirst(base.count + 1).split(separator: "/").first else { continue }
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: base).appendingPathComponent(String(first)))
        }
    }
}

import Foundation

/// How much disk space History uses: the database files and the blobs, not the extensions' folders.
public enum HistoryStorage {
    /// The size of `db.sqlite`, its `-wal` and `-shm` files and everything under `Blobs/`.
    public static func size(of directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        func fileSize(_ url: URL) -> Int64 {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return 0 }
            return Int64(values.fileSize ?? 0)
        }
        var total: Int64 = 0
        for name in ["db.sqlite", "db.sqlite-wal", "db.sqlite-shm"] {
            total += fileSize(directory.appendingPathComponent(name))
        }
        let blobs = directory.appendingPathComponent("Blobs", isDirectory: true)
        if let files = FileManager.default.enumerator(at: blobs, includingPropertiesForKeys: Array(keys)) {
            for case let url as URL in files { total += fileSize(url) }
        }
        return total
    }
}

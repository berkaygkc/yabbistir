import CryptoKit
import Foundation

/// Content-addressed storage for large representations: `<dir>/<first 2 hex>/<sha256>`.
/// Identical payloads are written once.
struct BlobStore: Sendable {
    let directory: URL

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func url(for hash: String) -> URL {
        directory.appendingPathComponent(String(hash.prefix(2)), isDirectory: true).appendingPathComponent(hash)
    }

    /// Writes `data` under its precomputed SHA-256 `hash` unless the file already exists.
    func write(_ data: Data, hash: String) throws {
        let target = url(for: hash)
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
    }

    func read(_ hash: String) throws -> Data {
        try Data(contentsOf: url(for: hash))
    }

    func allHashes() throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map(\.lastPathComponent)
    }

    func remove(_ hash: String) throws {
        let target = url(for: hash)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }
}

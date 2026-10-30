import Foundation
import GRDB
import YabCore

public enum PasteImportError: Error, Equatable {
    case unknownFormat
    case missingExternalData(String)
}

/// Decodes Paste's `ZITEMDATAENTITY.ZRAWPASTEBOARDITEMS`:
/// a Core Data storage marker (0x01 inline, 0x02 external UUID), then an optionally
/// LZFSE-compressed binary plist of `[{types, dataByType}]`, one entry per pasteboard item.
public enum PasteBlobDecoder {
    public static func decode(_ data: Data, externalDataDirectory: URL?) throws -> [[PasteboardRepresentation]] {
        guard let marker = data.first else { throw PasteImportError.unknownFormat }
        let body = Data(data.dropFirst())
        let payload: Data
        switch marker {
        case 0x01:
            payload = body
        case 0x02:
            let name = String(decoding: body, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            guard let directory = externalDataDirectory,
                  let file = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
                throw PasteImportError.missingExternalData(name)
            }
            payload = file
        default:
            throw PasteImportError.unknownFormat
        }
        return try items(from: try propertyList(from: payload))
    }

    /// Counts decodable records in a Paste database copy without exposing any content.
    public static func countDecodable(databasePath: String, externalDataDirectory: URL?) throws -> (decoded: Int, failed: Int) {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: databasePath, configuration: configuration)
        let blobs = try queue.read { db in
            try Data.fetchAll(db, sql: "SELECT ZRAWPASTEBOARDITEMS FROM ZITEMDATAENTITY WHERE ZRAWPASTEBOARDITEMS IS NOT NULL")
        }
        let decoded = blobs.filter { (try? decode($0, externalDataDirectory: externalDataDirectory)) != nil }.count
        return (decoded, blobs.count - decoded)
    }

    private static func propertyList(from payload: Data) throws -> Any {
        let plistData: Data
        if payload.starts(with: Array("bplist".utf8)) {
            plistData = payload
        } else if let inflated = try? (payload as NSData).decompressed(using: .lzfse) as Data {
            plistData = inflated
        } else {
            throw PasteImportError.unknownFormat
        }
        guard let object = try? PropertyListSerialization.propertyList(from: plistData, format: nil) else {
            throw PasteImportError.unknownFormat
        }
        return object
    }

    private static func items(from object: Any) throws -> [[PasteboardRepresentation]] {
        guard let entries = object as? [[String: Any]] else { throw PasteImportError.unknownFormat }
        return entries.map { entry in
            let dataByType = entry["dataByType"] as? [String: Data] ?? [:]
            let ordered = entry["types"] as? [String] ?? []
            // Original order first, then any types the order list left out.
            let types = ordered + dataByType.keys.filter { !ordered.contains($0) }.sorted()
            return types.compactMap { type in dataByType[type].map { PasteboardRepresentation(type: type, data: $0) } }
        }
    }
}

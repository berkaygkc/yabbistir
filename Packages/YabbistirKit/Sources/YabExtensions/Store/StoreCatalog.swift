import Foundation
import YabExtensionKit
import YabLocalization
import YabPlatform

/// What the store publishes: the list of extensions and what the app needs to know before installing one.
public struct StoreCatalog: Decodable, Equatable, Sendable {
    /// The only catalog format this app reads.
    public static let supportedFormatVersion = 1

    public let formatVersion: Int
    public let generatedAt: Date
    public let extensions: [StoreEntry]

    /// Reads a catalog that has already been verified. A newer format is not read at all, because its shape is unknown.
    public static func decode(_ data: Data) throws(StoreCatalogError) -> StoreCatalog {
        struct Header: Decodable { let formatVersion: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw .malformed }
        guard header.formatVersion == supportedFormatVersion else { throw .needsNewerApp }
        do {
            return try decoder.decode(StoreCatalog.self, from: data)
        } catch {
            throw .malformed
        }
    }

    /// Timestamps are ISO 8601 with a time zone and without fractions of a second.
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = try? Date(text, strategy: .iso8601) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "\(text) is not an ISO 8601 time"))
            }
            return date
        }
        return decoder
    }
}

public enum StoreCatalogError: Error, Equatable, Sendable {
    /// The catalog is in a format a newer yabbistir understands.
    case needsNewerApp
    /// Not JSON, or not the shape the catalog schema describes.
    case malformed
}

public struct StoreEntry: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let version: String
    public let apiVersion: Int
    public let minAppVersion: String?
    public let name: [String: String]
    public let description: [String: String]
    public let author: String
    public let categories: [ExtensionCategory]
    /// `sf:<SF Symbol name>`, or the address of an icon file.
    public let icon: String
    public let permissions: [String]
    public let networkHosts: [String]
    public let tools: [String]
    /// Of the package, in lowercase hex.
    public let sha256: String
    public let size: Int
    public let updatedAt: Date
    public let readme: URL
    public let package: URL

    /// The name in the app's language, else English, else whichever comes first.
    public func localizedName(_ language: AppLanguage) -> String {
        name[language.rawValue] ?? name["en"] ?? name.sorted { $0.key < $1.key }.first?.value ?? id
    }

    /// The description, chosen the same way as the name.
    public func localizedDescription(_ language: AppLanguage) -> String {
        description[language.rawValue] ?? description["en"] ?? description.sorted { $0.key < $1.key }.first?.value ?? ""
    }
}

/// Whether this app can install a catalog entry. An incompatible extension is still listed.
public enum StoreCompatibility: Equatable, Sendable {
    case compatible
    case needsNewerApp(minimum: String)
    case unsupportedAPI(Int)
}

extension StoreEntry {
    public func compatibility(appVersion: SemanticVersion) -> StoreCompatibility {
        if !ManifestValidator.supportedAPIVersions.contains(apiVersion) { return .unsupportedAPI(apiVersion) }
        if let minAppVersion, let minimum = SemanticVersion(minAppVersion), minimum > appVersion {
            return .needsNewerApp(minimum: minAppVersion)
        }
        return .compatible
    }
}

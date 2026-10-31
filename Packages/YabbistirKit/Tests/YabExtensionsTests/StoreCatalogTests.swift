import Foundation
import Testing
import YabLocalization
import YabPlatform
@testable import YabExtensions

struct StoreCatalogTests {
    static func entryJSON(apiVersion: Int = 1, minAppVersion: String? = nil, name: String = #"{"en":"Base64","tr":"Base64 Çevirici"}"#) -> String {
        """
        {"id":"dev.example.base64","version":"1.2.0","apiVersion":\(apiVersion),"minAppVersion":\(minAppVersion.map { "\"\($0)\"" } ?? "null"),
         "name":\(name),"description":{"en":"Encode"},"author":"example","categories":["text","developer"],
         "icon":"sf:number","permissions":["network"],"networkHosts":["example.com"],"tools":[],
         "sha256":"\(String(repeating: "a", count: 64))","size":1234,"updatedAt":"2026-10-30T12:00:00+03:00",
         "readme":"https://example.com/readme","package":"https://example.com/p.yabext"}
        """
    }

    static func catalogJSON(format: Int = 1, entries: [String]) -> Data {
        Data(#"{"formatVersion":\#(format),"generatedAt":"2026-10-31T09:30:00Z","extensions":[\#(entries.joined(separator: ","))]}"#.utf8)
    }

    func entry(apiVersion: Int = 1, minAppVersion: String? = nil) throws -> StoreEntry {
        try StoreCatalog.decode(Self.catalogJSON(entries: [Self.entryJSON(apiVersion: apiVersion, minAppVersion: minAppVersion)])).extensions[0]
    }

    @Test func decodesTheStoreShape() throws {
        let catalog = try StoreCatalog.decode(Self.catalogJSON(entries: [Self.entryJSON()]))
        let entry = try #require(catalog.extensions.first)
        #expect(entry.id == "dev.example.base64")
        #expect(entry.categories == [.text, .developer])
        #expect(entry.minAppVersion == nil)
        #expect(entry.size == 1234)
        #expect(entry.package.absoluteString == "https://example.com/p.yabext")
        #expect(catalog.generatedAt == ISO8601DateFormatter().date(from: "2026-10-31T09:30:00Z"))
    }

    @Test func localizedNameFollowsTheAppLanguage() throws {
        let entry = try entry()
        #expect(entry.localizedName(.turkish) == "Base64 Çevirici")
        #expect(entry.localizedName(.english) == "Base64")
        let onlyEnglish = try StoreCatalog.decode(Self.catalogJSON(entries: [Self.entryJSON(name: #"{"en":"Only"}"#)])).extensions[0]
        #expect(onlyEnglish.localizedName(.turkish) == "Only")
        let noEnglish = try StoreCatalog.decode(Self.catalogJSON(entries: [Self.entryJSON(name: #"{"de":"Nur"}"#)])).extensions[0]
        #expect(noEnglish.localizedName(.turkish) == "Nur")
    }

    @Test func minAppVersionAboveTheAppIsNeedsNewerApp() throws {
        let app = try #require(SemanticVersion("0.2.0"))
        #expect(try entry(minAppVersion: "0.3.0").compatibility(appVersion: app) == .needsNewerApp(minimum: "0.3.0"))
        #expect(try entry(minAppVersion: "0.2.0").compatibility(appVersion: app) == .compatible)
        #expect(try entry(minAppVersion: nil).compatibility(appVersion: app) == .compatible)
    }

    @Test func anUnsupportedApiVersionIsFlagged() throws {
        let app = try #require(SemanticVersion("0.2.0"))
        #expect(try entry(apiVersion: 2).compatibility(appVersion: app) == .unsupportedAPI(2))
        #expect(try entry(apiVersion: 1).compatibility(appVersion: app) == .compatible)
    }

    @Test func anUnknownFormatVersionIsNotUsed() throws {
        let future = Self.catalogJSON(format: 2, entries: [])
        #expect(throws: StoreCatalogError.needsNewerApp) { try StoreCatalog.decode(future) }
        // A newer format may have a different shape; it still reads as "newer app needed", not as damage.
        #expect(throws: StoreCatalogError.needsNewerApp) { try StoreCatalog.decode(Data(#"{"formatVersion":2,"items":{}}"#.utf8)) }
        #expect(throws: StoreCatalogError.malformed) { try StoreCatalog.decode(Data("nope".utf8)) }
        #expect(throws: StoreCatalogError.malformed) { try StoreCatalog.decode(Data(#"{"formatVersion":1}"#.utf8)) }
    }
}

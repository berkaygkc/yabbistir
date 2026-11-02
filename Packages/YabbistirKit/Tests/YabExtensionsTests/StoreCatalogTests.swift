import Foundation
import Testing
import YabLocalization
import YabPlatform
@testable import YabExtensions

struct StoreCatalogTests {
    static func entryJSON(id: String = "dev.example.base64", apiVersion: Int = 1, minAppVersion: String? = nil,
                          name: String = #"{"en":"Base64","tr":"Base64 Çevirici"}"#, categories: String = #"["text","developer"]"#) -> String {
        """
        {"id":"\(id)","version":"1.2.0","apiVersion":\(apiVersion),"minAppVersion":\(minAppVersion.map { "\"\($0)\"" } ?? "null"),
         "name":\(name),"description":{"en":"Encode"},"author":"example","categories":\(categories),
         "icon":"sf:number","permissions":["network"],"networkHosts":["example.com"],"tools":[],
         "sha256":"\(String(repeating: "a", count: 64))","size":1234,"updatedAt":"2026-10-30T12:00:00+03:00",
         "readme":"https://example.com/readme","package":"https://example.com/p.yabext"}
        """
    }

    static func catalogJSON(format: Int = 1, generatedAt: String = "2026-10-31T09:30:00Z", entries: [String]) -> Data {
        Data(#"{"formatVersion":\#(format),"generatedAt":"\#(generatedAt)","extensions":[\#(entries.joined(separator: ","))]}"#.utf8)
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

    @Test func anUnparsableMinAppVersionIsIncompatible() throws {
        let app = try #require(SemanticVersion("99.0.0"))
        #expect(try entry(minAppVersion: "soon").compatibility(appVersion: app) == .needsNewerApp(minimum: "soon"))
        #expect(try entry(minAppVersion: "1.2").compatibility(appVersion: app) == .needsNewerApp(minimum: "1.2"))
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

    /// A category added to the store later is one this app does not know: the entry stays, without it.
    @Test func anUnknownCategoryDoesNotBreakTheCatalog() throws {
        let catalog = try StoreCatalog.decode(Self.catalogJSON(entries: [Self.entryJSON(categories: #"["text","holograms","developer"]"#)]))
        #expect(catalog.extensions.map(\.id) == ["dev.example.base64"])
        #expect(catalog.extensions.first?.categories == [.text, .developer])
        let onlyUnknown = try StoreCatalog.decode(Self.catalogJSON(entries: [Self.entryJSON(categories: #"["holograms"]"#)]))
        #expect(onlyUnknown.extensions.first?.categories == [])
    }

    /// An entry this app cannot read is left out; the rest of the catalog is still listed.
    @Test func oneBrokenEntryIsSkippedNotTheWholeCatalog() throws {
        let wrongType = Self.entryJSON(id: "dev.example.broken").replacingOccurrences(of: #""size":1234"#, with: #""size":"big""#)
        let half = #"{"id":"dev.example.half","version":"1.0.0"}"#
        let catalog = try StoreCatalog.decode(Self.catalogJSON(entries: [wrongType, Self.entryJSON(), half, "42"]))
        #expect(catalog.extensions.map(\.id) == ["dev.example.base64"])
        // The catalog itself must still have its shape.
        #expect(throws: StoreCatalogError.malformed) {
            try StoreCatalog.decode(Data(#"{"formatVersion":1,"generatedAt":"2026-10-31T09:30:00Z","extensions":{}}"#.utf8))
        }
    }

    /// Whether the extension has a sensitive source, for the consent sheet before the download; a catalog made before
    /// sources existed says nothing, which is false.
    @Test func theSensitiveFlagIsOptional() throws {
        #expect(try entry().sensitive == false)
        let sensitive = Self.entryJSON().replacingOccurrences(of: #""tools":[]"#, with: #""tools":[],"sensitive":true"#)
        #expect(try StoreCatalog.decode(Self.catalogJSON(entries: [sensitive])).extensions.first?.sensitive == true)
        let notSensitive = Self.entryJSON().replacingOccurrences(of: #""tools":[]"#, with: #""tools":[],"sensitive":false"#)
        #expect(try StoreCatalog.decode(Self.catalogJSON(entries: [notSensitive])).extensions.first?.sensitive == false)
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

import Foundation
import Testing
@testable import YabExtensionKit

@Suite struct LocalizationTests {
    let localization: ExtensionLocalization

    init() throws {
        localization = try ExtensionLocalization(folder: Fixture().root, defaultLocale: "en")
    }

    @Test func stringsFallBackToTheDefaultLocaleThenTheKey() {
        #expect(localization.string("decode.title", language: "tr") == "Çöz")
        #expect(localization.string("encode.title", language: "tr") == "Encode")
        #expect(localization.string("nowhere", language: "tr") == "nowhere")
    }

    @Test func keywordsJoinBothLocales() {
        #expect(localization.keywords("decode.keywords", language: "tr") == ["çöz", "decode", "b64"])
        #expect(localization.keywords("decode.keywords", language: "en") == ["decode", "b64"])
    }
}

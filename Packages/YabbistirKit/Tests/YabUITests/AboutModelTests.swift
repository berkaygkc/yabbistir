import Foundation
import Testing
import YabLocalization
import YabTestSupport
@testable import YabUI

@MainActor @Suite struct AboutModelTests {
    func make(language: AppLanguage = .english, read: @escaping (String) -> String? = { _ in nil },
              open: @escaping (URL) -> Void = { _ in }) -> AboutModel {
        let store = LanguageStore(defaults: TestScratch.defaults("yab-lang"), preferredLanguages: ["en"])
        store.language = language
        return AboutModel(version: "0.3.0", build: "3", language: store, checkForUpdates: {},
                          readNotice: read, openURL: open)
    }

    @Test func versionReadsInBothLanguages() {
        #expect(make(language: .turkish).versionText == "Sürüm 0.3.0 (3)")
        #expect(make(language: .english).versionText == "Version 0.3.0 (3)")
    }

    @Test func linksAreExact() {
        #expect(AboutModel.repository == URL(string: "https://github.com/berkaygkc/yabbistir"))
        #expect(AboutModel.releases == URL(string: "https://github.com/berkaygkc/yabbistir/releases"))
        #expect(AboutModel.sponsors == URL(string: "https://github.com/sponsors/berkaygkc"))
    }

    @Test func licensesJoinBothFiles() {
        #expect(make(read: { $0 == "LICENSE" ? "A" : "B" }).licensesText == "A\n\nB")
        #expect(make(read: { $0 == "LICENSE" ? nil : "B" }).licensesText == "B")
        #expect(make(read: { $0 == "LICENSE" ? "A" : nil }).licensesText == "A")
    }

    @Test func nothingOpensOnItsOwn() {
        var opened: [URL] = []
        let model = make(open: { opened.append($0) })
        _ = model.versionText
        _ = model.licensesText
        #expect(opened.isEmpty)
        model.open(AboutModel.repository)
        #expect(opened == [AboutModel.repository])
    }

    @Test func runningSetupAgainOnlyOpensIt() {
        let store = LanguageStore(defaults: TestScratch.defaults("yab-lang"), preferredLanguages: ["en"])
        var opened: [URL] = []
        var reruns = 0
        let model = AboutModel(version: "0.3.0", build: "3", language: store, checkForUpdates: {}, readNotice: { _ in nil },
                               openURL: { opened.append($0) }, rerunSetup: { reruns += 1 })
        #expect(reruns == 0)
        model.rerunSetup()
        #expect(reruns == 1 && opened.isEmpty)
    }
}

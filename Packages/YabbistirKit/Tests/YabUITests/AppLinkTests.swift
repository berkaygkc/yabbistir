import Foundation
import Testing
@testable import YabUI

/// `yabbistir://` links, as the website's Install buttons write them.
@Suite struct AppLinkTests {
    private func link(_ text: String) -> AppLink {
        AppLink(url: URL(string: text)!)
    }

    @Test func storeOpensTheStore() {
        #expect(link("yabbistir://store") == .store)
        #expect(link("yabbistir://store/") == .store)
        // Scheme and host are case-insensitive, as in any URL.
        #expect(link("YABBISTIR://Store") == .store)
        // A query on the bare store address asks for nothing more.
        #expect(link("yabbistir://store?id=dev.yabbistir.jwt") == .store)
    }

    @Test func installWithOneID() {
        #expect(link("yabbistir://store/install?id=dev.yabbistir.jwt") == .install(ids: ["dev.yabbistir.jwt"]))
        #expect(link("yabbistir://store/install/?id=dev.yabbistir.jwt") == .install(ids: ["dev.yabbistir.jwt"]))
        // A percent-encoded id is read as written.
        #expect(link("yabbistir://store/install?id=dev%2Eyabbistir%2Ejwt") == .install(ids: ["dev.yabbistir.jwt"]))
    }

    @Test func installWithSeveralIDsKeepsTheirOrder() {
        #expect(link("yabbistir://store/install?id=dev.yabbistir.secret-guard&id=dev.yabbistir.github")
            == .install(ids: ["dev.yabbistir.secret-guard", "dev.yabbistir.github"]))
        // Other query items are ignored.
        #expect(link("yabbistir://store/install?ref=site&id=dev.yabbistir.github&utm_source=x&id=dev.yabbistir.jwt")
            == .install(ids: ["dev.yabbistir.github", "dev.yabbistir.jwt"]))
    }

    @Test func aRepeatedIDCountsOnce() {
        #expect(link("yabbistir://store/install?id=dev.yabbistir.jwt&id=dev.yabbistir.github&id=dev.yabbistir.jwt")
            == .install(ids: ["dev.yabbistir.jwt", "dev.yabbistir.github"]))
    }

    @Test(arguments: [
        "", "jwt", ".", "..", "../etc", "dev..jwt", "dev.", ".dev.jwt", "Dev.Yabbistir.JWT", "dev.yabbistir.jwt/../x",
        "dev.yabbistir.j wt", "dev.yabbistir.jwt;rm", "dev.yabbistir.jwt%00", "dev.yabbistir.jwt\n", "dev.yabbistir.jwt+1",
        "dev.yabbistir._jwt", "dev.yabbistır.jwt", "dev.yabbistir." + String(repeating: "a", count: 130),
    ])
    func aMalformedIDIsIgnored(id: String) {
        var components = URLComponents(string: "yabbistir://store/install")!
        components.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "id", value: "dev.yabbistir.jwt")]
        #expect(AppLink(url: components.url!) == .install(ids: ["dev.yabbistir.jwt"]))
        // On its own it leaves nothing to install: the link only opens the Store.
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        #expect(AppLink(url: components.url!) == .store)
    }

    @Test func anIDOfTheLongestLengthIsKept() {
        let id = "dev.yabbistir." + String(repeating: "a", count: AppLink.maxIDLength - "dev.yabbistir.".count)
        #expect(id.count == AppLink.maxIDLength)
        #expect(link("yabbistir://store/install?id=\(id)") == .install(ids: [id]))
    }

    @Test func anEmptyQueryOnlyOpensTheStore() {
        #expect(link("yabbistir://store/install") == .store)
        #expect(link("yabbistir://store/install?") == .store)
        #expect(link("yabbistir://store/install?id") == .store)
        #expect(link("yabbistir://store/install?id=") == .store)
        #expect(link("yabbistir://store/install?ids=dev.yabbistir.jwt") == .store)
    }

    @Test func tooManyIDsKeepOnlyTheFirstOnes() {
        let ids = (1...30).map { "dev.example.e\($0)" }
        let url = "yabbistir://store/install?" + ids.map { "id=\($0)" }.joined(separator: "&")
        #expect(link(url) == .install(ids: Array(ids.prefix(AppLink.maxIDs))))
        #expect(AppLink.maxIDs == 20)
        // Repeats do not use up the limit.
        let repeated = "yabbistir://store/install?" + Array(repeating: "id=dev.example.same", count: 40).joined(separator: "&") + "&id=dev.example.last"
        #expect(link(repeated) == .install(ids: ["dev.example.same", "dev.example.last"]))
    }

    @Test(arguments: [
        "yabbistir://", "yabbistir:store", "yabbistir://settings", "yabbistir://stores/install?id=dev.yabbistir.jwt",
        "yabbistir://store/uninstall?id=dev.yabbistir.jwt", "yabbistir://store/install/now?id=dev.yabbistir.jwt",
        "yabbistir://store/INSTALL?id=dev.yabbistir.jwt", "yabbistir://user@store/install?id=dev.yabbistir.jwt",
        "yabbistir://store:80/install?id=dev.yabbistir.jwt", "https://store/install?id=dev.yabbistir.jwt",
        "file:///Users/someone/notes.txt", "yabbistir://panel",
    ])
    func anyOtherAddressOnlyBringsTheAppForward(text: String) {
        #expect(link(text) == .other)
    }
}

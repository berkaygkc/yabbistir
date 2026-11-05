import Foundation
import Testing
import YabExtensionKit
import YabExtensions
import YabLocalization
@testable import YabUI

/// The website's Install buttons: `yabbistir://store/install?id=…` opens the Store, waits for the catalog and shows the
/// consent sheet of Install (N). Nothing is installed until it is confirmed.
@MainActor @Suite(.serialized) struct StoreLinkTests {
    typealias F = StoreFixture

    static let newer = StoreFixture.Entry(id: "dev.example.qr", minApp: "9.0.0", name: ["en": "QR Code", "tr": "QR Kod"],
                                          description: ["en": "Turns copied text into a QR code image."], categories: ["images"])

    /// Waits until no refresh or install is under way; a link may start a second refresh when the first ends.
    func settle(_ model: StoreModel) async {
        while let task = model.refreshTask ?? model.installTask { await task.value }
    }

    // MARK: Offering

    @Test func aLinkWaitsForTheTabAndTheCatalogThenAsks() async throws {
        let fixture = StoreFixture()
        try fixture.serve([F.video, F.jwt, F.translate])
        let model = fixture.model()
        model.offer([F.jwt.id])
        // Nothing happens before the tab is on screen: no request, no sheet.
        #expect(fixture.requests.isEmpty)
        #expect(model.pendingConsent == nil)
        #expect(model.pendingLinkIDs == [F.jwt.id])
        model.appeared()
        // The sheet waits for the store's answer.
        #expect(model.refreshTask != nil)
        #expect(model.pendingConsent == nil)
        await settle(model)
        let consent = try #require(model.pendingConsent)
        #expect(consent.kind == .install)
        #expect(consent.items.map(\.id) == [F.jwt.id])
        #expect(model.selection == [F.jwt.id])
        #expect(model.pendingLinkIDs == nil)
        #expect(model.linkNotice == nil)
        #expect(model.revealID == F.jwt.id)
        // One look at the store, and nothing downloaded or installed by the link itself.
        #expect(fixture.catalogRequests == 1)
        #expect(fixture.packageRequests == 0)
        #expect(!fixture.registry.installed.contains { $0.id == F.jwt.id })
    }

    @Test func severalIDsShareTheSameSheetAsInstallN() async throws {
        let fixture = StoreFixture()
        try fixture.serve([F.video, F.linkClean, F.jwt])
        let model = fixture.model()
        model.appeared()
        await settle(model)
        model.offer([F.video.id, F.linkClean.id])
        let fromLink = try #require(model.pendingConsent)
        // Picking the same two by hand gives the same sheet.
        model.cancelConsent()
        model.selection = []
        model.setSelected(F.video.id, true)
        model.setSelected(F.linkClean.id, true)
        model.installSelected()
        let byHand = try #require(model.pendingConsent)
        #expect(fromLink.items.map(\.id) == byHand.items.map(\.id))
        #expect(fromLink.items.map(\.sentences) == byHand.items.map(\.sentences))
        #expect(fromLink.kind == byHand.kind)
        #expect(fixture.catalogRequests == 1)
    }

    @Test func confirmingInstallsAndCancellingDoesNot() async throws {
        let fixture = StoreFixture()
        try fixture.serve([F.video, F.jwt], packaged: [F.video, F.jwt])
        let model = fixture.model()
        model.appeared()
        await settle(model)
        model.offer([F.video.id])
        model.cancelConsent()
        #expect(model.installTask == nil)
        #expect(fixture.packageRequests == 0)
        #expect(!fixture.registry.installed.contains { $0.id == F.video.id })

        model.offer([F.jwt.id])
        model.confirmConsent()
        await settle(model)
        #expect(model.failures.isEmpty)
        #expect(fixture.registry.installed.contains { $0.id == F.jwt.id })
        #expect(model.row(F.jwt.id)?.statusLabel == "Installed")
    }

    @Test func aLinkReplacesThePicksAndClearsTheSearch() async throws {
        let fixture = StoreFixture()
        try fixture.serve([F.video, F.linkClean, F.jwt])
        let model = fixture.model()
        model.appeared()
        await settle(model)
        model.setSelected(F.video.id, true)
        model.query = "video"
        model.category = .files
        model.offer([F.jwt.id])
        #expect(model.query.isEmpty)
        #expect(model.category == nil)
        #expect(model.selection == [F.jwt.id])
        #expect(model.pendingConsent?.items.map(\.id) == [F.jwt.id])
        #expect(model.rows.contains { $0.id == F.jwt.id })
    }

    // MARK: Already here, or not offered

    @Test func anInstalledExtensionIsNotOfferedAgain() async throws {
        let fixture = StoreFixture()
        try fixture.installLocally(F.jwt)
        try fixture.serve([F.video, F.jwt])
        let model = fixture.model()
        model.appeared()
        await settle(model)
        model.offer([F.jwt.id])
        #expect(model.pendingConsent == nil)
        #expect(model.selection.isEmpty)
        #expect(model.linkNotice == StoreModel.Notice(symbol: "checkmark.circle", text: "The extension from the link is already installed."))
        // Its row is the one brought into view.
        #expect(model.revealID == F.jwt.id)
        // Beside one that can be installed, only that one is in the sheet.
        model.offer([F.jwt.id, F.video.id])
        #expect(model.pendingConsent?.items.map(\.id) == [F.video.id])
        #expect(model.linkNotice == nil)
        #expect(model.revealID == F.video.id)
        // A newer link closes that sheet unanswered, and nothing is installed.
        model.offer([F.jwt.id])
        #expect(model.pendingConsent == nil)
        #expect(model.installTask == nil)
        #expect(model.linkNotice?.text == "The extension from the link is already installed.")
        #expect(fixture.catalogRequests == 1)
        #expect(fixture.packageRequests == 0)
    }

    /// A link that comes while Update All's sheet is open takes its place; the updates wait for another Update All.
    @Test func aLinkReplacesASheetStillOpen() async throws {
        let fixture = StoreFixture()
        var olderJWT = F.jwt
        olderJWT.version = "0.9.0"
        olderJWT.permissions = []
        try fixture.installLocally(olderJWT)
        var jwt = F.jwt
        jwt.permissions = ["network"]
        try fixture.serve([F.video, jwt])
        let model = fixture.model()
        model.appeared()
        await settle(model)
        model.updateAll()
        #expect(model.pendingConsent?.kind == .update)
        model.offer([F.video.id])
        #expect(model.pendingConsent?.kind == .install)
        #expect(model.pendingConsent?.items.map(\.id) == [F.video.id])
        #expect(fixture.packageRequests == 0)
    }

    @Test func anUnknownIDSaysItIsNotInTheStore() async throws {
        let fixture = StoreFixture()
        try fixture.serve([F.video])
        let model = fixture.model()
        model.offer(["dev.example.nowhere"])
        model.appeared()
        await settle(model)
        #expect(model.pendingConsent == nil)
        #expect(model.linkNotice == StoreModel.Notice(symbol: "link", text: "The extension from the link isn’t in the store."))
        // The check the tab made anyway answered the link: no second request.
        #expect(fixture.catalogRequests == 1)
        fixture.languageStore.language = .turkish
        #expect(model.linkNotice?.text == "Linkteki uzantı mağazada yok.")
        model.offer(["dev.example.nowhere", "dev.example.elsewhere"])
        await settle(model)
        #expect(model.linkNotice?.text == "Linkteki uzantılar mağazada yok.")
    }

    @Test func partOfALinkThatIsNotInTheStoreIsNamedBesideTheSheet() async throws {
        let fixture = StoreFixture()
        try fixture.serve([F.video, F.jwt])
        let model = fixture.model()
        model.appeared()
        await settle(model)
        model.offer(["dev.example.nowhere", F.jwt.id])
        await settle(model)
        #expect(model.pendingConsent?.items.map(\.id) == [F.jwt.id])
        #expect(model.linkNotice?.text == "Some extensions from the link aren’t in the store.")
    }

    @Test func anExtensionThatNeedsANewerAppIsNotOffered() async throws {
        let fixture = StoreFixture()
        try fixture.serve([F.jwt, Self.newer])
        let model = fixture.model()
        model.appeared()
        await settle(model)
        model.offer([Self.newer.id])
        #expect(model.pendingConsent == nil)
        #expect(model.linkNotice == StoreModel.Notice(symbol: "arrow.up.circle", text: "The extension from the link needs a newer yabbistir."))
        model.offer([Self.newer.id, F.jwt.id])
        #expect(model.pendingConsent?.items.map(\.id) == [F.jwt.id])
        #expect(model.linkNotice?.text == "Some extensions from the link need a newer yabbistir.")
    }

    @Test func whatKeepsALinkOutOfTheSheet() {
        typealias S = StoreModel.LinkShortfall
        #expect(StoreModel.shortfall(requested: 1, listed: [.notInstalled]) == nil)
        #expect(StoreModel.shortfall(requested: 1, listed: []) == S.missing(.one))
        #expect(StoreModel.shortfall(requested: 2, listed: []) == S.missing(.all))
        #expect(StoreModel.shortfall(requested: 2, listed: [.installed]) == S.missing(.part))
        #expect(StoreModel.shortfall(requested: 1, listed: [.builtIn]) == S.installed(.one))
        #expect(StoreModel.shortfall(requested: 2, listed: [.installed, .updateAvailable(from: "0.9.0")]) == S.installed(.all))
        #expect(StoreModel.shortfall(requested: 2, listed: [.installed, .notInstalled]) == nil)
        #expect(StoreModel.shortfall(requested: 2, listed: [.incompatible(.needsNewerApp(minimum: "9.0.0")), .incompatible(.unsupportedAPI(9))])
            == S.incompatible(.all))
        #expect(StoreModel.shortfall(requested: 2, listed: [.installed, .incompatible(.needsNewerApp(minimum: "9.0.0"))]) == S.incompatible(.part))
    }

    // MARK: The catalog

    /// The website can list an extension the saved list does not have yet: the store is checked once more.
    @Test func aLinkNewerThanTheListChecksTheStoreOnce() async throws {
        let fixture = StoreFixture()
        try fixture.serve([F.video])
        let model = fixture.model()
        model.appeared()
        await settle(model)
        #expect(fixture.catalogRequests == 1)
        try fixture.serve([F.video, F.jwt])
        model.offer([F.jwt.id])
        await settle(model)
        #expect(fixture.catalogRequests == 2)
        #expect(model.pendingConsent?.items.map(\.id) == [F.jwt.id])
        // Still unknown after that check: said once, with no further requests.
        model.cancelConsent()
        model.offer(["dev.example.nowhere"])
        await settle(model)
        #expect(fixture.catalogRequests == 3)
        #expect(model.linkNotice?.text == "The extension from the link isn’t in the store.")
        await settle(model)
        #expect(fixture.catalogRequests == 3)
    }

    /// With no list at all, the tab says why and that the link waits; Try Again then shows the sheet.
    @Test func aStoreThatCannotBeReachedKeepsTheLinkForTryAgain() async throws {
        let fixture = StoreFixture(language: .turkish)
        fixture.serveOffline()
        let model = fixture.model()
        model.offer([F.jwt.id])
        model.appeared()
        await settle(model)
        #expect(model.unavailable?.title == "Mağazaya ulaşılamadı.")
        #expect(model.linkWaiting == "Linkteki uzantı mağazayı bekliyor.")
        #expect(model.pendingConsent == nil)
        fixture.languageStore.language = .english
        #expect(model.linkWaiting == "The extension from the link is waiting for the store.")
        try fixture.serve([F.jwt])
        model.refresh()
        await settle(model)
        #expect(model.unavailable == nil)
        #expect(model.linkWaiting == nil)
        #expect(model.pendingConsent?.items.map(\.id) == [F.jwt.id])
    }

    /// Over the saved list, an unreachable store answers the link from that list, beside the usual line.
    @Test func anUnreachableStoreAnswersFromTheSavedList() async throws {
        let fixture = StoreFixture()
        try fixture.serve([F.jwt])
        let first = fixture.model()
        first.appeared()
        await settle(first)
        fixture.serveOffline()
        let model = fixture.model()
        model.offer([F.jwt.id, F.video.id])
        model.appeared()
        await settle(model)
        #expect(model.pendingConsent?.items.map(\.id) == [F.jwt.id])
        #expect(model.notice?.text == "Couldn’t reach the store. Showing the saved list.")
        #expect(model.linkNotice?.text == "Some extensions from the link aren’t in the store.")
    }

    /// A link left waiting when Settings closed does not come back on its own the next time.
    @Test func aNewSessionForgetsAnUnansweredLink() async throws {
        let fixture = StoreFixture()
        fixture.serveOffline()
        let model = fixture.model()
        model.offer([F.jwt.id])
        model.appeared()
        await settle(model)
        #expect(model.linkWaiting != nil)
        try fixture.serve([F.jwt])
        model.beginSession()
        await settle(model)
        #expect(model.pendingLinkIDs == nil)
        #expect(model.linkWaiting == nil)
        #expect(model.pendingConsent == nil)
        #expect(model.rows.map(\.id) == [F.jwt.id])
    }

    /// A link that comes while extensions install is offered once they are done.
    @Test func aLinkDuringAnInstallWaitsForIt() async throws {
        let fixture = StoreFixture()
        try fixture.serve([F.video, F.jwt], packaged: [F.video, F.jwt])
        let model = fixture.model()
        model.appeared()
        await settle(model)
        model.setSelected(F.video.id, true)
        model.installSelected()
        model.confirmConsent()
        #expect(model.installTask != nil)
        model.offer([F.jwt.id])
        #expect(model.pendingConsent == nil)
        await settle(model)
        #expect(fixture.registry.installed.contains { $0.id == F.video.id })
        #expect(model.pendingConsent?.items.map(\.id) == [F.jwt.id])
    }

    // MARK: Routing

    @Test func aStoreLinkOpensTheStoreTab() async throws {
        let fixture = StoreFixture()
        let model = fixture.model()
        let navigation = SettingsNavigation()
        var shown = 0, forward = 0
        navigation.open(.store, store: model, showWindow: { shown += 1 }, bringForward: { forward += 1 })
        #expect(navigation.section == .extensions)
        #expect(navigation.extensionsTab == .store)
        #expect((shown, forward) == (1, 0))
        #expect(model.pendingLinkIDs == nil)
    }

    /// The ids reach the Store after the window is up, so a new Settings session never drops them.
    @Test func anInstallLinkOpensTheStoreThenOffers() async throws {
        let fixture = StoreFixture()
        let model = fixture.model()
        let navigation = SettingsNavigation()
        var idsWhenShown: [String]? = ["not shown"]
        navigation.open(.install(ids: [F.jwt.id, F.video.id]), store: model,
                        showWindow: { model.beginSession(); idsWhenShown = model.pendingLinkIDs }, bringForward: {})
        #expect(idsWhenShown == nil)
        #expect(model.pendingLinkIDs == [F.jwt.id, F.video.id])
        #expect(navigation.section == .extensions)
        #expect(navigation.extensionsTab == .store)
    }

    @Test func anyOtherLinkOnlyBringsTheAppForward() async throws {
        let fixture = StoreFixture()
        let model = fixture.model()
        let navigation = SettingsNavigation()
        navigation.section = .history
        var shown = 0, forward = 0
        navigation.open(.other, store: model, showWindow: { shown += 1 }, bringForward: { forward += 1 })
        #expect(navigation.section == .history)
        #expect(navigation.extensionsTab == .installed)
        #expect((shown, forward) == (0, 1))
        #expect(model.pendingLinkIDs == nil)
    }
}

import Foundation
import Testing
import YabLocalization
import YabPlatform
@testable import YabUI

@MainActor
final class FakeProbe: PermissionProbing {
    var accessibility = false
    var inputMonitoring = false
    var pasteboard: PasteboardAccess = .notAsked
    var loginItem: LoginItemStatus = .disabled
}

@MainActor @Suite struct PermissionsModelTests {
    func make(_ probe: FakeProbe, item: FakeLoginItem = FakeLoginItem(),
              open: @escaping (URL) -> Bool = { _ in true }) -> PermissionsModel {
        let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-lang-\(UUID().uuidString)")!, preferredLanguages: ["en"])
        return PermissionsModel(probe: probe, loginItem: item, language: language, openURL: open)
    }

    func card(_ model: PermissionsModel, _ kind: PermissionKind) -> PermissionCard? {
        model.cards.first { $0.kind == kind }
    }

    @Test func accessibilityIsRequired() {
        let probe = FakeProbe()
        let model = make(probe)
        #expect(card(model, .accessibility)?.state == .needed)
        probe.accessibility = true
        model.refresh()
        #expect(card(model, .accessibility)?.state == .granted)
    }

    @Test func inputMonitoringIsOptional() {
        let probe = FakeProbe()
        let model = make(probe)
        #expect(card(model, .inputMonitoring)?.state == .optional)
        probe.inputMonitoring = true
        model.refresh()
        #expect(card(model, .inputMonitoring)?.state == .granted)
    }

    @Test func pasteboardStates() {
        let probe = FakeProbe()
        let model = make(probe)
        #expect(card(model, .pasteboard)?.state == .granted)
        #expect(card(model, .pasteboard)?.statusKey == "settings.permissions.pasteboard.notAsked")
        probe.pasteboard = .allowed
        model.refresh()
        #expect(card(model, .pasteboard)?.state == .granted)
        #expect(card(model, .pasteboard)?.statusKey == "settings.permissions.granted")
        probe.pasteboard = .ask
        model.refresh()
        #expect(card(model, .pasteboard)?.state == .needed)
        #expect(card(model, .pasteboard)?.statusKey == "settings.permissions.pasteboard.ask")
        probe.pasteboard = .denied
        model.refresh()
        #expect(card(model, .pasteboard)?.state == .needed)
        #expect(card(model, .pasteboard)?.statusKey == "settings.permissions.pasteboard.denied")
    }

    @Test func loginItemCard() {
        let probe = FakeProbe()
        let model = make(probe)
        for (status, state) in [(LoginItemStatus.enabled, PermissionState.granted),
                                (.requiresApproval, .needed), (.disabled, .optional)] {
            probe.loginItem = status
            model.refresh()
            #expect(card(model, .loginItem)?.state == state)
        }
        probe.loginItem = .unavailable
        model.refresh()
        #expect(card(model, .loginItem) == nil)
        #expect(model.cards.count == 3)
    }

    @Test func refreshReadsTheProbeAgain() {
        let probe = FakeProbe()
        let model = make(probe)
        let before = model.cards
        probe.accessibility = true
        #expect(model.cards == before)
        model.refresh()
        #expect(model.cards != before)
    }

    @Test func everyCardIsTranslated() {
        let probe = FakeProbe()
        let model = make(probe)
        var keys = Set<String>()
        for access in [PasteboardAccess.notAsked, .ask, .allowed, .denied] {
            for state in [true, false] {
                probe.pasteboard = access
                probe.accessibility = state
                probe.inputMonitoring = state
                for status in [LoginItemStatus.enabled, .disabled, .requiresApproval] {
                    probe.loginItem = status
                    model.refresh()
                    for card in model.cards {
                        keys.formUnion([card.titleKey, card.purposeKey, card.stepsKey, card.statusKey])
                    }
                }
            }
        }
        #expect(keys.count == 18)
        for key in keys {
            for language in AppLanguage.allCases {
                #expect(L10n.string(key, language) != key, "\(key) has no \(language) text")
            }
        }
    }

    @Test func openingUsesTheRightPane() {
        var opened: [URL] = []
        let item = FakeLoginItem()
        let model = make(FakeProbe(), item: item, open: { opened.append($0); return true })
        model.open(.accessibility)
        model.open(.inputMonitoring)
        model.open(.pasteboard)
        model.open(.loginItem)
        #expect(opened == [SystemSettingsLink.accessibility, SystemSettingsLink.inputMonitoring, SystemSettingsLink.pasteboard])
        #expect(item.openedSystemSettings == 1)
    }

    @Test func pasteboardFallsBackToThePrivacyPane() {
        var opened: [URL] = []
        let model = make(FakeProbe(), open: { opened.append($0); return $0 == SystemSettingsLink.privacy })
        model.open(.pasteboard)
        #expect(opened == [SystemSettingsLink.pasteboard, SystemSettingsLink.privacy])
    }
}

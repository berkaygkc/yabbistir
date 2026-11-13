import Foundation
import Testing
import YabLocalization
import YabPlatform
import YabTestSupport
@testable import YabUI

@MainActor @Suite struct GeneralSettingsModelTests {
    func model(_ item: FakeLoginItem) -> GeneralSettingsModel {
        let preferences = Preferences(defaults: TestScratch.defaults("yab-prefs"))
        let language = LanguageStore(defaults: TestScratch.defaults("yab-lang"), preferredLanguages: ["en"])
        return GeneralSettingsModel(preferences: preferences, language: language, loginItem: item)
    }

    @Test func launchAtLoginShowsTheRealStatus() {
        let item = FakeLoginItem()
        item.statusAfterEnabling = .requiresApproval
        let general = model(item)
        general.setLaunchAtLogin(true)
        #expect(general.launchAtLogin)
        #expect(general.loginStatus == .requiresApproval)
        #expect(!general.loginFailed)

        let broken = FakeLoginItem()
        broken.throwsOnChange = true
        let failing = model(broken)
        failing.setLaunchAtLogin(true)
        #expect(!failing.launchAtLogin)
        #expect(failing.loginFailed)
    }

    @Test func turningItOffUnregisters() {
        let item = FakeLoginItem(status: .enabled)
        let general = model(item)
        #expect(general.launchAtLogin)
        general.setLaunchAtLogin(false)
        #expect(item.setEnabledCalls == [false])
        #expect(general.loginStatus == .disabled)
        #expect(!general.launchAtLogin)
    }

    @Test func unavailableHidesTheSwitch() {
        #expect(!model(FakeLoginItem(status: .unavailable)).showsLaunchAtLogin)
        #expect(model(FakeLoginItem(status: .disabled)).showsLaunchAtLogin)
    }

    @Test func refreshFollowsTheSystem() {
        let item = FakeLoginItem(status: .disabled)
        let general = model(item)
        item.status = .enabled
        general.refresh()
        #expect(general.launchAtLogin)
    }

    @Test func refreshClearsAStaleFailure() {
        let item = FakeLoginItem(status: .disabled)
        item.throwsOnChange = true
        let general = model(item)
        general.setLaunchAtLogin(true)
        #expect(general.loginFailed)
        item.status = .enabled
        general.refresh()
        #expect(!general.loginFailed)
    }
}

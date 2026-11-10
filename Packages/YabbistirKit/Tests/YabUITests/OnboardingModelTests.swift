import Foundation
import Testing
import YabCore
import YabImport
import YabImportTestSupport
import YabLocalization
import YabPlatform
@testable import YabUI

@MainActor
private final class Probe {
    var trusted = false
    var prompts = 0
    var finishes = 0
}

@MainActor
private struct Rig {
    let model: OnboardingModel
    let importer: ImportModel
    let preferences: Preferences
    let login: FakeLoginItem
    let probe: Probe
}

private func library() throws -> PasteLibraryLocation {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("onb-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try SyntheticPasteLibrary.make(in: folder, items: [
        .init(externalID: "h1", createdAt: 100, timestamp: 110, payload: .plain([[("public.utf8-plain-text", "one")]])),
    ], boards: [])
    return PasteLibraryLocation(folder: folder, vendor: nil)
}

@MainActor
private func rig(withLibrary: Bool, loginStatus: LoginItemStatus = .disabled) async throws -> Rig {
    let location = withLibrary ? try library() : nil
    let languages = LanguageStore(defaults: UserDefaults(suiteName: "yab-onb-\(UUID().uuidString)")!, preferredLanguages: ["en"])
    let importer = ImportModel(
        store: try ItemStore.temporary(), reload: {}, ignoredApps: { [] }, locate: { location },
        otherAppRunning: { false }, quitOtherApp: {}, language: languages)
    let preferences = Preferences(defaults: UserDefaults(suiteName: "yab-onb-p-\(UUID().uuidString)")!)
    let login = FakeLoginItem(status: loginStatus)
    let probe = Probe()
    let model = OnboardingModel(
        importer: importer, preferences: preferences, language: languages, loginItem: login,
        isTrusted: { probe.trusted }, promptAccessibility: { probe.prompts += 1 }, onFinish: { probe.finishes += 1 })
    await model.appear()
    return Rig(model: model, importer: importer, preferences: preferences, login: login, probe: probe)
}

@MainActor @Suite struct OnboardingModelTests {
    @Test func withoutALibraryTheImportStepsAreSkipped() async throws {
        let r = try await rig(withLibrary: false)
        #expect(r.model.step == .welcome && r.model.dots == 2 && !r.model.showsPasteHint)
        r.model.next()
        #expect(r.model.step == .setup)
        #expect(r.model.shortcutSubtitleKey == "onboarding.setup.shortcut.change")
    }

    @Test func withALibraryTheStepsRunInOrder() async throws {
        let r = try await rig(withLibrary: true)
        #expect(r.model.dots == 3 && r.model.showsPasteHint)
        #expect(r.model.shortcutSubtitleKey == "onboarding.setup.shortcut.fromPaste")
        r.model.next()
        #expect(r.model.step == .importChoice)
        r.model.next()
        #expect(r.model.step == .importing && r.model.activeDot == 1)
        #expect(!r.model.primaryEnabled)
        r.model.next()
        #expect(r.model.step == .importing)
        await r.importer.finished()
        #expect(r.model.primaryEnabled)
        r.model.next()
        #expect(r.model.step == .setup)
    }

    @Test func aFailedScanStillOffersTheImportStep() async throws {
        let r = try await rig(withLibrary: true)
        r.importer.state = .failed
        r.model.next()
        #expect(r.model.step == .importChoice)
    }

    @Test func finishingHappensOnce() async throws {
        let r = try await rig(withLibrary: false)
        r.model.next()
        r.model.escape()
        r.model.finish()
        #expect(r.probe.finishes == 1 && r.login.setEnabledCalls == [true])
    }

    @Test func importingStartsOnlyFromAReadyLibrary() async throws {
        let r = try await rig(withLibrary: true)
        r.model.next()
        #expect(r.model.step == .importChoice && r.model.primaryEnabled)
        for state in [ImportModel.State.scanning, .failed] {
            r.importer.state = state
            #expect(!r.model.primaryEnabled)
            r.model.next()
            #expect(r.model.step == .importChoice)
        }
    }

    @Test func importWaitsForSomethingChosen() async throws {
        let r = try await rig(withLibrary: true)
        r.model.next()
        r.importer.selection = PasteSelection(history: false, boards: [])
        #expect(!r.model.primaryEnabled)
        r.model.primary()
        #expect(r.model.step == .importChoice)
        r.importer.selection.history = true
        #expect(r.model.primaryEnabled)
    }

    @Test func aFailedImportStillLetsThePersonGoOn() async throws {
        let r = try await rig(withLibrary: true)
        r.model.next()
        r.model.next()
        await r.importer.finished()
        r.importer.state = .failed
        #expect(r.model.primaryEnabled)
        r.model.next()
        #expect(r.model.step == .setup)
    }

    /// Settings reads the library again on every visit, also while this step shows a finished import: Continue waits
    /// only for an import that is running.
    @Test func continueWaitsOnlyForARunningImport() async throws {
        let r = try await rig(withLibrary: true)
        r.model.next()
        r.model.next()
        await r.importer.finished()
        await r.importer.scan()
        #expect(r.model.step == .importing && r.model.primaryEnabled)
        r.model.primary()
        #expect(r.model.step == .setup)
    }

    @Test func returnPressesTheEnabledPrimaryOnly() async throws {
        let r = try await rig(withLibrary: true)
        r.model.primary()
        #expect(r.model.step == .importChoice)
        r.model.primary()
        #expect(r.model.step == .importing)
        // Still importing: Continue is disabled, so Return does nothing.
        if case .importing = r.importer.state { r.model.primary() }
        #expect(r.model.step == .importing)
        await r.importer.finished()
        r.model.primary()
        #expect(r.model.step == .setup && r.probe.finishes == 0)
        r.model.primary()
        #expect(r.probe.finishes == 1 && r.preferences.onboarded)
    }

    /// Run again from About while an earlier import still runs: Welcome leads to its progress, never to the choice.
    @Test func anImportStillRunningIsShownInsteadOfTheChoice() async throws {
        let r = try await rig(withLibrary: true)
        let running = ImportProgress(done: 5, total: 10, kinds: [:])
        r.importer.state = .importing(running)
        #expect(!r.model.showsPasteHint)
        r.model.primary()
        #expect(r.model.step == .importing && r.model.activeDot == 1)
        #expect(r.importer.state == .importing(running))
        #expect(!r.model.primaryEnabled)
    }

    @Test func aFinishedImportIsShownInsteadOfTheChoice() async throws {
        let r = try await rig(withLibrary: true)
        r.importer.state = .done(ImportReport())
        #expect(!r.model.showsPasteHint)
        r.model.next()
        #expect(r.model.step == .importing && r.model.primaryEnabled)
        r.model.primary()
        #expect(r.model.step == .setup)
    }

    @Test func skipGoesStraightToSetup() async throws {
        let r = try await rig(withLibrary: true)
        r.model.next()
        r.model.skipImport()
        #expect(r.model.step == .setup)
    }

    /// The first run, the switch left on: finishing registers the login item.
    @Test func finishMarksOnboardedRegistersLoginAndOpens() async throws {
        let r = try await rig(withLibrary: false)
        #expect(r.model.launchAtLogin && !r.preferences.onboarded)
        r.model.next()
        #expect(r.model.step == .setup)
        r.model.finish()
        #expect(r.preferences.onboarded)
        #expect(r.login.setEnabledCalls == [true])
        #expect(r.probe.finishes == 1)
    }

    @Test func aFailingLoginRegistrationDoesNotStopFinishing() async throws {
        let r = try await rig(withLibrary: false)
        r.login.throwsOnChange = true
        r.model.next()
        r.model.finish()
        #expect(r.login.setEnabledCalls == [true])
        #expect(r.preferences.onboarded && r.probe.finishes == 1)
    }

    @Test func turningLoginOffDoesNotRegister() async throws {
        let r = try await rig(withLibrary: false)
        r.model.next()
        r.model.launchAtLogin = false
        r.model.finish()
        #expect(r.login.setEnabledCalls.isEmpty && r.preferences.onboarded)
    }

    /// Run again with the app already opening at login: switching it off and finishing turns it off.
    @Test func aRerunCanTurnOpenAtLoginOff() async throws {
        let r = try await rig(withLibrary: false, loginStatus: .enabled)
        r.model.launchAtLogin = true
        r.model.next()
        r.model.launchAtLogin = false
        r.model.finish()
        #expect(r.login.setEnabledCalls == [false])
    }

    /// A switch that matches how the app already opens changes nothing.
    @Test func anUnchangedSwitchLeavesTheLoginItemAlone() async throws {
        for status in [LoginItemStatus.enabled, .requiresApproval] {
            let r = try await rig(withLibrary: false, loginStatus: status)
            r.model.next()
            r.model.finish()
            #expect(r.login.setEnabledCalls.isEmpty)
        }
    }

    /// Esc (or the close button) before the setup step: the person never saw the switch, so the login item stays as it is.
    @Test func escapeOnWelcomeLeavesTheLoginItemAlone() async throws {
        let r = try await rig(withLibrary: false)
        r.model.escape()
        #expect(r.preferences.onboarded && r.probe.finishes == 1)
        #expect(r.login.setEnabledCalls.isEmpty)
    }

    @Test func escapeOnTheSetupStepKeepsTheSwitch() async throws {
        let r = try await rig(withLibrary: true)
        r.model.next()
        r.model.skipImport()
        r.model.escape()
        #expect(r.preferences.onboarded && r.probe.finishes == 1)
        #expect(r.login.setEnabledCalls == [true])
    }

    @Test func accessibilityIsAskedAndThenSeen() async throws {
        let r = try await rig(withLibrary: false)
        #expect(!r.model.accessibilityGranted)
        r.model.requestAccessibility()
        #expect(r.probe.prompts == 1)
        r.probe.trusted = true
        r.model.refreshAccessibility()
        #expect(r.model.accessibilityGranted)
    }

    @Test func launchRule() {
        #expect(OnboardingModel.shouldShowAtLaunch(onboarded: false, historyIsEmpty: true, firstRunStarted: false))
        // Someone upgrading: a history and never a first run. They are marked onboarded without it.
        #expect(!OnboardingModel.shouldShowAtLaunch(onboarded: false, historyIsEmpty: false, firstRunStarted: false))
        // Quit midway through the first run, after copying something: it shows again.
        #expect(OnboardingModel.shouldShowAtLaunch(onboarded: false, historyIsEmpty: false, firstRunStarted: true))
        #expect(OnboardingModel.shouldShowAtLaunch(onboarded: false, historyIsEmpty: true, firstRunStarted: true))
        #expect(!OnboardingModel.shouldShowAtLaunch(onboarded: true, historyIsEmpty: true, firstRunStarted: true))
        #expect(!OnboardingModel.shouldShowAtLaunch(onboarded: true, historyIsEmpty: false, firstRunStarted: true))
    }

    /// The window showing is what counts as a started first run, before anything is finished.
    @Test func showingTheWindowMarksTheFirstRunStarted() async throws {
        let r = try await rig(withLibrary: false)
        #expect(r.preferences.firstRunStarted && !r.preferences.onboarded)
    }
}

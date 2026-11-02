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
private func rig(withLibrary: Bool) async throws -> Rig {
    let location = withLibrary ? try library() : nil
    let languages = LanguageStore(defaults: UserDefaults(suiteName: "yab-onb-\(UUID().uuidString)")!)
    let importer = ImportModel(
        store: try ItemStore.temporary(), reload: {}, ignoredApps: { [] }, locate: { location },
        otherAppRunning: { false }, quitOtherApp: {}, language: languages)
    let preferences = Preferences(defaults: UserDefaults(suiteName: "yab-onb-p-\(UUID().uuidString)")!)
    let login = FakeLoginItem()
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

    @Test func skipGoesStraightToSetup() async throws {
        let r = try await rig(withLibrary: true)
        r.model.next()
        r.model.skipImport()
        #expect(r.model.step == .setup)
    }

    @Test func finishMarksOnboardedRegistersLoginAndOpens() async throws {
        let r = try await rig(withLibrary: false)
        #expect(r.model.launchAtLogin && !r.preferences.onboarded)
        r.model.finish()
        #expect(r.preferences.onboarded)
        #expect(r.login.setEnabledCalls == [true])
        #expect(r.probe.finishes == 1)
    }

    @Test func aFailingLoginRegistrationDoesNotStopFinishing() async throws {
        let r = try await rig(withLibrary: false)
        r.login.throwsOnChange = true
        r.model.finish()
        #expect(r.preferences.onboarded && r.probe.finishes == 1)
    }

    @Test func turningLoginOffDoesNotRegister() async throws {
        let r = try await rig(withLibrary: false)
        r.model.launchAtLogin = false
        r.model.finish()
        #expect(r.login.setEnabledCalls.isEmpty && r.preferences.onboarded)
    }

    @Test func escapeFinishes() async throws {
        let r = try await rig(withLibrary: false)
        r.model.escape()
        #expect(r.preferences.onboarded && r.probe.finishes == 1 && r.login.setEnabledCalls == [true])
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
        #expect(OnboardingModel.shouldShowAtLaunch(onboarded: false, historyIsEmpty: true))
        #expect(!OnboardingModel.shouldShowAtLaunch(onboarded: false, historyIsEmpty: false))
        #expect(!OnboardingModel.shouldShowAtLaunch(onboarded: true, historyIsEmpty: true))
    }
}

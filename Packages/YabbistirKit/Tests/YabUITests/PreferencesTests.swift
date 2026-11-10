import Foundation
import Testing
import YabCore
import YabLocalization
import YabPasteboard
import YabPlatform
@testable import YabUI

@MainActor @Suite struct PreferencesTests {
    let defaults = UserDefaults(suiteName: "yab-prefs-\(UUID().uuidString)")!

    @Test func defaultsMatchTheSpec() {
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.appearance == .system)
        #expect(prefs.showsMenuBarIcon)
        #expect(prefs.hidesFromScreenSharing)
        #expect(prefs.panelPosition == .caret)
        #expect(prefs.previewDelay == .short)
        #expect(prefs.pasteDestination == .app)
        #expect(!prefs.alwaysPlainText)
        #expect(prefs.retention == .oneYear)
        #expect(prefs.ignoredApps == CaptureFilter.defaultIgnoredBundleIDs)
        #expect(prefs.keepsRemoteCopies)
        #expect(prefs.showsExtensionOutputs)
        #expect(!prefs.onboarded && !prefs.firstRunStarted)
    }

    @Test func valuesPersistUnderTheirKeys() {
        let prefs = Preferences(defaults: defaults)
        prefs.appearance = .dark
        prefs.showsMenuBarIcon = false
        prefs.hidesFromScreenSharing = false
        prefs.panelPosition = .pointer
        prefs.previewDelay = .long
        prefs.pasteDestination = .clipboard
        prefs.alwaysPlainText = true
        prefs.retention = .oneMonth
        prefs.ignoredApps = ["dev.example.app"]
        prefs.keepsRemoteCopies = false
        prefs.showsExtensionOutputs = false
        prefs.firstRunStarted = true

        let again = Preferences(defaults: defaults)
        #expect(again.appearance == .dark)
        #expect(!again.showsMenuBarIcon)
        #expect(!again.hidesFromScreenSharing)
        #expect(again.panelPosition == .pointer)
        #expect(again.previewDelay == .long)
        #expect(again.pasteDestination == .clipboard)
        #expect(again.alwaysPlainText)
        #expect(again.retention == .oneMonth)
        #expect(again.ignoredApps == ["dev.example.app"])
        #expect(!again.keepsRemoteCopies)
        #expect(!again.showsExtensionOutputs)
        #expect(again.firstRunStarted)
        #expect(defaults.object(forKey: "pref.firstRunStarted") as? Bool == true)
        #expect(defaults.string(forKey: "pref.retention") == "oneMonth")
        #expect(defaults.stringArray(forKey: "pref.ignoredApps") == ["dev.example.app"])
        #expect(defaults.string(forKey: "pref.appearance") == "dark")
        #expect(defaults.object(forKey: "pref.menuBarIcon") as? Bool == false)
        #expect(defaults.object(forKey: "pref.hideFromScreenSharing") as? Bool == false)
        #expect(defaults.string(forKey: "pref.panelPosition") == "pointer")
        #expect(defaults.string(forKey: "pref.previewDelay") == "long")
        #expect(defaults.string(forKey: "pref.pasteDestination") == "clipboard")
        #expect(defaults.object(forKey: "pref.alwaysPlainText") as? Bool == true)
        #expect(defaults.object(forKey: "pref.keepRemoteCopies") as? Bool == false)
        #expect(defaults.object(forKey: "pref.showExtensionOutputs") as? Bool == false)
    }

    @Test func aCorruptValueFallsBackToTheDefault() {
        defaults.set("sometimes", forKey: "pref.previewDelay")
        defaults.set("neon", forKey: "pref.appearance")
        #expect(Preferences(defaults: defaults).previewDelay == .short)
        #expect(Preferences(defaults: defaults).appearance == .system)
    }

    /// LanguageStore reads the onboarding flag by its key: someone onboarded before 0.6 keeps English, not the system's.
    @Test func anOnboardedPersonKeepsEnglishAfterTheUpdate() {
        Preferences(defaults: defaults).onboarded = true
        #expect(LanguageStore(defaults: defaults, preferredLanguages: ["de-DE"]).language == .english)
    }

    @Test func previewDelaysHaveTheirDurations() {
        #expect(PreviewDelay.short.duration == .milliseconds(100))
        #expect(PreviewDelay.medium.duration == .milliseconds(300))
        #expect(PreviewDelay.long.duration == .milliseconds(600))
    }
}

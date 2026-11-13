import AppKit
import Foundation
import Testing
import YabExtensionKit
import YabExtensions
import YabLocalization
import YabTestSupport
@testable import YabUI

@MainActor @Suite struct ExtensionsSettingsModelTests {
    static let builtIns = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Extensions/BuiltinExtensions")

    let root = TestScratch.url("yab-settings")
    let defaults = TestScratch.defaults("yab-settings")
    let settings: ExtensionSettings
    let model: ExtensionsSettingsModel

    init() {
        settings = ExtensionSettings(defaults: defaults)
        model = Self.model(root: root, settings: settings)
    }

    static func model(root: URL, settings: ExtensionSettings, toolLocator: ToolLocator = .standard) -> ExtensionsSettingsModel {
        let registry = ExtensionRegistry(builtInRoot: builtIns, userRoot: root.appendingPathComponent("Extensions"),
                                         dataRoot: root.appendingPathComponent("Data"), settings: settings)
        let language = LanguageStore(defaults: TestScratch.defaults("yab-settings-lang"), preferredLanguages: ["en"])
        language.language = .turkish
        return ExtensionsSettingsModel(registry: registry, settings: settings, language: language, logs: ExtensionLogBuffer(),
                                      toolLocator: toolLocator)
    }

    /// A copy of the UUID built-in under another id: a valid local extension.
    func sampleFolder(id: String = "dev.example.sample") throws -> URL {
        let folder = root.appendingPathComponent("source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.builtIns.appendingPathComponent("dev.yabbistir.uuid"), to: folder)
        let manifestURL = folder.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifest["id"] = id
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        return folder
    }

    @Test func builtInsAreListedFirstWithTheirSourceLabel() throws {
        model.installFolder(try sampleFolder())
        #expect(model.lastError == nil)
        let sources = model.rows.map(\.source)
        #expect(sources.first == .builtIn)
        #expect(sources.last == .local)
        #expect(sources.firstIndex(of: .local)! > sources.lastIndex(of: .builtIn)!)
        #expect(model.rows.first?.sourceLabel == "Yerleşik")
        #expect(model.rows.first { $0.id == "dev.yabbistir.uuid" }?.version == "1.0.0")
    }

    @Test func togglingPersists() {
        model.setEnabled("dev.yabbistir.uuid", false)
        #expect(model.rows.first { $0.id == "dev.yabbistir.uuid" }?.isEnabled == false)
        let again = Self.model(root: root, settings: ExtensionSettings(defaults: defaults))
        #expect(again.rows.first { $0.id == "dev.yabbistir.uuid" }?.isEnabled == false)
    }

    @Test func removingALocalExtensionDeletesIt() throws {
        model.installFolder(try sampleFolder())
        #expect(model.selectedID == "dev.example.sample")
        #expect(model.selected?.canRemove == true)
        #expect(model.rows.first { $0.id == "dev.yabbistir.uuid" }.map { model.detail(for: $0.id)?.canRemove } == false)
        model.remove("dev.example.sample")
        #expect(!model.rows.contains { $0.id == "dev.example.sample" })
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Extensions/dev.example.sample").path))
        #expect(model.selectedID == nil)
    }

    @Test func aBrokenFolderShowsItsProblemsAndInstallsNothing() throws {
        let folder = try sampleFolder(id: "Not An Id")
        let before = model.rows.map(\.id)
        model.installFolder(folder)
        #expect(model.rows.map(\.id) == before)
        let error = try #require(model.lastError)
        #expect(error.contains("id:"))
    }

    @Test func preferencesAreSaved() throws {
        model.selectedID = "dev.yabbistir.uuid"
        let preference = try #require(model.selected?.preferences.first)
        #expect(preference.id == "uppercase")
        #expect(preference.value == .bool(false))
        model.setPreference("dev.yabbistir.uuid", "uppercase", .bool(true))
        let manifest = try #require(model.registry.installed.first { $0.id == "dev.yabbistir.uuid" }?.manifest)
        #expect(settings.preferences("dev.yabbistir.uuid", specs: manifest.preferences)["uppercase"] == .bool(true))
        #expect(model.selected?.preferences.first?.value == .bool(true))
    }

    @Test func theDetailListsCommandsWithKeywords() {
        model.selectedID = "dev.yabbistir.uuid"
        #expect(model.selected?.commands.map(\.title) == ["UUID oluştur", "UUID oluştur (v7)"])
        #expect(model.selected?.commands.first?.keywords.contains("uuid") == true)
        #expect(model.selected?.description.isEmpty == false)
    }

    @Test func theLogKeepsTheLast200LinesPerExtension() {
        let logs = ExtensionLogBuffer()
        for index in 0..<250 { logs.append("a", "line \(index)") }
        logs.append("b", "other")
        #expect(logs.lines(for: "a").count == 200)
        #expect(logs.lines(for: "a").first == "line 50")
        #expect(logs.lines(for: "b") == ["other"])
        #expect(logs.entries.last?.extensionID == "b")
    }

    // MARK: Permissions

    /// A Video İndir-like synthetic extension: network and exec, two tools and a confirmed preference.
    func videoFolder(id: String = "dev.example.video") throws -> URL {
        let folder = try sampleFolder(id: id)
        let manifestURL = folder.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifest["permissions"] = ["network", "exec"]
        manifest["network"] = ["domains": ["video.example", "vid.example"]]
        manifest["requires"] = ["tools": [["name": "yt-dlp", "install": "brew install yt-dlp"],
                                          ["name": "ffmpeg", "install": "brew install ffmpeg"]]]
        manifest["preferences"] = [["id": "browserCookies", "type": "choice", "title": "cookies", "default": "off", "confirm": "cookies.confirm",
                                    "options": [["id": "off", "title": "off"], ["id": "safari", "title": "safari"]]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        for (language, confirm) in [("en", "Use your Safari cookies?"), ("tr", "Safari çerezleri kullanılsın mı?")] {
            let url = folder.appendingPathComponent("locales/\(language).json")
            var table = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            table["cookies"] = "Cookies"
            table["off"] = "Off"
            table["safari"] = "Safari"
            table["cookies.confirm"] = confirm
            try JSONSerialization.data(withJSONObject: table).write(to: url)
        }
        return folder
    }

    func emptyToolFolder() throws -> ToolLocator {
        let folder = root.appendingPathComponent("no-tools")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return ToolLocator(searchPath: [folder.path])
    }

    @Test func installingAnExtensionWithPermissionsAsksFirst() throws {
        model.installFolder(try videoFolder())
        #expect(model.lastError == nil)
        let request = try #require(model.pendingConsent)
        #expect(request.id == "dev.example.video")
        #expect(request.isNewInstall)
        let manifest = try #require(model.registry.installed.first { $0.id == request.id }?.manifest)
        #expect(request.sentences == ConsentText.sentences(for: manifest, source: .local, language: .turkish))
        #expect(!request.sentences.isEmpty)
        #expect(model.registry.installed.first { $0.id == request.id }?.isUsable == false)
        #expect(model.selected?.row.needsConsent == true)
        #expect(model.selected?.permissions == request.sentences)
    }

    @Test func anExtensionWithoutPermissionsInstallsWithoutAsking() throws {
        model.installFolder(try sampleFolder())
        #expect(model.pendingConsent == nil)
    }

    @Test func decliningANewInstallRemovesIt() throws {
        model.installFolder(try videoFolder())
        model.declineConsent()
        #expect(model.pendingConsent == nil)
        #expect(!model.rows.contains { $0.id == "dev.example.video" })
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Extensions/dev.example.video").path))
    }

    @Test func decliningAReviewKeepsTheExtensionWaiting() throws {
        model.installFolder(try videoFolder())
        model.pendingConsent = nil
        model.reviewPermissions("dev.example.video")
        #expect(model.pendingConsent?.isNewInstall == false)
        model.declineConsent()
        #expect(model.pendingConsent == nil)
        #expect(model.registry.installed.first { $0.id == "dev.example.video" }?.needsConsent == true)
    }

    @Test func approvingMakesItUsable() throws {
        model.installFolder(try videoFolder())
        model.approveConsent()
        #expect(model.pendingConsent == nil)
        let entry = try #require(model.registry.installed.first { $0.id == "dev.example.video" })
        #expect(entry.needsConsent == false)
        #expect(entry.isUsable)
        #expect(model.selected?.row.needsConsent == false)
        // The sentences stay listed once approved.
        #expect(model.selected?.permissions.isEmpty == false)
    }

    /// Approving records what the sheet showed, not what the manifest
    /// asks for by then. One that grew meanwhile keeps waiting until its new request is shown and approved.
    @Test func approvingRecordsOnlyWhatTheSheetShowed() throws {
        let folder = try videoFolder()
        model.linkFolder(folder)
        let shown = try #require(model.pendingConsent)
        // The developer adds a domain while the sheet is open.
        let manifestURL = folder.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifest["network"] = ["domains": ["video.example", "vid.example", "photos.example"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        model.registry.reload()
        #expect(model.pendingConsent == shown)

        model.approveConsent()
        #expect(model.pendingConsent == nil)
        #expect(Set(settings.grant("dev.example.video")?.domains ?? []) == ["video.example", "vid.example"])
        let waiting = try #require(model.registry.installed.first { $0.id == "dev.example.video" })
        #expect(waiting.needsConsent)
        #expect(!waiting.isUsable)

        // Shown again, with the new domain, and approved: usable.
        model.reviewPermissions("dev.example.video")
        #expect(model.pendingConsent?.sentences != shown.sentences)
        model.approveConsent()
        let usable = try #require(model.registry.installed.first { $0.id == "dev.example.video" })
        #expect(!usable.needsConsent)
        #expect(usable.isUsable)
    }

    @Test func linkingAnExtensionWithPermissionsAsksAndDecliningUnlinks() throws {
        let folder = try videoFolder()
        model.linkFolder(folder)
        #expect(model.pendingConsent?.isNewInstall == true)
        model.declineConsent()
        #expect(!model.rows.contains { $0.id == "dev.example.video" })
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path))
    }

    @Test func aMissingToolIsListedWithItsInstallCommand() throws {
        let model = Self.model(root: root, settings: settings, toolLocator: try emptyToolFolder())
        model.installFolder(try videoFolder())
        #expect(model.selected?.missingTools == [ToolSpec(name: "yt-dlp", install: "brew install yt-dlp"),
                                                 ToolSpec(name: "ffmpeg", install: "brew install ffmpeg")])
    }

    @Test func copyingAnInstallCommandUsesThePasteboardAndTellsTheApp() {
        var seen: [Int] = []
        model.onPasteboardWrite = { seen.append($0) }
        let saved = NSPasteboard.general.string(forType: .string)
        defer { NSPasteboard.general.clearContents(); if let saved { NSPasteboard.general.setString(saved, forType: .string) } }
        model.copy("brew install yt-dlp")
        #expect(NSPasteboard.general.string(forType: .string) == "brew install yt-dlp")
        #expect(seen == [NSPasteboard.general.changeCount])
    }

    @Test func aPreferenceWithConfirmAsksBeforeTurningOn() throws {
        model.installFolder(try videoFolder())
        model.approveConsent()
        model.setPreference("dev.example.video", "browserCookies", .string("safari"))
        let pending = try #require(model.pendingPreferenceConfirm)
        #expect(pending.id == "dev.example.video")
        #expect(pending.key == "browserCookies")
        #expect(pending.value == .string("safari"))
        #expect(pending.text == "Safari çerezleri kullanılsın mı?")
        #expect(model.selected?.preferences.first?.value == .string("off"))
        model.cancelPreference()
        #expect(model.pendingPreferenceConfirm == nil)
        #expect(model.selected?.preferences.first?.value == .string("off"))

        model.setPreference("dev.example.video", "browserCookies", .string("safari"))
        model.confirmPreference(try #require(model.pendingPreferenceConfirm))
        #expect(model.pendingPreferenceConfirm == nil)
        #expect(model.selected?.preferences.first?.value == .string("safari"))

        // Back to the default never asks.
        model.setPreference("dev.example.video", "browserCookies", .string("off"))
        #expect(model.pendingPreferenceConfirm == nil)
        #expect(model.selected?.preferences.first?.value == .string("off"))
    }

    @Test func theMasterSwitchTurnsOffLocalExtensions() throws {
        model.installFolder(try sampleFolder())
        #expect(model.rows.first { $0.id == "dev.example.sample" }?.isEnabled == true)
        model.thirdPartyDisabled = true
        #expect(model.thirdPartyDisabled)
        // No manual reload: the model reloads the registry itself.
        #expect(model.registry.installed.first { $0.id == "dev.example.sample" }?.isUsable == false)
        #expect(model.rows.first { $0.id == "dev.example.sample" }?.isEnabled == false)
        #expect(model.rows.first { $0.id == "dev.yabbistir.uuid" }?.isEnabled == true)
        #expect(model.registry.installed.first { $0.id == "dev.yabbistir.uuid" }?.isUsable == true)
        model.thirdPartyDisabled = false
        #expect(model.rows.first { $0.id == "dev.example.sample" }?.isEnabled == true)
    }

    @Test func confirmingStillSavesWhenTheDialogCancelledFirst() throws {
        model.installFolder(try videoFolder())
        model.approveConsent()
        model.setPreference("dev.example.video", "browserCookies", .string("safari"))
        let captured = try #require(model.pendingPreferenceConfirm)
        model.cancelPreference()
        model.confirmPreference(captured)
        #expect(model.selected?.preferences.first?.value == .string("safari"))
    }

    @Test func aWaitingExtensionCannotBeToggled() throws {
        model.installFolder(try videoFolder())
        #expect(model.rows.first { $0.id == "dev.example.video" }?.canToggle == false)
        model.approveConsent()
        #expect(model.rows.first { $0.id == "dev.example.video" }?.canToggle == true)
        #expect(model.rows.first { $0.id == "dev.yabbistir.uuid" }?.canToggle == true)
    }

    // MARK: Secret and folder preferences

    /// An extension with a secret and a folder preference, on an in-memory Keychain.
    func secretModel(store: InMemorySecretStore = InMemorySecretStore()) throws -> ExtensionsSettingsModel {
        let settings = ExtensionSettings(defaults: TestScratch.defaults("yab-secret-ui"), secrets: store)
        let model = Self.model(root: root, settings: settings)
        let folder = try sampleFolder(id: "dev.example.keys")
        let manifestURL = folder.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifest["preferences"] = [["id": "token", "type": "secret", "title": "uppercase"],
                                   ["id": "dir", "type": "folder", "title": "uppercase", "default": "~/Downloads"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        model.installFolder(folder)
        return model
    }

    @Test func aSecretIsStoredAndNeverReadBack() throws {
        let store = InMemorySecretStore()
        let model = try secretModel(store: store)
        model.selectedID = "dev.example.keys"
        let before = try #require(model.selected?.preferences.first { $0.id == "token" })
        #expect(!before.hasSecret)
        model.setSecret("dev.example.keys", "token", "sk-synthetic-1")
        #expect(store.read("dev.example.keys", "token") == "sk-synthetic-1")
        let after = try #require(model.selected?.preferences.first { $0.id == "token" })
        #expect(after.hasSecret)
        #expect(after.value == .null)
        model.setSecret("dev.example.keys", "token", nil)
        #expect(store.read("dev.example.keys", "token") == nil)
        #expect(model.selected?.preferences.first { $0.id == "token" }?.hasSecret == false)
    }

    @Test func savingASecretReloadsTheExtensions() throws {
        let model = try secretModel()
        var changes = 0
        model.registry.onChange = { changes += 1 }
        model.setSecret("dev.example.keys", "token", "sk-synthetic-1")
        model.setSecret("dev.example.keys", "token", nil)
        #expect(changes == 2)
    }

    @Test func onlyADeclaredSecretCanBeSet() throws {
        let store = InMemorySecretStore()
        let model = try secretModel(store: store)
        model.setSecret("dev.example.keys", "dir", "x")
        model.setSecret("dev.example.keys", "other", "x")
        model.setSecret("dev.nobody", "token", "x")
        #expect(store.accounts.isEmpty)
    }

    @Test func aFolderPreferenceCanBeChosenAndCleared() throws {
        let model = try secretModel()
        model.selectedID = "dev.example.keys"
        model.setFolder("dev.example.keys", "dir", "/tmp/chosen")
        let chosen = try #require(model.selected?.preferences.first { $0.id == "dir" })
        #expect(chosen.isChosen)
        #expect(chosen.value == .string("/tmp/chosen"))
        #expect(chosen.suggested == nil)
        // The generic path does not choose a folder.
        model.setPreference("dev.example.keys", "dir", .string("/tmp/typed"))
        #expect(model.selected?.preferences.first { $0.id == "dir" }?.value == .string("/tmp/chosen"))
        model.setFolder("dev.example.keys", "dir", nil)
        #expect(model.selected?.preferences.first { $0.id == "dir" }?.isChosen == false)
    }

    /// A folder's manifest default grants nothing, so it never looks chosen: the row
    /// says no folder is chosen and offers the default as a suggestion, with nothing to clear.
    @Test func anUnchosenFolderShowsItsDefaultOnlyAsASuggestion() throws {
        let model = try secretModel()
        model.selectedID = "dev.example.keys"
        let unset = try #require(model.selected?.preferences.first { $0.id == "dir" })
        #expect(!unset.isChosen)
        #expect(unset.value == .null)
        #expect(unset.suggested == "~/Downloads")
        model.setFolder("dev.example.keys", "dir", "/tmp/chosen")
        model.setFolder("dev.example.keys", "dir", nil)
        #expect(model.selected?.preferences.first { $0.id == "dir" }?.suggested == "~/Downloads")
    }

    @Test func theDetailListsCaptureRulesWithTheirSwitches() throws {
        let folder = try sampleFolder(id: "dev.example.rules")
        let manifestURL = folder.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifest["permissions"] = ["capture"]
        manifest["contributes"] = ["captureRules": [
            ["id": "tracking", "title": "tracking.title", "description": "tracking.description", "accepts": ["kinds": ["link"]]],
            ["id": "amp", "title": "amp.title", "accepts": ["kinds": ["link"]]],
        ]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        for language in ["en", "tr"] {
            let url = folder.appendingPathComponent("locales/\(language).json")
            var table = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            table["tracking.title"] = language == "tr" ? "İzleme parametrelerini sil" : "Remove tracking parameters"
            table["tracking.description"] = language == "tr" ? "utm_ ve benzerlerini atar." : "Drops utm_ and the like."
            table["amp.title"] = language == "tr" ? "AMP yerine asıl sayfa" : "The real page instead of AMP"
            try JSONSerialization.data(withJSONObject: table).write(to: url)
        }
        model.installFolder(folder)
        model.approveConsent()
        let rules = try #require(model.selected?.rules)
        #expect(rules == [.init(id: "tracking", title: "İzleme parametrelerini sil", description: "utm_ ve benzerlerini atar.", isEnabled: true),
                          .init(id: "amp", title: "AMP yerine asıl sayfa", description: nil, isEnabled: true)])
        model.setRuleEnabled("dev.example.rules", "amp", false)
        #expect(model.selected?.rules.map(\.isEnabled) == [true, false])
        #expect(!settings.isRuleEnabled("dev.example.rules", "amp"))
        // Gone with the extension.
        model.remove("dev.example.rules")
        #expect(settings.isRuleEnabled("dev.example.rules", "amp"))
        // Built-ins without rules show none.
        #expect(model.detail(for: "dev.yabbistir.uuid")?.rules == [])
    }

    @Test func theGenericPathRefusesASecretKey() throws {
        let store = InMemorySecretStore()
        let model = try secretModel(store: store)
        model.setPreference("dev.example.keys", "token", .string("sk-synthetic-1"))
        #expect(store.accounts.isEmpty)
        #expect(model.selected == nil || model.selected?.preferences.first { $0.id == "token" }?.value == .null)
    }
}

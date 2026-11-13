import Foundation
import Testing
import YabExtensionKit
import YabLocalization
import YabTestSupport
@testable import YabExtensions

@MainActor @Suite struct PermissionTests {
    let builtIn = RegistryFixture.temporary("BuiltinExtensions")
    let user = RegistryFixture.temporary("Extensions")
    let data = RegistryFixture.temporary("ExtensionData")
    let settings = ExtensionSettings(defaults: TestScratch.defaults("yab-perm"))

    func registry() -> ExtensionRegistry {
        ExtensionRegistry(builtInRoot: builtIn, userRoot: user, dataRoot: data, settings: settings)
    }

    func networkManifest(id: String, domains: [String]) -> [String: Any] {
        var manifest = RegistryFixture.manifest(id: id, permissions: ["network"])
        manifest["network"] = ["domains": domains]
        return manifest
    }

    @Test func anExtensionAskingForPermissionsWaitsForConsent() throws {
        let id = "dev.example.net"
        let source = try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: id, manifest: networkManifest(id: id, domains: ["video.example"]))
        let registry = registry()
        #expect(try registry.install(folder: source) == id)
        let entry = try #require(registry.installed.first { $0.id == id })
        #expect(entry.needsConsent)
        #expect(!entry.isUsable)
        #expect(entry.issues.isEmpty)
    }

    @Test func approvingTheExactSetMakesItUsable() throws {
        let id = "dev.example.net"
        let source = try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: id, manifest: networkManifest(id: id, domains: ["video.example"]))
        let registry = registry()
        try registry.install(folder: source)
        registry.approveRequested(id)
        let entry = try #require(registry.installed.first { $0.id == id })
        #expect(!entry.needsConsent)
        #expect(entry.isUsable)
        #expect(settings.grant(id) == PermissionGrant(permissions: ["network"], domains: ["video.example"], tools: []))
    }

    @Test func aDevelopmentEditThatAddsAPermissionStopsIt() throws {
        let id = "dev.example.dev"
        let folder = try RegistryFixture.write(in: RegistryFixture.temporary("dev"), id: id, manifest: networkManifest(id: id, domains: ["video.example"]))
        let registry = registry()
        try registry.linkDevelopmentFolder(folder)
        registry.approveRequested(id)
        let approved = try #require(registry.installed.first { $0.id == id })
        #expect(approved.isUsable)
        try JSONSerialization.data(withJSONObject: networkManifest(id: id, domains: ["video.example", "photos.example"]))
            .write(to: folder.appendingPathComponent("manifest.json"))
        registry.reload()
        let entry = try #require(registry.installed.first { $0.id == id })
        #expect(entry.needsConsent)
        #expect(!entry.isUsable)
    }

    @Test func narrowingPermissionsKeepsItUsable() throws {
        let id = "dev.example.dev"
        let folder = try RegistryFixture.write(in: RegistryFixture.temporary("dev"), id: id, manifest: networkManifest(id: id, domains: ["video.example", "vid.example"]))
        let registry = registry()
        try registry.linkDevelopmentFolder(folder)
        registry.approveRequested(id)
        try JSONSerialization.data(withJSONObject: networkManifest(id: id, domains: ["video.example"]))
            .write(to: folder.appendingPathComponent("manifest.json"))
        registry.reload()
        let entry = try #require(registry.installed.first { $0.id == id })
        #expect(!entry.needsConsent)
        #expect(entry.isUsable)
    }

    @Test func consentSentencesAreTurkish() throws {
        var manifest = RegistryFixture.manifest(id: "dev.example.dl", permissions: ["network", "exec"])
        manifest["network"] = ["domains": ["video.example", "vid.example"]]
        manifest["requires"] = ["tools": [["name": "yt-dlp", "install": "brew install yt-dlp"], ["name": "ffmpeg", "install": "brew install ffmpeg"]]]
        let folder = try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: "dev.example.dl", manifest: manifest)
        guard case .valid(let parsed, _) = ManifestValidator.validate(folder: folder) else { Issue.record("manifest is not valid"); return }
        #expect(ConsentText.sentences(for: parsed, source: .local, language: .turkish) == [
            "İnternete çıkabilir: video.example, vid.example",
            "Bilgisayarındaki şu programları çalıştırabilir: yt-dlp, ffmpeg. Bu programlar dosyalarına erişebilir ve internete çıkabilir.",
            "Yerel uzantılar imzasızdır.",
        ])
        #expect(ConsentText.sentences(for: parsed, source: .builtIn, language: .english).count == 2)
    }

    @Test func consentSaysCaptureAndHistory() throws {
        let folder = try RegistryFixture.write(in: RegistryFixture.temporary("src"), id: "dev.example.rules",
                                               manifest: RegistryFixture.manifest(id: "dev.example.rules", permissions: ["capture", "history"]))
        guard case .valid(let parsed, _) = ManifestValidator.validate(folder: folder) else { Issue.record("manifest is not valid"); return }
        let turkish = ConsentText.sentences(for: parsed, source: .builtIn, language: .turkish)
        #expect(turkish.contains("Her kopyanı görebilir"))
        #expect(turkish.contains("Geçmişinin tamamını okuyabilir"))
        let english = ConsentText.sentences(for: parsed, source: .builtIn, language: .english)
        #expect(english.contains("Can see everything you copy"))
        #expect(english.contains("Can read your whole history"))
    }

    /// A sensitive source is said in the app's own words, right after the programs that read it; the store's catalog
    /// flag says the same before the download.
    @Test func aSensitiveSourceAddsTheSecretSentence() throws {
        let folder = try SourceFixture.write(in: RegistryFixture.temporary("src"), id: "dev.example.vault", permissions: ["exec", "history"],
                                             tools: ["vault-cli"])
        guard case .valid(let parsed, _) = ManifestValidator.validate(folder: folder) else { Issue.record("manifest is not valid"); return }
        #expect(ConsentText.sentences(for: parsed, source: .local, language: .turkish) == [
            "Bilgisayarındaki şu programları çalıştırabilir: vault-cli. Bu programlar dosyalarına erişebilir ve internete çıkabilir.",
            "Şifre gibi gizli kayıtları okuyup yapıştırabilir. Bunlar geçmişe ve diske yazılmaz.",
            "Geçmişinin tamamını okuyabilir",
            "Yerel uzantılar imzasızdır.",
        ])
        #expect(ConsentText.sentences(permissions: ["exec"], domains: [], tools: ["vault-cli"], sensitive: true, language: .english) == [
            "Can run these programs on your Mac: vault-cli. They can read and write your files and reach the internet.",
            "Can read and paste secrets such as passwords. They’re never written to history or disk.",
        ])
        #expect(ConsentText.sentences(permissions: ["exec"], domains: [], tools: ["vault-cli"], language: .english).count == 1)
        let plain = try SourceFixture.write(in: RegistryFixture.temporary("src"), id: "dev.example.notes", permissions: ["exec"], tools: ["vault-cli"],
                                            sensitive: false)
        guard case .valid(let notes, _) = ManifestValidator.validate(folder: plain) else { Issue.record("manifest is not valid"); return }
        #expect(ConsentText.sentences(for: notes, source: .builtIn, language: .turkish).count == 1)
    }

    @Test func theMasterSwitchStopsThirdPartyExtensions() throws {
        try RegistryFixture.write(in: builtIn, id: "dev.yabbistir.a")
        try RegistryFixture.write(in: user, id: "dev.example.b")
        let registry = registry()
        #expect(!settings.thirdPartyDisabled)
        #expect(registry.installed.allSatisfy { $0.isUsable })
        settings.thirdPartyDisabled = true
        registry.reload()
        #expect(registry.installed.first { $0.source == .builtIn }?.isUsable == true)
        #expect(registry.installed.first { $0.source == .local }?.isUsable == false)
    }

    @Test func grantsCoverAndStaySortedAndUnique() {
        let a = PermissionGrant(permissions: ["network", "exec", "network"], domains: ["b.com", "a.com"], tools: [])
        #expect(a.permissions == ["exec", "network"])
        #expect(a.domains == ["a.com", "b.com"])
        #expect(a.covers(PermissionGrant(permissions: ["network"], domains: ["a.com"], tools: [])))
        #expect(!a.covers(PermissionGrant(permissions: [], domains: ["c.com"], tools: [])))
        #expect(PermissionGrant(permissions: [], domains: [], tools: []).isEmpty)
    }

    @Test func wideningToAnyWebsiteNeedsConsent() throws {
        let id = "dev.example.dev"
        let folder = try RegistryFixture.write(in: RegistryFixture.temporary("dev"), id: id, manifest: networkManifest(id: id, domains: ["video.example"]))
        let registry = registry()
        try registry.linkDevelopmentFolder(folder)
        registry.approveRequested(id)
        try JSONSerialization.data(withJSONObject: networkManifest(id: id, domains: []))
            .write(to: folder.appendingPathComponent("manifest.json"))
        registry.reload()
        let entry = try #require(registry.installed.first { $0.id == id })
        #expect(entry.needsConsent)
        #expect(!entry.isUsable)
    }

    @Test func anAnyWebsiteGrantCoversADomainList() {
        let any = PermissionGrant(permissions: ["network"], domains: [], tools: [])
        let listed = PermissionGrant(permissions: ["network"], domains: ["video.example"], tools: [])
        #expect(any.covers(listed))
        #expect(any.covers(any))
        #expect(!listed.covers(any))
    }
}

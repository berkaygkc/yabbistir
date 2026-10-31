import AppKit
import CryptoKit
import SwiftUI
import Testing
import YabExtensionKit
import YabExtensions
import YabLocalization
@testable import YabUI

/// Renders Settings → Extensions → Store to PNG for visual review, from a synthetic catalog shaped like the store's
/// first extensions. Off by default; run with
/// `TEST_RUNNER_YAB_SNAPSHOT_DIR=/some/dir make test ONLY=YabUITests/StoreSnapshot`.
@MainActor @Suite(.serialized) struct StoreSnapshot {
    typealias F = StoreFixture

    static let qr = StoreFixture.Entry(id: "dev.example.qr", minApp: "9.0.0", name: ["en": "QR Code", "tr": "QR Kod"],
                                       description: ["en": "Turns copied text into a QR code image.", "tr": "Kopyalanan metni QR kod görseline çevirir."],
                                       categories: ["images"], icon: "sf:qrcode")

    var dir: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"]!) }

    static let appearances: [(String, NSAppearance.Name)] = [("dark", .darkAqua), ("light", .aqua)]

    func render<V: View>(_ view: V, size: NSSize?, name: String, appearance: NSAppearance.Name) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let fitted = size ?? host.fittingSize
        host.frame = NSRect(origin: .zero, size: fitted)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: fitted), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
        }
    }

    func settings(_ fixture: StoreFixture) -> ExtensionsSettingsModel {
        ExtensionsSettingsModel(registry: fixture.registry, settings: fixture.settings, language: fixture.languageStore, logs: ExtensionLogBuffer())
    }

    /// Every row state at once: two picked (one whose download failed), an update, one installed, one that needs a
    /// newer yabbistir. Then the same list when the store cannot be reached, and the sheet for the two picked.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderList() async throws {
        for language in [AppLanguage.english, .turkish] {
            let fixture = StoreFixture(language: language)
            try fixture.installLocally(F.jwt)
            var olderLink = F.linkClean
            olderLink.version = "0.9.0"
            try fixture.installLocally(olderLink)
            // The translation package is missing, so its install fails on its row.
            try fixture.serve([F.video, F.linkClean, F.translate, F.jwt, Self.qr], packaged: [F.video])
            let model = fixture.model()
            model.appeared()
            await model.refreshTask?.value
            model.setSelected(F.translate.id, true)
            model.installSelected()
            model.confirmConsent()
            await model.installTask?.value
            model.setSelected(F.video.id, true)
            let settings = settings(fixture)
            for (scheme, appearance) in Self.appearances {
                render(ExtensionsSettingsView(model: settings, store: model, tab: .store).frame(width: 660, height: 560),
                       size: NSSize(width: 660, height: 560), name: "store-list-\(scheme)-\(language.rawValue).png", appearance: appearance)
            }
            if language == .turkish {
                render(ExtensionsSettingsView(model: settings, store: model, tab: .store).frame(width: 560, height: 520),
                       size: NSSize(width: 560, height: 520), name: "store-list-narrow-dark-tr.png", appearance: .darkAqua)
            }

            model.installSelected()
            let consent = try #require(model.pendingConsent)
            model.cancelConsent()
            for (scheme, appearance) in Self.appearances {
                render(StoreConsentSheet(consent: consent, language: language, onConfirm: {}, onCancel: {}), size: nil,
                       name: "store-consent-install-\(scheme)-\(language.rawValue).png", appearance: appearance)
            }

            fixture.serveOffline()
            model.refresh()
            await model.refreshTask?.value
            for (scheme, appearance) in Self.appearances {
                render(ExtensionsSettingsView(model: settings, store: model, tab: .store).frame(width: 660, height: 560),
                       size: NSSize(width: 660, height: 560), name: "store-offline-\(scheme)-\(language.rawValue).png", appearance: appearance)
            }
        }
    }

    /// Update All with one update that asks for more (a new site and a new program) and one that does not.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderUpdateConsent() async throws {
        for (language, scheme, appearance) in [(AppLanguage.english, "dark", NSAppearance.Name.darkAqua), (.turkish, "light", .aqua)] {
            let fixture = StoreFixture(language: language)
            var olderVideo = F.video
            olderVideo.version = "0.9.0"
            olderVideo.hosts = Array(F.video.hosts.prefix(2))
            olderVideo.tools = Array(F.video.tools.prefix(2))
            var olderJWT = F.jwt
            olderJWT.version = "0.9.0"
            try fixture.installLocally(olderVideo)
            try fixture.installLocally(olderJWT)
            try fixture.serve([F.video, F.jwt, F.translate])
            let model = fixture.model()
            model.appeared()
            await model.refreshTask?.value
            model.updateAll()
            let consent = try #require(model.pendingConsent)
            render(StoreConsentSheet(consent: consent, language: language, onConfirm: {}, onCancel: {}), size: nil,
                   name: "store-consent-update-\(scheme)-\(language.rawValue).png", appearance: appearance)
        }
    }

    /// No saved catalog and one that is not signed by a known key: what the store shows until its keys ship.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderUnverified() async throws {
        for (language, scheme, appearance) in [(AppLanguage.turkish, "dark", NSAppearance.Name.darkAqua), (.english, "light", .aqua)] {
            let fixture = StoreFixture(language: language)
            let catalog = try fixture.catalog([F.video])
            let stranger = Curve25519.Signing.PrivateKey()
            StoreTabMockProtocol.serve(host: fixture.host, [
                "/v1/catalog.json": .success(catalog),
                "/v1/catalog.json.sig": .success(Data(try stranger.signature(for: catalog).base64EncodedString().utf8)),
            ])
            let model = fixture.model()
            model.appeared()
            await model.refreshTask?.value
            render(ExtensionsSettingsView(model: settings(fixture), store: model, tab: .store).frame(width: 660, height: 560),
                   size: NSSize(width: 660, height: 560), name: "store-unverified-\(scheme)-\(language.rawValue).png", appearance: appearance)
        }
    }
}

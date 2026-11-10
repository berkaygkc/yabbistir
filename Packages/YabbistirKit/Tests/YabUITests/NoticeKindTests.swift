import AppKit
import Foundation
import SwiftUI
import Testing
import YabLocalization
@testable import YabUI

@Suite struct NoticeKindTests {
    @Test func aFailedExtensionSaysWhichAndWhy() {
        let kind = NoticeKind.extensionFailed(name: "Base64", message: "line 3: boom")
        #expect(kind.titleText(.turkish) == "Uzantı hata verdi")
        #expect(kind.bodyText(.turkish) == "Base64: line 3: boom")
        #expect(!kind.offersSettings)
    }

    @Test func aDisabledExtensionIsNamed() {
        #expect(NoticeKind.extensionDisabled(name: "Takılan").bodyText(.turkish) == "Takılan üst üste hata verdiği için kapatıldı.")
        #expect(NoticeKind.extensionDisabled(name: "Stuck").bodyText(.english) == "Stuck was turned off after repeated errors.")
    }

    /// An action that answers with only a message (`{none, message}`) says it calmly: the
    /// extension's name over its own words, not "Extension failed".
    @Test func anExtensionsMessageIsShownAsWritten() {
        let kind = NoticeKind.extensionMessage(name: "Video İndir", message: "Bu bağlantıda video yok.")
        #expect(kind.titleText(.turkish) == "Video İndir")
        #expect(kind.bodyText(.turkish) == "Bu bağlantıda video yok.")
        #expect(kind.bodyText(.english) == "Bu bağlantıda video yok.")
        #expect(!kind.offersSettings)
    }

    @Test func permissionNoticesStillOfferSettings() {
        #expect(NoticeKind.accessibility.offersSettings)
        #expect(NoticeKind.inputMonitoring.offersSettings)
        #expect(!NoticeKind.copiedOnly.offersSettings)
        #expect(NoticeKind.accessibility.actionText(.english) == "Open Settings")
        #expect(NoticeKind.inputMonitoring.actionText(.turkish) == "Ayarları aç")
        #expect(NoticeKind.copiedOnly.actionText(.english) == nil)
        #expect(NoticeKind.extensionFailed(name: "Base64", message: "boom").actionText(.english) == nil)
    }

    /// A translation whose language pack is not downloaded: the pair, in the app's language, and one
    /// button that downloads it.
    @Test func aMissingLanguagePackOffersTheDownload() {
        let kind = NoticeKind.translationNeeded(from: "en", to: "tr")
        #expect(kind.titleText(.turkish) == "Çeviri için dil paketi gerekli")
        #expect(kind.bodyText(.turkish) == "İngilizce → Türkçe")
        #expect(kind.actionText(.turkish) == "İndir")
        #expect(kind.titleText(.english) == "Translation needs a language pack")
        #expect(kind.bodyText(.english) == "English → Turkish")
        #expect(kind.actionText(.english) == "Download")
        #expect(!kind.offersSettings)
    }

    /// The target left before ⌘V: a calm one-liner, no button.
    @Test func aPasteThatTargetLeftIsToldCalmly() {
        #expect(NoticeKind.copiedOnly.titleText(.english) == "Copied, paste with ⌘V")
        #expect(NoticeKind.copiedOnly.titleText(.turkish) == "Kopyalandı, ⌘V ile yapıştır")
        #expect(NoticeKind.copiedOnly.actionText(.english) == nil)
        #expect(!NoticeKind.copiedOnly.offersSettings)
    }

    static let every: [NoticeKind] = [
        .accessibility, .inputMonitoring, .copiedOnly, .extensionFailed(name: "Base64", message: "boom"),
        .extensionDisabled(name: "Base64"), .extensionMessage(name: "Base64", message: "bitti"), .translationNeeded(from: "en", to: "tr"),
        .upToDate(version: "0.1.0"), .updateAvailable(version: "0.2.0", page: URL(string: "https://example.test/releases/tag/v0.2.0")!), .updateCheckFailed,
    ]

    /// The button does what it says: the two permission notices open their own pane, the language pack's downloads that
    /// pair; every other notice has no button and does nothing.
    @Test func eachButtonDoesWhatItSays() {
        #expect(NoticeKind.accessibility.action == .accessibilitySettings)
        #expect(NoticeKind.inputMonitoring.action == .inputMonitoringSettings)
        #expect(NoticeKind.translationNeeded(from: "en", to: "tr").action == .downloadLanguagePack(from: "en", to: "tr"))
        for kind in Self.every {
            #expect((kind.action == nil) == (kind.actionText(.english) == nil))
            #expect((kind.action == nil) == (kind.actionText(.turkish) == nil))
        }
        #expect(Self.every.filter { $0.action != nil }.count == 4)
        #expect(NoticeKind.updateAvailable(version: "0.2.0", page: URL(string: "https://example.test/x")!).action == .openURL(URL(string: "https://example.test/x")!))
    }

    /// A notice that offers something to do stays 8 s, so there is time to do it (a click closes it sooner); the rest 4 s.
    @Test func anOfferStaysLongerThanANotice() {
        #expect(NoticeKind.translationNeeded(from: "en", to: "tr").duration == .seconds(8))
        #expect(NoticeKind.extensionMessage(name: "Base64", message: "bitti").duration == .seconds(4))
        for kind in Self.every {
            #expect(kind.duration == (kind.action == nil ? .seconds(4) : .seconds(8)))
        }
    }

    static let sources: [NoticeKind] = [
        .sourcePasted, .secretCopiedOnly, .sourceNotPasted, .sourceEmpty, .sourceCopied(message: "Kullanıcı adı kopyalandı."),
        .sourceCopied(message: nil), .sourceCommandCopied,
    ]

    /// A source's notices only confirm what the person did: a title alone stays 2.4 s, a second line 4 s; none has a
    /// button.
    @Test func aSourcesNoticesSayWhatHappened() {
        let turkish = Self.sources.map { [$0.titleText(.turkish), $0.bodyText(.turkish)] }
        #expect(turkish == [
            ["Yapıştırıldı.", ""],
            ["⌘V ile yapıştır", "30 sn sonra panodan silinir."],
            ["Yapıştırılmadı.", "Başka bir uygulama öne geçti."],
            ["Boş sonuç yapıştırılmadı.", ""],
            ["Kullanıcı adı kopyalandı.", ""],
            ["Kopyalandı.", ""],
            ["Komut kopyalandı.", "Terminal’de çalıştır, sonra paneli yeniden aç."],
        ])
        let english = Self.sources.map { [$0.titleText(.english), $0.bodyText(.english)] }
        #expect(english == [
            ["Pasted.", ""],
            ["Press ⌘V to paste", "It leaves the clipboard in 30 seconds."],
            ["Not pasted.", "Another app came to the front."],
            ["Nothing pasted: the value was empty.", ""],
            ["Kullanıcı adı kopyalandı.", ""],
            ["Copied.", ""],
            ["Command copied.", "Run it in Terminal, then open the panel again."],
        ])
        #expect(Self.sources.map(\.duration) == [.milliseconds(2400), .seconds(4), .seconds(4), .milliseconds(2400), .milliseconds(2400),
                                                 .milliseconds(2400), .seconds(4)])
        for kind in Self.sources {
            #expect(kind.action == nil)
            #expect(kind.actionText(.turkish) == nil)
            #expect(!kind.offersSettings)
        }
    }

    /// The three update notices say exactly what the check found, in both languages; a failure never reads as "up to date".
    @Test func updateNoticesSayWhatTheCheckFound() {
        let available = NoticeKind.updateAvailable(version: "0.2.0", page: URL(string: "https://example.test/x")!)
        #expect(NoticeKind.upToDate(version: "0.1.0").titleText(.english) == "yabbistir is up to date (0.1.0)")
        #expect(NoticeKind.upToDate(version: "0.1.0").titleText(.turkish) == "yabbistir güncel (0.1.0)")
        #expect(available.titleText(.english) == "yabbistir 0.2.0 is available")
        #expect(available.titleText(.turkish) == "yabbistir 0.2.0 çıktı")
        #expect(available.actionText(.english) == "Download")
        #expect(available.actionText(.turkish) == "İndir")
        #expect(NoticeKind.updateCheckFailed.titleText(.english) == "Couldn’t check for updates")
        #expect(NoticeKind.updateCheckFailed.titleText(.turkish) == "Güncellemeler denetlenemedi")
        #expect(!NoticeKind.updateCheckFailed.titleText(.english).contains("up to date"))
    }
}

/// A notice sizes its window to itself: a body past 360 pt wraps, and the notice is as tall as its lines, so the window
/// never cuts the second one off (German and French bodies often wrap).
@MainActor @Suite struct NoticeLayoutTests {
    func size(_ kind: NoticeKind, _ language: AppLanguage = .english) -> CGSize {
        NSHostingView(rootView: NoticeView(language: language, kind: kind) {}).fittingSize
    }

    @Test func aBodyThatWrapsMakesTheNoticeTaller() {
        let short = size(.extensionMessage(name: "Video", message: "No video at this link."))
        let long = size(.extensionMessage(name: "Video", message: String(repeating: "This post needs a sign-in to download. ", count: 2)))
        // The body is 360 pt at most, beside the 18 pt mark and its 12 pt gap, inside 14 pt of padding.
        let widest: CGFloat = 360 + 18 + 12 + 28
        #expect(long.width <= widest)
        #expect(long.height >= short.height + 12)
    }

    @Test func aGermanBodyKeepsItsSecondLine() {
        let oneLine = size(.sourceNotPasted, .german)
        let twoLines = size(.secretCopiedOnly, .german)
        #expect(twoLines.height >= oneLine.height + 12)
    }
}

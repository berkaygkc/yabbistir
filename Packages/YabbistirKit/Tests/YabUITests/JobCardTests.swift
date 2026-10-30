import AppKit
import Foundation
import Testing
import YabExtensionKit
import YabExtensions
import YabLocalization
@testable import YabUI

/// The job card's rows: state first, then the subject, then the numbers;
/// a finished row says where its result went; app-made failures in the app's language.
@MainActor @Suite struct JobCardTests {
    static let download = FakeCommands.command("dev.example.video/video", title: "Video olarak indir", keywords: ["indir"],
                                               extensionName: "Video İndir", hint: false, icon: "sf:film", output: .file,
                                               targets: [.finder], isJob: true, verb: "İndir")
    static let finder = TargetInfo(bundleID: "com.apple.finder", name: "Finder", kind: .finder)
    static let textEdit = TargetInfo(bundleID: "com.apple.TextEdit", name: "TextEdit", kind: .editor)
    static let subject = "SwiftUI ile Liquid Glass — tam rehber"
    /// The card's short subject: the title without its " — …" tail.
    static let short = "SwiftUI ile Liquid Glass"

    func job(_ phase: JobCenter.Job.Phase, command: ExtensionCommand = download, target: TargetInfo? = finder, delivery: JobCenter.Job.Delivery? = nil, fraction: Double? = nil,
             message: String? = nil, resultName: String? = nil, errorMessage: String? = nil,
             errorCode: ExtensionError.Code? = nil) -> JobCenter.Job {
        JobCenter.Job(id: 1, command: command, subjectTitle: Self.subject, target: target, toClipboard: false, phase: phase,
                      delivery: delivery, fraction: fraction, message: message, resultName: resultName, errorMessage: errorMessage,
                      errorCode: errorCode)
    }

    /// A bar of unknown progress redraws at most 30 times a second, not at the
    /// display's rate, for as long as a download takes.
    @Test func theSlidingBarRedrawsAtMostThirtyTimesASecond() {
        let dates = Array(JobBar.schedule(paused: false).entries(from: Date(), mode: .normal).prefix(10))
        #expect(dates.count == 10)
        for (earlier, later) in zip(dates, dates.dropFirst()) {
            #expect(later.timeIntervalSince(earlier) >= 1.0 / 30 - 1e-6)
        }
    }

    @Test func runningShowsSubjectThenNumbers() {
        let running = job(.running, fraction: 0.42, message: "18,4 / 43,7 MB · 1 dk kaldı")
        let row = JobRowPresentation.make(running, language: .turkish)
        #expect(row.percent == "%42")
        #expect(JobRowPresentation.make(running, language: .english).percent == "42%")
        #expect(row.status.head == nil)
        #expect(row.status.subject == Self.short)
        #expect(row.status.tail == "18,4 / 43,7 MB · 1 dk kaldı")
        #expect(row.title == "Video olarak indir")
        #expect(row.icon == "sf:film")
        #expect(row.showsBar)
        #expect(row.fraction == 0.42)
        #expect(!row.isIndeterminate)
    }

    @Test func aStateWordLeadsWhenThereIsNoFraction() {
        let finishing = JobRowPresentation.make(job(.running, message: "Birleştiriliyor"), language: .turkish)
        #expect(finishing.status.head == "Birleştiriliyor")
        #expect(finishing.status.subject == Self.short)
        #expect(finishing.status.tail == nil)
        #expect(finishing.percent == nil)
        #expect(finishing.isIndeterminate)
        #expect(finishing.showsBar)
        // Before the extension says anything, it is starting.
        let starting = JobRowPresentation.make(job(.running), language: .turkish)
        #expect(starting.status.head == "Başlıyor")
        #expect(JobRowPresentation.make(job(.running), language: .english).status.head == "Starting")
    }

    @Test func queuedSaysSo() {
        let row = JobRowPresentation.make(job(.queued), language: .turkish)
        #expect(row.status.head == "Sırada")
        #expect(row.status.subject == Self.short)
        #expect(row.status.tail == nil)
        #expect(row.title == "Video olarak indir")
        #expect(row.percent == nil)
        #expect(row.showsBar)
        #expect(!row.isIndeterminate)
        #expect(row.style == .queued)
        #expect(JobRowPresentation.make(job(.queued), language: .english).status.head == "Queued")
    }

    @Test func readyOffersCommandV() {
        let ready = job(.ready, resultName: "SwiftUI ile Liquid Glass — tam rehber.mp4")
        let row = JobRowPresentation.make(ready, language: .turkish)
        #expect(row.title == "Hazır, ⌘V ile yapıştır")
        #expect(row.titleKeys == ["⌘", "V"])
        #expect(!row.showsBar)
        #expect(row.icon == "sf:clipboard")
        #expect(row.status.head == nil)
        #expect(row.status.subject == "SwiftUI ile Liquid Glass — tam rehber.mp4")
        #expect(row.status.tail == nil)
        #expect(JobRowPresentation.make(ready, language: .english).title == "Ready, ⌘V to paste")
        // An older result the clipboard no longer holds makes no promise.
        let superseded = JobRowPresentation.make(job(.superseded, resultName: "a.m4a"), language: .turkish)
        #expect(superseded.title == "Geçmişe eklendi")
        #expect(superseded.titleKeys.isEmpty)
        #expect(superseded.icon == "sf:checkmark")
    }

    @Test func accessibilityNamesActionSubjectAndState() {
        let running = JobRowPresentation.make(job(.running, fraction: 0.42, message: "18,4 / 43,7 MB · 1 dk kaldı"), language: .turkish)
        #expect(running.accessibilityLabel == "Video olarak indir, SwiftUI ile Liquid Glass, %42")
        #expect(JobRowPresentation.make(job(.queued), language: .turkish).accessibilityLabel
            == "Video olarak indir, SwiftUI ile Liquid Glass, Sırada")
        #expect(JobRowPresentation.make(job(.running, message: "Birleştiriliyor"), language: .turkish).accessibilityLabel
            == "Video olarak indir, SwiftUI ile Liquid Glass, Birleştiriliyor")
        #expect(JobRowPresentation.make(job(.done, delivery: .pasted, resultName: "a.mp4"), language: .turkish).accessibilityLabel
            == "Video olarak indir, SwiftUI ile Liquid Glass, Finder’a kaydedildi")
        #expect(JobRowPresentation.make(job(.failed, errorMessage: "yt-dlp is not installed", errorCode: .toolMissing),
                                        language: .turkish).accessibilityLabel
            == "Video olarak indir, SwiftUI ile Liquid Glass, yt-dlp bulunamadı")
        // The ✕ says what it does to which job.
        #expect(running.buttonLabel == "İptal: Video olarak indir, SwiftUI ile Liquid Glass")
        #expect(JobRowPresentation.make(job(.ready, resultName: "a.mp4"), language: .turkish).buttonLabel
            == "Kapat: Video olarak indir, SwiftUI ile Liquid Glass")
    }

    @Test func theRingIsATemplateOfStatusItemSize() {
        for image in [StatusRingImage.image(fraction: 0.42, spinPhase: 0), StatusRingImage.image(fraction: nil, spinPhase: 0.3)] {
            #expect(image.size == NSSize(width: 22, height: 22))
            #expect(image.isTemplate)
        }
    }

    /// The arc starts at 12 o'clock and runs clockwise over a faint track; without a fraction a
    /// quarter-ish segment sits at the spin phase.
    @Test func theArcRunsClockwiseFromTwelveOverAFaintTrack() throws {
        func alpha(_ image: NSImage, atDegrees degrees: Double) throws -> CGFloat {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 88, pixelsHigh: 88, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: 88, height: 88))
            NSGraphicsContext.restoreGraphicsState()
            // Clockwise from 12 o'clock, on the ring's radius (8.4 of 22), in a top-left pixel grid.
            let radians = degrees * .pi / 180
            let x = Int((11 + 8.4 * sin(radians)) * 4), y = Int((11 - 8.4 * cos(radians)) * 4)
            return try #require(rep.colorAt(x: x, y: y)).alphaComponent
        }
        let quarter = StatusRingImage.image(fraction: 0.42, spinPhase: 0)
        #expect(try alpha(quarter, atDegrees: 20) > 0.9)
        #expect(try alpha(quarter, atDegrees: 140) > 0.9)
        let track = try alpha(quarter, atDegrees: 240)
        #expect(track > 0.15 && track < 0.4)
        let spinning = StatusRingImage.image(fraction: nil, spinPhase: 0.5)
        #expect(try alpha(spinning, atDegrees: 220) > 0.9)
        let behind = try alpha(spinning, atDegrees: 90)
        #expect(behind > 0.15 && behind < 0.4)
    }

    // MARK: Finished and failed rows

    @Test func aFinishedJobSaysWhereItsResultWent() {
        let name = "SwiftUI ile Liquid Glass — tam rehber.mp4"
        let finder = JobRowPresentation.make(job(.done, delivery: .pasted, resultName: name), language: .turkish)
        #expect(finder.title == "Finder’a kaydedildi")
        #expect(finder.icon == "sf:checkmark")
        #expect(finder.status.head == nil && finder.status.subject == name && finder.status.tail == nil)
        #expect(!finder.showsBar)
        #expect(finder.style == .finished)
        #expect(JobRowPresentation.make(job(.done, target: Self.textEdit, delivery: .pasted, resultName: name), language: .turkish).title
            == "Yapıştırıldı")
        #expect(JobRowPresentation.make(job(.done, delivery: .stacked, resultName: name), language: .turkish).title == "Sıraya eklendi")
        #expect(JobRowPresentation.make(job(.done, delivery: .stacked, resultName: name), language: .english).title == "Added to Stack")
        #expect(JobRowPresentation.make(job(.done, delivery: .pasted, resultName: name), language: .english).title == "Saved to Finder")
    }

    @Test(arguments: [
        (ExtensionError.Code?.some(.interrupted), "Uzantı beklenmedik biçimde durdu", "The extension stopped unexpectedly"),
        (.unavailable, "Uzantı şu an kullanılamıyor", "The extension isn’t available right now"),
        (.networkError, "Bağlantı kurulamadı", "Couldn’t connect"),
        (.permissionDenied, "İzin verilmedi", "Not allowed"),
        (.timeout, "Tamamlanamadı", "Couldn’t finish"),
    ])
    func appMadeFailuresAreWordedInTheAppsLanguage(code: ExtensionError.Code?, turkish: String, english: String) {
        let failed = job(.failed, errorMessage: "host said something in English", errorCode: code)
        let row = JobRowPresentation.make(failed, language: .turkish)
        #expect(row.status.subject == "\(Self.short): \(turkish)")
        #expect(JobRowPresentation.make(failed, language: .english).status.subject == "\(Self.short): \(english)")
        #expect(row.title == "Video olarak indir")
        #expect(row.icon == "sf:exclamationmark.circle")
        #expect(row.style == .failed)
        #expect(!row.showsBar)
        #expect(row.percent == nil)
    }

    /// ExecAPI words a missing tool as "<name> is not installed[. Install it with: …]"; the card
    /// takes the name from there.
    @Test func aMissingToolIsNamedFromExecsMessage() throws {
        let execAPI = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/YabExtensionRuntime/ExecAPI.swift")
        let source = try String(contentsOf: execAPI, encoding: .utf8)
        #expect(source.contains(#"ExtensionError(.toolMissing, "\(name) is not installed""#))
        for message in ["yt-dlp is not installed. Install it with: brew install yt-dlp", "yt-dlp is not installed"] {
            let failed = job(.failed, errorMessage: message, errorCode: .toolMissing)
            #expect(JobRowPresentation.make(failed, language: .turkish).status.subject == "\(Self.short): yt-dlp bulunamadı")
            #expect(JobRowPresentation.make(failed, language: .english).status.subject == "\(Self.short): yt-dlp isn’t installed")
        }
    }

    /// A result that is not one is the app's finding, in English: the card says it
    /// could not finish (the reason goes to the Development log).
    @Test func aBadResultIsWordedInTheAppsLanguage() {
        let failed = job(.failed, errorMessage: "a file result must be a file in yab.files.workDir", errorCode: .badResult)
        #expect(JobRowPresentation.make(failed, language: .turkish).status.subject == "\(Self.short): Tamamlanamadı")
        #expect(JobRowPresentation.make(failed, language: .english).status.subject == "\(Self.short): Couldn’t finish")
    }

    @Test func theExtensionsOwnMessageShowsForItsFailures() {
        let message = "Bu gönderi giriş istiyor. Ayarlar’da tarayıcı çerezlerini açabilirsin."
        for code in [ExtensionError.Code.script, nil] {
            #expect(JobRowPresentation.make(job(.failed, errorMessage: message, errorCode: code), language: .turkish).status.subject
                == "\(Self.short): \(message)")
        }
        // Nothing said: the card still says something.
        #expect(JobRowPresentation.make(job(.failed), language: .turkish).status.subject == "\(Self.short): Tamamlanamadı")
        #expect(JobRowPresentation.make(job(.failed, errorMessage: "  ", errorCode: .script), language: .english).status.subject
            == "\(Self.short): Couldn’t finish")
    }

    /// The failed line: "<short subject>: <reason>", so a reason is tied to its item;
    /// the status menu shortens subjects the same way.
    @Test func aFailureNamesItsSubject() {
        let failed = JobRowPresentation.make(job(.failed, errorMessage: "yt-dlp is not installed", errorCode: .toolMissing), language: .turkish)
        #expect(failed.status.head == nil && failed.status.tail == nil)
        #expect(failed.status.subject == "SwiftUI ile Liquid Glass: yt-dlp bulunamadı")
        #expect(JobRowPresentation.shortSubject("SwiftUI ile Liquid Glass — tam rehber") == "SwiftUI ile Liquid Glass")
        #expect(JobRowPresentation.shortSubject("WWDC26 · Tasarımda yenilikler") == "WWDC26 · Tasarımda yenilikler")
        #expect(JobRowPresentation.shortSubject("İlk satır\nikinci — satır") == "İlk satır ikinci")
        // A finished row names its file in full.
        let done = JobRowPresentation.make(job(.done, delivery: .pasted, resultName: "SwiftUI ile Liquid Glass — tam rehber.mp4"),
                                           language: .turkish)
        #expect(done.status.subject == "SwiftUI ile Liquid Glass — tam rehber.mp4")
    }

    /// An action may name its own failure ("Video indirilemedi"); otherwise a failed row keeps the
    /// action's title. Only a failed row uses it.
    @Test func aFailureUsesItsOwnTitle() {
        let named = FakeCommands.command("dev.example.video/video", title: "Video olarak indir", keywords: ["indir"], icon: "sf:film",
                                         output: .file, isJob: true, failTitle: "Video indirilemedi")
        #expect(JobRowPresentation.make(job(.failed, command: named, errorCode: .timeout), language: .turkish).title == "Video indirilemedi")
        #expect(JobRowPresentation.make(job(.running, command: named, fraction: 0.5), language: .turkish).title == "Video olarak indir")
        #expect(JobRowPresentation.make(job(.failed, errorCode: .timeout), language: .turkish).title == "Video olarak indir")
        // The row is still named by its action for VoiceOver.
        #expect(JobRowPresentation.make(job(.failed, command: named, errorCode: .timeout), language: .turkish).accessibilityLabel
            == "Video olarak indir, SwiftUI ile Liquid Glass, Tamamlanamadı")
    }
}

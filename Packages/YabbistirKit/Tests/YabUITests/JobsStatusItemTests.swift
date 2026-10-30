import AppKit
import Foundation
import Testing
import YabCore
import YabExtensionKit
import YabExtensions
import YabLocalization
@testable import YabUI

/// The status item while jobs run: the menu's
/// "Süren işler" rows, the ring's motion (design.json `status-ring`) and the subject a job is named by.
@MainActor @Suite struct JobsStatusItemTests {
    static let download = JobCardTests.download
    static let audio = FakeCommands.command("dev.example.video/audio", title: "Sesi indir", keywords: ["ses"], extensionName: "Video İndir",
                                            hint: false, icon: "sf:waveform", output: .file, targets: [.finder], isJob: true, verb: "İndir")

    func job(_ id: Int, _ phase: JobCenter.Job.Phase, command: ExtensionCommand = download,
             subject: String = JobCardTests.subject) -> JobCenter.Job {
        JobCenter.Job(id: id, command: command, subjectTitle: subject, target: JobCardTests.finder, toClipboard: false, phase: phase)
    }

    // MARK: Menu

    /// One "İptal: <action>" row per job that waits or runs, in the order they started, with the
    /// short subject after it; finished and failed jobs are not cancelled from here.
    @Test func theMenuOffersToCancelEveryJobAtWork() throws {
        let jobs = [job(1, .running), job(2, .done), job(3, .queued, command: Self.audio, subject: "Başka bir video"),
                    job(4, .failed), job(5, .ready)]
        let section = try #require(JobsMenuPresentation.section(for: jobs, language: .turkish))
        #expect(section.title == "Süren işler")
        #expect(section.rows.map(\.jobID) == [1, 3])
        #expect(section.rows.map(\.title) == ["İptal: Video olarak indir", "İptal: Sesi indir"])
        #expect(section.rows.map(\.subject) == [JobCardTests.short, "Başka bir video"])
        #expect(section.rows[0].accessibilityLabel == "İptal: Video olarak indir, SwiftUI ile Liquid Glass")
    }

    @Test func theMenuSpeaksTheAppsLanguage() throws {
        let section = try #require(JobsMenuPresentation.section(for: [job(1, .queued)], language: .english))
        #expect(section.title == "Running Jobs")
        #expect(section.rows.first?.title == "Cancel: Video olarak indir")
    }

    /// Nothing waits or runs: the section is left out of the menu.
    @Test func withNothingAtWorkTheSectionIsLeftOut() {
        #expect(JobsMenuPresentation.section(for: [], language: .turkish) == nil)
        #expect(JobsMenuPresentation.section(for: [job(1, .done), job(2, .ready), job(3, .failed), job(4, .superseded)],
                                             language: .turkish) == nil)
    }

    /// A long subject is cut at the end to fit its place in the menu; a short one stays whole.
    @Test func aLongSubjectIsTruncated() {
        let font = NSFont.menuFont(ofSize: 0)
        let long = "Çok uzun bir video başlığı ki menüye asla sığmaz ve sonu kesilmek zorunda kalır"
        let cut = JobsMenuPresentation.truncated(long, toWidth: 140, font: font)
        #expect(cut.hasSuffix("…"))
        #expect(long.hasPrefix(String(cut.dropLast())))
        #expect((cut as NSString).size(withAttributes: [.font: font]).width <= 140)
        #expect(JobsMenuPresentation.truncated("Kısa", toWidth: 140, font: font) == "Kısa")
    }

    // MARK: Subject

    /// A job is named after its item as the panel's row names it; a titled link keeps its title.
    @Test func aJobIsNamedAfterItsItem() {
        #expect(JobRowPresentation.subjectTitle(kind: .link, previewText: "SwiftUI ile Liquid Glass — tam rehber")
            == "SwiftUI ile Liquid Glass — tam rehber")
        #expect(JobRowPresentation.subjectTitle(kind: .link, previewText: "https://vid.example/dQw4w9WgXcQ?si=abc") == "vid.example/dQw4w9WgXcQ")
        #expect(JobRowPresentation.subjectTitle(kind: .text, previewText: "https://example.com/a is a page") == "https://example.com/a is a page")
    }

    /// An untitled link names itself without its scheme, a leading www. or m.,
    /// or a trailing slash; a short path keeps its first query item that is not a tracker, so two
    /// video downloads read apart.
    @Test(arguments: [
        ("https://www.video.example/watch?v=dQw4w9WgXcQ&t=42s", "video.example/watch?v=dQw4w9WgXcQ"),
        ("https://vid.example/dQw4w9WgXcQ?si=abc", "vid.example/dQw4w9WgXcQ"),
        ("https://www.photos.example/p/Cxyz/?igsh=abc", "photos.example/p/Cxyz"),
        ("https://example.com/", "example.com"),
        ("https://m.video.example/watch?feature=share&utm_source=x&v=abc123", "video.example/watch?v=abc123"),
        ("https://www.video.example/shorts/abc123?feature=share", "video.example/shorts/abc123"),
        ("https://example.com/?ref=home&q=kedi", "example.com?q=kedi"),
        ("https://tr.wikipedia.org/wiki/%C3%87ay", "tr.wikipedia.org/wiki/Çay"),
        ("http://short.example/user/status/123?s=20", "short.example/user/status/123"),
    ])
    func anUntitledLinkNamesItself(url: String, subject: String) {
        #expect(LinkSubject.name(of: url) == subject)
        #expect(JobRowPresentation.subjectTitle(kind: .link, previewText: url) == subject)
    }

    @Test func onlyWebAddressesAreNamedThisWay() {
        #expect(LinkSubject.name(of: "ftp://example.com/a") == nil)
        #expect(LinkSubject.name(of: "SwiftUI ile Liquid Glass") == nil)
    }

    // MARK: Ring motion

    /// The glyph steps back and the ring fades in over 0.3 s with the ease-out, and back at the end;
    /// at rest the plain glyph shows and nothing is drawn.
    @Test func theRingComesAndGoesWithTheJobs() {
        var motion = StatusRingMotion(reduceMotion: false)
        #expect(motion.isAtRest)
        #expect(motion.frameInterval == nil)
        motion.set(busy: true, fraction: nil, at: 10)
        #expect(motion.presence == 0)
        #expect(motion.frameInterval == 1.0 / 30)
        motion.advance(to: 10.15)
        // Halfway through an ease-out it is most of the way there.
        #expect(motion.presence > 0.7 && motion.presence < 1)
        motion.advance(to: 10.3)
        #expect(motion.presence == 1)
        #expect(!motion.isAtRest)

        motion.set(busy: false, fraction: nil, at: 12)
        motion.advance(to: 12.15)
        #expect(motion.presence > 0 && motion.presence < 0.3)
        motion.advance(to: 12.3)
        #expect(motion.presence == 0)
        #expect(motion.isAtRest)
        #expect(motion.frameInterval == nil)
    }

    /// While no job can say how far it is, a segment turns once a second, drawn 12 times a second.
    @Test func unknownProgressSpinsOnceASecond() {
        var motion = StatusRingMotion(reduceMotion: false)
        motion.set(busy: true, fraction: nil, at: 0)
        motion.advance(to: 0.5)
        #expect(motion.fraction == nil)
        #expect(abs(motion.spinPhase - 0.5) < 1e-9)
        #expect(motion.frameInterval == 1.0 / 12)
        motion.advance(to: 1.25)
        #expect(abs(motion.spinPhase - 0.25) < 1e-9)
    }

    /// The arc eases linearly to each new share over 0.35 s, then nothing is drawn until the next.
    @Test func theArcEasesToEachNewShare() throws {
        var motion = StatusRingMotion(reduceMotion: false)
        motion.set(busy: true, fraction: 0.2, at: 0)
        motion.advance(to: 0.35)
        #expect(try #require(motion.fraction) == 0.2)
        motion.advance(to: 0.5)
        #expect(motion.frameInterval == nil)

        motion.set(busy: true, fraction: 0.6, at: 1)
        #expect(motion.frameInterval == 1.0 / 30)
        motion.advance(to: 1.175)
        #expect(abs(try #require(motion.fraction) - 0.4) < 1e-9)
        motion.advance(to: 1.35)
        #expect(try #require(motion.fraction) == 0.6)
        #expect(motion.frameInterval == nil)
    }

    /// A download reports many times a second; the ring moves only when the whole percent does, so
    /// an update within the same percent, or one that only changes the
    /// time left, draws nothing and starts no easing.
    @Test func progressWithinTheSamePercentDrawsNothing() throws {
        var motion = StatusRingMotion(reduceMotion: false)
        let first = motion.set(busy: true, fraction: 0.421, at: 0)
        #expect(first)
        motion.advance(to: 1)
        #expect(try #require(motion.fraction) == 0.42)
        #expect(motion.frameInterval == nil)

        let samePercent = motion.set(busy: true, fraction: 0.4249, at: 2)
        #expect(!samePercent)
        let sameAgain = motion.set(busy: true, fraction: 0.42, at: 2.1)
        #expect(!sameAgain)
        #expect(motion.frameInterval == nil)
        #expect(try #require(motion.fraction) == 0.42)

        let nextPercent = motion.set(busy: true, fraction: 0.426, at: 3)
        #expect(nextPercent)
        #expect(motion.frameInterval == 1.0 / 30)
        motion.advance(to: 3.35)
        #expect(try #require(motion.fraction) == 0.43)
    }

    /// The same jobs, told again: nothing to draw. Starting, ending and spinning are.
    @Test func onlyAVisibleChangeAsksForADrawing() {
        var motion = StatusRingMotion(reduceMotion: false)
        let stillIdle = motion.set(busy: false, fraction: nil, at: 0)
        #expect(!stillIdle)
        let starting = motion.set(busy: true, fraction: nil, at: 1)
        #expect(starting)
        motion.advance(to: 2)
        let stillSpinning = motion.set(busy: true, fraction: nil, at: 2)
        #expect(!stillSpinning)
        let ending = motion.set(busy: false, fraction: nil, at: 3)
        #expect(ending)
    }

    /// From spinning to a known share, the arc grows from the spinning segment's length at 12 o'clock.
    @Test func aKnownShareTakesOverFromTheSpin() throws {
        var motion = StatusRingMotion(reduceMotion: false)
        motion.set(busy: true, fraction: nil, at: 0)
        motion.advance(to: 0.4)
        motion.set(busy: true, fraction: 0.5, at: 1)
        #expect(abs(try #require(motion.fraction) - StatusRingImage.spinLength) < 1e-9)
        #expect(motion.spinPhase == 0)
        motion.advance(to: 1.35)
        #expect(try #require(motion.fraction) == 0.5)
    }

    /// Leaving, the ring keeps what it showed while it fades: it does not start spinning.
    @Test func theRingFadesWithItsLastShare() throws {
        var motion = StatusRingMotion(reduceMotion: false)
        motion.set(busy: true, fraction: 0.9, at: 0)
        motion.advance(to: 1)
        motion.set(busy: false, fraction: nil, at: 2)
        motion.advance(to: 2.1)
        #expect(try #require(motion.fraction) == 0.9)
    }

    /// With Reduce Motion the ring appears and changes at once, and the unknown segment rests at 12 o'clock.
    @Test func reduceMotionDrawsNoFrames() throws {
        var motion = StatusRingMotion(reduceMotion: true)
        motion.set(busy: true, fraction: nil, at: 0)
        #expect(motion.presence == 1)
        #expect(motion.frameInterval == nil)
        motion.advance(to: 0.5)
        #expect(motion.spinPhase == 0)
        motion.set(busy: true, fraction: 0.3, at: 1)
        #expect(try #require(motion.fraction) == 0.3)
        motion.set(busy: false, fraction: nil, at: 2)
        #expect(motion.isAtRest)
    }

    // MARK: Ring image

    func pixels(_ image: NSImage) throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 88, pixelsHigh: 88, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 88, height: 88))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Without presence the ring image is the plain glyph at its own size, centred: handing the
    /// icon back to the plain glyph at the end does not move it.
    @Test func atNoPresenceTheRingImageIsThePlainGlyph() throws {
        let rest = try pixels(StatusRingImage.image(fraction: 0.5, spinPhase: 0, presence: 0))
        let glyph = try #require(NSImage(systemSymbolName: StatusRingImage.glyphName, accessibilityDescription: nil))
        let plain = try pixels(NSImage(size: NSSize(width: 22, height: 22), flipped: false) { bounds in
            glyph.draw(in: NSRect(x: bounds.midX - glyph.size.width / 2, y: bounds.midY - glyph.size.height / 2,
                                  width: glyph.size.width, height: glyph.size.height))
            return true
        })
        var different = 0
        for x in 0..<88 { for y in 0..<88 where abs((rest.colorAt(x: x, y: y)?.alphaComponent ?? 0) - (plain.colorAt(x: x, y: y)?.alphaComponent ?? 0)) > 0.02 {
            different += 1
        } }
        #expect(different == 0)
    }

    /// Halfway in, the ring is half as strong.
    @Test func theRingFadesWithPresence() throws {
        // At 240°, on the ring and clear of the glyph.
        let radians = 240 * Double.pi / 180
        let x = Int((11 + 8.4 * sin(radians)) * 4), y = Int((11 - 8.4 * cos(radians)) * 4)
        let full = try #require(try pixels(StatusRingImage.image(fraction: 0.1, spinPhase: 0)).colorAt(x: x, y: y)).alphaComponent
        let half = try #require(try pixels(StatusRingImage.image(fraction: 0.1, spinPhase: 0, presence: 0.5)).colorAt(x: x, y: y))
            .alphaComponent
        #expect(abs(half - full / 2) < 0.05)
    }
}

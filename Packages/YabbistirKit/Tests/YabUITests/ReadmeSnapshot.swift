import AppKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
import YabCore
import YabExtensionKit
import YabExtensions
import YabLocalization
@testable import YabUI

/// Draws the README images from synthetic data, in English, at their final pixel sizes. Off by default;
/// `tools/readme-images.sh` runs it with `TEST_RUNNER_YAB_SNAPSHOT_DIR=<dir> make test ONLY=YabUITests/ReadmeSnapshot`.
/// `social-preview.png` puts the app icon beside the panel and reads it from `<dir>/icon.png`, which the script draws first.
///
/// ImageRenderer draws no glass, so every surface is the solid one (the Reduce Transparency look) on a calm grey
/// wallpaper, with the shadow the window server would add.
@MainActor @Suite(.serialized) struct ReadmeSnapshot {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The README's first image, light and dark: an editor with its caret, the panel opened just under it, and the menu
    /// bar's status item with one download on its card.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func hero() throws {
        let dir = try #require(Self.directory)
        for dark in [false, true] {
            let fixture = try ReadmeFixture()
            let model = try fixture.panelModel()
            model.select(fixture.ids["docker"]!, in: .history)
            let scene = HeroScene(model: model, job: ReadmeFixture.heroJob, dark: dark)
            try ReadmeRender.write(scene, size: HeroScene.size, pixelWidth: 1800, dark: dark,
                                   to: dir.appendingPathComponent(dark ? "hero-dark.png" : "hero-light.png"))
        }
    }

    /// The panel with a category open as a second column.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func panel() throws {
        let dir = try #require(Self.directory)
        let fixture = try ReadmeFixture(snippets: true)
        let model = try fixture.panelModel()
        model.select(fixture.ids["video"]!, in: .history)
        let sheet = ReadmePanel(model: model, dark: ReadmeTheme.panel)
        let scene = ReadmeWallpaper(dark: ReadmeTheme.panel)
            .overlay { sheet }
            .frame(width: PanelScene.size.width, height: PanelScene.size.height)
        try ReadmeRender.write(scene, size: PanelScene.size, pixelWidth: 1600, dark: ReadmeTheme.panel,
                               to: dir.appendingPathComponent("panel.png"))
    }

    /// The ⇧ panel on a video link with Finder in front: the download leads.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func transforms() throws {
        let dir = try #require(Self.directory)
        let fixture = try ReadmeFixture()
        let model = try fixture.panelModel()
        model.select(fixture.ids["video"]!, in: .history)
        _ = model.handle(.toggleTransforms)
        let dark = ReadmeTheme.pair
        let surface = TransformPanelView(model: model) { _ in }
            .background(SolidSurface(radius: 14))
            .readmeShadow(dark: dark)
        let scene = ReadmeWallpaper(dark: dark)
            .overlay { surface }
            .frame(width: PairScene.size.width, height: PairScene.size.height)
        try ReadmeRender.write(scene, size: PairScene.size, pixelWidth: 960, dark: dark,
                               to: dir.appendingPathComponent("transforms.png"))
    }

    /// The job card under the menu bar's status item: a download running, one merging, one ready to paste, one saved.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func jobs() throws {
        let dir = try #require(Self.directory)
        let dark = ReadmeTheme.pair
        let scene = JobsScene(jobs: ReadmeFixture.cardJobs, dark: dark)
        try ReadmeRender.write(scene, size: PairScene.size, pixelWidth: 960, dark: dark,
                               to: dir.appendingPathComponent("jobs.png"))
    }

    /// GitHub's social preview (1280×640): the icon, the name and one line beside the panel.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func socialPreview() throws {
        let dir = try #require(Self.directory)
        let icon = try #require(NSImage(contentsOf: dir.appendingPathComponent("icon.png")),
                                "Draw icon.png into the snapshot folder first (tools/readme-images.sh does).")
        let fixture = try ReadmeFixture()
        let model = try fixture.panelModel()
        model.select(fixture.ids["docker"]!, in: .history)
        let dark = ReadmeTheme.social
        let scene = SocialScene(model: model, icon: icon, dark: dark)
        try ReadmeRender.write(scene, size: SocialScene.size, pixelWidth: 1280, dark: dark,
                               to: dir.appendingPathComponent("social-preview.png"))
    }
}

/// Which appearance each single image uses (the hero has both).
enum ReadmeTheme {
    static let panel = false
    static let pair = false
    static let social = true
}

// MARK: - Content

/// The synthetic clipboard behind every image: everyday developer and designer copies, example domains only.
@MainActor
struct ReadmeFixture {
    let store: ItemStore
    var ids: [String: Int64] = [:]
    let fake = FakeCommands()
    /// Mid-afternoon today, so the sections ("Today", "Yesterday") never depend on when the images are drawn.
    let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(15 * 3600)

    static let videoURL = "https://www.video.example/watch?v=yab-glass26"
    static let videoTitle = "Liquid Glass in SwiftUI — a complete guide"

    init(snippets: Bool = false) throws {
        store = try ItemStore.temporary()
        let safari = SourceApp(bundleID: "com.apple.Safari", name: "Safari")
        func ingest(_ key: String, _ representations: [PasteboardRepresentation], minutes: Double, source: SourceApp? = nil,
                    device: DeviceKind = .local) throws {
            let clip = CapturedClip(items: [representations], source: source, device: device,
                                    capturedAt: now.addingTimeInterval(-minutes * 60))
            ids[key] = try #require(try store.ingest(clip)).item.id!
        }
        func text(_ value: String) -> [PasteboardRepresentation] {
            [PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(value.utf8))]
        }

        if snippets {
            // Older copies kept only in the category: they never show in History.
            let category = try store.createCategory(name: "Snippets", color: .slate, visibility: .always)
            // Top to bottom as the column shows them, newest first; added oldest first.
            let saved: [(String, String, Double)] = [
                ("s1", "SELECT pg_size_pretty(pg_total_relation_size('orders'));", 2),
                ("s2", "Thanks for reaching out! We’ll get back to you within a day.", 4),
                ("s3", "git log --oneline --graph -20", 6),
                ("s4", "brew install yt-dlp ffmpeg", 9),
                ("s5", "Your invoice is attached. Let us know if anything looks off.", 12),
                ("s6", "kubectl rollout restart deployment/api", 15),
                ("s7", "npm run build && npm test", 21),
            ]
            for (key, value, days) in saved.reversed() {
                try ingest(key, text(value), minutes: days * 24 * 60)
                try store.add(itemID: ids[key]!, toCategory: category.id!)
                _ = try store.deleteFromHistory(ids[key]!)
            }
        }

        try ingest("reply", text("Hi! Your refund is approved and will reach your card in 3–5 business days."), minutes: 1500)
        try ingest("issue", text("https://git.example.dev/yabbistir/issues/142"), minutes: 47, source: safari)
        try ingest("docker", text("docker compose up -d db"), minutes: 25)
        try ingest("color", text("#C8A27C"), minutes: 14)
        try ingest("note", text("Thursday 2 pm: refund flow demo with Elif and Mert."), minutes: 9, device: .remote)
        try ingest("video", [PasteboardRepresentation(type: TypeIdentifiers.url, data: Data(Self.videoURL.utf8)),
                             PasteboardRepresentation(type: TypeIdentifiers.urlName, data: Data(Self.videoTitle.utf8))],
                   minutes: 6, source: safari)
        try ingest("sql", text("SELECT id, email FROM users WHERE status = 'pending_refund';"), minutes: 2)

        // What the built-in Base64 and Paste to Finder as a File, and the Download Video extension, offer (their
        // English titles), with Finder in front.
        fake.target = TargetInfo(bundleID: "com.apple.finder", name: "Finder", kind: .finder)
        let encode = FakeCommands.command("dev.yabbistir.base64/encode", title: "Encode Base64", keywords: ["base64"],
                                          icon: "sf:arrow.left.arrow.right")
        for key in ["reply", "issue", "docker", "note", "sql"] { fake.transformsByItem[ids[key]!] = [encode] }
        fake.transformsByItem[ids["video"]!] = [
            Self.videoCommand("video"), Self.videoCommand("audio"),
            FakeCommands.command("dev.yabbistir.finderfile/file", title: "Paste to Finder as a File", keywords: ["finder"],
                                 extensionName: "Paste to Finder as a File", hint: false, icon: "sf:arrow.down.doc", output: .file,
                                 targets: [.finder]),
            encode,
        ]
        fake.hints = ["dev.example.video/video": "MP4 · best quality", "dev.example.video/audio": "M4A · audio only",
                      "dev.yabbistir.finderfile/file": "",
                      "dev.yabbistir.base64/encode": Data(Self.videoURL.utf8).base64EncodedString()]
    }

    func panelModel() throws -> PanelViewModel {
        let language = LanguageStore(defaults: UserDefaults(suiteName: "readme-\(UUID())")!)
        language.language = .english
        let now = self.now
        let model = PanelViewModel(library: try Library(store: store), language: language, extensions: fake, now: { now })
        model.reset()
        model.isPresented = true
        return model
    }

    /// The Download Video extension's two variants, as its English manifest names them.
    static func videoCommand(_ variant: String) -> ExtensionCommand {
        let video = variant == "video"
        return FakeCommands.command("dev.example.video/\(variant)", title: video ? "Download as video" : "Download audio",
                                    keywords: ["download"], extensionName: "Download Video", hint: false, icon: "sf:arrow.down.circle",
                                    subtitle: video ? "MP4 · best quality" : "M4A · audio only", output: .file, targets: [.finder],
                                    isJob: true, verb: "Download",
                                    failTitle: video ? "Couldn’t download the video" : "Couldn’t download the audio")
    }

    static let finder = TargetInfo(bundleID: "com.apple.finder", name: "Finder", kind: .finder)

    static var heroJob: JobCenter.Job {
        JobCenter.Job(id: 1, command: videoCommand("video"), subjectTitle: videoTitle, target: finder, toClipboard: false, phase: .running,
                      fraction: 0.42, message: "18.4 / 43.7 MB · 1 min left")
    }

    /// Running, finishing (no fraction), ready on the clipboard (started with ⌘C) and saved: every look a row has.
    static var cardJobs: [JobCenter.Job] {
        [heroJob,
         JobCenter.Job(id: 2, command: videoCommand("audio"), subjectTitle: "Designing calm interfaces", target: finder,
                       toClipboard: false, phase: .running, message: "Merging"),
         JobCenter.Job(id: 3, command: videoCommand("video"), subjectTitle: "Keyboard-first workflows", target: finder, toClipboard: true,
                       phase: .ready, resultName: "Keyboard-first workflows.mp4"),
         JobCenter.Job(id: 4, command: videoCommand("audio"), subjectTitle: "Morning ambient mix", target: finder, toClipboard: false,
                       phase: .done, resultName: "Morning ambient mix.m4a")]
    }
}

// MARK: - Scenes

/// 1280 × 770 pt, drawn at 1800 px: menu bar, editor, the panel 8 pt under its caret (left edge 24 pt left of it, as
/// `PanelPlacement` puts it), the job card under the status item. The panel's bottom keeps 64 pt to the edge.
struct HeroScene: View {
    static let size = CGSize(width: 1280, height: 770)
    let model: PanelViewModel
    let job: JobCenter.Job
    let dark: Bool

    static let editorOrigin = CGPoint(x: (size.width - ReadmeEditor.width) / 2, y: 66)

    var body: some View {
        let caret = ReadmeEditor.caret
        let panelOrigin = CGPoint(x: Self.editorOrigin.x + caret.minX - 24, y: Self.editorOrigin.y + caret.maxY + 8)
        let bar = MenuBarStrip(dark: dark, width: Self.size.width, iconRight: Self.size.width - 24 - MenuBarStrip.longClockWidth - 14,
                               clock: MenuBarStrip.longClock, fraction: job.fraction)
        ReadmeWallpaper(dark: dark)
            .frame(width: Self.size.width, height: Self.size.height)
            .overlay(alignment: .topLeading) {
                ReadmeEditor(dark: dark, height: Self.size.height - Self.editorOrigin.y + 60)
                    .offset(x: Self.editorOrigin.x, y: Self.editorOrigin.y)
            }
            .overlay(alignment: .topLeading) {
                ReadmeJobCard(jobs: [job], dark: dark)
                    .offset(x: bar.cardOrigin.x, y: bar.cardOrigin.y)
            }
            .overlay(alignment: .topLeading) {
                ReadmePanel(model: model, dark: dark)
                    .offset(x: panelOrigin.x, y: panelOrigin.y)
            }
            .overlay(alignment: .top) { bar }
            .clipped()
    }
}

/// The panel with a category column, centered with 56 pt around it.
enum PanelScene {
    static let size = CGSize(width: 720 + 2 * 56, height: Tokens.Metrics.panelHeight + 2 * 56)
}

/// transforms.png and jobs.png share one canvas, so they sit side by side in the README.
enum PairScene {
    static let size = CGSize(width: 480, height: 408)
}

/// The job card hanging from the status item, on the same canvas as transforms.png.
struct JobsScene: View {
    let jobs: [JobCenter.Job]
    let dark: Bool

    var body: some View {
        // The card centered; the status item 10 pt in from its right edge, then the clock.
        let iconRight = (PairScene.size.width + JobCardView.width) / 2 - 10
        let bar = MenuBarStrip(dark: dark, width: PairScene.size.width, iconRight: iconRight, clock: "9:41 AM", fraction: 0.42)
        ReadmeWallpaper(dark: dark)
            .frame(width: PairScene.size.width, height: PairScene.size.height)
            .overlay(alignment: .topLeading) {
                ReadmeJobCard(jobs: jobs, dark: dark)
                    .offset(x: bar.cardOrigin.x, y: bar.cardOrigin.y)
            }
            .overlay(alignment: .top) { bar }
            .clipped()
    }
}

/// 640 × 320 pt at 2×: the icon, name and tagline on the left; the panel, cut by the bottom edge, on the right.
struct SocialScene: View {
    static let size = CGSize(width: 640, height: 320)
    let model: PanelViewModel
    let icon: NSImage
    let dark: Bool

    var body: some View {
        let ink: Color = dark ? .white : .black
        ReadmeWallpaper(dark: dark)
            .frame(width: Self.size.width, height: Self.size.height)
            .overlay(alignment: .leading) {
                VStack(alignment: .leading, spacing: 0) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 84, height: 84).padding(.leading, -7)
                    Text(verbatim: "yabbistir")
                        .font(.system(size: 40, weight: .bold))
                        .tracking(-0.9)
                        .foregroundStyle(ink.opacity(0.92))
                        .padding(.top, 10)
                    Text(verbatim: "Clipboard history that opens\nright under your caret.")
                        .font(.system(size: 17, weight: .medium))
                        .lineSpacing(3)
                        .foregroundStyle(ink.opacity(0.62))
                        .padding(.top, 6)
                    Text(verbatim: "Free and open source · macOS 26+")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(ink.opacity(0.4))
                        .padding(.top, 18)
                }
                .padding(.leading, 48)
            }
            .overlay(alignment: .topLeading) {
                ReadmePanel(model: model, dark: dark)
                    .scaleEffect(0.74, anchor: .topLeading)
                    .offset(x: 326, y: 44)
            }
            .clipped()
    }
}

// MARK: - Parts

/// The panel as the window server shows it: the sheet at its own size with the floating-surface shadow.
struct ReadmePanel: View {
    let model: PanelViewModel
    let dark: Bool

    var body: some View {
        var panel = PanelView(model: model, material: .liquidGlass)
        panel.snapshot = true
        return panel
            .frame(width: model.sheetWidth, height: model.panelHeight)
            .readmeShadow(dark: dark)
    }
}

struct ReadmeJobCard: View {
    let jobs: [JobCenter.Job]
    let dark: Bool

    var body: some View {
        var card = JobCardView(jobs: jobs, language: .english, onCancel: { _ in }, onDismiss: { _ in })
        card.snapshot = true
        return card.readmeShadow(dark: dark)
    }
}

/// The solid surface behind a view that draws glass, which ImageRenderer leaves out (the view keeps its own rim).
struct SolidSurface: View {
    let radius: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Tokens.Colors.surfaceSolid)
    }
}

extension View {
    /// The floating-surface shadow: one deep ambient shadow and a closer, tighter one.
    func readmeShadow(dark: Bool) -> some View {
        let tint = dark ? Color.black : Color(red: 30 / 255, green: 40 / 255, blue: 80 / 255)
        return compositingGroup()
            .shadow(color: tint.opacity(dark ? 0.55 : 0.26), radius: 36, x: 0, y: 26)
            .shadow(color: tint.opacity(dark ? 0.4 : 0.14), radius: 10, x: 0, y: 6)
    }
}

/// A calm grey desktop: a soft diagonal gradient with two pools of light, no hue.
struct ReadmeWallpaper: View {
    let dark: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                LinearGradient(colors: dark ? [grey(0x34363c), grey(0x18191c)] : [grey(0xe4e6ea), grey(0xbfc4cc)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [(dark ? grey(0x5a5e68) : .white).opacity(dark ? 0.42 : 0.6), .clear],
                               center: UnitPoint(x: 0.14, y: 0.0), startRadius: 0, endRadius: max(size.width, size.height) * 0.7)
                RadialGradient(colors: [(dark ? grey(0x2f333c) : grey(0xaab0bc)).opacity(dark ? 0.75 : 0.5), .clear],
                               center: UnitPoint(x: 0.92, y: 1.0), startRadius: 0, endRadius: max(size.width, size.height) * 0.6)
            }
        }
    }
}

/// A minimal menu bar: the yabbistir status item (its ring at the job's progress) and, 14 pt after it, the clock.
struct MenuBarStrip: View {
    static let height: CGFloat = 28
    static let longClock = "Fri Oct 30  9:41 AM"
    static let longClockWidth = (longClock as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width.rounded(.up)
    let dark: Bool
    let width: CGFloat
    /// The status item's right edge.
    let iconRight: CGFloat
    let clock: String
    let fraction: Double?

    /// The status item's frame in the strip.
    var icon: CGRect { CGRect(x: iconRight - 22, y: (Self.height - 22) / 2, width: 22, height: 22) }

    /// The job card hangs 7 pt below the icon, its right edge 10 pt past the icon's.
    var cardOrigin: CGPoint { CGPoint(x: icon.maxX + 10 - JobCardView.width, y: icon.maxY + 7) }

    var body: some View {
        let ink: Color = dark ? Color.white.opacity(0.9) : Color.black.opacity(0.8)
        Rectangle()
            .fill(dark ? Color.black.opacity(0.2) : Color.white.opacity(0.26))
            .frame(width: width, height: Self.height)
            .overlay(alignment: .topLeading) {
                Image(nsImage: StatusRingImage.image(fraction: fraction, spinPhase: 0))
                    .renderingMode(.template)
                    .foregroundStyle(ink)
                    .frame(width: icon.width, height: icon.height)
                    .offset(x: icon.minX, y: icon.minY)
            }
            .overlay(alignment: .leading) {
                Text(verbatim: clock)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(ink)
                    .offset(x: iconRight + 14)
            }
    }
}

/// A generic text editor window (not any real app): traffic lights, a file name, a few lines and the caret.
struct ReadmeEditor: View {
    static let width: CGFloat = 700
    static let titleBar: CGFloat = 48
    static let inset: CGFloat = 40
    static let headingTop: CGFloat = titleBar + 18
    static let lineHeight: CGFloat = 24
    static let bodyFont = NSFont.systemFont(ofSize: 15)
    static let paragraph = "Refund flow walkthrough with Elif and Mert on staging."
    static let caretLine = "To bring the database up locally, run "
    static let checklist = ["Reset staging from last night’s snapshot", "Seed three pending refunds",
                            "Share the screen five minutes early", "Keep the refund email template open"]
    static let caretLineTop = headingTop + 30 + 8 + lineHeight + 6

    /// The caret in window coordinates, right after the last line's text.
    static var caret: CGRect {
        let width = (caretLine as NSString).size(withAttributes: [.font: bodyFont]).width
        return CGRect(x: inset + width.rounded(), y: caretLineTop + 2, width: 2, height: 20)
    }

    let dark: Bool
    let height: CGFloat

    var body: some View {
        let ink: Color = dark ? Color.white.opacity(0.9) : Color.black.opacity(0.84)
        let quiet: Color = dark ? Color.white.opacity(0.5) : Color.black.opacity(0.45)
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                // Grey, as macOS draws a window that isn't key: the panel is where the keys go now.
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { _ in light }
                    Spacer()
                }
                .padding(.leading, 18)
                Text(verbatim: "demo-notes.md")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(quiet)
            }
            .frame(height: Self.titleBar)
            Text(verbatim: "Thursday demo")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(ink)
                .frame(height: 30)
                .padding(.top, Self.headingTop - Self.titleBar)
            Text(verbatim: Self.paragraph)
                .font(.system(size: 15))
                .foregroundStyle(ink.opacity(0.78))
                .frame(height: Self.lineHeight)
                .padding(.top, 8)
            Text(verbatim: Self.caretLine)
                .font(.system(size: 15))
                .foregroundStyle(ink.opacity(0.78))
                .frame(height: Self.lineHeight)
                .padding(.top, 6)
            // The rest of the note runs on under the panel, which floats over it.
            Text(verbatim: "Checklist")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ink)
                .frame(height: Self.lineHeight)
                .padding(.top, 22)
            ForEach(Self.checklist, id: \.self) { line in
                Text(verbatim: "•  " + line)
                    .font(.system(size: 15))
                    .foregroundStyle(ink.opacity(0.78))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: Self.lineHeight)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, Self.inset)
        .frame(width: Self.width, height: height, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(ink)
                .frame(width: Self.caret.width, height: Self.caret.height)
                .offset(x: Self.caret.minX, y: Self.caret.minY)
        }
        .background(dark ? grey(0x252528) : Color.white, in: shape)
        .overlay(shape.strokeBorder(dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08), lineWidth: 0.5))
        .compositingGroup()
        .shadow(color: .black.opacity(dark ? 0.45 : 0.1), radius: 28, x: 0, y: 18)
    }

    private var light: some View {
        Circle()
            .fill(dark ? Color.white.opacity(0.16) : Color.black.opacity(0.11))
            .frame(width: 12, height: 12)
    }
}

private func grey(_ hex: Int) -> Color {
    Color(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
}

// MARK: - Rendering

@MainActor
enum ReadmeRender {
    /// Renders `view` (laid out at `size` points) to an opaque sRGB PNG exactly `pixelWidth` pixels wide.
    static func write(_ view: some View, size: CGSize, pixelWidth: Int, dark: Bool, to url: URL) throws {
        let content = view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.locale, AppLanguage.english.locale)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = CGFloat(pixelWidth) / size.width
        renderer.isOpaque = true
        // The search caret blinks (0.53 s on, 0.53 s off): draw early in an "on" phase so every image shows it.
        let phase = Date().timeIntervalSinceReferenceDate / 0.53
        if Int(phase) % 2 != 0 { Thread.sleep(forTimeInterval: (ceil(phase) - phase) * 0.53 + 0.01) }
        var image: CGImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        let rendered = try #require(image)
        #expect(rendered.width == pixelWidth, "\(url.lastPathComponent) is \(rendered.width) px wide")
        // ImageRenderer may hand back 16 bits per channel; README images are 8-bit sRGB without alpha.
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: rendered.width, height: rendered.height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
        let flat = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, flat, nil)
        #expect(CGImageDestinationFinalize(destination), "\(url.lastPathComponent) was not written")
    }
}

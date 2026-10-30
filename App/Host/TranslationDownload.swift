import AppKit
import SwiftUI
// Translation is not annotated for concurrency: its session cannot be Sendable. The one SwiftUI hands the
// task is used by that task alone, one call at a time.
@preconcurrency import Translation
import YabLocalization
import YabUI

/// Downloads a language pair's pack for Apple Translation, which only the system can do: a small window
/// whose `.translationTask` calls `prepareTranslation()`, and the system's own download sheet opens on
/// it. The window closes once the person is done with the sheet, downloaded or not. The
/// `translationNeeded` notice's "Download" starts it.
@MainActor
final class TranslationDownload {
    static let shared = TranslationDownload()

    private var window: NSWindow?

    /// BCP-47 codes, as the notice carries them.
    func start(from: String, to: String, language: AppLanguage) {
        window?.close()
        let pair = LanguageNames.pair(from: from, to: to, in: language)
        let configuration = TranslationSession.Configuration(source: Locale.Language(identifier: from), target: Locale.Language(identifier: to))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: TranslationDownloadView.size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = pair
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: TranslationDownloadView(pair: pair, configuration: configuration) {
            [weak self, weak window] in
            guard let window, self?.window === window else { return }
            window.close()
            self?.window = nil
        })
        window.center()
        self.window = window
        // A menu bar app: the window, and the sheet on it, come forward only when the app does.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// What sits under the system's sheet: the pair being downloaded, and that it is under way.
private struct TranslationDownloadView: View {
    static let size = CGSize(width: 400, height: 220)

    let pair: String
    let configuration: TranslationSession.Configuration
    let done: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            AppMark()
            Text(pair)
                .font(Tokens.Fonts.labelStrong)
                .foregroundStyle(Tokens.Colors.text)
            ProgressView()
                .controlSize(.small)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .translationTask(configuration) { session in
            // Throws when the person declines the sheet: either way the window has done its work.
            try? await session.prepareTranslation()
            done()
        }
    }
}

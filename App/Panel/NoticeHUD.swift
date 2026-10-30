import AppKit
import SwiftUI
import YabLocalization
import YabPlatform
import YabUI

/// A small floating notice where the panel was, e.g. "Copied — allow Accessibility"
/// or "Copied — Secure Keyboard Entry is on, press ⌘V"; or under the Sıra window; or, from an
/// extension, under the menu bar status item: its own message, or a translation's missing
/// language pack with its download.
@MainActor
final class NoticeHUD {
    private let window: NSPanel
    private var hideTask: Task<Void, Never>?

    init() {
        window = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        window.isFloatingPanel = true
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.sharingType = .none
    }

    func show(near frame: CGRect, language: AppLanguage, kind: NoticeKind) {
        show(language: language, kind: kind) { size in CGPoint(x: frame.minX, y: frame.maxY - size.height) }
    }

    /// With its top-right corner at `corner`, e.g. under the Sıra window.
    func show(topRight corner: CGPoint, language: AppLanguage, kind: NoticeKind) {
        show(language: language, kind: kind) { size in CGPoint(x: corner.x - size.width, y: corner.y - size.height) }
    }

    /// At the origin `origin` gives for the notice's measured size, e.g. under the menu bar status item.
    /// It stays `kind.duration` (an offer longer, so there is time to take it), or until its button is clicked.
    func show(language: AppLanguage, kind: NoticeKind, origin: (CGSize) -> CGPoint) {
        let host = NSHostingView(rootView: NoticeView(language: language, kind: kind) { [weak self] in
            self?.hideTask?.cancel()
            self?.window.orderOut(nil)
            if let action = kind.action { Self.perform(action, language: language) }
        })
        window.contentView = host
        let size = host.fittingSize
        window.setFrame(CGRect(origin: origin(size), size: size), display: true)
        window.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: kind.duration)
            guard !Task.isCancelled else { return }
            self?.window.orderOut(nil)
        }
    }

    /// The notice's button: the settings pane it asks for, or the language pack's download. A notice without one
    /// (`kind.action == nil`) does nothing.
    private static func perform(_ action: NoticeAction, language: AppLanguage) {
        switch action {
        case .accessibilitySettings: NSWorkspace.shared.open(SystemSettingsLink.accessibility)
        case .inputMonitoringSettings: NSWorkspace.shared.open(SystemSettingsLink.inputMonitoring)
        case .downloadLanguagePack(let from, let to): TranslationDownload.shared.start(from: from, to: to, language: language)
        case .openURL(let url): NSWorkspace.shared.open(url)
        }
    }
}

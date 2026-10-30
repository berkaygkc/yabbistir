import AppKit
import Observation
import QuartzCore
import YabExtensions
import YabLocalization
import YabUI

/// Menu bar icon: a click opens the panel under the icon, or, while there are jobs,
/// puts their card away or brings it back; a right or ⌃ click shows the menu, rebuilt on every
/// open so it follows the language and the jobs. While jobs run the icon carries a progress ring.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let env: AppEnvironment
    private let jobsCard: JobsSurfaceController
    private let isPanelVisible: () -> Bool
    private let openPanel: (CGRect?) -> Void
    private let menu = NSMenu()
    private let openMaterialComparison: () -> Void
    private let openSettings: () -> Void
    private let restingImage: NSImage?
    /// A "Check for Updates…" is in flight: its menu item stays off until the answer comes.
    private var isCheckingForUpdates = false
    private var ring = StatusRingMotion(reduceMotion: false)
    private var ringTimer: Timer?
    private var ringTimerInterval: Double?
    /// What the icon shows now; nil for the plain glyph.
    private var drawnRing: RingFrame?

    private struct RingFrame: Equatable {
        var presence: Double, fraction: Double?, spinPhase: Double
    }

    init(env: AppEnvironment, jobsCard: JobsSurfaceController, isPanelVisible: @escaping () -> Bool,
         openPanel: @escaping (CGRect?) -> Void, openSettings: @escaping () -> Void,
         openMaterialComparison: @escaping () -> Void = {}) {
        self.env = env
        self.jobsCard = jobsCard
        self.isPanelVisible = isPanelVisible
        self.openPanel = openPanel
        self.openSettings = openSettings
        self.openMaterialComparison = openMaterialComparison
        let image = NSImage(systemSymbolName: StatusRingImage.glyphName, accessibilityDescription: "yabbistir")
        image?.isTemplate = true
        restingImage = image
        super.init()
        item.button?.image = image
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu.delegate = self
        jobsCard.anchor = { [weak self] in self?.anchor }
        followJobs()
    }

    /// The button on screen and its screen's visible frame (the job card hangs from it).
    private var anchor: (icon: CGRect, visibleFrame: CGRect)? {
        guard let button = item.button, let window = button.window, let screen = window.screen else { return nil }
        return (window.convertToScreen(button.convert(button.bounds, to: nil)), screen.visibleFrame)
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            // Attach the menu only for this click, so a plain click keeps opening the panel.
            item.menu = menu
            sender.performClick(nil)
            item.menu = nil
        } else if !isPanelVisible(), jobsCard.hasJobs {
            // Jobs anchor here: the click puts their card away or brings it back (an open panel closes first).
            jobsCard.toggle()
        } else if let window = sender.window {
            openPanel(window.convertToScreen(sender.convert(sender.bounds, to: nil)))
        }
    }

    // MARK: Ring

    /// The ring follows the jobs: there while any waits or runs, its arc their combined share.
    private func followJobs() {
        let (busy, fraction) = withObservationTracking {
            (env.jobs.isBusy, env.jobs.aggregateFraction)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followJobs() }
        }
        if ring.isAtRest, !busy { return }
        if ring.isAtRest { ring = StatusRingMotion(reduceMotion: Tokens.Motion.reduceMotion()) }
        // Within the same whole percent, or only a new time left: the icon has nothing new to show.
        guard ring.set(busy: busy, fraction: fraction, at: CACurrentMediaTime()) else { return }
        drawRing()
    }

    private func drawRing() {
        ring.advance(to: CACurrentMediaTime())
        let frame = ring.isAtRest ? nil : RingFrame(presence: ring.presence, fraction: ring.fraction, spinPhase: ring.spinPhase)
        if frame != drawnRing {
            item.button?.image = frame == nil ? restingImage : ring.image
            drawnRing = frame
        }
        runRingTimer(every: ring.frameInterval)
    }

    /// Frames only while something moves: 30 a second while easing, 12 while spinning, none at rest.
    /// In the common modes, so the ring keeps turning while a menu is open.
    private func runRingTimer(every interval: Double?) {
        guard interval != ringTimerInterval else { return }
        ringTimer?.invalidate()
        ringTimer = nil
        ringTimerInterval = interval
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drawRing() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ringTimer = timer
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        jobsCard.isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        jobsCard.isMenuOpen = false
    }

    /// "Paneli aç ⇧⌘V"; while jobs wait or run, a **Süren işler** section with an "İptal: <action>"
    /// row for each (the keyboard and VoiceOver route to cancelling); then Language, Settings and Quit.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let language = env.language.language

        let open = NSMenuItem(title: L10n.string("menu.open", language), action: #selector(openPanelAction), keyEquivalent: "v")
        open.keyEquivalentModifierMask = [.command, .shift]
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        if let section = JobsMenuPresentation.section(for: env.jobs.jobs, language: language) {
            menu.addItem(.sectionHeader(title: section.title))
            for row in section.rows { menu.addItem(cancelItem(row)) }
            menu.addItem(.separator())
        }

        let languageItem = NSMenuItem(title: L10n.string("menu.language", language), action: nil, keyEquivalent: "")
        let languages = NSMenu()
        for option in AppLanguage.allCases {
            let entry = NSMenuItem(title: option.nativeName, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            entry.representedObject = option.rawValue
            entry.state = option == language ? .on : .off
            entry.target = self
            languages.addItem(entry)
        }
        languageItem.submenu = languages
        menu.addItem(languageItem)

        let updates = NSMenuItem(title: L10n.string("menu.checkForUpdates", language), action: #selector(checkForUpdatesAction), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)

        let settings = NSMenuItem(title: L10n.string("menu.settings", language), action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        #if DEBUG
        menu.addItem(.separator())
        let comparison = NSMenuItem(title: "Malzeme karşılaştırması", action: #selector(materialComparisonAction), keyEquivalent: "")
        comparison.target = self
        menu.addItem(comparison)
        #endif

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.string("menu.quit", language), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// "İptal: Video olarak indir" with the subject after it in secondary text, cut to fit.
    private func cancelItem(_ row: JobsMenuPresentation.Row) -> NSMenuItem {
        let entry = NSMenuItem(title: row.title, action: #selector(cancelJob(_:)), keyEquivalent: "")
        let font = NSFont.menuFont(ofSize: 0)
        // The title keeps the menu's own color (it follows the highlight); the subject reads secondary.
        let title = NSMutableAttributedString(string: row.title, attributes: [.font: font])
        let subject = JobsMenuPresentation.truncated(row.subject, toWidth: JobsMenuPresentation.subjectWidth, font: font)
        if !subject.isEmpty {
            title.append(NSAttributedString(string: "\u{2003}" + subject, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        entry.attributedTitle = title
        entry.setAccessibilityLabel(row.accessibilityLabel)
        entry.representedObject = row.jobID
        entry.target = self
        return entry
    }

    @objc private func cancelJob(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int else { return }
        env.jobs.cancel(id)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(checkForUpdatesAction) || !isCheckingForUpdates
    }

    /// The only moment the app asks the network anything on its own: the person chose this item.
    @objc private func checkForUpdatesAction() {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        Task { @MainActor [weak self] in
            await self?.env.checkForUpdates()
            self?.isCheckingForUpdates = false
        }
    }

    @objc private func openPanelAction() {
        // Let the menu close first so the panel can take key focus.
        DispatchQueue.main.async { self.openPanel(nil) }
    }

    @objc private func openSettingsAction() {
        DispatchQueue.main.async { self.openSettings() }
    }

    @objc private func materialComparisonAction() {
        DispatchQueue.main.async { self.openMaterialComparison() }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = AppLanguage(rawValue: raw) else { return }
        env.language.language = language
    }
}

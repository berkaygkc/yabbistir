import AppKit
import Observation
import SwiftUI
import YabCore
import YabLocalization
import YabPasteboard
import YabPlatform
import YabStack
import YabUI

/// The Sıra in the app: ⌘⇧C opens it (empty when nothing is selected) and copies the selection
/// into it, copies made while it is open join it, the user's ⌘V brings the next one up. Its window
/// opens beside the pointer and the user can drag it anywhere.
@MainActor
final class StackController {
    let session: StackSession
    private let env: AppEnvironment
    private let window: FloatingSurface
    private let presence = StackWindowState()
    private let notice: NoticeHUD
    private lazy var pasteTap = PasteKeyTap { [weak self] isRepeat in self?.userPasted(isRepeat: isRepeat) ?? true }
    /// Under secure input the tap hears no ⌘V; this claims it instead while the stack is open.
    private let securePaste: SecureInputPaste
    private var tapRunning = false
    private var copying = false
    /// The latest copy kept in history, for ⌘⇧C after an app that copies on its own (`RecentCopy`).
    private var lastCopy: ClipItem?
    private var hideTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?
    private var shadowTask: Task<Void, Never>?
    /// After every change to the stack (the panel's Sıra column follows it).
    var onChange: (() -> Void)?

    private static let screenMargin: CGFloat = 12

    init(env: AppEnvironment) {
        self.env = env
        let sharing = PreferenceEffects.sharingType(hidden: env.preferences.hidesFromScreenSharing)
        window = FloatingSurface(canBecomeKey: false, sizedByOwner: true, sharingType: sharing)
        notice = NoticeHUD(sharingType: sharing)
        // Marked, so the tap lets it pass.
        let securePaste = SecureInputPaste(claim: GlobalShortcuts.setStackPaste(claimed:), type: {
            CGEventKeystrokePoster().post(.commandV, keyCode: KeyCodeResolver.currentASCIICapable().keyCode(for: "v") ?? 9)
        })
        self.securePaste = securePaste
        session = StackSession(library: env.library, writer: SystemPasteboardWriter(),
                               didWrite: { [weak env] changeCount in env?.monitor.ignore(changeCount: changeCount) },
                               changeCount: { NSPasteboard.general.changeCount },
                               // A held ⌘V, now that its item is on the clipboard.
                               replayPaste: { securePaste.typePaste() },
                               plainText: { [weak env] in env?.preferences.alwaysPlainText ?? false })
        session.onChange = { [weak self] in self?.sessionChanged() }
        followRailShortcuts()
    }

    /// ⌘⇧C: opens the stack at once, then copies the frontmost app's selection into it with a
    /// marked ⌘C. When that copies nothing, a copy the app made on its own a moment before joins
    /// instead (`RecentCopy`); otherwise the stack stays open and empty, ready for copies made with
    /// a page's copy button. A beep only when it was already open.
    func copyIntoStack() {
        guard !copying else { return }
        copying = true
        let wasOpen = session.isOpen
        let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let pressedAt = Date()
        session.open()
        Task {
            let trigger = CopyTrigger(reader: SystemPasteboardReader(), resolver: .currentASCIICapable(), poster: CGEventKeystrokePoster())
            let copied = await trigger.copy()
            copying = false
            guard !copied else { return }
            if wasOpen {
                NSSound.beep()
            } else if let id = RecentCopy.meant(lastCopy, frontApp: frontApp, pressedAt: pressedAt),
                      !session.entries.contains(where: { $0.itemID == id }) {
                session.append(id)
            }
        }
    }

    /// Every captured copy joins the open stack. Copying the head again (a snippet tool putting
    /// the clipboard back) adds nothing.
    func captured(_ item: ClipItem) {
        lastCopy = item
        guard let id = item.id, session.isOpen, session.entries.first?.itemID != id else { return }
        session.append(id)
    }

    /// True lets the keystroke through.
    private func userPasted(isRepeat: Bool) -> Bool {
        // With a yabbistir window key (the panel's search field), ⌘V pastes into it, not into an app.
        guard NSApp.keyWindow == nil else { return true }
        return session.userPasted(isRepeat: isRepeat, canHold: pasteTap.holdsKeystrokes)
    }

    /// ⌘V while secure input is on: the tap could not hear it, so the stack counts it here and it is typed again.
    func claimedPastePressed() {
        securePaste.pressed(ownWindowKey: NSApp.keyWindow != nil) { session.userPasted(canHold: true) }
    }

    private func sessionChanged() {
        defer { onChange?() }
        if session.isOpen { securePaste.start() } else { securePaste.stop() }
        if session.isOpen {
            if window.isVisible, hideTask == nil {
                // Input Monitoring may have been granted since the stack opened.
                startTap(announcing: false)
                return
            }
            open()
        } else if window.isVisible {
            close()
        }
    }

    // MARK: Window

    private func open() {
        hideTask?.cancel()
        hideTask = nil
        let wasVisible = window.isVisible
        let pointer = NSEvent.mouseLocation
        let visible = (wasVisible ? window.screen : screen(containing: pointer))?.visibleFrame ?? .zero
        let content = StackWindowContent(
            presence: presence, session: session, library: env.library, language: env.language,
            listMaxHeight: min(StackPanelView.defaultListMaxHeight, visible.height - 260)
        ) { [weak self] size in self?.fit(size) }
        let size = window.fittingSize(of: content)
        window.setFrame(wasVisible ? keepingTop(size) : beside(pointer, size: size, in: visible), display: true)
        window.orderFrontRegardless()
        startTap(announcing: true)
        refreshShadow()
        guard !wasVisible || !presence.shown else { return }
        presence.shown = false
        // Commit the hidden state before animating in (see PanelPresentation.show).
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        presence.shown = true
    }

    private func close() {
        presence.shown = false
        stopTap()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard let self, !Task.isCancelled else { return }
            hideTask = nil
            window.hide()
        }
    }

    /// The window keeps its top edge where it is (the user may have dragged it) and grows down at
    /// once; it shrinks once a leaving row has faded out.
    private func fit(_ size: CGSize) {
        guard window.isVisible, size.height > 0 else { return }
        shrinkTask?.cancel()
        if size.height >= window.frame.height {
            window.setFrame(keepingTop(size), display: true)
            refreshShadow()
            return
        }
        shrinkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard let self, !Task.isCancelled else { return }
            window.setFrame(keepingTop(size), display: true)
            refreshShadow()
        }
    }

    /// Below and to the right of the pointer, like a tooltip; to its left when there is no room.
    private func beside(_ pointer: CGPoint, size: CGSize, in visible: CGRect) -> CGRect {
        var x = pointer.x + 16
        if x + size.width > visible.maxX - Self.screenMargin { x = pointer.x - 16 - size.width }
        return clamped(CGRect(x: x, y: pointer.y - 12 - size.height, width: size.width, height: size.height), to: visible)
    }

    private func keepingTop(_ size: CGSize) -> CGRect {
        let frame = window.frame
        let target = CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        return window.screen.map { clamped(target, to: $0.visibleFrame) } ?? target
    }

    private func clamped(_ frame: CGRect, to visible: CGRect) -> CGRect {
        var frame = frame
        frame.origin.x = max(visible.minX + Self.screenMargin, min(frame.minX, visible.maxX - Self.screenMargin - frame.width))
        frame.origin.y = max(visible.minY + Self.screenMargin, min(frame.minY, visible.maxY - Self.screenMargin - frame.height))
        return frame
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    /// The window's shadow follows its content's alpha: recomputed now and once the entrance or
    /// the rows have settled, as the panel does.
    private func refreshShadow() {
        window.invalidateShadow()
        shadowTask?.cancel()
        shadowTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(360))
            guard !Task.isCancelled else { return }
            self?.window.invalidateShadow()
        }
    }

    // MARK: ⌘V tap and ⌥1 / ⌥2

    /// Without Input Monitoring the stack still works by hand (panel, drag, Bitir); the notice
    /// says why ⌘V does not advance it.
    private func startTap(announcing: Bool) {
        guard !tapRunning else { return }
        tapRunning = pasteTap.start()
        guard !tapRunning, announcing else { return }
        InputMonitoringPermission.request()
        let frame = window.frame
        notice.show(topRight: CGPoint(x: frame.maxX, y: frame.minY - 8), language: env.language.language, kind: .inputMonitoring)
    }

    private func stopTap() {
        pasteTap.stop()
        tapRunning = false
    }

    private func followRailShortcuts() {
        let wanted = withObservationTracking {
            (first: session.wantsRailShortcuts, second: session.offersSecondPlace)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followRailShortcuts() }
        }
        GlobalShortcuts.setRailShortcuts(first: wanted.first, second: wanted.second)
    }
}

@MainActor @Observable
final class StackWindowState {
    var shown = false
}

/// The Sıra panel in its window: top-aligned, fading in with a slight growth from its top-left.
private struct StackWindowContent: View {
    let presence: StackWindowState
    let session: StackSession
    let library: Library
    let language: LanguageStore
    let listMaxHeight: CGFloat
    let onSize: (CGSize) -> Void

    var body: some View {
        StackPanelView(session: session, library: library, language: language.language, listMaxHeight: listMaxHeight)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
            .opacity(presence.shown ? 1 : 0)
            .scaleEffect(presence.shown ? 1 : 0.97, anchor: .topLeading)
            .animation(Tokens.Motion.resolved(Tokens.Motion.ease(0.22)), value: presence.shown)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

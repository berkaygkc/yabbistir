import AppKit
import Observation
import SwiftUI
import YabExtensions
import YabLocalization
import YabPlatform
import YabUI

/// The job card under the menu bar status item: a non-activating surface
/// that never takes focus, so the app in front keeps the keyboard and its ⌘V. It shows while there
/// are jobs, unless a click on the icon put it away (a new job brings it back), and it steps aside
/// while the status item's menu is open.
///
/// Motion follows design.json `job-card`: it enters from 6 pt above at 0.985 scale (0.3 s, the
/// panel's ease-out) while fading in over 0.18 s, and leaves in 0.16 s to 4 pt above at 0.99. The
/// fade is the window's own alpha, so its shadow fades with it; the drop and the scale are the
/// card's, inside a window that reaches `motionRoom` above it. Reduce Motion: it simply appears.
@MainActor
final class JobsSurfaceController {
    /// Room above the card for the drop it enters with.
    static let motionRoom: CGFloat = 6

    private let center: JobCenter
    private let language: LanguageStore
    private let window = FloatingSurface(canBecomeKey: false, sizedByOwner: true)
    private let state = JobCardWindowState()
    /// The status item's button on screen and its screen's visible frame; nil while it has none
    /// (hidden behind the notch), then the card hangs at the top right of the main screen.
    var anchor: () -> (icon: CGRect, visibleFrame: CGRect)? = { nil }
    /// A click on the status item put the card away.
    private(set) var isPutAway = false
    /// The status item's menu is open: the card steps aside, and comes back when it closes.
    var isMenuOpen = false {
        didSet { if isMenuOpen != oldValue { update() } }
    }
    private var knownIDs: Set<Int> = []
    /// The card's own size (the window is `motionRoom` taller).
    private var cardSize: CGSize = .zero
    /// Entering or shown (false while leaving or gone).
    private var isShown = false
    private var leaveTask: Task<Void, Never>?
    private var shadowTask: Task<Void, Never>?

    init(center: JobCenter, language: LanguageStore) {
        self.center = center
        self.language = language
        followJobs()
    }

    var hasJobs: Bool { !center.jobs.isEmpty }

    /// A click on the status item while there are jobs: puts the card away, or brings it back.
    func toggle() {
        isPutAway.toggle()
        update()
    }

    // MARK: Jobs

    private func followJobs() {
        withObservationTracking { _ = center.jobs } onChange: { [weak self] in
            Task { @MainActor in
                self?.jobsChanged()
                self?.followJobs()
            }
        }
    }

    private func jobsChanged() {
        let jobs = center.jobs
        let ids = Set(jobs.map(\.id))
        // A new job brings the card back, and so does the first one after the card emptied.
        if !ids.isSubset(of: knownIDs) || ids.isEmpty { isPutAway = false }
        knownIDs = ids
        // The last card leaves with its rows as they were, not as an empty sliver.
        if !jobs.isEmpty { state.jobs = jobs }
        update()
    }

    // MARK: Showing

    private func update() {
        if !center.jobs.isEmpty, !isPutAway, !isMenuOpen { show() } else { leave() }
    }

    private func show() {
        leaveTask?.cancel()
        leaveTask = nil
        guard !isShown else { return place() }
        isShown = true
        let reduceMotion = Tokens.Motion.reduceMotion()
        let measured = window.fittingSize(of: content)
        cardSize = CGSize(width: measured.width, height: max(0, measured.height - Self.motionRoom))
        if !window.isVisible {
            // From above, unseen; a card still leaving turns back from where it is.
            withTransaction(Self.still) { state.phase = .before }
            window.alphaValue = 0
        }
        place()
        window.orderFrontRegardless()
        // Commit the starting state before animating (see PanelPresentation.show).
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        withAnimation(Tokens.Motion.resolved(Tokens.Motion.ease(0.3))) { state.phase = .shown }
        fade(to: 1, duration: reduceMotion ? 0 : 0.18)
        refreshShadow()
    }

    private func leave() {
        guard isShown else { return }
        isShown = false
        guard !Tokens.Motion.reduceMotion() else { return gone() }
        withAnimation(Tokens.Motion.ease(0.16)) { state.phase = .leaving }
        fade(to: 0, duration: 0.16)
        leaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(170))
            guard !Task.isCancelled else { return }
            self?.gone()
        }
    }

    private func gone() {
        leaveTask = nil
        window.hide()
        withTransaction(Self.still) {
            state.phase = .before
            // Nothing left: the next card starts empty, so its first row grows in.
            if center.jobs.isEmpty { state.jobs = [] }
        }
    }

    /// A change that must not animate, the card's own row animations included.
    private static var still: Transaction {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        return transaction
    }

    private func fade(to alpha: CGFloat, duration: Double) {
        guard duration > 0 else {
            window.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            window.animator().alphaValue = alpha
        }
    }

    // MARK: Placement

    private var content: some View {
        JobCardWindowContent(state: state, language: language,
                             onCancel: { [weak self] in self?.center.cancel($0) },
                             onDismiss: { [weak self] in self?.center.dismiss($0) },
                             onSize: { [weak self] in self?.sized($0) })
    }

    /// Hangs from the status item (JobCardPlacement); the window reaches `motionRoom` above the card.
    private func place() {
        guard cardSize.width > 0 else { return }
        let anchor = anchor() ?? Self.fallbackAnchor()
        let placed = JobCardPlacement.place(cardSize: cardSize, icon: anchor.icon, visibleFrame: anchor.visibleFrame)
        if state.growAnchorX != placed.growAnchorX { state.growAnchorX = placed.growAnchorX }
        var frame = placed.frame
        frame.size.height += Self.motionRoom
        if window.frame != frame { window.setFrame(frame, display: true) }
    }

    /// The height follows the rows as they come and go; the top stays under the icon.
    private func sized(_ size: CGSize) {
        guard size.height > 0, size != cardSize else { return }
        cardSize = size
        guard window.isVisible else { return }
        place()
        refreshShadow()
    }

    /// Where a notice of `size` hangs (an extension's, while the panel is closed): from the status item like the
    /// card, and under the card while it shows, so neither covers the other.
    func noticeOrigin(for size: CGSize) -> CGPoint {
        let anchor = anchor() ?? Self.fallbackAnchor()
        var card: CGRect?
        if isShown, window.isVisible {
            card = window.frame
            card?.size.height -= Self.motionRoom
        }
        return NoticePlacement.underStatusItem(size: size, icon: anchor.icon, visibleFrame: anchor.visibleFrame, jobCard: card).origin
    }

    /// Top right of the main screen, as if the icon were there.
    private static func fallbackAnchor() -> (icon: CGRect, visibleFrame: CGRect) {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return (CGRect(x: visible.maxX - 40, y: visible.maxY, width: 30, height: 0), visible)
    }

    /// The window's shadow follows its content: recomputed now and once the motion has settled.
    private func refreshShadow() {
        window.invalidateShadow()
        shadowTask?.cancel()
        shadowTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(360))
            guard !Task.isCancelled else { return }
            self?.window.invalidateShadow()
        }
    }
}

@MainActor @Observable
final class JobCardWindowState {
    enum Phase { case before, shown, leaving }
    var phase: Phase = .before
    /// The rows on the card: the job center's, kept as they were while the last card leaves.
    var jobs: [JobCenter.Job] = []
    var growAnchorX: CGFloat = 1
}

/// The card at the top of its window, dropping in from above and growing from under the icon.
private struct JobCardWindowContent: View {
    let state: JobCardWindowState
    let language: LanguageStore
    let onCancel: (Int) -> Void
    let onDismiss: (Int) -> Void
    let onSize: (CGSize) -> Void

    var body: some View {
        JobCardView(jobs: state.jobs, language: language.language, onCancel: onCancel, onDismiss: onDismiss)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
            .scaleEffect(scale, anchor: UnitPoint(x: state.growAnchorX, y: 0))
            .offset(y: offset)
            .padding(.top, JobsSurfaceController.motionRoom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var scale: CGFloat {
        switch state.phase {
        case .before: 0.985
        case .shown: 1
        case .leaving: 0.99
        }
    }

    private var offset: CGFloat {
        switch state.phase {
        case .before: -6
        case .shown: 0
        case .leaving: -4
        }
    }
}

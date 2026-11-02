import Carbon.HIToolbox
import Foundation

/// Secure Event Input (a password field, Terminal's Secure Keyboard Entry) hides every keystroke from the Sıra's tap,
/// so a ⌘V pressed there went unheard and the head never left. Global shortcuts still fire under it: while the Sıra
/// is open and secure input is on, ⌘V is claimed as one, the press is counted here and typed again into the app.
@MainActor
public final class SecureInputPaste {
    private let isSecureInput: () -> Bool
    private let claim: (Bool) -> Void
    private let type: () -> Void
    private let interval: Duration
    private let rearm: Duration
    private var watching: Task<Void, Never>?
    /// ⌘V typed within the last `rearm`: the claim waits, so that keystroke reaches the app, not the claim.
    private var typing = 0
    public private(set) var claimed = false

    /// `claim` takes ⌘V as a global shortcut (true) or gives it back (false); `type` types a marked ⌘V.
    public init(isSecureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() }, claim: @escaping (Bool) -> Void,
                type: @escaping () -> Void, interval: Duration = .milliseconds(250), rearm: Duration = .milliseconds(150)) {
        self.isSecureInput = isSecureInput
        self.claim = claim
        self.type = type
        self.interval = interval
        self.rearm = rearm
    }

    /// While the Sıra is open: secure input is looked at every `interval`, and ⌘V claimed while it is on.
    public func start() {
        guard watching == nil else { return }
        watching = Task { [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                self?.refresh()
            }
        }
        refresh()
    }

    public func stop() {
        watching?.cancel()
        watching = nil
        setClaimed(false)
    }

    /// The claimed ⌘V was pressed. Under secure input the tap could not hear it, so `count` (the Sıra's own paste
    /// rule) decides; false holds it for the Sıra to replay. Once secure input is off the tap heard it on its way,
    /// and into yabbistir's own window it is no paste of the Sıra's: either way it is only typed again.
    public func pressed(ownWindowKey: Bool, count: () -> Bool) {
        if ownWindowKey || !isSecureInput() || count() { typePaste() }
    }

    /// Types ⌘V into the front app; the claim is let go meanwhile, so it reaches the app.
    public func typePaste() {
        typing += 1
        setClaimed(false)
        type()
        Task { [weak self, rearm] in
            try? await Task.sleep(for: rearm)
            guard let self else { return }
            typing -= 1
            refresh()
        }
    }

    private func refresh() {
        setClaimed(watching != nil && typing == 0 && isSecureInput())
    }

    private func setClaimed(_ value: Bool) {
        guard value != claimed else { return }
        claimed = value
        claim(value)
    }
}

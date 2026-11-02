import AppKit

/// Hears the moments the Mac stops being in the person's hands: the screen locks, the displays or the Mac go to sleep,
/// or another user takes over. What the app holds in memory only for the moment of use (a source's rows) goes then.
@MainActor
public final class SessionLockObserver {
    /// A system-wide notification with no AppKit name, posted whenever the screen locks (⌃⌘Q, the screen saver, the lid).
    nonisolated static let screenIsLocked = Notification.Name("com.apple.screenIsLocked")

    private let onLock: @MainActor () -> Void
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?

    public init(onLock: @escaping @MainActor () -> Void) {
        self.onLock = onLock
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onLock() }
            })
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: Self.screenIsLocked, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onLock() }
        }
    }

    isolated deinit {
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
    }
}

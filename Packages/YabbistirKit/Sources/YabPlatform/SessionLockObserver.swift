import AppKit

/// Hears the moments the Mac stops being in the person's hands: the screen locks, the displays or the Mac go to sleep,
/// or another user takes over. What the app holds in memory only for the moment of use (a source's rows) goes then.
@MainActor
public final class SessionLockObserver {
    /// A system-wide notification with no AppKit name, posted whenever the screen locks (⌃⌘Q, the screen saver, the lid).
    nonisolated static let screenIsLocked = Notification.Name("com.apple.screenIsLocked")

    private let onLock: @MainActor () -> Void
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockTarget: ScreenLockTarget?

    public init(onLock: @escaping @MainActor () -> Void) {
        self.onLock = onLock
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onLock() }
            })
        }
        // The app is an accessory, so it is inactive most of the time, and a distributed notification waits for an
        // inactive app unless its observer asks otherwise. Only the selector form can ask: the lock is heard at once.
        let target = ScreenLockTarget { [weak self] in self?.onLock() }
        DistributedNotificationCenter.default().addObserver(target, selector: #selector(ScreenLockTarget.screenLocked(_:)),
                                                            name: Self.screenIsLocked, object: nil, suspensionBehavior: .deliverImmediately)
        lockTarget = target
    }

    isolated deinit {
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let lockTarget { DistributedNotificationCenter.default().removeObserver(lockTarget) }
    }
}

/// The screen lock's observer, an Objective-C target for the selector form.
private final class ScreenLockTarget: NSObject {
    let fire: @MainActor @Sendable () -> Void

    init(_ fire: @escaping @MainActor @Sendable () -> Void) {
        self.fire = fire
    }

    @objc func screenLocked(_ notification: Notification) {
        let fire = fire
        // Distributed notifications come on the main thread's run loop; from anywhere else, the lock is told there.
        if Thread.isMainThread {
            MainActor.assumeIsolated { fire() }
        } else {
            Task { @MainActor [fire] in fire() }
        }
    }
}

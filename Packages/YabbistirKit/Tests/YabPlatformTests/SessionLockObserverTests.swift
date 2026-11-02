import AppKit
import Testing
@testable import YabPlatform

/// The Mac going to sleep, its displays sleeping and another user taking over each count as a lock. (The screen lock
/// itself is a system-wide notification: a test never posts it, other apps would hear it too.) One test at a time: they
/// post to the same workspace notification center.
@MainActor @Suite(.serialized) struct SessionLockObserverTests {
    @Test func sleepAndSwitchingUsersCountAsALock() async throws {
        var locks = 0
        let observer = SessionLockObserver { locks += 1 }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            center.post(name: name, object: NSWorkspace.shared)
        }
        let start = ContinuousClock.now
        while locks < 3, ContinuousClock.now - start < .seconds(2) { await Task.yield() }
        #expect(locks == 3)
        // Another app becoming active is no lock.
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared)
        await Task.yield()
        #expect(locks == 3)
        withExtendedLifetime(observer) {}
    }

    /// Once the observer is gone, nothing is called.
    @Test func aGoneObserverHearsNothing() async throws {
        var locks = 0
        var observer: SessionLockObserver? = SessionLockObserver { locks += 1 }
        observer = nil
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        await Task.yield()
        #expect(locks == 0)
        #expect(observer == nil)
    }
}

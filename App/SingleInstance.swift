import AppKit
import os
import YabPlatform

/// The release and the Debug build share one history, so two running copies would both capture every copy. The
/// one launched last wins: it asks the other to quit before the store opens, and quits itself when the other is
/// launched later.
@MainActor
enum SingleInstance {
    private static let log = Logger(subsystem: "dev.yabbistir.app", category: "launch")

    /// Asks the other build to quit and waits up to `timeout` seconds. The run loop keeps turning while it waits.
    static func replaceCounterpart(timeout: TimeInterval = 3) {
        guard let own = Bundle.main.bundleIdentifier, let other = CounterpartApp.counterpart(of: own) else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: other).filter { !$0.isTerminated }
        guard !running.isEmpty else { return }
        for app in running { app.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while running.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if running.contains(where: { !$0.isTerminated }) {
            log.error("The other build is still running after \(timeout, format: .fixed(precision: 0)) s; continuing anyway.")
        }
    }

    /// Quits this copy when the other build is launched later, so the one launched last wins even when that build
    /// predates the check above. Observes `runningApplications` rather than the launch notification, which
    /// workspace does not reliably post for accessory apps. Apps already running when this starts are ignored.
    static func yieldToLaterLaunches() {
        guard let own = Bundle.main.bundleIdentifier, CounterpartApp.counterpart(of: own) != nil else { return }
        runningObserver = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { _, change in
            // A replacement carries the whole list, an insertion only the new entries; diffing covers both.
            let known = Set((change.oldValue ?? []).map(\.processIdentifier))
            let added = (change.newValue ?? []).filter { !known.contains($0.processIdentifier) }.compactMap(\.bundleIdentifier)
            guard CounterpartApp.shouldQuit(ownID: own, added: added) else { return }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private static var runningObserver: NSKeyValueObservation?
}

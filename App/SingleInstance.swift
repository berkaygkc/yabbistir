import AppKit
import os
import YabPlatform

/// The release and the Debug build share one history, so two running copies would both capture every copy. The
/// one launched last wins: it asks an earlier copy of the other build to quit before the store opens, and quits
/// itself when the other is launched later. Each side acts only against an earlier launch (`CounterpartApp`), so two
/// copies started within a moment of each other never quit each other.
@MainActor
enum SingleInstance {
    private static let log = Logger(subsystem: "dev.yabbistir.app", category: "launch")

    /// Asks the other build to quit, when it was launched before this copy, and waits up to `timeout` seconds. The run
    /// loop keeps turning while it waits.
    static func replaceCounterpart(timeout: TimeInterval = 3) {
        guard let own = Bundle.main.bundleIdentifier, let other = CounterpartApp.counterpart(of: own) else { return }
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: other).filter { !$0.isTerminated }
        let earlier = Set(CounterpartApp.copiesToReplace(own: copy(NSRunningApplication.current, bundleID: own),
                                                         running: candidates.map { copy($0, bundleID: other) }).map(\.processID))
        let running = candidates.filter { earlier.contains($0.processIdentifier) }
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
        let me = copy(NSRunningApplication.current, bundleID: own)
        runningObserver = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { _, change in
            // A replacement carries the whole list, an insertion only the new entries; diffing covers both.
            let known = Set((change.oldValue ?? []).map(\.processIdentifier))
            let added = (change.newValue ?? []).filter { !known.contains($0.processIdentifier) }
                .compactMap { app in app.bundleIdentifier.map { copy(app, bundleID: $0) } }
            guard CounterpartApp.shouldQuit(own: me, added: added) else { return }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private static var runningObserver: NSKeyValueObservation?

    private nonisolated static func copy(_ app: NSRunningApplication, bundleID: String) -> RunningCopy {
        RunningCopy(bundleID: bundleID, launchDate: app.launchDate, processID: app.processIdentifier)
    }
}

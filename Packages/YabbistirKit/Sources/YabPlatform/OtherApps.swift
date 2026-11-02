import AppKit

/// Another clipboard manager that may be running beside this app, both builds of it (its own and the subscription build).
public enum OtherClipboardApp {
    public static let bundleIDs = ["com.wiheads.paste-setapp", "com.wiheads.paste"]

    private static func running() -> [NSRunningApplication] {
        bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }.filter { !$0.isTerminated }
    }

    public static func isRunning() -> Bool { !running().isEmpty }

    /// Asks every running copy to quit; it does not wait.
    public static func quit() {
        for app in running() { app.terminate() }
    }
}

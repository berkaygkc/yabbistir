import Foundation

/// Paths and defaults suites for tests that must not outlive the test process.
///
/// Every path sits in one folder per process in the temporary directory, and every suite name carries the
/// process id. Both are removed when the process exits, and whatever a crashed run left behind is removed by
/// the next run. Before this, each run left thousands of folders in the temporary directory and of suites in
/// ~/Library/Preferences, which macOS never clears (115,000 of them by 2026-11-13).
public enum TestScratch {
    /// A fresh path in this run's folder; nothing exists at it yet.
    public static func url(_ name: String, pathExtension: String? = nil) -> URL {
        var url = scratchRun.folder.appendingPathComponent("\(name)-\(UUID().uuidString)")
        if let pathExtension { url.appendPathExtension(pathExtension) }
        return url
    }

    /// A new, empty defaults suite.
    public static func defaults(_ name: String) -> UserDefaults {
        UserDefaults(suiteName: suiteName(name))!
    }

    /// The name of a new, empty defaults suite, for a test that reads the suite's persistent domain.
    public static func suiteName(_ name: String) -> String {
        let suite = scratchRun.suitePrefix + "\(name)-\(UUID().uuidString)"
        scratchRun.record(suite)
        return suite
    }
}

private let scratchRun = ScratchRun()

private final class ScratchRun: @unchecked Sendable {
    static let namePrefix = "yabbistir-tests."
    static let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences", isDirectory: true)

    let folder: URL
    let suitePrefix: String
    private let lock = NSLock()
    private var suites: [String] = []

    init() {
        let pid = getpid()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.namePrefix)\(pid)", isDirectory: true)
        suitePrefix = "\(Self.namePrefix)\(pid)."
        Self.removeLeftovers()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        atexit { scratchRun.removeAll() }
    }

    func record(_ suite: String) {
        lock.withLock { suites.append(suite) }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: folder)
        for suite in lock.withLock({ suites }) { Self.removeSuite(suite) }
    }

    private static func removeSuite(_ suite: String) {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        CFPreferencesSynchronize(suite as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        // Emptying the domain leaves its file behind.
        try? FileManager.default.removeItem(at: preferences.appendingPathComponent("\(suite).plist"))
    }

    /// Folders and suites of earlier runs whose process is gone; a run still going in another checkout keeps its own.
    private static func removeLeftovers() {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory
        for name in (try? fm.contentsOfDirectory(atPath: temporary.path)) ?? [] where isLeftover(name) {
            try? fm.removeItem(at: temporary.appendingPathComponent(name))
        }
        for name in (try? fm.contentsOfDirectory(atPath: preferences.path)) ?? [] where name.hasSuffix(".plist") && isLeftover(name) {
            removeSuite(String(name.dropLast(".plist".count)))
        }
    }

    /// "yabbistir-tests.<pid>" or "yabbistir-tests.<pid>.<suite>", where no process <pid> is running.
    private static func isLeftover(_ name: String) -> Bool {
        guard name.hasPrefix(namePrefix), let pid = Int32(name.dropFirst(namePrefix.count).prefix { $0.isNumber }) else { return false }
        return kill(pid, 0) != 0 && errno == ESRCH
    }
}

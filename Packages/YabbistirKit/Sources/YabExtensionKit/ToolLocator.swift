import Foundation

/// Finds the command-line tools extensions run (`requires.tools`): the first
/// folder of the search path that holds an executable file of that name.
public struct ToolLocator: Sendable {
    public let searchPath: [String]

    public init(searchPath: [String]) {
        self.searchPath = searchPath
    }

    /// Homebrew's folders (Apple silicon, then Intel), then the process's PATH; each folder once, in
    /// order. Only absolute folders: an empty or relative entry would mean the current folder.
    public static var standard: ToolLocator {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen: Set<String> = []
        return ToolLocator(searchPath: (["/opt/homebrew/bin", "/usr/local/bin"] + path).filter { $0.hasPrefix("/") && seen.insert($0).inserted })
    }

    /// The tool's path in the first folder that has it as an executable file (a folder never counts).
    public func locate(_ name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for folder in searchPath {
            let path = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(name).path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// The tools that are not found, in the order given.
    public func missing(_ tools: [ToolSpec]) -> [ToolSpec] {
        tools.filter { locate($0.name) == nil }
    }
}

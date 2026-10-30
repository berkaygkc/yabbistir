import Foundation
import Testing
import YabExtensionKit

@Suite struct ToolLocatorTests {
    static let ytdlp = ToolSpec(name: "yt-dlp", install: "brew install yt-dlp")
    static let ffmpeg = ToolSpec(name: "ffmpeg", install: "brew install ffmpeg")
    static let ffprobe = ToolSpec(name: "ffprobe", install: "brew install ffmpeg")

    @Test func theStandardSearchPathPrefersHomebrew() {
        let searchPath = ToolLocator.standard.searchPath
        #expect(Array(searchPath.prefix(2)) == ["/opt/homebrew/bin", "/usr/local/bin"])
        // Then the process's PATH in its own order, each folder once; an empty or relative entry is never searched.
        var seen: Set<String> = []
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let expected = (["/opt/homebrew/bin", "/usr/local/bin"] + path).filter { $0.hasPrefix("/") && seen.insert($0).inserted }
        #expect(searchPath == expected)
    }

    @Test func missingListsOnlyToolsNotFound() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-locate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ffmpeg = folder.appendingPathComponent("ffmpeg")
        try Data("#!/bin/sh\n".utf8).write(to: ffmpeg)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpeg.path)
        // Neither a file that cannot be run nor a folder counts as the tool.
        let notExecutable = folder.appendingPathComponent("yt-dlp")
        try Data("#!/bin/sh\n".utf8).write(to: notExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: notExecutable.path)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("ffprobe"), withIntermediateDirectories: true)

        let locator = ToolLocator(searchPath: [folder.appendingPathComponent("nowhere").path, folder.path])
        #expect(locator.missing([Self.ytdlp, Self.ffmpeg]) == [Self.ytdlp])
        #expect(locator.missing([Self.ffprobe, Self.ffmpeg, Self.ytdlp]) == [Self.ffprobe, Self.ytdlp])
        #expect(locator.locate("ffmpeg")?.path == ffmpeg.path)
        #expect(locator.locate("../\(folder.lastPathComponent)/ffmpeg") == nil)
        #expect(locator.locate("") == nil)
    }

    @Test func theFirstFolderThatHasTheToolWins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yab-locate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let tool = folder.appendingPathComponent("ffmpeg")
            try Data("#!/bin/sh\n".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        #expect(ToolLocator(searchPath: [first.path, second.path]).locate("ffmpeg")?.path == first.appendingPathComponent("ffmpeg").path)
        #expect(ToolLocator(searchPath: [second.path, first.path]).locate("ffmpeg")?.path == second.appendingPathComponent("ffmpeg").path)
    }
}

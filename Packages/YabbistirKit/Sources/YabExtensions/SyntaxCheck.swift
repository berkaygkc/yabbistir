import Foundation
import JavaScriptCore
import YabExtensionKit

/// Parses index.js without running any of it (JSCheckScriptSyntax), so a broken extension is
/// listed with its problem instead of failing in the panel.
enum SyntaxCheck {
    static func problem(in folder: URL) -> ManifestIssue? {
        // A missing index.js is the validator's problem.
        guard let source = try? String(contentsOf: folder.appendingPathComponent("index.js"), encoding: .utf8) else { return nil }
        let context = JSGlobalContextCreate(nil)
        defer { JSGlobalContextRelease(context) }
        let script = JSStringCreateWithUTF8CString(source)
        defer { JSStringRelease(script) }
        var exception: JSValueRef?
        guard !JSCheckScriptSyntax(context, script, nil, 1, &exception), let exception else { return nil }
        let error = JSValue(jsValueRef: exception, in: JSContext(jsGlobalContextRef: context))
        let message = error?.forProperty("message")?.toString() ?? error?.toString() ?? "syntax error"
        let line = error?.forProperty("line").flatMap { $0.isNumber ? Int($0.toInt32()) : nil }
        return ManifestIssue("index.js", (line.map { "line \($0): " } ?? "") + message,
                             fix: "Fix the syntax error and save; the extension reloads on its own.")
    }
}

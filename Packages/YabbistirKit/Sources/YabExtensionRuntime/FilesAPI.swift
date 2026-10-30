import Foundation
import JavaScriptCore
import YabExtensionKit

/// `yab.files`: the call's work folder and what may be read from it. Every
/// path is resolved (links and `..`) before it is compared with the folder, so nothing leaves it.
enum FilesAPI {
    static let nameLimit = 200

    static func install(in runtime: ExtensionRuntime) {
        let context = runtime.context
        let yab = context.objectForKeyedSubscript("yab")!
        let files = JSValue(newObjectIn: context)!

        let workDir: @convention(block) () -> JSValue? = { [weak runtime] in
            guard let runtime else { return nil }
            return guarded { () throws(ExtensionError) -> JSValue? in
                runtime.jsValue(.string(try scope(in: runtime).workFolder.path))
            }
        }
        let define = context.evaluateScript("(function (o, g) { Object.defineProperty(o, 'workDir', { get: g, enumerable: true }); })")
        define?.call(withArguments: [files, unsafeBitCast(workDir, to: AnyObject.self)])

        let write: @convention(block) (JSValue?, JSValue?) -> JSValue? = { [weak runtime] name, data in
            guard let runtime else { return nil }
            return guarded { () throws(ExtensionError) -> JSValue? in
                let scope = try scope(in: runtime)
                guard let name, name.isString else { throw ExtensionError(.badResult, "yab.files.write takes a file name") }
                let clean = try sanitized(name.toString())
                guard let data, let bytes = bytes(of: data, runtime: runtime) else {
                    throw ExtensionError(.badResult, "yab.files.write takes a string, a Uint8Array or an image handle")
                }
                let file = try scope.workFolder.appendingPathComponent(clean)
                do {
                    try bytes.write(to: file, options: .atomic)
                } catch {
                    throw ExtensionError(.unavailable, "the file could not be written: \(error.localizedDescription)")
                }
                return runtime.jsValue(.string(file.path))
            }
        }
        let read: @convention(block) (JSValue?) -> JSValue? = { [weak runtime] path in
            guard let runtime else { return nil }
            return guarded { () throws(ExtensionError) -> JSValue? in
                let scope = try scope(in: runtime)
                guard let real = try allowed(path, in: scope), let data = FileManager.default.contents(atPath: real) else {
                    throw ExtensionError(.badResult, "yab.files.read reads only files in yab.files.workDir, the item's own files and the folders chosen in preferences")
                }
                return bytesValue(data, in: runtime.context)
            }
        }
        let exists: @convention(block) (JSValue?) -> Bool = { [weak runtime] path in
            guard let runtime, let scope = runtime.currentScope, scope.endReason == nil else { return false }
            return ((try? allowed(path, in: scope)) ?? nil) != nil
        }
        for (name, function) in [("write", unsafeBitCast(write, to: AnyObject.self)), ("read", unsafeBitCast(read, to: AnyObject.self)),
                                 ("exists", unsafeBitCast(exists, to: AnyObject.self))] {
            files.setValue(function, forProperty: name)
        }
        yab.setValue(files, forProperty: "files")
    }

    // MARK: Names and paths

    /// `/` and `:` become `-`; `.`, `..` (alone or as a part), an empty name and one over 200 characters are
    /// refused. Checked on the final name, after every transformation, so no spelling gets past.
    static func sanitized(_ name: String) throws(ExtensionError) -> String {
        let trim = { (text: Substring) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if name.split(separator: "/", omittingEmptySubsequences: false).map(trim).contains(where: { $0 == ".." || $0 == "." }) {
            throw ExtensionError(.badResult, "a file name cannot contain \"..\" or \".\"")
        }
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != ".", clean != ".." else { throw ExtensionError(.badResult, "a file name cannot be empty, \".\" or \"..\"") }
        guard clean.count <= nameLimit else { throw ExtensionError(.badResult, "a file name is at most \(nameLimit) characters") }
        return clean
    }

    /// The real path when `path` is in the work folder or is one of the item's own files; nil otherwise.
    private static func allowed(_ path: JSValue?, in scope: CallScope) throws(ExtensionError) -> String? {
        guard let path, path.isString else { throw ExtensionError(.badResult, "expected a file path") }
        let text = path.toString() ?? ""
        if let folder = scope.createdWorkFolder, let real = WorkFolders.contained(text, in: folder) { return real }
        guard let real = WorkFolders.realPath(text) else { return nil }
        if scope.readablePaths.contains(real) { return real }
        return scope.readableFolders.lazy.compactMap { WorkFolders.contained(real, in: URL(fileURLWithPath: $0)) }.first
    }

    // MARK: Plumbing

    private static func scope(in runtime: ExtensionRuntime) throws(ExtensionError) -> CallScope {
        guard let scope = runtime.currentScope else { throw ExtensionError(.permissionDenied, "yab.files works inside a call") }
        if let ended = scope.endReason { throw ended }
        return scope
    }

    /// Runs `body`; what it throws reaches the script as an Error carrying its code.
    private static func guarded(_ body: () throws(ExtensionError) -> JSValue?) -> JSValue? {
        let context = JSContext.current()!
        do {
            return try body()
        } catch {
            context.exception = NativeAPI.errorValue(error, in: context)
            return JSValue(undefinedIn: context)
        }
    }

    private static func bytes(of value: JSValue, runtime: ExtensionRuntime) -> Data? {
        if value.isString { return Data((value.toString() ?? "").utf8) }
        if let data = NativeAPI.typedArrayData(value, in: runtime.context) { return data }
        guard let entry = runtime.images.entry(runtime.json(value)) else { return nil }
        if entry.uti == "public.png", let data = entry.data { return data }
        return ImageCodec.encode(entry.image, as: "public.png")
    }

    static func bytesValue(_ data: Data, in context: JSContext) -> JSValue? {
        if data.isEmpty { return context.evaluateScript("new Uint8Array(0)") }
        let global = context.jsGlobalContextRef
        var exception: JSValueRef?
        guard let array = JSObjectMakeTypedArray(global, kJSTypedArrayTypeUint8Array, data.count, &exception),
              let pointer = JSObjectGetTypedArrayBytesPtr(global, array, &exception) else { return nil }
        data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: data.count)
        return JSValue(jsValueRef: array, in: context)
    }
}

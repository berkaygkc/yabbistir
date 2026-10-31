import Foundation
import JavaScriptCore
import YabExtensionKit

/// The `yab` object's core: language, translations, preferences, a small
/// per-extension store and a job's progress.
enum HostAPI {
    /// The store's ceiling: storage.json may not grow past this.
    static let storageLimit = 1_048_576

    static func install(in runtime: ExtensionRuntime) {
        let context = runtime.context
        let yab = JSValue(newObjectIn: context)!
        yab.setValue("en", forProperty: "language")
        yab.setValue(JSValue(newObjectIn: context), forProperty: "preferences")

        let translate: @convention(block) (String, JSValue?) -> String = { [weak runtime] key, arguments in
            guard let runtime else { return key }
            var text = runtime.localization.string(key, language: runtime.currentLanguage)
            for (name, value) in runtime.json(arguments).objectValue ?? [:] {
                let replacement = switch value {
                case .string(let string): string
                // Whole numbers print without ".0"; huge or infinite ones never reach Int.
                case .number(let number): number.isFinite && abs(number) < 1e15 && number == number.rounded() ? String(Int(number)) : String(number)
                case .bool(let flag): String(flag)
                default: ""
                }
                text = text.replacingOccurrences(of: "{\(name)}", with: replacement)
            }
            return text
        }
        yab.setValue(unsafeBitCast(translate, to: AnyObject.self), forProperty: "t")

        let storage = JSValue(newObjectIn: context)!
        let get: @convention(block) (String) -> JSValue? = { [weak runtime] key in
            guard let runtime, let value = runtime.storage[key] else { return JSValue(undefinedIn: JSContext.current()) }
            return runtime.jsValue(value)
        }
        let set: @convention(block) (String, JSValue?) -> Void = { [weak runtime] key, value in
            guard let runtime else { return }
            var next = runtime.storage
            next[key] = runtime.json(value)
            guard runtime.saveStorage(next) else {
                let context = JSContext.current()
                context?.exception = JSValue(newErrorFromMessage: "yab.storage is full (1 MB); remove keys before adding more", in: context)
                return
            }
        }
        let remove: @convention(block) (String) -> Void = { [weak runtime] key in
            guard let runtime else { return }
            var next = runtime.storage
            next.removeValue(forKey: key)
            _ = runtime.saveStorage(next)
        }
        storage.setValue(unsafeBitCast(get, to: AnyObject.self), forProperty: "get")
        storage.setValue(unsafeBitCast(set, to: AnyObject.self), forProperty: "set")
        storage.setValue(unsafeBitCast(remove, to: AnyObject.self), forProperty: "remove")
        yab.setValue(storage, forProperty: "storage")

        // yab.secrets.get(id): this extension's own secret preference or null. No permission and no effects
        // are needed, so it works in every kind of call and at the top level; an id that is not a declared
        // secret has no value. Nothing here is ever logged.
        let secrets = JSValue(newObjectIn: context)!
        let secret: @convention(block) (JSValue?) -> JSValue? = { [weak runtime] id in
            let context = JSContext.current()!
            guard let runtime, let id, id.isString, let value = runtime.secrets[id.toString() ?? ""] else { return JSValue(nullIn: context) }
            return JSValue(object: value, in: context)
        }
        secrets.setValue(unsafeBitCast(secret, to: AnyObject.self), forProperty: "get")
        yab.setValue(secrets, forProperty: "secrets")

        let job = JSValue(newObjectIn: context)!
        let progress: @convention(block) (JSValue?, JSValue?) -> Void = { [weak runtime] fraction, message in
            guard let runtime else { return }
            var share: Double?
            if let fraction, !fraction.isUndefined, !fraction.isNull {
                guard fraction.isNumber, fraction.toDouble().isFinite else {
                    let context = JSContext.current()!
                    context.exception = NativeAPI.errorValue(ExtensionError(.badResult, "yab.job.progress takes a fraction from 0 to 1, or null"),
                                                             in: context)
                    return
                }
                share = min(1, max(0, fraction.toDouble()))
            }
            let text = message.flatMap { $0.isUndefined || $0.isNull ? nil : $0.toString() }
            // Outside any call (index.js's top level, a call long over) it goes nowhere.
            runtime.currentScope?.progress(share, text)
        }
        job.setValue(unsafeBitCast(progress, to: AnyObject.self), forProperty: "progress")
        yab.setValue(job, forProperty: "job")

        context.setObject(yab, forKeyedSubscript: "yab" as NSString)
    }

    // MARK: Effects

    /// The network and programs: only in a run the person started, only while it runs
    /// (never from a timer or continuation it left behind), and only with the permission granted.
    static func require(_ permission: String, in scope: CallScope) throws(ExtensionError) {
        try require(effectsFor: permission, in: scope)
        guard scope.grant.permissions.contains(permission) else {
            throw ExtensionError(.permissionDenied, "\(scope.extensionID) has no \(permission) permission")
        }
    }

    /// The same rule for what reaches beyond the call without a permission of its own (`yab.notify`, `yab.open`).
    static func require(effectsFor name: String, in scope: CallScope) throws(ExtensionError) {
        if let ended = scope.endReason { throw ended }
        guard scope.effects else {
            throw ExtensionError(.permissionDenied, "\(name) is not available in hints, detectors and previews")
        }
    }

    /// History: the `history` permission, and not from a rule, detector or preview. Its messages are fixed English
    /// for the developer: the script sees the app's refusal, in the app's language, instead (`HistoryAPI`).
    static func require(historyIn scope: CallScope) throws(ExtensionError) {
        if let ended = scope.endReason { throw ended }
        guard scope.grant.permissions.contains("history") else {
            throw ExtensionError(.permissionDenied, "\(scope.extensionID) has no history permission")
        }
        guard scope.kind == .run else {
            throw ExtensionError(.permissionDenied, "history is not available in rules, detectors and previews")
        }
    }

    // MARK: Arguments

    static func json(_ item: ExtensionItem) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .number(Double(item.id)),
            "kind": .string(item.kind),
            "tags": .array(item.tags.map(JSONValue.string)),
            "copiedAt": .string(ISO8601DateFormatter().string(from: item.copiedAt)),
        ]
        if let text = item.text { fields["text"] = .string(text) }
        if let url = item.url { fields["url"] = .string(url) }
        if let color = item.color {
            fields["color"] = .object(["hex": .string(color.hex), "r": .number(Double(color.r)), "g": .number(Double(color.g)),
                                       "b": .number(Double(color.b)), "a": .number(color.a)])
        }
        if let files = item.files {
            fields["files"] = .array(files.map { .object(["path": .string($0.path), "name": .string($0.name),
                                                         "size": .number(Double($0.size)), "uti": .string($0.uti)]) })
        }
        if let html = item.richText?.html { fields["richText"] = .object(["html": .string(html)]) }
        if let source = item.source {
            fields["source"] = .object(["name": source.name.map(JSONValue.string) ?? .null,
                                        "bundleID": source.bundleID.map(JSONValue.string) ?? .null, "device": .string(source.device)])
        }
        return .object(fields)
    }

    static func json(_ context: ExtensionContext) -> JSONValue {
        let target: JSONValue = context.target.map {
            .object(["bundleID": .string($0.bundleID), "name": .string($0.name), "kind": .string($0.kind.rawValue)])
        } ?? .null
        return .object(["language": .string(context.language), "preferences": .object(context.preferences),
                        "trigger": .string(context.trigger.rawValue), "variant": context.variant.map(JSONValue.string) ?? .null,
                        "target": target])
    }

    // MARK: Results

    /// `workFolder`: the call's work folder; a `{ file }` or `{ files }` must lie inside it (nil: no file can).
    static func result(from value: JSONValue, images: ImageHandleStore, workFolder: URL? = nil) throws(ExtensionError) -> ExtensionResult {
        let shapes = "expected {text}, {html, text}, {image}, {link: {url, title}}, {file}, {files} or {none: true}"
        guard let object = value.objectValue else { throw ExtensionError(.badResult, "run returned \(shape(of: value)); \(shapes)") }
        if let html = object["html"]?.stringValue {
            return .html(html: html, text: object["text"]?.stringValue ?? "")
        }
        if let text = object["text"]?.stringValue { return .text(text) }
        if let link = object["link"]?.objectValue {
            guard let url = link["url"]?.stringValue else { throw ExtensionError(.badResult, "link.url is missing; \(shapes)") }
            return .link(url: url, title: link["title"]?.stringValue)
        }
        if let file = object["file"] {
            return .file(path: try workFile(file, in: workFolder))
        }
        if let list = object["files"] {
            guard let entries = list.arrayValue, !entries.isEmpty else {
                throw ExtensionError(.badResult, "files must be a list of paths with at least one file")
            }
            return .files(paths: try entries.map { (entry: JSONValue) throws(ExtensionError) -> String in try workFile(entry, in: workFolder) })
        }
        if object["none"]?.boolValue == true { return .none(message: object["message"]?.stringValue) }
        if let handle = object["image"] {
            guard let image = images.encoded(handle) else {
                throw ExtensionError(.badResult, "image must be an image handle (item.image or the result of a yab.image call)")
            }
            return .image(data: image.data, uti: image.uti, width: image.width, height: image.height)
        }
        throw ExtensionError(.badResult, "run returned an object of another shape; \(shapes)")
    }

    /// A result file's real path: it exists, is a file and lies inside the call's work folder (links and `..` resolved first).
    private static func workFile(_ value: JSONValue, in folder: URL?) throws(ExtensionError) -> String {
        guard let path = value.stringValue else { throw ExtensionError(.badResult, "a file result takes a path (a string from yab.files.write)") }
        var isDirectory: ObjCBool = false
        guard let folder, let real = WorkFolders.contained(path, in: folder),
              FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ExtensionError(.badResult, "a file result must be a file in yab.files.workDir")
        }
        return real
    }

    /// A capture rule's answer. Nothing (`undefined` or `null`) keeps the copy. The
    /// reason for an answer that is none of these names shapes only: a rule sees every copy, and its answer
    /// may carry one.
    static func captureOutcome(from value: JSONValue) throws(ExtensionError) -> CaptureOutcome {
        let shapes = "expected {keep: true}, {ignore: true}, {replace: {text}}, {replace: {url}}, {addToCategory: name} or nothing"
        if value == .null { return .keep }
        guard let object = value.objectValue else { throw ExtensionError(.badResult, "a capture rule returned \(shape(of: value)); \(shapes)") }
        if object["keep"]?.boolValue == true { return .keep }
        if object["ignore"]?.boolValue == true { return .ignore }
        if let replace = object["replace"] {
            if let text = replace["text"]?.stringValue, !text.isEmpty { return .replaceText(text) }
            if let url = replace["url"]?.stringValue, !url.isEmpty { return .replaceURL(url) }
            throw ExtensionError(.badResult, "replace takes a non-empty {text} or {url}; \(shapes)")
        }
        if let name = object["addToCategory"]?.stringValue, !name.isEmpty { return .addToCategory(name) }
        throw ExtensionError(.badResult, "a capture rule returned an object of another shape; \(shapes)")
    }

    static func sections(from value: JSONValue, images: ImageHandleStore) throws(ExtensionError) -> [PreviewSection] {
        guard let list = value.arrayValue else { throw ExtensionError(.badResult, "preview must return an array of sections") }
        var sections: [PreviewSection] = []
        for entry in list {
            let title = entry["title"]?.stringValue ?? ""
            switch entry["type"]?.stringValue {
            case "text": sections.append(.text(title: title, text: entry["text"]?.stringValue ?? ""))
            case "code": sections.append(.code(title: title, code: entry["code"]?.stringValue ?? "", language: entry["language"]?.stringValue))
            case "keyValue":
                let rows = (entry["rows"]?.arrayValue ?? []).map { ($0.arrayValue ?? []).compactMap(\.stringValue) }
                sections.append(.keyValue(title: title, rows: rows))
            case "link": sections.append(.link(title: title, url: entry["url"]?.stringValue ?? ""))
            case "image":
                guard let image = images.encoded(entry["image"]) else { throw ExtensionError(.badResult, "an image section needs an image handle") }
                sections.append(.image(title: title, data: image.data))
            default:
                throw ExtensionError(.badResult, "unknown preview section type \(entry["type"].map(shape) ?? "nothing"); expected text, code, keyValue, image or link")
            }
        }
        return sections
    }

    // MARK: Sources

    /// The most rows a listing keeps; the longest a row's id, title and subtitle may be; the longest a locked
    /// listing's message and command may be (characters).
    static let sourceRowLimit = 10_000
    static let sourceTextLimit = 256
    static let lockedTextLimit = 200

    /// A source's `list` answer: `{ rows: [{ id, title, subtitle? }] }`, or `{ locked: true, message, command? }`
    /// (which wins over rows). Titles, subtitles, the message and the command become one line (`oneLine`), and a blank
    /// subtitle or command is none; the id goes back to `run` exactly as listed, so one that could not is refused. Rows
    /// past `sourceRowLimit` are dropped with one line to `log`. As for every bad result, the reason names shapes and
    /// places only: a source's rows may be secrets.
    static func sourceListing(from value: JSONValue, log: (String) -> Void) throws(ExtensionError) -> SourceListing {
        let shapes = "expected {rows} or {locked}"
        guard let object = value.objectValue else { throw ExtensionError(.badResult, "list returned \(shape(of: value)); \(shapes)") }
        if object["locked"]?.boolValue == true {
            let message = try requiredLine(object["message"], limit: lockedTextLimit, else: "a locked listing needs a non-empty message")
            let command = try optionalLine(object["command"], limit: lockedTextLimit, else: "command must be a string")
            return .locked(message: message, command: command)
        }
        guard let rows = object["rows"] else { throw ExtensionError(.badResult, "list returned an object of another shape; \(shapes)") }
        guard var entries = rows.arrayValue else { throw ExtensionError(.badResult, "rows must be an array of {id, title, subtitle?}") }
        if entries.count > sourceRowLimit {
            log("list returned more than \(sourceRowLimit) rows; kept the first \(sourceRowLimit)")
            entries.removeSubrange(sourceRowLimit...)
        }
        var listed: [SourceRow] = []
        listed.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() { listed.append(try sourceRow(entry, at: "rows[\(index)]")) }
        return .rows(listed)
    }

    private static func sourceRow(_ entry: JSONValue, at place: String) throws(ExtensionError) -> SourceRow {
        guard let row = entry.objectValue else {
            throw ExtensionError(.badResult, "\(place) is \(shape(of: entry)); expected {id, title, subtitle?}")
        }
        guard let id = row["id"]?.stringValue, !id.isEmpty else { throw ExtensionError(.badResult, "\(place).id must be a non-empty string") }
        guard id.count <= sourceTextLimit else {
            throw ExtensionError(.badResult, "\(place).id is longer than \(sourceTextLimit) characters")
        }
        let title = try requiredLine(row["title"], limit: sourceTextLimit, else: "\(place).title must be a non-empty string")
        let subtitle = try optionalLine(row["subtitle"], limit: sourceTextLimit, else: "\(place).subtitle must be a string")
        return SourceRow(id: id, title: title, subtitle: subtitle)
    }

    /// An optional field as one line: nil when it is left out, null or blank; `reason` when it is not a string.
    private static func optionalLine(_ value: JSONValue?, limit: Int, else reason: String) throws(ExtensionError) -> String? {
        switch value {
        case nil, .null?: return nil
        case .string(let text)?:
            let line = oneLine(text, limit: limit)
            return line.isEmpty ? nil : line
        default: throw ExtensionError(.badResult, reason)
        }
    }

    /// A field that must hold text, as one line; `reason` when it does not, or is blank.
    private static func requiredLine(_ value: JSONValue?, limit: Int, else reason: String) throws(ExtensionError) -> String {
        guard let line = try optionalLine(value, limit: limit, else: reason) else { throw ExtensionError(.badResult, reason) }
        return line
    }

    private static let lineBreaks: Set<Unicode.Scalar> = ["\t", "\n", "\u{0B}", "\u{0C}", "\r", "\u{85}", "\u{2028}", "\u{2029}"]

    /// Short plain text for a row: every tab and line end (each scalar, so "\r\n" is two) becomes a space, the ends are
    /// trimmed, and what lies past `limit` characters is cut.
    static func oneLine(_ text: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.lazy.map { lineBreaks.contains($0) ? " " : $0 })
        return String(String(scalars).trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    /// A source action's answer: `{ secret: string }` for a secret action, `{ text: string }` for a text one, and not
    /// blank. Kept exactly as given (a password may end in a space). The reason for anything else names shapes only,
    /// never the value.
    static func sourceValue(from value: JSONValue, expected kind: SourceActionSpec.Kind) throws(ExtensionError) -> SourceValue {
        let expects = "this action expects {\(kind.rawValue)}"
        guard let object = value.objectValue else { throw ExtensionError(.badResult, "run returned \(shape(of: value)); \(expects)") }
        guard let field = object[kind.rawValue] else {
            let other = SourceActionSpec.Kind.allCases.first { $0 != kind && object[$0.rawValue] != nil }
            throw ExtensionError(.badResult, "run returned \(other.map { "{\($0.rawValue)}" } ?? "an object of another shape"); \(expects)")
        }
        guard let text = field.stringValue else { throw ExtensionError(.badResult, "\(kind.rawValue) must be a string") }
        let result: SourceValue = switch kind {
        case .secret: .secret(text)
        case .text: .text(text)
        }
        guard !result.isBlank else { throw ExtensionError(.badResult, "run returned an empty value") }
        return result
    }

    /// What kind of value it is, never the value itself, nor an object's keys: a bad result's reason goes to the
    /// Development log, and what a run, preview or capture rule returns may come from the clipboard.
    private static func shape(of value: JSONValue) -> String {
        switch value {
        case .string: "a string"
        case .number: "a number"
        case .bool: "a boolean"
        case .array: "an array"
        case .object: "an object"
        case .null: "nothing"
        }
    }

}

extension ExtensionRuntime {
    /// Runs one call with its item and context, and types what came back. `effects`: the network and
    /// programs are allowed (a run the person started, a source's list or run); `source`: a `sourceRun`'s row
    /// and action; `callID` is what `cancel(callID:)` takes; `onProgress` hears `yab.job.progress`, on the
    /// extension's queue.
    public func invoke(_ kind: InvokeKind, name: String, item: ExtensionItem?, context: ExtensionContext, effects: Bool = false,
                       source: SourceInvocation? = nil, callID: Int = 0,
                       onProgress: (@Sendable (_ fraction: Double?, _ message: String?) -> Void)? = nil)
        async throws(ExtensionError) -> InvokeOutput {
        if kind == .sourceRun, source == nil { throw ExtensionError(.badResult, "a source run needs its row and action") }
        // A source's calls see no item, nor its files.
        let item = kind == .sourceList || kind == .sourceRun ? nil : item
        let scope = CallScope(callID: callID, extensionID: extensionID, kind: kind, grant: grant, effects: effects, onProgress: onProgress)
        scope.readablePaths = Set((item?.files ?? []).compactMap { WorkFolders.realPath($0.path) })
        // Folders the person chose (the app sends stored values only, never a manifest default): read-only access to what
        // lies inside them (links are resolved first, as for the work folder).
        scope.readableFolders = context.readableFolders.filter { $0.hasPrefix("/") }.compactMap { WorkFolders.realPath($0) }
        images.beginCall()
        defer { images.endCall() }
        await prepare(context)
        var itemJSON = item.map(HostAPI.json) ?? .null
        if let payload = item?.image, case .object(var fields) = itemJSON, let decoded = ImageCodec.decode(payload.data) {
            fields["image"] = images.add(decoded, data: payload.data, uti: "public.png")
            itemJSON = .object(fields)
        }
        // A source's calls take no item: the row and action (for `run`), then the context.
        let arguments: [JSONValue] = switch kind {
        case .validate: [itemJSON]
        case .sourceList: [HostAPI.json(context)]
        // Never nil here (checked above).
        case .sourceRun: [.string(source?.rowID ?? ""), .string(source?.actionID ?? ""), HostAPI.json(context)]
        case .run, .preview, .captureRule: [itemJSON, HostAPI.json(context)]
        }
        // The work folder stays only for a file result, which the app adopts; any other end removes it.
        do throws(ExtensionError) {
            let value = try await call(kind, name: name, arguments: arguments, in: scope)
            switch kind {
            case .run:
                let folder = await onQueue { scope.createdWorkFolder }
                let result = try HostAPI.result(from: value, images: images, workFolder: folder)
                switch result {
                case .file, .files: break
                default: await removeWorkFolder(of: scope)
                }
                return .result(result)
            case .validate:
                await removeWorkFolder(of: scope)
                return .valid(value.boolValue ?? (value != .null))
            case .preview:
                await removeWorkFolder(of: scope)
                return .sections(try HostAPI.sections(from: value, images: images))
            case .captureRule:
                await removeWorkFolder(of: scope)
                return .capture(try HostAPI.captureOutcome(from: value))
            case .sourceList:
                await removeWorkFolder(of: scope)
                return .listing(try HostAPI.sourceListing(from: value, log: log))
            case .sourceRun:
                await removeWorkFolder(of: scope)
                return .value(try HostAPI.sourceValue(from: value, expected: source?.kind ?? .secret))
            }
        } catch {
            await removeWorkFolder(of: scope)
            throw error
        }
    }

    private func removeWorkFolder(of scope: CallScope) async {
        await onQueue { scope.removeWorkFolder() }
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: body()) } }
    }

    /// Points `yab.language` and `yab.preferences` at this call's context.
    private func prepare(_ context: ExtensionContext) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.currentLanguage = context.language
                let yab = self.context.objectForKeyedSubscript("yab")
                yab?.setValue(context.language, forProperty: "language")
                yab?.setValue(self.jsValue(.object(context.preferences)), forProperty: "preferences")
                continuation.resume()
            }
        }
    }
}

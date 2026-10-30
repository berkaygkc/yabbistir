import Foundation
import JavaScriptCore
import YabExtensionKit

/// One extension's JavaScript world: its own virtual machine and context, touched only from its
/// own serial queue (timers and native promise resolutions come back to the same queue).
///
/// index.js is a CommonJS module (esbuild `format: cjs`) exporting
/// `actions: { [id]: { run(item, ctx) } }`, `detectors: { [id]: { validate?(item), preview?(item, ctx) } }`
/// and `captureRules: { [id]: { run(item, ctx) } }`.
public final class ExtensionRuntime: @unchecked Sendable {
    public let extensionID: String
    let queue: DispatchQueue
    let context: JSContext
    let log: @Sendable (String) -> Void
    let localization: ExtensionLocalization
    let dataFolder: URL
    /// What the extension may use (its manifest's request, agreed to) and where its tools are looked
    /// for; fixed while it is loaded.
    let grant: PermissionGrant
    let toolSearchPath: [String]
    /// The extension's own secret preferences; read only by `yab.secrets.get`, never logged.
    let secrets: [String: String]
    /// The manifest's `requires.tools`, for how to install one that is missing.
    let toolSpecs: [ToolSpec]
    /// This runtime's number in `ToolRegistry.shared`.
    let toolOwner = ToolRegistry.shared.newOwner()
    let images = ImageHandleStore()
    /// The one URLSession the runtime's requests go through (no cookies kept).
    let http: HTTPClient
    /// Where requests to the app go (`hostCall`); nil outside a host, where the app cannot be asked.
    let hostCalls: HostCallChannel?
    /// The language of the call in progress (queue-confined).
    var currentLanguage: String
    /// The call whose code is running (queue-confined); see CallScope.
    var currentScope: CallScope?
    /// The AbortController the web polyfills made, kept before any script could replace it.
    var abortControllerType: JSValue?
    private var exportsValue: JSValue
    private var storageCache: [String: JSONValue]?
    private var pendingException: JSValue?
    /// Calls in progress by id, for cancels (queue-confined).
    private var scopes: [Int: CallScope] = [:]
    /// Cancels that came before their call reached the queue.
    private var cancelledEarly: Set<Int> = []
    /// setTimeout's work items by id (queue-confined).
    var timers: [Int: DispatchWorkItem] = [:]
    var nextTimerID = 1

    public convenience init(folder: URL, manifest: ExtensionManifest, localization: ExtensionLocalization, dataFolder: URL,
                            grant: PermissionGrant = .empty, toolSearchPath: [String] = [], secrets: [String: String] = [:],
                            urlSessionConfiguration: URLSessionConfiguration = .ephemeral,
                            log: @escaping @Sendable (String) -> Void) throws(ExtensionError) {
        try self.init(folder: folder, manifest: manifest, localization: localization, dataFolder: dataFolder, grant: grant,
                      toolSearchPath: toolSearchPath, secrets: secrets, urlSessionConfiguration: urlSessionConfiguration, hostCalls: nil, log: log)
    }

    /// `hostCalls`: the host's channel to the app.
    init(folder: URL, manifest: ExtensionManifest, localization: ExtensionLocalization, dataFolder: URL,
         grant: PermissionGrant = .empty, toolSearchPath: [String] = [], secrets: [String: String] = [:],
         urlSessionConfiguration: URLSessionConfiguration = .ephemeral, hostCalls: HostCallChannel?,
         log: @escaping @Sendable (String) -> Void) throws(ExtensionError) {
        extensionID = manifest.id
        queue = DispatchQueue(label: "dev.yabbistir.extension.\(manifest.id)")
        self.log = log
        self.localization = localization
        self.dataFolder = dataFolder
        self.grant = grant
        self.toolSearchPath = toolSearchPath
        // Only keys the manifest declares as secrets (the app sends no others; this keeps it so).
        let declared = Set((manifest.preferences).filter { $0.type == .secret }.map(\.id))
        self.secrets = secrets.filter { declared.contains($0.key) }
        toolSpecs = manifest.requires?.tools ?? []
        http = HTTPClient(configuration: urlSessionConfiguration)
        self.hostCalls = hostCalls
        currentLanguage = localization.defaultLocale
        guard let virtualMachine = JSVirtualMachine(), let context = JSContext(virtualMachine: virtualMachine) else {
            throw ExtensionError(.unavailable, "JavaScriptCore could not start")
        }
        self.context = context
        exportsValue = JSValue(undefinedIn: context)
        let source: String
        do {
            source = try String(contentsOf: folder.appendingPathComponent("index.js"), encoding: .utf8)
        } catch {
            throw ExtensionError(.notFound, "index.js could not be read")
        }
        let failure: ExtensionError? = queue.sync { load(source, url: folder.appendingPathComponent("index.js")) }
        if let failure { throw failure }
    }

    deinit {
        http.invalidate()
        let timers = timers
        queue.async { timers.values.forEach { $0.cancel() } }
    }

    /// Runs `actions[name].run`, `detectors[name].validate`, `detectors[name].preview` or
    /// `captureRules[name].run` with the arguments, awaiting a returned promise. The raw JSON result;
    /// typed results are built on top.
    public func call(_ kind: InvokeKind, name: String, arguments: [JSONValue]) async throws(ExtensionError) -> JSONValue {
        try await call(kind, name: name, arguments: arguments, in: CallScope(callID: 0, extensionID: extensionID, kind: kind, grant: grant, effects: false))
    }

    /// The same, as `scope`'s call: a context argument (the second) gets the call's signal.
    func call(_ kind: InvokeKind, name: String, arguments: [JSONValue], in scope: CallScope) async throws(ExtensionError) -> JSONValue {
        let outcome: Result<JSONValue, ExtensionError> = await withCheckedContinuation { continuation in
            queue.async {
                scope.begin { [weak self] outcome in
                    if let self, self.scopes[scope.callID] === scope { self.scopes[scope.callID] = nil }
                    continuation.resume(returning: outcome)
                    self?.end(scope)
                }
                self.start(kind, name: name, arguments: arguments, scope: scope)
            }
        }
        return try outcome.get()
    }

    /// Cancels a call in progress, from any thread: its tools stop, its signal fires, it ends with
    /// `cancelled` now whatever its script does next, and its pending `yab` promises reject with `cancelled`.
    public func cancel(callID: Int) {
        // Before the hop: a script stuck in a loop holds the queue, never the kill.
        ToolRegistry.shared.cancel(owner: toolOwner, callID: callID)
        queue.async {
            guard let scope = self.scopes[callID] else {
                // Not on the queue yet: it ends as soon as it gets there.
                self.cancelledEarly.insert(callID)
                return
            }
            self.cancel(scope)
        }
    }

    private func cancel(_ scope: CallScope) {
        guard scope.endReason == nil else { return }
        // Marked first: the abort listeners already see a cancelled call (no effects, no progress,
        // and whatever they settle the call with, it ends `cancelled`).
        scope.markCancelled()
        within(scope) {
            let reason = NativeAPI.errorValue(CallScope.cancelled, in: context)
            reason.setValue("AbortError", forProperty: "name")
            scope.controller?.invokeMethod("abort", withArguments: [reason])
        }
        _ = takeException()
        scope.finish(.failure(CallScope.cancelled))
    }

    /// The call ended (answered or cancelled): what it left running stops (its tools too, and what
    /// they started), and its pending `yab` promises reject with why. After the signal, so a
    /// rejection handler sees `ctx.signal.aborted`.
    private func end(_ scope: CallScope) {
        guard let reason = scope.endReason else { return }
        ToolRegistry.shared.end(owner: toolOwner, callID: scope.callID)
        // The controller keeps its signal, and every listener on it, alive: an ended call lets go of it.
        scope.controller = nil
        let stops = scope.takeStops()
        guard !stops.isEmpty else { return }
        within(scope) { stops.forEach { $0(reason) } }
    }

    // MARK: Loading

    private func load(_ source: String, url: URL) -> ExtensionError? {
        context.exceptionHandler = { [weak self] _, exception in self?.pendingException = exception }
        WebPolyfills.install(in: self)
        HostAPI.install(in: self)
        NotifyOpenAPI.install(in: self)
        HistoryAPI.install(in: self)
        AIAPI.install(in: self)
        NativeAPI.install(in: self)
        FilesAPI.install(in: self)
        HTTPAPI.install(in: self)
        ExecAPI.install(in: self)
        context.evaluateScript("var module = { exports: {} }; var exports = module.exports;")
        pendingException = nil
        context.evaluateScript(source, withSourceURL: url)
        if let exception = takeException() {
            let isSyntax = exception.forProperty("name")?.toString() == "SyntaxError"
            return ExtensionError(isSyntax ? .syntax : .script, describe(exception))
        }
        exportsValue = context.objectForKeyedSubscript("module").objectForKeyedSubscript("exports")
        return nil
    }

    // MARK: Storage (queue-confined)

    private var storageURL: URL { dataFolder.appendingPathComponent("storage.json") }

    var storage: [String: JSONValue] {
        if let storageCache { return storageCache }
        let loaded = (try? Data(contentsOf: storageURL)).flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
        storageCache = loaded
        return loaded
    }

    /// False (nothing written) when the store would pass `HostAPI.storageLimit`.
    func saveStorage(_ next: [String: JSONValue]) -> Bool {
        guard let data = try? JSONEncoder().encode(next), data.count <= HostAPI.storageLimit else { return false }
        do {
            try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            return false
        }
        storageCache = next
        return true
    }

    // MARK: Calling

    private func start(_ kind: InvokeKind, name: String, arguments: [JSONValue], scope: CallScope) {
        scopes[scope.callID] = scope
        if cancelledEarly.remove(scope.callID) != nil {
            cancel(scope)
            return
        }
        let (group, method) = switch kind {
        case .run: ("actions", "run")
        case .captureRule: ("captureRules", "run")
        case .validate, .preview: ("detectors", kind.rawValue)
        }
        guard let entry = exportsValue.forProperty(group)?.forProperty(name), entry.isObject,
              isFunction(entry.forProperty(method)) else {
            scope.finish(.failure(ExtensionError(.notFound, "\(group).\(name).\(method) is not exported")))
            return
        }
        scope.controller = abortControllerType?.construct(withArguments: [])
        within(scope) {
            pendingException = nil
            let values = arguments.map(jsValue)
            if values.count > 1, values[1].isObject, let signal = scope.controller?.forProperty("signal") {
                values[1].setValue(signal, forProperty: "signal")
            }
            let value = entry.invokeMethod(method, withArguments: values)
            if let exception = takeException() {
                scope.finish(.failure(extensionError(from: exception)))
                return
            }
            guard let value, value.isObject, isFunction(value.forProperty("then")) else {
                scope.finish(.success(json(value)))
                return
            }
            // Only the first outcome counts (a cancel may have come first). Weakly: these functions live
            // until the next garbage collection, and the call in progress is held by `scopes` meanwhile.
            let fulfilled: @convention(block) (JSValue?) -> Void = { [weak self, weak scope] result in
                guard let scope, !scope.isOver, let self else { return }
                scope.finish(.success(self.json(result)))
            }
            let rejected: @convention(block) (JSValue?) -> Void = { [weak self, weak scope] error in
                guard let scope, !scope.isOver, let self else { return }
                scope.finish(.failure(self.extensionError(from: error)))
            }
            value.invokeMethod("then", withArguments: [unsafeBitCast(fulfilled, to: AnyObject.self), unsafeBitCast(rejected, to: AnyObject.self)])
            if let exception = takeException() {
                scope.finish(.failure(extensionError(from: exception)))
            }
        }
    }

    private func takeException() -> JSValue? {
        defer { pendingException = nil }
        return pendingException
    }

    /// A thrown or rejected value as an ExtensionError. Native errors carry their code in `code`;
    /// anything the script throws itself is `.script`.
    func extensionError(from error: JSValue?) -> ExtensionError {
        guard let error, !error.isUndefined else { return ExtensionError(.script, "the promise was rejected") }
        let code = error.forProperty("code").flatMap { $0.isString ? ExtensionError.Code(rawValue: $0.toString()) : nil } ?? .script
        // The message is the extension's own text; where it was thrown is for the development log.
        if let line = error.forProperty("line"), line.isNumber { log("\(extensionID): a call failed at line \(line.toInt32())") }
        return ExtensionError(code, message(of: error))
    }

    private func message(of error: JSValue) -> String {
        error.forProperty("message").flatMap { $0.isUndefined ? nil : $0.toString() } ?? error.toString() ?? "error"
    }

    /// "line 3: Unexpected token ','" for errors that carry a line, the message otherwise (load and syntax errors only).
    func describe(_ error: JSValue) -> String {
        let message = message(of: error)
        if let line = error.forProperty("line"), line.isNumber { return "line \(line.toInt32()): \(message)" }
        return message
    }

    private lazy var typeOf: JSValue = context.evaluateScript("(function (v) { return typeof v; })")

    func isFunction(_ value: JSValue?) -> Bool {
        guard let value, !value.isUndefined, !value.isNull else { return false }
        return typeOf.call(withArguments: [value])?.toString() == "function"
    }

    // MARK: JSON ⇄ JavaScript

    func jsValue(_ value: JSONValue) -> JSValue {
        switch value {
        case .string(let text): return JSValue(object: text, in: context)
        case .number(let number): return JSValue(double: number, in: context)
        case .bool(let flag): return JSValue(bool: flag, in: context)
        case .null: return JSValue(nullIn: context)
        case .array(let items):
            let array = JSValue(newArrayIn: context)!
            for (index, item) in items.enumerated() { array.setValue(jsValue(item), at: index) }
            return array
        case .object(let fields):
            let object = JSValue(newObjectIn: context)!
            for (key, field) in fields { object.setValue(jsValue(field), forProperty: key) }
            return object
        }
    }

    private lazy var objectKeys: JSValue = context.evaluateScript("(function (o) { return Object.keys(o); })")

    /// Arrays longer than this are cut when they cross into Swift.
    static let arrayLimit = 100_000

    func json(_ value: JSValue?, depth: Int = 0) -> JSONValue {
        guard let value, !value.isUndefined, !value.isNull, depth < 64 else { return .null }
        if value.isBoolean { return .bool(value.toBool()) }
        if value.isNumber { return .number(value.toDouble()) }
        if value.isString { return .string(value.toString()) }
        if value.isArray {
            // A script can set length to 2^32 − 1: only the first entries cross.
            let length = value.forProperty("length")?.toDouble() ?? 0
            let count = length.isFinite ? Int(max(0, min(length, Double(Self.arrayLimit)))) : 0
            return .array((0..<count).map { json(value.atIndex($0), depth: depth + 1) })
        }
        if value.isObject, !isFunction(value) {
            let keys = objectKeys.call(withArguments: [value])?.toArray() as? [String] ?? []
            return .object(Dictionary(uniqueKeysWithValues: keys.map { ($0, json(value.forProperty($0), depth: depth + 1)) }))
        }
        return .null
    }
}

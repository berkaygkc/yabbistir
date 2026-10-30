import Foundation
import JavaScriptCore
import YabExtensionKit

/// One call into an extension and what belongs to it alone: whether it may reach the network and
/// run programs, its `AbortSignal` (`ctx.signal`), the `yab` work that stops when it ends, and
/// where its progress goes, and its work folder. Touched only on the extension's queue.
///
/// JavaScript cannot tell which call a piece of code belongs to, so the runtime carries the scope
/// along: it is current while the call's own code runs, and every timer and `yab` promise keeps the
/// scope it was started in and makes it current again when it fires or settles. Code awaiting one
/// of them goes on inside the right call. Once the call has ended (answered or cancelled), what it
/// left behind keeps the scope but loses its effects: see `endReason`.
final class CallScope: @unchecked Sendable {
    static let cancelled = ExtensionError(.cancelled, "the call was cancelled")
    static let over = ExtensionError(.permissionDenied, "the call is over")

    let callID: Int
    let extensionID: String
    /// What the call runs; requests to the app name it.
    let kind: InvokeKind
    let grant: PermissionGrant
    /// The network and programs are allowed: only in a run the person started.
    let effects: Bool
    /// `ctx.signal` is its signal; made when the call starts.
    var controller: JSValue?
    private(set) var isCancelled = false
    /// The call has its outcome (an answer or a cancel): nothing more reaches the caller.
    private(set) var isOver = false
    private let onProgress: (@Sendable (_ fraction: Double?, _ message: String?) -> Void)?
    private var completion: ((Result<JSONValue, ExtensionError>) -> Void)?
    private var stops: [Int: (ExtensionError) -> Void] = [:]
    private var nextStop = 0
    private var folder: URL?
    /// Files the call may read besides its work folder: the item's own, as given to it.
    var readablePaths: Set<String> = []
    /// Real paths of the folders the person chose in `folder` preferences: files inside them may be read, never written.
    var readableFolders: [String] = []

    init(callID: Int, extensionID: String, kind: InvokeKind = .run, grant: PermissionGrant, effects: Bool,
         onProgress: (@Sendable (_ fraction: Double?, _ message: String?) -> Void)? = nil) {
        (self.callID, self.extensionID, self.kind, self.grant, self.effects, self.onProgress) = (callID, extensionID, kind, grant, effects, onProgress)
    }

    /// Why nothing more may start for this call: `cancelled` from the moment it is cancelled, "the
    /// call is over" once it answered; nil while it runs.
    var endReason: ExtensionError? {
        isCancelled ? Self.cancelled : isOver ? Self.over : nil
    }

    func progress(_ fraction: Double?, _ message: String?) {
        guard endReason == nil else { return }
        onProgress?(fraction, message)
    }

    /// Where the outcome goes; set once, as the call starts.
    func begin(_ completion: @escaping (Result<JSONValue, ExtensionError>) -> Void) {
        self.completion = completion
    }

    /// Hands the caller the outcome; only the first one counts, and a cancelled call's is `cancelled`.
    func finish(_ outcome: Result<JSONValue, ExtensionError>) {
        guard !isOver else { return }
        isOver = true
        let completion = completion
        self.completion = nil
        completion?(isCancelled ? .failure(Self.cancelled) : outcome)
    }

    /// `stop` ends some work if the call ends first, and gets `endReason`; `forget` it once that
    /// work is done.
    func whenEnded(_ stop: @escaping (ExtensionError) -> Void) -> Int {
        nextStop += 1
        stops[nextStop] = stop
        return nextStop
    }

    func forget(_ token: Int) {
        stops[token] = nil
    }

    /// The call's work folder, made on first use (`<temporary folder>/yabbistir-work/<uuid>/`).

    var workFolder: URL {
        get throws(ExtensionError) {
            if let folder { return folder }
            do {
                let made = try WorkFolders.make()
                folder = made
                return made
            } catch {
                throw ExtensionError(.unavailable, "the work folder could not be made: \(error.localizedDescription)")
            }
        }
    }


    /// The work folder if the call made one.
    var createdWorkFolder: URL? { folder }

    /// Removes the work folder (the call returned no file for the app to adopt, or it did not finish).
    func removeWorkFolder() {
        guard let folder else { return }
        try? FileManager.default.removeItem(at: folder)
        self.folder = nil
    }

    func markCancelled() {
        isCancelled = true
    }

    /// What still has to stop, oldest first; each is handed over once.
    func takeStops() -> [(ExtensionError) -> Void] {
        defer { stops = [:] }
        return stops.sorted { $0.key < $1.key }.map(\.value)
    }
}

extension ExtensionRuntime {
    /// Runs `body` as part of `scope`'s call (queue-confined).
    func within<T>(_ scope: CallScope?, _ body: () -> T) -> T {
        let outer = currentScope
        currentScope = scope
        defer { currentScope = outer }
        return body()
    }

    /// A `yab` promise: `work` runs on a background queue and the promise settles back on the
    /// extension's queue, inside the call that made it. When that call ends first, it rejects at
    /// once with `cancelled` or "the call is over"; one made after that rejects straight away.
    func promise(_ work: @escaping @Sendable () -> Result<JSONValue, ExtensionError>) -> JSValue? {
        let scope = currentScope
        return JSValue(newPromiseIn: context) { resolve, reject in
            let settle = Settle(resolve: resolve, reject: reject)
            if let ended = scope?.endReason {
                self.settle(settle, .failure(ended))
                return
            }
            let token = scope?.whenEnded { [weak self] reason in self?.settle(settle, .failure(reason)) }
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = work()
                self.queue.async {
                    if let token { scope?.forget(token) }
                    self.within(scope) { self.settle(settle, outcome) }
                }
            }
        }
    }

    private func settle(_ settle: Settle, _ outcome: Result<JSONValue, ExtensionError>) {
        switch outcome {
        case .success(let value): settle.resolve?.call(withArguments: [jsValue(value)])
        case .failure(let error): settle.reject?.call(withArguments: [NativeAPI.errorValue(error, in: context)])
        }
    }

}

/// An abort listener a `yab` call puts on a script's signal, taken off again once that work settles
/// (queue-confined). The JavaScript function it adds lives until the next garbage collection, and a
/// signal can outlive the call (`ctx.signal` is held by the scope, a script may keep its own), so the
/// function holds only a weak reference to this, and `remove()` lets go of the work at once.
final class AbortListener: @unchecked Sendable {
    private var action: (() -> Void)?
    private var signal: JSValue?
    private var function: JSValue?

    /// Adds `action` as an `abort` listener on `signal`; it runs at most once.
    init(signal: JSValue, in context: JSContext, action: @escaping () -> Void) {
        self.action = action
        let fire: @convention(block) () -> Void = { [weak self] in
            let action = self?.action
            self?.action = nil
            action?()
        }
        let function = JSValue(object: unsafeBitCast(fire, to: AnyObject.self), in: context)
        (self.signal, self.function) = (signal, function)
        signal.invokeMethod("addEventListener", withArguments: ["abort", function as Any])
    }

    /// Off the signal, and whatever the action held is let go.
    func remove() {
        if let signal, let function { signal.invokeMethod("removeEventListener", withArguments: ["abort", function]) }
        (action, signal, function) = (nil, nil, nil)
    }
}

/// A promise's resolve and reject, carried to the background and back; used only on the extension's queue.
private final class Settle: @unchecked Sendable {
    let resolve: JSValue?
    let reject: JSValue?
    init(resolve: JSValue?, reject: JSValue?) { (self.resolve, self.reject) = (resolve, reject) }
}

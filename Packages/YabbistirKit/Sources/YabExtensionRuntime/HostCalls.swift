import Foundation
import JavaScriptCore
import Synchronization
import YabExtensionKit

/// The host's end of the channel to the app: an extension's request goes out as a `call` event naming
/// the call that made it, and the app's reply comes back on the reading loop, which hands it to whoever
/// waits for that request number. Request numbers are the host's own, never reused while it runs.
final class HostCallChannel: Sendable {
    private struct State {
        var next = 1
        var waiting: [Int: @Sendable (Result<JSONValue, ExtensionError>) -> Void] = [:]
    }

    private let write: @Sendable (HostMessage) -> Void
    private let state = Mutex(State())

    init(write: @escaping @Sendable (HostMessage) -> Void) {
        self.write = write
    }

    /// A new request number; `settle` hears the app's reply, once, unless the request is closed first.
    func open(_ settle: @escaping @Sendable (Result<JSONValue, ExtensionError>) -> Void) -> Int {
        state.withLock { state in
            defer { state.next += 1 }
            state.waiting[state.next] = settle
            return state.next
        }
    }

    /// Nobody waits for the request any more (its call ended): a reply that still comes is dropped.
    func close(_ requestID: Int) {
        _ = state.withLock { $0.waiting.removeValue(forKey: requestID) }
    }

    func send(_ message: HostMessage) {
        write(message)
    }

    /// From the reading loop. A reply for a request nobody waits for is dropped.
    func deliver(_ reply: ReplyRequest) {
        let settle = state.withLock { $0.waiting.removeValue(forKey: reply.requestID) }
        settle?(reply.error.map { .failure($0) } ?? .success(reply.ok ?? .null))
    }
}

extension ExtensionRuntime {
    /// Asks the app for `method` as `scope`'s call (queue-confined), and returns a promise that settles
    /// with the app's answer inside that call. When the call ends first it rejects with why (`cancelled`
    /// or "the call is over") and a later answer is dropped; one asked after the call ended rejects
    /// straight away. The checks the request needs (`effects`, permissions) are the caller's.
    ///
    /// `refusal`: the caller's own check refused the request, and asks anyway so that the app's refusal, in
    /// the app's language, is the one the script sees. Should the app answer instead, the answer is dropped
    /// and the promise rejects with `refusal`: the script gets nothing either check refused.
    func hostCall(_ method: String, _ params: JSONValue, in scope: CallScope, refusal: ExtensionError? = nil) -> JSValue {
        JSValue(newPromiseIn: context) { resolve, reject in
            let request = HostRequestSettler(runtime: self, scope: scope, resolve: resolve, reject: reject)
            if let ended = scope.endReason {
                request.settle(.failure(ended))
                return
            }
            guard let channel = self.hostCalls else {
                request.settle(.failure(refusal ?? ExtensionError(.unavailable, "the app cannot be asked from here")))
                return
            }
            let requestID = channel.open { [weak self] outcome in
                var outcome = outcome
                if let refusal, case .success = outcome { outcome = .failure(refusal) }
                self?.queue.async { request.settle(outcome) }
            }
            request.token = scope.whenEnded { reason in
                channel.close(requestID)
                request.settle(.failure(reason))
            }
            channel.send(.call(scope.callID, requestID: requestID, method: method, params: params, effects: scope.effects,
                               kind: scope.kind, extensionID: self.extensionID))
        }
    }
}

/// Settles one request's promise, once, inside the call that made it (queue-confined).
private final class HostRequestSettler: @unchecked Sendable {
    private weak var runtime: ExtensionRuntime?
    private let scope: CallScope
    private var resolve: JSValue?
    private var reject: JSValue?
    /// The call's hold on the request until it settles.
    var token: Int?
    private var settled = false

    init(runtime: ExtensionRuntime, scope: CallScope, resolve: JSValue?, reject: JSValue?) {
        (self.runtime, self.scope, self.resolve, self.reject) = (runtime, scope, resolve, reject)
    }

    func settle(_ outcome: Result<JSONValue, ExtensionError>) {
        guard !settled, let runtime else { return }
        settled = true
        if let token { scope.forget(token) }
        let (resolve, reject) = (self.resolve, self.reject)
        (self.resolve, self.reject, token) = (nil, nil, nil)
        runtime.within(scope) {
            switch outcome {
            case .success(let value): _ = resolve?.call(withArguments: [runtime.jsValue(value)])
            case .failure(let error): _ = reject?.call(withArguments: [NativeAPI.errorValue(error, in: runtime.context)])
            }
        }
    }
}

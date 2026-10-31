import Foundation
import JavaScriptCore
import YabExtensionKit

/// `yab.notify` and `yab.open`: the app shows the notice and opens the link. Both
/// reach beyond the call, so only a run the person started may use them; neither needs a permission.
/// They return nothing: the request goes to the app and the script goes on.
enum NotifyOpenAPI {
    static func install(in runtime: ExtensionRuntime) {
        guard let yab = runtime.context.objectForKeyedSubscript("yab") else { return }
        let notify: @convention(block) (JSValue?) -> Void = { [weak runtime] message in
            guard let runtime else { return }
            ask(runtime, "yab.notify") { () throws(ExtensionError) -> (String, JSONValue)? in
                guard let message, message.isString else { throw ExtensionError(.badResult, "yab.notify takes a message") }
                // A flood stops here: the excess never leaves the helper, and the script is not told.
                switch runtime.notifyLimiter.admit(at: runtime.clock()) {
                case .allowed: break
                case .dropped(let first):
                    if first {
                        runtime.log("\(runtime.extensionID): yab.notify dropped; at most \(NotifyLimiter.limit) per \(Int(NotifyLimiter.window)) s are shown")
                    }
                    return nil
                }
                // The app cuts it to its length.
                return ("notify", .object(["message": .string(message.toString())]))
            }
        }
        let open: @convention(block) (JSValue?) -> Void = { [weak runtime] url in
            guard let runtime else { return }
            ask(runtime, "yab.open") { () throws(ExtensionError) -> (String, JSONValue)? in
                guard let url, url.isString, let link = URL(string: url.toString()), DomainPolicy.isWebURL(link), link.host?.isEmpty == false else {
                    throw ExtensionError(.badResult, "only http and https links open")
                }
                return ("open", .object(["url": .string(link.absoluteString)]))
            }
        }
        yab.setValue(unsafeBitCast(notify, to: AnyObject.self), forProperty: "notify")
        yab.setValue(unsafeBitCast(open, to: AnyObject.self), forProperty: "open")
    }

    /// Checked here, then sent as the running call's request; a refusal throws into the script.
    private static func ask(_ runtime: ExtensionRuntime, _ name: String, _ request: () throws(ExtensionError) -> (String, JSONValue)?) {
        do throws(ExtensionError) {
            guard let scope = runtime.currentScope else { throw ExtensionError(.permissionDenied, "\(name) works inside a call") }
            try HostAPI.require(effectsFor: name, in: scope)
            guard let (method, params) = try request() else { return }
            _ = runtime.hostCall(method, params, in: scope)
        } catch {
            runtime.context.exception = NativeAPI.errorValue(error, in: runtime.context)
        }
    }
}

/// At most `limit` notifications in any `window` seconds; the rest are dropped. One per extension.
struct NotifyLimiter {
    static let limit = 5
    static let window: TimeInterval = 10

    enum Admission: Equatable {
        case allowed
        /// `first`: the first drop since a notification was last let through (the one worth a log line).
        case dropped(first: Bool)
    }

    private var sent: [TimeInterval] = []
    private var warned = false

    mutating func admit(at now: TimeInterval) -> Admission {
        sent.removeAll { now - $0 >= Self.window }
        guard sent.count < Self.limit else {
            defer { warned = true }
            return .dropped(first: !warned)
        }
        sent.append(now)
        warned = false
        return .allowed
    }
}

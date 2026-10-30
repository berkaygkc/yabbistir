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
            ask(runtime, "yab.notify") { () throws(ExtensionError) -> (String, JSONValue) in
                guard let message, message.isString else { throw ExtensionError(.badResult, "yab.notify takes a message") }
                // The app cuts it to its length.
                return ("notify", .object(["message": .string(message.toString())]))
            }
        }
        let open: @convention(block) (JSValue?) -> Void = { [weak runtime] url in
            guard let runtime else { return }
            ask(runtime, "yab.open") { () throws(ExtensionError) -> (String, JSONValue) in
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
    private static func ask(_ runtime: ExtensionRuntime, _ name: String, _ request: () throws(ExtensionError) -> (String, JSONValue)) {
        do throws(ExtensionError) {
            guard let scope = runtime.currentScope else { throw ExtensionError(.permissionDenied, "\(name) works inside a call") }
            try HostAPI.require(effectsFor: name, in: scope)
            let (method, params) = try request()
            _ = runtime.hostCall(method, params, in: scope)
        } catch {
            runtime.context.exception = NativeAPI.errorValue(error, in: runtime.context)
        }
    }
}

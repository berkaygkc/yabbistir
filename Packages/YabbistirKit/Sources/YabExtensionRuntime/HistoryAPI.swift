import Foundation
import JavaScriptCore
import YabExtensionKit

/// `yab.history.recent` and `yab.history.search`: the app reads its history and
/// answers. Needs the `history` permission; rules, detectors and previews cannot read it. A refusal rejects
/// the returned promise. The app caps `limit` (1 to 50, 20 when left out) and trims what it sends.
///
/// Both sides check. The app words its refusal in the app's language, which the helper cannot: a request the
/// helper refuses still goes to the app (without its arguments), and the app's refusal is the one the script
/// sees. Should the app answer it anyway, the answer is dropped and the helper's own refusal (in English, for
/// the developer) stands.
enum HistoryAPI {
    static func install(in runtime: ExtensionRuntime) {
        guard let yab = runtime.context.objectForKeyedSubscript("yab"), let history = JSValue(newObjectIn: runtime.context) else { return }
        let recent: @convention(block) (JSValue?) -> JSValue? = { [weak runtime] limit in
            guard let runtime else { return nil }
            return ask(runtime, "history.recent") { () throws(ExtensionError) -> JSONValue in .object(try limitField(limit)) }
        }
        let search: @convention(block) (JSValue?, JSValue?) -> JSValue? = { [weak runtime] query, limit in
            guard let runtime else { return nil }
            return ask(runtime, "history.search") { () throws(ExtensionError) -> JSONValue in
                guard let query, query.isString else { throw ExtensionError(.badResult, "yab.history.search takes a query") }
                var fields = try limitField(limit)
                fields["query"] = .string(query.toString())
                return .object(fields)
            }
        }
        history.setValue(unsafeBitCast(recent, to: AnyObject.self), forProperty: "recent")
        history.setValue(unsafeBitCast(search, to: AnyObject.self), forProperty: "search")
        yab.setValue(history, forProperty: "history")
    }

    private static func limitField(_ limit: JSValue?) throws(ExtensionError) -> [String: JSONValue] {
        guard let limit, !limit.isUndefined, !limit.isNull else { return [:] }
        guard limit.isNumber, limit.toDouble().isFinite else { throw ExtensionError(.badResult, "limit must be a number from 1 to 50") }
        return ["limit": .number(limit.toDouble())]
    }

    private static func ask(_ runtime: ExtensionRuntime, _ method: String, _ params: () throws(ExtensionError) -> JSONValue) -> JSValue? {
        do throws(ExtensionError) {
            guard let scope = runtime.currentScope else { throw ExtensionError(.permissionDenied, "yab.history works inside a call") }
            if let ended = scope.endReason { throw ended }
            do throws(ExtensionError) {
                try HostAPI.require(historyIn: scope)
            } catch where error.code == .permissionDenied {
                return runtime.hostCall(method, .object([:]), in: scope, refusal: error)
            }
            return runtime.hostCall(method, try params(), in: scope)
        } catch {
            let rejection = NativeAPI.errorValue(error, in: runtime.context)
            return JSValue(newPromiseIn: runtime.context) { _, reject in _ = reject?.call(withArguments: [rejection as Any]) }
        }
    }
}

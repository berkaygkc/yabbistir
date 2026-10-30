import Foundation
import JavaScriptCore
import YabExtensionKit

/// `yab.ai.generate` and `yab.translate`: the app runs Apple's on-device model and
/// Apple Translation and answers. Neither needs a permission, but both run only in a run the person started
/// or a job: a model on every keystroke is too costly, so hints, detectors, previews and rules are refused.
/// A refusal rejects the returned promise. The app bounds what it is sent (32 000 characters; `maxTokens`
/// 1–2048; `temperature` 0–2) and says in its own language why it cannot answer.
enum AIAPI {
    static func install(in runtime: ExtensionRuntime) {
        guard let yab = runtime.context.objectForKeyedSubscript("yab"), let ai = JSValue(newObjectIn: runtime.context) else { return }
        let generate: @convention(block) (JSValue?, JSValue?) -> JSValue? = { [weak runtime] prompt, options in
            guard let runtime else { return nil }
            return ask(runtime, "yab.ai.generate") { () throws(ExtensionError) -> (String, JSONValue) in
                guard let prompt, prompt.isString else { throw ExtensionError(.badResult, "yab.ai.generate takes a prompt") }
                var params: [String: JSONValue] = ["prompt": .string(prompt.toString())]
                if let options = try generateOptions(options) { params["options"] = .object(options) }
                return ("ai.generate", .object(params))
            }
        }
        let translate: @convention(block) (JSValue?, JSValue?) -> JSValue? = { [weak runtime] text, options in
            guard let runtime else { return nil }
            return ask(runtime, "yab.translate") { () throws(ExtensionError) -> (String, JSONValue) in
                guard let text, text.isString else { throw ExtensionError(.badResult, "yab.translate takes a text") }
                guard let options, options.isObject, let to = field(options, "to"), to.isString, !to.toString().isEmpty else {
                    throw ExtensionError(.badResult, "yab.translate needs the target language: { to: \"tr\" }")
                }
                var params: [String: JSONValue] = ["text": .string(text.toString()), "to": .string(to.toString())]
                if let from = field(options, "from") {
                    guard from.isString, !from.toString().isEmpty else { throw ExtensionError(.badResult, "from must be a language code, like \"en\"") }
                    params["from"] = .string(from.toString())
                }
                return ("translate", .object(params))
            }
        }
        ai.setValue(unsafeBitCast(generate, to: AnyObject.self), forProperty: "generate")
        yab.setValue(ai, forProperty: "ai")
        yab.setValue(unsafeBitCast(translate, to: AnyObject.self), forProperty: "translate")
    }

    /// `{ instructions?, temperature?, maxTokens? }`, the ones given; nil when there are no options.
    private static func generateOptions(_ options: JSValue?) throws(ExtensionError) -> [String: JSONValue]? {
        guard let options, !options.isUndefined, !options.isNull else { return nil }
        guard options.isObject else { throw ExtensionError(.badResult, "yab.ai.generate's options are { instructions?, temperature?, maxTokens? }") }
        var fields: [String: JSONValue] = [:]
        if let instructions = field(options, "instructions") {
            guard instructions.isString else { throw ExtensionError(.badResult, "instructions must be a string") }
            fields["instructions"] = .string(instructions.toString())
        }
        for name in ["temperature", "maxTokens"] {
            guard let value = field(options, name) else { continue }
            guard value.isNumber, value.toDouble().isFinite else { throw ExtensionError(.badResult, "\(name) must be a number") }
            fields[name] = .number(value.toDouble())
        }
        return fields
    }

    /// The property, unless it is missing, undefined or null.
    private static func field(_ object: JSValue, _ name: String) -> JSValue? {
        guard let value = object.forProperty(name), !value.isUndefined, !value.isNull else { return nil }
        return value
    }

    /// Checked here, then sent as the running call's request; a refusal rejects the promise.
    private static func ask(_ runtime: ExtensionRuntime, _ name: String,
                            _ request: () throws(ExtensionError) -> (String, JSONValue)) -> JSValue? {
        do throws(ExtensionError) {
            guard let scope = runtime.currentScope else { throw ExtensionError(.permissionDenied, "\(name) works inside a call") }
            try HostAPI.require(effectsFor: name, in: scope)
            let (method, params) = try request()
            return runtime.hostCall(method, params, in: scope)
        } catch {
            let rejection = NativeAPI.errorValue(error, in: runtime.context)
            return JSValue(newPromiseIn: runtime.context) { _, reject in _ = reject?.call(withArguments: [rejection as Any]) }
        }
    }
}

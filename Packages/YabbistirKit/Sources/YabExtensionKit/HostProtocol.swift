import Foundation

/// The app ↔ extension host protocol: one JSON object per line on the host's standard input and
/// output.
public struct HostRequest: Codable, Sendable {
    public var id: Int
    public var load: LoadRequest?
    public var unload: UnloadRequest?
    public var invoke: InvokeRequest?
    /// Never answered: the call it names ends on the app's side at once.
    public var cancel: CancelRequest?
    /// The app's answer to a `call` event; never answered either.
    public var reply: ReplyRequest?

    public init(id: Int = 0, load: LoadRequest? = nil, unload: UnloadRequest? = nil, invoke: InvokeRequest? = nil,
                cancel: CancelRequest? = nil, reply: ReplyRequest? = nil) {
        (self.id, self.load, self.unload, self.invoke, self.cancel, self.reply) = (id, load, unload, invoke, cancel, reply)
    }
}

public struct LoadRequest: Codable, Equatable, Sendable {
    public var extensionID: String
    public var folder: String
    public var dataFolder: String
    public var language: String
    /// What the extension may use: what its manifest asks for once the person agreed (empty for built-ins).
    public var grant: PermissionGrant
    /// Where `requires.tools` are looked for, in order.
    public var toolSearchPath: [String]
    /// The extension's own `secret` preferences that have a value, by key. Never logged, never in
    /// `ctx.preferences`; it reaches only this extension, through `yab.secrets.get`.
    public var secrets: [String: String]

    public init(extensionID: String, folder: String, dataFolder: String, language: String, grant: PermissionGrant = .empty,
                toolSearchPath: [String] = [], secrets: [String: String] = [:]) {
        (self.extensionID, self.folder, self.dataFolder, self.language) = (extensionID, folder, dataFolder, language)
        (self.grant, self.toolSearchPath, self.secrets) = (grant, toolSearchPath, secrets)
    }

    /// A request without a grant, a search path or secrets grants and holds nothing.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(extensionID: try c.decode(String.self, forKey: .extensionID), folder: try c.decode(String.self, forKey: .folder),
                  dataFolder: try c.decode(String.self, forKey: .dataFolder), language: try c.decode(String.self, forKey: .language),
                  grant: try c.decodeIfPresent(PermissionGrant.self, forKey: .grant) ?? .empty,
                  toolSearchPath: try c.decodeIfPresent([String].self, forKey: .toolSearchPath) ?? [],
                  secrets: try c.decodeIfPresent([String: String].self, forKey: .secrets) ?? [:])
    }
}

public struct UnloadRequest: Codable, Equatable, Sendable {
    public var extensionID: String
    public init(extensionID: String) { self.extensionID = extensionID }
}

public struct InvokeRequest: Codable, Sendable {
    public var extensionID: String
    public var kind: InvokeKind
    public var name: String
    public var item: ExtensionItem?
    public var context: ExtensionContext
    /// The network and programs are allowed: only in a `run` the person started.
    public var effects: Bool

    public init(extensionID: String, kind: InvokeKind, name: String, item: ExtensionItem?, context: ExtensionContext, effects: Bool = false) {
        (self.extensionID, self.kind, self.name, self.item, self.context, self.effects) = (extensionID, kind, name, item, context, effects)
    }
}

/// Stop the call that went out with this request id: its AbortSignal fires and its pending `yab`
/// promises reject with `cancelled`.
public struct CancelRequest: Codable, Equatable, Sendable {
    public var callID: Int
    public init(callID: Int) { self.callID = callID }
}

/// The app's answer to a `call` event: `ok` (nil reads as null) or `error`. The host drops one for a
/// request nobody waits for any more (its call ended first).
public struct ReplyRequest: Codable, Equatable, Sendable {
    public var requestID: Int
    public var ok: JSONValue?
    public var error: ExtensionError?

    public init(requestID: Int, ok: JSONValue? = nil, error: ExtensionError? = nil) {
        (self.requestID, self.ok, self.error) = (requestID, ok, error)
    }
}

/// From the host: an answer to a request (`id` with `ok`, `done` or `error`), or an event.
public struct HostMessage: Codable, Sendable {
    public var id: Int?
    public var ok: InvokeOutput?
    /// A load or unload went through.
    public var done: Bool?
    public var error: ExtensionError?
    /// "log", "progress" (`id` is the call's) or "call": a request to the app made by the call that went
    /// out with `id`, answered with `HostRequest.reply`.
    public var event: String?
    public var extensionID: String?
    public var message: String?
    /// A progress event's share done, 0…1; nil while it cannot be told.
    public var fraction: Double?
    /// A call event's number, which the reply names.
    public var requestID: Int?
    /// What a call event asks the app for ("notify", "open" …), and with what.
    public var method: String?
    public var params: JSONValue?
    /// Whether the asking call may reach beyond itself, and what kind of call it is.
    public var effects: Bool?
    public var kind: InvokeKind?

    public init(id: Int? = nil, ok: InvokeOutput? = nil, done: Bool? = nil, error: ExtensionError? = nil,
                event: String? = nil, extensionID: String? = nil, message: String? = nil, fraction: Double? = nil,
                requestID: Int? = nil, method: String? = nil, params: JSONValue? = nil, effects: Bool? = nil, kind: InvokeKind? = nil) {
        (self.id, self.ok, self.done, self.error) = (id, ok, done, error)
        (self.event, self.extensionID, self.message, self.fraction) = (event, extensionID, message, fraction)
        (self.requestID, self.method, self.params, self.effects, self.kind) = (requestID, method, params, effects, kind)
    }

    public static func log(_ extensionID: String, _ message: String) -> HostMessage {
        HostMessage(event: "log", extensionID: extensionID, message: message)
    }

    /// `yab.job.progress` during the call that went out with `callID`.
    public static func progress(_ callID: Int, fraction: Double?, message: String?) -> HostMessage {
        HostMessage(id: callID, event: "progress", message: message, fraction: fraction)
    }

    /// A request to the app from the call that went out with `callID`.
    public static func call(_ callID: Int, requestID: Int, method: String, params: JSONValue, effects: Bool, kind: InvokeKind,
                            extensionID: String) -> HostMessage {
        HostMessage(id: callID, event: "call", extensionID: extensionID, requestID: requestID, method: method, params: params,
                    effects: effects, kind: kind)
    }
}

/// `yab.ai.generate`'s options, as the extension gave them.
public struct AIOptions: Codable, Equatable, Sendable {
    public var instructions: String?
    public var temperature: Double?
    public var maxTokens: Int?

    public init(instructions: String? = nil, temperature: Double? = nil, maxTokens: Int? = nil) {
        (self.instructions, self.temperature, self.maxTokens) = (instructions, temperature, maxTokens)
    }
}

/// What `yab.translate` resolves with: the translated text, and the source language (recognized, or the one given).
public struct TranslationOutput: Codable, Equatable, Sendable {
    public var text: String
    public var from: String

    public init(text: String, from: String) {
        (self.text, self.from) = (text, from)
    }
}

/// Cuts a byte stream into newline-terminated lines. Each byte is looked at once: a long line
/// arriving in pipe-sized chunks is never rescanned from its start.
public final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    /// Bytes at the front of `buffer` already known to hold no newline.
    private var scanned = 0

    public init() {}

    public func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        var lineStart = 0
        buffer.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var offset = scanned
            while offset < bytes.count, let found = memchr(base + offset, 0x0A, bytes.count - offset) {
                let newline = base.distance(to: UnsafeRawPointer(found))
                if newline > lineStart { lines.append(Data(bytes[lineStart..<newline])) }
                lineStart = newline + 1
                offset = lineStart
            }
        }
        if lineStart > 0 { buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + lineStart) }
        scanned = buffer.count
        return lines
    }
}

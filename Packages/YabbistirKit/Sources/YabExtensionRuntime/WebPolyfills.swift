import Foundation
import JavaScriptCore
import Security

/// The web standards extensions may use: console, timers, atob/btoa, TextEncoder/TextDecoder,
/// crypto.getRandomValues/randomUUID, URL and URLSearchParams, AbortController and
/// AbortSignal. Node's built-ins stay absent.
enum WebPolyfills {
    static func install(in runtime: ExtensionRuntime) {
        let context = runtime.context

        let console = JSValue(newObjectIn: context)!
        let write: @convention(block) () -> Void = { [weak runtime] in
            let line = (JSContext.currentArguments() as? [JSValue] ?? []).map(Self.format).joined(separator: " ")
            runtime?.log(line)
        }
        for level in ["log", "info", "warn", "error", "debug"] { console.setValue(unsafeBitCast(write, to: AnyObject.self), forProperty: level) }
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        let setTimeout: @convention(block) (JSValue, JSValue?) -> Int = { [weak runtime] callback, delay in
            guard let runtime else { return 0 }
            let id = runtime.nextTimerID
            runtime.nextTimerID += 1
            let arguments = Array((JSContext.currentArguments() as? [JSValue] ?? []).dropFirst(2))
            let milliseconds = delay.map { $0.isNumber ? max(0, $0.toDouble()) : 0 } ?? 0
            // The callback goes on inside the call that set it.
            let scope = runtime.currentScope
            let item = DispatchWorkItem { [weak runtime] in
                guard let runtime, runtime.timers.removeValue(forKey: id) != nil else { return }
                runtime.within(scope) { _ = callback.call(withArguments: arguments) }
            }
            runtime.timers[id] = item
            runtime.queue.asyncAfter(deadline: .now() + (milliseconds.isFinite ? milliseconds : 0) / 1000, execute: item)
            return id
        }
        let clearTimeout: @convention(block) (Int) -> Void = { [weak runtime] id in
            runtime?.timers.removeValue(forKey: id)?.cancel()
        }
        context.setObject(unsafeBitCast(setTimeout, to: AnyObject.self), forKeyedSubscript: "setTimeout" as NSString)
        context.setObject(unsafeBitCast(clearTimeout, to: AnyObject.self), forKeyedSubscript: "clearTimeout" as NSString)

        let btoa: @convention(block) (String) -> JSValue? = { text in
            var bytes: [UInt8] = []
            bytes.reserveCapacity(text.utf16.count)
            for unit in text.utf16 {
                guard unit <= 0xFF else { return Self.throwError("InvalidCharacterError: btoa only takes Latin-1 characters") }
                bytes.append(UInt8(unit))
            }
            return JSValue(object: Data(bytes).base64EncodedString(), in: JSContext.current())
        }
        let atob: @convention(block) (String) -> JSValue? = { text in
            var cleaned = text.filter { !$0.isWhitespace }
            while cleaned.count % 4 != 0 { cleaned.append("=") }
            guard let data = Data(base64Encoded: cleaned) else {
                return Self.throwError("InvalidCharacterError: the string is not valid base64")
            }
            return JSValue(object: String(data.map { Character(Unicode.Scalar($0)) }), in: JSContext.current())
        }
        context.setObject(unsafeBitCast(btoa, to: AnyObject.self), forKeyedSubscript: "btoa" as NSString)
        context.setObject(unsafeBitCast(atob, to: AnyObject.self), forKeyedSubscript: "atob" as NSString)

        let randomBytes: @convention(block) (Int) -> [Int] = { count in
            var bytes = [UInt8](repeating: 0, count: max(0, min(count, 65_536)))
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return bytes.map(Int.init)
        }
        context.setObject(unsafeBitCast(randomBytes, to: AnyObject.self), forKeyedSubscript: "__yabRandomBytes" as NSString)

        context.evaluateScript(script)
        runtime.abortControllerType = context.objectForKeyedSubscript("AbortController")
    }

    private static func format(_ value: JSValue) -> String {
        if value.isString { return value.toString() }
        if value.isObject, let json = value.context.objectForKeyedSubscript("JSON").invokeMethod("stringify", withArguments: [value]),
           json.isString { return json.toString() }
        return value.toString() ?? ""
    }

    private static func throwError(_ message: String) -> JSValue? {
        let context = JSContext.current()
        context?.exception = JSValue(newErrorFromMessage: message, in: context)
        return JSValue(undefinedIn: context)
    }

    /// The parts written in JavaScript.
    private static let script = #"""
    (function () {
      class TextEncoder {
        get encoding() { return "utf-8"; }
        encode(input = "") {
          const text = String(input), out = [];
          for (let i = 0; i < text.length; i++) {
            let code = text.charCodeAt(i);
            if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
              const next = text.charCodeAt(i + 1);
              if (next >= 0xdc00 && next <= 0xdfff) { code = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00); i++; }
              else code = 0xfffd;
            } else if (code >= 0xd800 && code <= 0xdfff) code = 0xfffd;
            if (code < 0x80) out.push(code);
            else if (code < 0x800) out.push(0xc0 | (code >> 6), 0x80 | (code & 63));
            else if (code < 0x10000) out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
            else out.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 63), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
          }
          return new Uint8Array(out);
        }
      }
      class TextDecoder {
        constructor(label = "utf-8", options = {}) {
          if (!/^utf-?8$/i.test(String(label))) throw new RangeError("TextDecoder only decodes utf-8");
          this.fatal = !!options.fatal;
        }
        get encoding() { return "utf-8"; }
        decode(input) {
          if (input === undefined) return "";
          const bytes = input instanceof Uint8Array ? input
            : ArrayBuffer.isView(input) ? new Uint8Array(input.buffer, input.byteOffset, input.byteLength)
            : new Uint8Array(input);
          let out = "", i = 0;
          const bad = () => { if (this.fatal) throw new TypeError("The encoded data was not valid utf-8"); out += "�"; };
          while (i < bytes.length) {
            const b = bytes[i];
            let need = 0, code = 0;
            if (b < 0x80) { out += String.fromCharCode(b); i++; continue; }
            else if (b >= 0xc2 && b < 0xe0) { need = 1; code = b & 31; }
            else if (b >= 0xe0 && b < 0xf0) { need = 2; code = b & 15; }
            else if (b >= 0xf0 && b < 0xf5) { need = 3; code = b & 7; }
            else { bad(); i++; continue; }
            let ok = true;
            for (let k = 1; k <= need; k++) {
              const c = bytes[i + k];
              if (c === undefined || (c & 0xc0) !== 0x80) { ok = false; break; }
              code = (code << 6) | (c & 63);
            }
            if (!ok || (need === 2 && code < 0x800) || (need === 3 && (code < 0x10000 || code > 0x10ffff)) || (code >= 0xd800 && code <= 0xdfff)) {
              bad(); i++; continue;
            }
            out += String.fromCodePoint(code);
            i += need + 1;
          }
          return out;
        }
      }
      globalThis.TextEncoder = TextEncoder;
      globalThis.TextDecoder = TextDecoder;

      const hex = n => n.toString(16).padStart(2, "0");
      globalThis.crypto = {
        getRandomValues(array) {
          if (!ArrayBuffer.isView(array)) throw new TypeError("getRandomValues takes a typed array");
          if (array.byteLength > 65536) throw new RangeError("getRandomValues takes at most 65536 bytes");
          const bytes = __yabRandomBytes(array.byteLength);
          const view = new Uint8Array(array.buffer, array.byteOffset, array.byteLength);
          for (let i = 0; i < bytes.length; i++) view[i] = bytes[i];
          return array;
        },
        randomUUID() {
          const b = crypto.getRandomValues(new Uint8Array(16));
          b[6] = (b[6] & 0x0f) | 0x40;
          b[8] = (b[8] & 0x3f) | 0x80;
          const h = Array.from(b, hex).join("");
          return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
        },
      };

      const encodeParam = s => encodeURIComponent(s).replace(/%20/g, "+");
      const decodeParam = s => { try { return decodeURIComponent(s.replace(/\+/g, " ")); } catch (e) { return s; } };
      class URLSearchParams {
        constructor(init = "") {
          this._list = [];
          this._url = null;
          if (typeof init === "string") this._parse(init);
          else if (init instanceof URLSearchParams) this._list = init._list.map(p => [p[0], p[1]]);
          else if (Array.isArray(init)) this._list = init.map(p => [String(p[0]), String(p[1])]);
          else if (init && typeof init === "object") this._list = Object.keys(init).map(k => [k, String(init[k])]);
        }
        _parse(text) {
          this._list = [];
          for (const part of String(text).replace(/^\?/, "").split("&")) {
            if (!part) continue;
            const at = part.indexOf("=");
            this._list.push(at < 0 ? [decodeParam(part), ""] : [decodeParam(part.slice(0, at)), decodeParam(part.slice(at + 1))]);
          }
        }
        _update() { if (this._url) { const s = this.toString(); this._url._search = s ? "?" + s : ""; } }
        append(k, v) { this._list.push([String(k), String(v)]); this._update(); }
        delete(k) { this._list = this._list.filter(p => p[0] !== String(k)); this._update(); }
        get(k) { const p = this._list.find(p => p[0] === String(k)); return p ? p[1] : null; }
        getAll(k) { return this._list.filter(p => p[0] === String(k)).map(p => p[1]); }
        has(k) { return this._list.some(p => p[0] === String(k)); }
        set(k, v) {
          const key = String(k), i = this._list.findIndex(p => p[0] === key);
          if (i < 0) this._list.push([key, String(v)]);
          else { this._list[i][1] = String(v); this._list = this._list.filter((p, j) => j <= i || p[0] !== key); }
          this._update();
        }
        sort() { this._list.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0)); this._update(); }
        forEach(fn, self) { for (const [k, v] of this._list) fn.call(self, v, k, this); }
        keys() { return this._list.map(p => p[0])[Symbol.iterator](); }
        values() { return this._list.map(p => p[1])[Symbol.iterator](); }
        entries() { return this._list.map(p => [p[0], p[1]])[Symbol.iterator](); }
        [Symbol.iterator]() { return this.entries(); }
        get size() { return this._list.length; }
        toString() { return this._list.map(p => encodeParam(p[0]) + "=" + encodeParam(p[1])).join("&"); }
      }
      const pattern = /^([a-zA-Z][a-zA-Z0-9+.-]*:)(?:\/\/(?:([^:@\/?#]*)(?::([^@\/?#]*))?@)?(\[[^\]]*\]|[^:\/?#]*)(?::(\d*))?)?([^?#]*)(\?[^#]*)?(#.*)?$/;
      const defaultPorts = { "http:": "80", "https:": "443", "ftp:": "21", "ws:": "80", "wss:": "443" };
      class URL {
        constructor(input, base) {
          let text = String(input).trim();
          if (base !== undefined && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(text)) {
            const b = new URL(base);
            if (text.startsWith("//")) text = b.protocol + text;
            else if (text.startsWith("/")) text = b.origin + text;
            else if (text.startsWith("?")) text = b.origin + b.pathname + text;
            else if (text.startsWith("#")) text = b.origin + b.pathname + b.search + text;
            else text = b.origin + b.pathname.replace(/[^/]*$/, "") + text;
          }
          const m = pattern.exec(text);
          if (!m) throw new TypeError(`Invalid URL: ${input}`);
          this._protocol = m[1].toLowerCase();
          this._hierarchical = text.slice(m[1].length).startsWith("//");
          this.username = m[2] || "";
          this.password = m[3] || "";
          this._hostname = (m[4] || "").toLowerCase();
          this._port = m[5] && m[5] !== defaultPorts[this._protocol] ? m[5] : "";
          this.pathname = m[6] || (this._hierarchical ? "/" : "");
          this._search = m[7] && m[7] !== "?" ? m[7] : "";
          this.hash = m[8] && m[8] !== "#" ? m[8] : "";
          if (this._hierarchical && !this._hostname && this._protocol !== "file:") throw new TypeError(`Invalid URL: ${input}`);
          this._params = new URLSearchParams(this._search);
          this._params._url = this;
        }
        get protocol() { return this._protocol; }
        get hostname() { return this._hostname; }
        get port() { return this._port; }
        get host() { return this._hostname + (this._port ? ":" + this._port : ""); }
        get origin() { return this._hierarchical ? `${this._protocol}//${this.host}` : "null"; }
        get search() { return this._search; }
        set search(value) { const s = String(value); this._search = s && s !== "?" ? (s.startsWith("?") ? s : "?" + s) : ""; this._params._parse(this._search); }
        get searchParams() { return this._params; }
        get href() {
          const auth = this.username ? this.username + (this.password ? ":" + this.password : "") + "@" : "";
          return this._hierarchical ? `${this._protocol}//${auth}${this.host}${this.pathname}${this._search}${this.hash}`
            : `${this._protocol}${this.pathname}${this._search}${this.hash}`;
        }
        toString() { return this.href; }
        toJSON() { return this.href; }
      }
      globalThis.URL = URL;
      globalThis.URLSearchParams = URLSearchParams;

      const signalToken = {};
      const abortError = (name, message) => { const e = new Error(message); e.name = name; return e; };
      class AbortSignal {
        constructor(token) {
          if (token !== signalToken) throw new TypeError("Illegal constructor");
          this._aborted = false;
          this._reason = undefined;
          this._listeners = [];
          this.onabort = null;
        }
        get aborted() { return this._aborted; }
        get reason() { return this._reason; }
        addEventListener(type, listener) {
          if (type !== "abort" || typeof listener !== "function" || this._aborted || this._listeners.includes(listener)) return;
          this._listeners.push(listener);
        }
        removeEventListener(type, listener) {
          if (type === "abort") this._listeners = this._listeners.filter(l => l !== listener);
        }
        throwIfAborted() { if (this._aborted) throw this._reason; }
        _abort(reason) {
          if (this._aborted) return;
          this._aborted = true;
          this._reason = reason === undefined ? abortError("AbortError", "This operation was aborted") : reason;
          const event = { type: "abort", target: this, currentTarget: this };
          const handlers = (typeof this.onabort === "function" ? [this.onabort] : []).concat(this._listeners);
          this._listeners = [];
          for (const handler of handlers) {
            try { handler.call(this, event); } catch (e) { console.error(String(e)); }
          }
        }
        static timeout(ms) {
          const controller = new AbortController();
          setTimeout(() => controller.abort(abortError("TimeoutError", "The operation timed out")), ms);
          return controller.signal;
        }
      }
      class AbortController {
        constructor() { this._signal = new AbortSignal(signalToken); }
        get signal() { return this._signal; }
        abort(reason) { this._signal._abort(reason); }
      }
      globalThis.AbortSignal = AbortSignal;
      globalThis.AbortController = AbortController;
    })();
    """#
}

extension WebPolyfills {
    /// `Headers`, `Response`, `fetch` and `yab.http`, built around the native call (url, options, binary),
    /// which only this script holds. `fetch` asks for bytes (so `arrayBuffer()` works); `yab.http.fetch` for text or a file.
    static let fetchScript = #"""
    (function (native) {
      "use strict";
      const lower = (name) => String(name).toLowerCase();
      class Headers {
        constructor(init) {
          this._map = new Map();
          if (init === undefined || init === null) return;
          if (init instanceof Headers) init.forEach((value, name) => this.append(name, value));
          else if (Array.isArray(init)) for (const pair of init) this.append(pair[0], pair[1]);
          else if (typeof init === "object") for (const name of Object.keys(init)) this.append(name, init[name]);
        }
        append(name, value) {
          const key = lower(name);
          this._map.set(key, this._map.has(key) ? this._map.get(key) + ", " + String(value) : String(value));
        }
        set(name, value) { this._map.set(lower(name), String(value)); }
        get(name) { const key = lower(name); return this._map.has(key) ? this._map.get(key) : null; }
        has(name) { return this._map.has(lower(name)); }
        delete(name) { this._map.delete(lower(name)); }
        forEach(callback, thisArg) { for (const [name, value] of this._map) callback.call(thisArg, value, name, this); }
        keys() { return this._map.keys(); }
        values() { return this._map.values(); }
        entries() { return this._map.entries(); }
        [Symbol.iterator]() { return this._map.entries(); }
      }
      const bytesOf = (body) => {
        if (body === undefined || body === null) return new Uint8Array(0);
        if (typeof body === "string") return new TextEncoder().encode(body);
        if (body instanceof ArrayBuffer) return new Uint8Array(body);
        if (ArrayBuffer.isView(body)) return new Uint8Array(body.buffer, body.byteOffset, body.byteLength);
        return new TextEncoder().encode(String(body));
      };
      class Response {
        constructor(body, init) {
          const options = init || {};
          this._body = bytesOf(body);
          this.status = options.status === undefined ? 200 : options.status;
          this.statusText = options.statusText || "";
          this.headers = new Headers(options.headers);
          this.url = "";
          this.bodyUsed = false;
        }
        get ok() { return this.status >= 200 && this.status < 300; }
        _consume() {
          if (this.bodyUsed) return Promise.reject(new TypeError("Body has already been consumed"));
          this.bodyUsed = true;
          return Promise.resolve(this._body);
        }
        text() { return this._consume().then((bytes) => new TextDecoder().decode(bytes)); }
        json() { return this.text().then((text) => JSON.parse(text)); }
        arrayBuffer() { return this._consume().then((bytes) => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)); }
      }
      globalThis.Headers = Headers;
      globalThis.Response = Response;

      globalThis.fetch = function fetch(input, init) {
        const options = init || {};
        const url = input !== null && typeof input === "object" ? String(input.href !== undefined ? input.href : input.url) : String(input);
        const headers = new Headers(options.headers);
        let body = options.body;
        if (body instanceof URLSearchParams) {
          if (!headers.has("content-type")) headers.set("content-type", "application/x-www-form-urlencoded;charset=UTF-8");
          body = body.toString();
        } else if (body instanceof ArrayBuffer) {
          body = new Uint8Array(body);
        } else if (ArrayBuffer.isView(body) && !(body instanceof Uint8Array)) {
          body = new Uint8Array(body.buffer, body.byteOffset, body.byteLength);
        }
        const plain = {};
        headers.forEach((value, name) => { plain[name] = value; });
        return native(url, { method: options.method, headers: plain, body: body, signal: options.signal }, true).then((result) => {
          const response = new Response(result.bytes, { status: result.status, headers: result.headers });
          response.url = url;
          return response;
        });
      };

      yab.http = {
        fetch(url, init) { return native(String(url), init, false); },
      };
    })
    """#
}

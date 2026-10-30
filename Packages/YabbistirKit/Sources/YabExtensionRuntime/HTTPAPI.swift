import Foundation
import JavaScriptCore
import YabExtensionKit

/// Which hosts a call may reach: a host is allowed when it equals one of the
/// extension's `domains` or ends with `"." + domain`. No domains: any host. Only http and https.
struct DomainPolicy: Sendable {
    let domains: [String]

    init(domains: [String]) {
        self.domains = domains.map(Self.normalized).filter { !$0.isEmpty }
    }

    static func normalized(_ host: String) -> String {
        var name = host.lowercased().trimmingCharacters(in: .whitespaces)
        while name.hasSuffix(".") { name.removeLast() }
        return name
    }

    static func host(of url: URL) -> String {
        normalized(url.host ?? "")
    }

    /// Whether the URL's scheme is one that may be fetched at all.
    static func isWebURL(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "")
    }

    /// A real host name: letters, digits, dots and hyphens (an IDN host is already punycode), or an IPv6
    /// literal. URL.host is percent-decoded, so "/", "@", "#" or "?" in it would otherwise get past a suffix test.
    static func isHostName(_ host: String) -> Bool {
        let host = normalized(host)
        guard !host.isEmpty else { return false }
        if host.contains(":") { return host.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } }
        return host.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "-" }
    }

    func permits(host: String) -> Bool {
        let host = Self.normalized(host)
        guard Self.isHostName(host) else { return false }
        if domains.isEmpty { return true }
        // An address is never "inside" a domain: only an exact match counts.
        let isAddress = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
        return domains.contains { host == $0 || (!isAddress && host.hasSuffix("." + $0)) }
    }

    func permits(_ url: URL) -> Bool {
        Self.isWebURL(url) && permits(host: url.host ?? "")
    }
}

/// One session for the runtime, with a delegate that holds every request to the domains (redirect
/// hops included), streams the body (so a limit stops the read) and cancels on request. No cookies
/// are kept.
final class HTTPClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let textLimit = 10 * 1_048_576

    enum Mode {
        case text
        case bytes
        case file(URL)
    }

    struct Outcome {
        var status: Int
        var headers: [String: String]
        var body: Data
        var file: String?
        var isBytes: Bool
    }

    private final class Transfer: @unchecked Sendable {
        let policy: DomainPolicy
        let host: String
        let mode: Mode
        let completion: @Sendable (Result<Outcome, ExtensionError>) -> Void
        var status = 0
        var headers: [String: String] = [:]
        var body = Data()
        var handle: FileHandle?
        var fileURL: URL?
        var failure: ExtensionError?

        init(policy: DomainPolicy, host: String, mode: Mode, completion: @escaping @Sendable (Result<Outcome, ExtensionError>) -> Void) {
            (self.policy, self.host, self.mode, self.completion) = (policy, host, mode, completion)
        }
    }

    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    private var session: URLSession!

    init(configuration: URLSessionConfiguration) {
        super.init()
        let configuration = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    /// Starts the request; `completion` hears the outcome once, on the session's queue. The returned
    /// closure cancels it (the first reason given is the one `completion` gets).
    func start(_ request: URLRequest, policy: DomainPolicy, mode: Mode,
               completion: @escaping @Sendable (Result<Outcome, ExtensionError>) -> Void) -> @Sendable (ExtensionError) -> Void {
        let task = session.dataTask(with: request)
        let transfer = Transfer(policy: policy, host: DomainPolicy.host(of: request.url ?? URL(fileURLWithPath: "/")), mode: mode, completion: completion)
        lock.withLock { transfers[task.taskIdentifier] = transfer }
        task.resume()
        return { [weak self] reason in self?.abort(task, transfer, reason) }
    }

    private func abort(_ task: URLSessionTask, _ transfer: Transfer, _ reason: ExtensionError) {
        lock.withLock { if transfer.failure == nil { transfer.failure = reason } }
        task.cancel()
    }

    private func transfer(for task: URLSessionTask) -> Transfer? {
        lock.withLock { transfers[task.taskIdentifier] }
    }

    private func fail(_ task: URLSessionTask, _ transfer: Transfer, _ error: ExtensionError) {
        abort(task, transfer, error)
    }

    // MARK: Delegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let transfer = transfer(for: task) else { completionHandler(nil); return }
        if let url = request.url, transfer.policy.permits(url) {
            completionHandler(request)
            return
        }
        let host = request.url.map(DomainPolicy.host(of:)).flatMap { DomainPolicy.isHostName($0) ? $0 : nil } ?? "an invalid host"
        fail(task, transfer, ExtensionError(.networkError, "redirected outside the allowed domains (\(host))"))
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = transfer(for: dataTask), let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        transfer.status = http.statusCode
        for (key, value) in http.allHeaderFields {
            transfer.headers["\(key)".lowercased()] = "\(value)"
        }
        switch transfer.mode {
        case .file(let url) where (200..<300).contains(http.statusCode):
            do {
                try? FileManager.default.removeItem(at: url)
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                transfer.handle = try FileHandle(forWritingTo: url)
                transfer.fileURL = url
            } catch {
                fail(dataTask, transfer, ExtensionError(.unavailable, "the file could not be written: \(error.localizedDescription)"))
                completionHandler(.cancel)
                return
            }
        default:
            // A failed download's body is read as text (an error page), never saved as the file.
            if http.expectedContentLength > Int64(Self.textLimit) {
                fail(dataTask, transfer, Self.tooLarge(transfer.mode))
                completionHandler(.cancel)
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfer(for: dataTask), lock.withLock({ transfer.failure }) == nil else { return }
        if let handle = transfer.handle {
            do {
                try handle.write(contentsOf: data)
            } catch {
                fail(dataTask, transfer, ExtensionError(.unavailable, "the file could not be written: \(error.localizedDescription)"))
            }
            return
        }
        transfer.body.append(data)
        if transfer.body.count > Self.textLimit {
            fail(dataTask, transfer, Self.tooLarge(transfer.mode))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let finished: Transfer? = lock.withLock { transfers.removeValue(forKey: task.taskIdentifier) }
        guard let transfer = finished else { return }
        try? transfer.handle?.close()
        let failure = lock.withLock { transfer.failure } ?? error.map { Self.map($0, host: transfer.host) }
        if let failure {
            // Nothing half-written stays behind.
            if let url = transfer.fileURL { try? FileManager.default.removeItem(at: url) }
            transfer.completion(.failure(failure))
            return
        }
        var isBytes = false
        if case .bytes = transfer.mode { isBytes = true }
        transfer.completion(.success(Outcome(status: transfer.status, headers: transfer.headers, body: transfer.body,
                                             file: transfer.fileURL?.path, isBytes: isBytes)))
    }

    // MARK: Errors

    private static func tooLarge(_ mode: Mode) -> ExtensionError {
        if case .bytes = mode { return ExtensionError(.networkError, "the response is larger than 10 MB") }
        return ExtensionError(.networkError, "the response is larger than 10 MB; pass toFile")
    }

    /// A short reason and the host, never the URL (it usually came from the clipboard).
    static func map(_ error: any Error, host: String) -> ExtensionError {
        guard let urlError = error as? URLError else { return ExtensionError(.networkError, "\(host): the request failed") }
        let reason: String
        switch urlError.code {
        case .cancelled: return CallScope.cancelled
        case .timedOut: reason = "the request timed out"
        case .cannotFindHost, .dnsLookupFailed: reason = "the host was not found"
        case .cannotConnectToHost: reason = "could not connect"
        case .notConnectedToInternet: reason = "no internet connection"
        case .networkConnectionLost: reason = "the connection was lost"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
            reason = "the secure connection failed"
        case .httpTooManyRedirects, .redirectToNonExistentLocation: reason = "too many redirects"
        default: reason = "the request failed"
        }
        return ExtensionError(.networkError, "\(host): \(reason)")
    }
}

/// `yab.http.fetch` and the web `fetch`. Both go through the same native call.
enum HTTPAPI {
    static func install(in runtime: ExtensionRuntime) {
        let context = runtime.context
        let native: @convention(block) (JSValue?, JSValue?, Bool) -> JSValue? = { [weak runtime] url, options, binary in
            guard let runtime else { return nil }
            return fetch(url, options, binary: binary, runtime: runtime)
        }
        // The native call is handed to the script that builds the wrappers and kept nowhere else.
        let build = context.evaluateScript(WebPolyfills.fetchScript)
        build?.call(withArguments: [unsafeBitCast(native, to: AnyObject.self)])
    }

    private struct Prepared {
        var request: URLRequest
        var policy: DomainPolicy
        var mode: HTTPClient.Mode
        var signal: JSValue?
    }

    private static func fetch(_ url: JSValue?, _ options: JSValue?, binary: Bool, runtime: ExtensionRuntime) -> JSValue? {
        let scope = runtime.currentScope
        return JSValue(newPromiseIn: runtime.context) { resolve, reject in
            let settler = Settler(runtime: runtime, scope: scope, resolve: resolve, reject: reject)
            do throws(ExtensionError) {
                guard let scope else { throw ExtensionError(.permissionDenied, "yab.http works inside a call") }
                try HostAPI.require("network", in: scope)
                let prepared = try prepare(url, options, binary: binary, scope: scope, runtime: runtime)
                if prepared.signal?.forProperty("aborted")?.toBool() == true { throw CallScope.cancelled }
                // The request never keeps the runtime alive: one let go of meanwhile settles nothing.
                let cancel = runtime.http.start(prepared.request, policy: prepared.policy, mode: prepared.mode) { [weak runtime] result in
                    runtime?.queue.async { settler.complete(result) }
                }
                settler.token = scope.whenEnded { reason in
                    cancel(reason)
                    settler.settle(.failure(reason))
                }
                if let signal = prepared.signal {
                    // Taken off when the fetch settles, so a finished one leaves nothing on the signal.
                    settler.listener = AbortListener(signal: signal, in: runtime.context) { cancel(CallScope.cancelled) }
                }
            } catch {
                settler.settle(.failure(error))
            }
        }
    }

    private static func prepare(_ url: JSValue?, _ options: JSValue?, binary: Bool, scope: CallScope,
                                runtime: ExtensionRuntime) throws(ExtensionError) -> Prepared {
        guard let url, url.isString, let target = URL(string: url.toString()) else {
            throw ExtensionError(.badResult, "the URL is not valid")
        }
        guard DomainPolicy.isWebURL(target) else {
            throw ExtensionError(.permissionDenied, "only http and https URLs can be fetched")
        }
        let host = DomainPolicy.host(of: target)
        guard !host.isEmpty else { throw ExtensionError(.badResult, "the URL has no host") }
        guard DomainPolicy.isHostName(host) else { throw ExtensionError(.permissionDenied, "the URL's host is not a valid host name") }
        let policy = DomainPolicy(domains: scope.grant.domains)
        guard policy.permits(host: host) else {
            throw ExtensionError(.permissionDenied, "\(host) is not in the extension's domains")
        }

        var request = URLRequest(url: target)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        let options = options.flatMap { $0.isObject ? $0 : nil }
        func option(_ name: String) -> JSValue? {
            options?.forProperty(name).flatMap { $0.isUndefined || $0.isNull ? nil : $0 }
        }
        if let method = option("method") {
            let text = method.toString().uppercased()
            guard method.isString, !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isLetter }) else {
                throw ExtensionError(.badResult, "method must be an HTTP method name")
            }
            request.httpMethod = text
        }
        if let headers = option("headers") {
            guard let table = headers.toDictionary() as? [String: Any] else { throw ExtensionError(.badResult, "headers must be an object of strings") }
            for (name, value) in table { request.setValue("\(value)", forHTTPHeaderField: name) }
        }
        if let body = option("body") {
            if body.isString {
                request.httpBody = Data(body.toString().utf8)
            } else if let data = NativeAPI.typedArrayData(body, in: runtime.context) {
                request.httpBody = data
            } else {
                throw ExtensionError(.badResult, "body must be a string or a Uint8Array")
            }
        }

        var mode = HTTPClient.Mode.text
        if binary {
            mode = .bytes
        } else if let toFile = option("toFile") {
            if toFile.isString {
                mode = .file(try scope.workFolder.appendingPathComponent(try FilesAPI.sanitized(toFile.toString())))
            } else if toFile.isBoolean {
                if toFile.toBool() {
                    // The URL's last path component; "download" when it has none a file can have.
                    let derived = target.lastPathComponent.removingPercentEncoding ?? target.lastPathComponent
                    let name = derived == "/" ? "download" : (try? FilesAPI.sanitized(derived)) ?? "download"
                    mode = .file(try scope.workFolder.appendingPathComponent(name))
                }
            } else {
                throw ExtensionError(.badResult, "toFile must be true or a file name")
            }
        }
        return Prepared(request: request, policy: policy, mode: mode, signal: option("signal"))
    }

    /// Settles one fetch's promise, once, inside the call that made it (queue-confined).
    private final class Settler: @unchecked Sendable {
        weak var runtime: ExtensionRuntime?
        let scope: CallScope?
        private var resolve: JSValue?
        private var reject: JSValue?
        var token: Int?
        var listener: AbortListener?
        private var settled = false

        init(runtime: ExtensionRuntime, scope: CallScope?, resolve: JSValue?, reject: JSValue?) {
            (self.runtime, self.scope, self.resolve, self.reject) = (runtime, scope, resolve, reject)
        }

        func complete(_ result: Result<HTTPClient.Outcome, ExtensionError>) {
            if let token, let scope { scope.forget(token) }
            settle(result)
        }

        func settle(_ result: Result<HTTPClient.Outcome, ExtensionError>) {
            guard !settled, let runtime else { return }
            settled = true
            listener?.remove()
            let (resolve, reject) = (self.resolve, self.reject)
            (self.resolve, self.reject, listener) = (nil, nil, nil)
            runtime.within(scope) {
                switch result {
                case .success(let outcome): resolve?.call(withArguments: [Self.value(outcome, in: runtime)])
                case .failure(let error): reject?.call(withArguments: [NativeAPI.errorValue(error, in: runtime.context)])
                }
            }
        }

        private static func value(_ outcome: HTTPClient.Outcome, in runtime: ExtensionRuntime) -> JSValue {
            let object = JSValue(newObjectIn: runtime.context)!
            object.setValue(outcome.status, forProperty: "status")
            object.setValue(runtime.jsValue(.object(outcome.headers.mapValues(JSONValue.string))), forProperty: "headers")
            if let file = outcome.file {
                object.setValue(file, forProperty: "file")
            } else if outcome.isBytes {
                object.setValue(FilesAPI.bytesValue(outcome.body, in: runtime.context), forProperty: "bytes")
            } else {
                object.setValue(String(decoding: outcome.body, as: UTF8.self), forProperty: "text")
            }
            return object
        }
    }
}

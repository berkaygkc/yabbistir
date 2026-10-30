import Foundation
import Testing
@testable import YabPlatform

/// A canned server for `UpdateChecker`, keyed by host so tests running in parallel never see each other's traffic. It
/// answers every request itself: nothing here reaches the network.
final class MockUpdateServer: URLProtocol, @unchecked Sendable {
    enum Reply {
        case redirect(status: Int, location: String?)
        case status(Int)
        case error(URLError.Code)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var seen: [String: [URLRequest]] = [:]

    /// A fresh host with its canned reply, and the session that talks only to the mock.
    static func make(_ reply: Reply) -> (url: URL, session: URLSession) {
        let host = "\(UUID().uuidString.lowercased()).test"
        lock.withLock { replies[host] = reply }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockUpdateServer.self]
        return (URL(string: "https://\(host)/releases/latest")!, URLSession(configuration: configuration))
    }

    static func requests(to host: String) -> [URLRequest] { lock.withLock { seen[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let reply = Self.lock.withLock { () -> Reply? in
            Self.seen[host, default: []].append(request)
            return Self.replies[host]
        }
        switch reply {
        case .redirect(let status, let location):
            var fields: [String: String] = [:]
            if let location { fields["Location"] = location }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
            if let location, let target = URL(string: location, relativeTo: url) {
                // What the real stack does: offer the redirect to the task's delegate first. A session that follows it
                // starts a second request (which this mock would record); one that declines gets the 302 itself.
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .status(let code):
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .error(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        }
    }
}

struct UpdateCheckerTests {
    @Test func aNewerVersionIsOffered() async {
        let live = MockUpdateServer.make(.redirect(status: 302, location: "/releases/tag/v0.2.0"))
        let result = await UpdateChecker(latestURL: live.url, session: live.session, current: "0.1.0").check()
        #expect(result == .available(version: "0.2.0", page: URL(string: "https://\(live.url.host!)/releases/tag/v0.2.0")!))
    }

    @Test func theSameVersionIsUpToDate() async {
        let live = MockUpdateServer.make(.redirect(status: 302, location: "/releases/tag/v0.1.0"))
        let result = await UpdateChecker(latestURL: live.url, session: live.session, current: "0.1.0").check()
        #expect(result == .upToDate(current: "0.1.0"))
    }

    @Test func anOlderLatestIsUpToDateToo() async {
        let live = MockUpdateServer.make(.redirect(status: 302, location: "/releases/tag/v0.0.9"))
        let result = await UpdateChecker(latestURL: live.url, session: live.session, current: "0.1.0").check()
        #expect(result == .upToDate(current: "0.1.0"))
    }

    @Test func semanticOrderNotStringOrder() async {
        #expect(SemanticVersion("0.10.0")! > SemanticVersion("0.9.0")!)
        #expect(SemanticVersion("1.0.0")! > SemanticVersion("0.99.9")!)
        #expect(SemanticVersion("0.2.0-beta")! < SemanticVersion("0.2.0")!)
        #expect(SemanticVersion("v0.2.0")! == SemanticVersion("0.2.0")!)
        #expect(SemanticVersion("0.2.0-beta")! < SemanticVersion("0.2.0-rc")!)
        #expect(SemanticVersion("0.2") == nil)
        #expect(SemanticVersion("0.2.x") == nil)
        #expect(SemanticVersion("") == nil)
        let live = MockUpdateServer.make(.redirect(status: 302, location: "/releases/tag/v0.10.0"))
        let result = await UpdateChecker(latestURL: live.url, session: live.session, current: "0.9.0").check()
        #expect(result == .available(version: "0.10.0", page: URL(string: "https://\(live.url.host!)/releases/tag/v0.10.0")!))
    }

    @Test func aFailureNeverSaysUpToDate() async {
        let replies: [MockUpdateServer.Reply] = [
            .status(404), .status(200), .redirect(status: 500, location: "/releases/tag/v9.9.9"),
            .redirect(status: 302, location: nil),
            .redirect(status: 302, location: "/releases/latest"),
            .redirect(status: 302, location: "/releases/tag/nightly"),
            .redirect(status: 302, location: "/releases/tag/v1.2"),
            .redirect(status: 302, location: "https://elsewhere.test/releases/tag/v9.9.9"),
            .error(.timedOut), .error(.notConnectedToInternet), .error(.cannotFindHost),
        ]
        for reply in replies {
            let live = MockUpdateServer.make(reply)
            let result = await UpdateChecker(latestURL: live.url, session: live.session, current: "0.1.0").check()
            #expect(result == .failed, "\(reply)")
        }
        // An unreadable running version cannot be compared: also a failure.
        let live = MockUpdateServer.make(.redirect(status: 302, location: "/releases/tag/v0.2.0"))
        #expect(await UpdateChecker(latestURL: live.url, session: live.session, current: "dev").check() == .failed)
    }

    @Test func redirectsAreNotFollowed() async {
        let live = MockUpdateServer.make(.redirect(status: 302, location: "https://followed.test/releases/tag/v0.2.0"))
        _ = await UpdateChecker(latestURL: live.url, session: live.session, current: "0.1.0").check()
        #expect(MockUpdateServer.requests(to: live.url.host!).count == 1)
        #expect(MockUpdateServer.requests(to: "followed.test").isEmpty)
    }

    @Test func theRequestIsAnAnonymousHead() async {
        let live = MockUpdateServer.make(.redirect(status: 302, location: "/releases/tag/v0.2.0"))
        _ = await UpdateChecker(latestURL: live.url, session: live.session, current: "0.1.0").check()
        let request = MockUpdateServer.requests(to: live.url.host!).first
        #expect(request?.httpMethod == "HEAD")
        #expect(request?.timeoutInterval == 10)
        #expect(request?.httpShouldHandleCookies == false)
        #expect(request?.httpBody == nil)
        #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request?.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func checkingNeverRunsByItself() async {
        let live = MockUpdateServer.make(.redirect(status: 302, location: "/releases/tag/v0.2.0"))
        let checker = UpdateChecker(latestURL: live.url, session: live.session, current: "0.1.0")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(MockUpdateServer.requests(to: live.url.host!).isEmpty)
        _ = await checker.check()
        #expect(MockUpdateServer.requests(to: live.url.host!).count == 1)
    }
}

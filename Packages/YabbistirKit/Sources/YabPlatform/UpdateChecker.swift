import Foundation

/// major.minor.patch with an optional pre-release suffix (`0.2.0-beta`), compared by number, never by text.
public struct SemanticVersion: Comparable, Hashable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// `beta`, `rc.1`; nil for a release. A pre-release is lower than the same version without one.
    public let preRelease: String?

    /// Reads `1.2.3`, `v1.2.3` and `1.2.3-beta`; anything else is nil.
    public init?(_ text: String) {
        var rest = Substring(text)
        if rest.hasPrefix("v") { rest = rest.dropFirst() }
        var suffix: String?
        if let dash = rest.firstIndex(of: "-") {
            let tail = rest[rest.index(after: dash)...]
            guard !tail.isEmpty else { return nil }
            suffix = String(tail)
            rest = rest[..<dash]
        }
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.map { part -> Int? in
            part.allSatisfy { $0.isASCII && $0.isNumber } ? Int(part) : nil
        }
        guard let major = numbers[0], let minor = numbers[1], let patch = numbers[2] else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        preRelease = suffix
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.preRelease, rhs.preRelease) {
        case (nil, _): return false
        case (_?, nil): return true
        case (let left?, let right?): return left < right
        }
    }

    /// `1.2.3` or `1.2.3-beta`, without the `v`.
    public var text: String {
        let base = "\(major).\(minor).\(patch)"
        return preRelease.map { base + "-" + $0 } ?? base
    }
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(current: String)
    case available(version: String, page: URL)
    case failed
}

/// Asks GitHub which release is the latest, once per `check()` and only then: no timer, no launch-time call, no API,
/// no token. The request is a bare HEAD to `/releases/latest`; GitHub answers with a 302 whose `Location` ends in
/// `/tag/v<version>`. That redirect is read, never followed. It carries no cookies and nothing about the person.
public struct UpdateChecker: Sendable {
    private let latestURL: URL
    private let session: URLSession
    private let current: String

    public init(latestURL: URL = URL(string: "https://github.com/berkaygkc/yabbistir/releases/latest")!,
                session: URLSession = .shared, current: String) {
        self.latestURL = latestURL
        self.session = session
        self.current = current
    }

    /// Never throws: whatever goes wrong (no network, a timeout, another status, a tag that is not a version) is
    /// `.failed`, which is never reported as "up to date".
    public func check() async -> UpdateCheckResult {
        guard let running = SemanticVersion(current) else { return .failed }
        var request = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        request.httpShouldHandleCookies = false
        do {
            let (_, response) = try await session.data(for: request, delegate: NoRedirects())
            guard let http = response as? HTTPURLResponse, http.statusCode == 302,
                  let location = http.value(forHTTPHeaderField: "Location"),
                  let page = URL(string: location, relativeTo: latestURL)?.absoluteURL,
                  page.scheme == latestURL.scheme, page.host == latestURL.host,
                  page.pathComponents.dropLast().last == "tag",
                  let latest = SemanticVersion(page.lastPathComponent), page.lastPathComponent.hasPrefix("v")
            else { return .failed }
            return latest > running ? .available(version: latest.text, page: page) : .upToDate(current: current)
        } catch {
            return .failed
        }
    }
}

/// Declines every redirect, so the 302 itself is the answer.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

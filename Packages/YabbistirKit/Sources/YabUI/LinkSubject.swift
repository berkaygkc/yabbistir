import Foundation

/// What an untitled web link is called on the job card and in the status menu: short, and different
/// for two different videos. The scheme and a leading `www.` or `m.` go, the path stays decoded
/// without a trailing slash, and a short path (one segment at most, where the address alone says
/// little: `watch`) keeps its first query item that is not a tracker.
///
/// "https://www.video.example/watch?v=dQw4w9WgXcQ&t=42s" → "video.example/watch?v=dQw4w9WgXcQ"
public enum LinkSubject {
    /// Query items that only say where a link was shared from or where to start.
    static let trackers: Set<String> = ["si", "fbclid", "gclid", "feature", "t", "ref"]
    static let trackerPrefixes = ["utm_", "igsh"]

    /// Nil unless `address` is an http(s) URL with a host.
    public static func name(of address: String) -> String? {
        guard let components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = components.host, !host.isEmpty else { return nil }
        for prefix in ["www.", "m."] where host.lowercased().hasPrefix(prefix) {
            host.removeFirst(prefix.count)
            break
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        var name = host + path
        let segments = path.split(separator: "/")
        if segments.count <= 1, let item = components.queryItems?.first(where: { !$0.name.isEmpty && !isTracker($0.name) }) {
            name += "?" + item.name + (item.value.map { "=" + $0 } ?? "")
        }
        return name
    }

    static func isTracker(_ name: String) -> Bool {
        let name = name.lowercased()
        return trackers.contains(name) || trackerPrefixes.contains { name.hasPrefix($0) }
    }
}

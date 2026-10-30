import Foundation

/// What a person approved for one extension: permissions, network domains and programs.
/// Every list is sorted and free of duplicates, so two grants compare by content.
public struct PermissionGrant: Codable, Equatable, Sendable {
    public let permissions: [String]
    public let domains: [String]
    public let tools: [String]

    public init(permissions: [String], domains: [String], tools: [String]) {
        self.permissions = Set(permissions).sorted()
        self.domains = Set(domains).sorted()
        self.tools = Set(tools).sorted()
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(permissions: try c.decode([String].self, forKey: .permissions),
                  domains: try c.decode([String].self, forKey: .domains),
                  tools: try c.decode([String].self, forKey: .tools))
    }

    /// Nothing at all: what built-ins and permission-free extensions get.
    public static let empty = PermissionGrant(permissions: [], domains: [], tools: [])

    public var isEmpty: Bool { permissions.isEmpty && domains.isEmpty && tools.isEmpty }

    /// Everything the manifest asks for.
    public static func requested(by manifest: ExtensionManifest) -> PermissionGrant {
        PermissionGrant(permissions: manifest.permissions,
                        domains: manifest.network?.domains ?? [],
                        tools: manifest.requires?.tools.map(\.name) ?? [])
    }

    /// `network` with no domains means any website.
    private var reachesAnyWebsite: Bool { permissions.contains("network") && domains.isEmpty }

    /// Whether every permission, domain and tool of `other` is also here. Any website covers every
    /// domain list; a request for any website is covered only by a grant for any website.
    public func covers(_ other: PermissionGrant) -> Bool {
        let domainsCovered = reachesAnyWebsite || (!other.reachesAnyWebsite && Set(other.domains).isSubset(of: domains))
        return Set(other.permissions).isSubset(of: permissions) && domainsCovered && Set(other.tools).isSubset(of: tools)
    }
}

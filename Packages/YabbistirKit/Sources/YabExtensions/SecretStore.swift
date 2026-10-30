import Foundation
import Security

/// Where `secret` preferences live: nowhere but here. Never UserDefaults, never
/// `ctx.preferences`, never a log.
public protocol SecretStoring: Sendable {
    func read(_ extensionID: String, _ key: String) -> String?
    /// `nil` deletes the item.
    func write(_ value: String?, _ extensionID: String, _ key: String) throws
}

public struct SecretStoreError: Error, Equatable, Sendable {
    public let status: Int32
}

/// The login keychain (the file-based one; no data-protection keychain, which needs an entitlement a
/// personal build does not have): generic passwords, service `dev.yabbistir.extension-secret`, account
/// `<extensionID>/<key>`.
public struct KeychainSecretStore: SecretStoring {
    public let service: String

    public init(service: String = "dev.yabbistir.extension-secret") {
        self.service = service
    }

    public func read(_ extensionID: String, _ key: String) -> String? {
        var query = identity(extensionID, key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String?, _ extensionID: String, _ key: String) throws {
        let query = identity(extensionID, key)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { throw SecretStoreError(status: status) }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        if status != errSecSuccess { throw SecretStoreError(status: status) }
    }

    private func identity(_ extensionID: String, _ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "\(extensionID)/\(key)"]
    }
}

/// For tests.
public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func read(_ extensionID: String, _ key: String) -> String? {
        lock.withLock { values["\(extensionID)/\(key)"] }
    }

    public func write(_ value: String?, _ extensionID: String, _ key: String) throws {
        lock.withLock { values["\(extensionID)/\(key)"] = value }
    }

    /// Every account held, for assertions.
    public var accounts: [String] { lock.withLock { Array(values.keys) } }
}

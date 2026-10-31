import CryptoKit
import Foundation

/// Where the extension store lives and which keys vouch for it.
public enum StoreConfiguration {
    /// The store's catalog. Its signature sits next to it, at the same address with ".sig" added.
    public static let catalogURL = URL(string: "https://berkaygkc.github.io/yabbistir-extensions/v1/catalog.json")!

    /// The Ed25519 keys a catalog may be signed with, as raw 32-byte keys. The release keys are added when the store
    /// goes live; until then the list is empty, so no catalog verifies and the store stays closed.
    public static let publicKeys: [Curve25519.Signing.PublicKey] = []
}

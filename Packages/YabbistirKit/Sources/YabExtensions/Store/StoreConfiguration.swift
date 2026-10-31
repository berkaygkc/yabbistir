import CryptoKit
import Foundation

/// Where the extension store lives and which keys vouch for it.
public enum StoreConfiguration {
    /// The store's catalog. Its signature sits next to it, at the same address with ".sig" added.
    public static let catalogURL = URL(string: "https://berkaygkc.github.io/yabbistir-extensions/v1/catalog.json")!

    /// The Ed25519 keys a catalog may be signed with, as raw 32-byte keys in base64. The first signs every catalog;
    /// the second is kept offline and takes over if the first ever has to be replaced.
    public static let publicKeys: [Curve25519.Signing.PublicKey] = [
        "F0se6Z0RSyz4Y5Q9Syj08AS6QLggHj0XJp56eonsAe8=",
        "gWOcRfE26gCJynx3Zhaq53wfuLZvx3AaomZyfJSSXjg=",
    ].map { try! Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: $0)!) }
}

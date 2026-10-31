import CryptoKit
import Foundation

/// Decides whether the bytes that came from the network can be trusted.
public enum CatalogVerifier {
    /// True when `signatureBase64` holds the base64 of a 64-byte Ed25519 signature over exactly `catalog`'s bytes,
    /// made by any of `keys`. Surrounding whitespace (the file's trailing newline) is ignored.
    public static func verify(catalog: Data, signatureBase64: Data, keys: [Curve25519.Signing.PublicKey]) -> Bool {
        guard let text = String(data: signatureBase64, encoding: .utf8),
              let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              signature.count == 64 else { return false }
        return keys.contains { $0.isValidSignature(signature, for: catalog) }
    }

    /// The only way to read a catalog that came from outside: the signature is checked first, and the bytes are
    /// parsed only when it holds.
    public static func verifyAndDecode(catalog: Data, signatureBase64: Data, keys: [Curve25519.Signing.PublicKey]) throws(StoreCatalogError) -> StoreCatalog {
        guard verify(catalog: catalog, signatureBase64: signatureBase64, keys: keys) else { throw .badSignature }
        return try StoreCatalog.decode(catalog)
    }

    /// True when the package's SHA-256 is `hex` (case does not matter).
    public static func packageMatches(_ data: Data, sha256 hex: String) -> Bool {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == hex.lowercased()
    }
}

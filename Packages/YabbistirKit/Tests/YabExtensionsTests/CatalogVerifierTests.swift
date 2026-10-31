import CryptoKit
import Foundation
import Testing
import YabPlatform
@testable import YabExtensions

struct CatalogVerifierTests {
    let catalog = Data(#"{"formatVersion":1,"generatedAt":"2026-10-31T09:30:00Z","extensions":[]}"#.utf8)

    func sign(_ data: Data, with key: Curve25519.Signing.PrivateKey) throws -> Data {
        Data(try key.signature(for: data).base64EncodedString().utf8)
    }

    @Test func aSignedCatalogVerifies() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try sign(catalog, with: key)
        #expect(CatalogVerifier.verify(catalog: catalog, signatureBase64: signature, keys: [key.publicKey]))
        // The file on disk ends with a newline.
        #expect(CatalogVerifier.verify(catalog: catalog, signatureBase64: signature + Data("\n".utf8), keys: [key.publicKey]))
    }

    @Test func theSecondKeyAlsoVerifies() throws {
        let first = Curve25519.Signing.PrivateKey(), second = Curve25519.Signing.PrivateKey()
        let signature = try sign(catalog, with: second)
        #expect(CatalogVerifier.verify(catalog: catalog, signatureBase64: signature, keys: [first.publicKey, second.publicKey]))
    }

    @Test func aTamperedByteFailsVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try sign(catalog, with: key)
        var tampered = catalog
        tampered[tampered.startIndex + 20] ^= 1
        #expect(!CatalogVerifier.verify(catalog: tampered, signatureBase64: signature, keys: [key.publicKey]))
    }

    @Test func anUnknownKeyFails() throws {
        let signature = try sign(catalog, with: Curve25519.Signing.PrivateKey())
        #expect(!CatalogVerifier.verify(catalog: catalog, signatureBase64: signature, keys: [Curve25519.Signing.PrivateKey().publicKey]))
        #expect(!CatalogVerifier.verify(catalog: catalog, signatureBase64: signature, keys: []))
    }

    @Test func aTruncatedOrNonBase64SignatureFails() throws {
        let key = Curve25519.Signing.PrivateKey()
        let good = try sign(catalog, with: key)
        let truncated = good.prefix(good.count - 8)
        let notBase64 = Data("this is not base64 !!!".utf8)
        let wrongLength = Data(Data(repeating: 7, count: 63).base64EncodedString().utf8)
        for bad in [Data(truncated), notBase64, wrongLength, Data()] {
            #expect(!CatalogVerifier.verify(catalog: catalog, signatureBase64: bad, keys: [key.publicKey]))
        }
    }

    @Test func aPackageWithAnotherHashIsRejected() {
        let package = Data("package bytes".utf8)
        let hex = SHA256.hash(data: package).map { String(format: "%02x", $0) }.joined()
        #expect(CatalogVerifier.packageMatches(package, sha256: hex))
        #expect(CatalogVerifier.packageMatches(package, sha256: hex.uppercased()))
        #expect(!CatalogVerifier.packageMatches(Data("other".utf8), sha256: hex))
        #expect(!CatalogVerifier.packageMatches(package, sha256: String(hex.dropLast())))
        #expect(!CatalogVerifier.packageMatches(package, sha256: ""))
    }
}

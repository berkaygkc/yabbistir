import CryptoKit
import Foundation
import Testing
import YabPlatform
import YabTestSupport
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

extension CatalogVerifierTests {
    @Test func verifyAndDecodeReadsOnlyAVerifiedCatalog() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try sign(catalog, with: key)
        #expect(try CatalogVerifier.verifyAndDecode(catalog: catalog, signatureBase64: signature, keys: [key.publicKey]).extensions.isEmpty)
        // Unsigned or wrongly signed bytes are refused before anyone parses them, even when they are well formed.
        #expect(throws: StoreCatalogError.badSignature) {
            try CatalogVerifier.verifyAndDecode(catalog: catalog, signatureBase64: signature, keys: [Curve25519.Signing.PrivateKey().publicKey])
        }
        let junk = Data("nope".utf8)
        #expect(throws: StoreCatalogError.badSignature) {
            try CatalogVerifier.verifyAndDecode(catalog: junk, signatureBase64: signature, keys: [key.publicKey])
        }
        // Signed but malformed.
        #expect(throws: StoreCatalogError.malformed) {
            try CatalogVerifier.verifyAndDecode(catalog: junk, signatureBase64: try sign(junk, with: key), keys: [key.publicKey])
        }
    }
}

extension CatalogVerifierTests {
    /// With no key no catalog verifies, so a release shipped that way would have a Store tab that never opens:
    /// scripts/release.sh stops first, through scripts/check-store-keys.sh.
    @Test func aReleaseRefusesAnEmptyKeyList() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let release = try String(contentsOf: root.appendingPathComponent("scripts/release.sh"), encoding: .utf8)
        #expect(release.contains("scripts/check-store-keys.sh"))
        /// The gate's exit status for a StoreConfiguration.swift that declares `keys`.
        func gate(_ keys: String) throws -> Int32 {
            let file = TestScratch.url("StoreConfiguration", pathExtension: "swift")
            defer { try? FileManager.default.removeItem(at: file) }
            try "import CryptoKit\n\npublic enum StoreConfiguration {\n    /// The keys.\n    \(keys)\n}\n".write(to: file, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [root.appendingPathComponent("scripts/check-store-keys.sh").path, file.path]
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(try gate("public static let publicKeys: [Curve25519.Signing.PublicKey] = []") != 0)
        #expect(try gate("public static let publicKeys: [Curve25519.Signing.PublicKey] = [ ] // none yet") != 0)
        #expect(try gate("public static let publicKeys: [Curve25519.Signing.PublicKey] = [\n    ]") != 0)
        #expect(try gate("public static let otherKeys: [Curve25519.Signing.PublicKey] = [key(\"a\")]") != 0)
        #expect(try gate("public static let publicKeys: [Curve25519.Signing.PublicKey] = [\n        key(\"q0aJ\"),\n        key(\"Zm9v\"),\n    ]") == 0)
        #expect(try gate("public static let publicKeys: [Curve25519.Signing.PublicKey] = [key(\"q0aJ\")]") == 0)
    }

    /// Fixtures/store-live holds the first catalog the store published, byte for byte, with its signature.
    static let live = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/store-live")

    @Test func thePublishedCatalogVerifiesWithTheEmbeddedKeys() throws {
        let catalog = try Data(contentsOf: Self.live.appendingPathComponent("catalog.json"))
        let signature = try Data(contentsOf: Self.live.appendingPathComponent("catalog.json.sig"))
        #expect(StoreConfiguration.publicKeys.count == 2)
        let decoded = try CatalogVerifier.verifyAndDecode(catalog: catalog, signatureBase64: signature, keys: StoreConfiguration.publicKeys)
        #expect(decoded.extensions.map(\.id).sorted()
            == ["dev.yabbistir.jwt", "dev.yabbistir.link-clean", "dev.yabbistir.translate", "dev.yabbistir.video-download"])
        var flipped = catalog
        flipped[flipped.count / 2] ^= 0x01
        #expect(!CatalogVerifier.verify(catalog: flipped, signatureBase64: signature, keys: StoreConfiguration.publicKeys))
    }
}

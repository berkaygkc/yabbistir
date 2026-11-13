import Foundation
import Testing
import YabCore
import YabTestSupport
@testable import YabImport
import YabImportTestSupport

let expected = [[PasteboardRepresentation(type: "public.utf8-plain-text", data: Data("hello".utf8)),
                 PasteboardRepresentation(type: "public.html", data: Data("<b>hello</b>".utf8))]]

@Suite struct PasteBlobDecoderTests {
    @Test func decodesCompressedInlineBlob() throws {
        let blob = Data([0x01]) + (try lzfse(try pastePlist(sampleItems)))
        #expect(try PasteBlobDecoder.decode(blob, externalDataDirectory: nil) == expected)
    }

    @Test func decodesUncompressedInlineBlob() throws {
        let blob = Data([0x01]) + (try pastePlist(sampleItems))
        #expect(try PasteBlobDecoder.decode(blob, externalDataDirectory: nil) == expected)
    }

    @Test func externalReferenceReadsFile() throws {
        let dir = TestScratch.url("paste-ext")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = UUID().uuidString
        try lzfse(try pastePlist(sampleItems)).write(to: dir.appendingPathComponent(name))
        let blob = Data([0x02]) + Data(name.utf8) + Data([0x00])
        #expect(try PasteBlobDecoder.decode(blob, externalDataDirectory: dir) == expected)
    }

    @Test func missingExternalFileThrows() {
        let name = UUID().uuidString
        let blob = Data([0x02]) + Data(name.utf8) + Data([0x00])
        #expect(throws: PasteImportError.missingExternalData(name)) {
            try PasteBlobDecoder.decode(blob, externalDataDirectory: FileManager.default.temporaryDirectory)
        }
    }

    @Test func garbageThrowsUnknownFormat() {
        #expect(throws: PasteImportError.unknownFormat) {
            try PasteBlobDecoder.decode(Data([0x01, 0xDE, 0xAD, 0xBE, 0xEF]), externalDataDirectory: nil)
        }
    }

    /// Opt-in count over a real Paste database copy. Prints counts only, never content.
    /// `TEST_RUNNER_YAB_PASTE_DB=/path/copy.sqlite TEST_RUNNER_YAB_PASTE_EXT=/path/_EXTERNAL_DATA make test ONLY=YabImportTests`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_PASTE_DB"] != nil))
    func countRealLibrary() throws {
        let env = ProcessInfo.processInfo.environment
        let counts = try PasteBlobDecoder.countDecodable(databasePath: env["YAB_PASTE_DB"]!,
                                                         externalDataDirectory: env["YAB_PASTE_EXT"].map(URL.init(fileURLWithPath:)))
        print("PASTE_COUNTS decoded=\(counts.decoded) failed=\(counts.failed)")
        #expect(counts.decoded > 0)
    }
}

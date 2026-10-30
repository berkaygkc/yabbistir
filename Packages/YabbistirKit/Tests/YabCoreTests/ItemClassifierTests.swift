import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import YabCore

private func rep(_ type: String, _ string: String) -> PasteboardRepresentation {
    PasteboardRepresentation(type: type, data: Data(string.utf8))
}

private func text(_ s: String) -> [[PasteboardRepresentation]] {
    [[rep(TypeIdentifiers.plainText, s)]]
}

private func classify(_ s: String) -> Classification? {
    ItemClassifier.classify(text(s))
}

func pngData(width: Int, height: Int) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

@Suite struct ItemClassifierTests {
    @Test func sqlIsCode() {
        #expect(classify("UPDATE users SET status = 'refunded' WHERE id = 4821;")?.kind == .code)
    }

    @Test func shellCommandIsCode() {
        #expect(classify("git rebase -i HEAD~3")?.kind == .code)
    }

    @Test func jsonIsCode() {
        #expect(classify("{\"orderId\": 99812}")?.kind == .code)
    }

    @Test func longTokenIsCode() {
        #expect(classify("eyJ1c2VySWQiOjQ4MjEsInJvbGUiOiJkZXN0ZWsiLCJleHAiOjE3OTMxNzQ0MDB9")?.kind == .code)
    }

    @Test func proseIsText() {
        #expect(classify("Perşembe 14:00 — iade akışı demosu")?.kind == .text)
    }

    @Test func emailIsText() {
        #expect(classify("ops@ornek.dev")?.kind == .text)
    }

    @Test func hexIsColorUppercased() {
        #expect(classify("#6E56CF") == Classification(kind: .color, previewText: "#6E56CF", searchText: SearchNormalizer.normalize("#6E56CF")))
        #expect(classify("#6e56cf")?.previewText == "#6E56CF")
    }

    @Test func urlWithTitleIsLink() {
        let items = [[
            rep(TypeIdentifiers.plainText, "https://tracker.example/yabbistir/issue/YAB-142"),
            rep(TypeIdentifiers.urlName, "YAB-142 · Sıra"),
        ]]
        let result = ItemClassifier.classify(items)
        #expect(result?.kind == .link)
        #expect(result?.previewText == "YAB-142 · Sıra")
    }

    @Test func fileURLIsFile() {
        let items = [[rep(TypeIdentifiers.fileURL, "file:///Users/x/Downloads/fatura-ekim-2026.pdf")]]
        let result = ItemClassifier.classify(items)
        #expect(result?.kind == .file)
        #expect(result?.previewText == "fatura-ekim-2026.pdf")
    }

    @Test func pngIsImageWithSize() {
        let items = [[PasteboardRepresentation(type: TypeIdentifiers.png, data: pngData(width: 4, height: 2))]]
        let result = ItemClassifier.classify(items)
        #expect(result?.kind == .image)
        #expect(result?.previewText == "4×2 PNG")
    }

    @Test func textWithRenderedPictureIsText() {
        // Office and iWork put a picture of the selection next to its text.
        let items = [[rep(TypeIdentifiers.plainText, "Q3 gelir\t1.200"),
                      PasteboardRepresentation(type: TypeIdentifiers.png, data: pngData(width: 4, height: 2))]]
        #expect(ItemClassifier.classify(items)?.kind == .text)
    }

    @Test func imageWithItsAddressIsImage() {
        // A browser's "Copy Image" can carry the image URL as text.
        let items = [[PasteboardRepresentation(type: TypeIdentifiers.png, data: pngData(width: 4, height: 2)),
                      rep(TypeIdentifiers.plainText, "https://example.com/kedi.png")]]
        #expect(ItemClassifier.classify(items)?.kind == .image)
    }

    @Test func bareHexIsColor() {
        #expect(classify("6e56cf")?.kind == .color)
        #expect(classify("6e56cf")?.previewText == "6E56CF")
    }

    @Test func bareHexNeedsDigitsAndLetters() {
        // Six digits are a number, six a–f letters a word ("facade"), not colors.
        #expect(classify("123456")?.kind != .color)
        #expect(classify("facade")?.kind == .text)
    }

    @Test func whitespaceOnlyIsSkipped() {
        #expect(classify("   \n ") == nil)
    }

    @Test func privateTypesOnlyAreSkipped() {
        #expect(ItemClassifier.classify([[rep("com.example.private", "x")]]) == nil)
    }

    @Test func hugeTextIsTruncated() {
        let huge = String(repeating: "a ", count: 5_000_000)
        let result = classify(huge)
        #expect(result != nil)
        #expect(result!.previewText.count <= 500)
        #expect(result!.searchText.count <= 20_000)
    }
}

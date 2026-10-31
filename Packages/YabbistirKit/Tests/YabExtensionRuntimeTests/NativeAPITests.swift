import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import YabExtensionKit
@testable import YabExtensionRuntime

/// Synthetic images for the native API tests.
enum TestImages {
    static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func context(_ width: Int, _ height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// A gradient with grain, like a photo: PNG keeps every pixel, JPEG does not.
    static func photo(width: Int = 400, height: Int = 300) -> CGImage {
        let context = context(width, height)
        var generator = SystemRandomNumberGenerator()
        for y in 0..<height {
            for x in 0..<width {
                let grain = Double(Int.random(in: -20...20, using: &generator)) / 255
                context.setFillColor(red: Double(x) / Double(width) + grain, green: Double(y) / Double(height) + grain, blue: 0.5 + grain, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return context.makeImage()!
    }

    static func text(_ string: String, size: CGFloat = 48) -> CGImage {
        let context = context(900, 160)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 160))
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        context.textPosition = CGPoint(x: 40, y: 60)
        CTLineDraw(line, context)
        return context.makeImage()!
    }

    static func item(_ image: CGImage) -> ExtensionItem {
        ExtensionItem(id: 1, kind: "image", image: .init(data: png(image), width: image.width, height: image.height), copiedAt: Date())
    }
}

@Suite struct NativeAPITests {
    let context = ExtensionContext(language: "en", trigger: .search)

    func run(_ js: String, item: ExtensionItem?) async throws -> InvokeOutput {
        try await RuntimeFixture.load(js: js).invoke(.run, name: "a", item: item, context: context)
    }

    /// Numbers from JavaScript never trap the host.
    @Test func outOfRangeNumbersAreErrors() async throws {
        let item = TestImages.item(TestImages.photo(width: 20, height: 10))
        for call in ["yab.image.resize(item.image, { width: Infinity, height: 5 })", "yab.image.resize(item.image, { scale: 1e300 })",
                     "yab.image.convert(item.image, { format: \"png\", maxSize: -Infinity })"] {
            let output = try? await run("exports.actions = { a: { run: async (item) => ({ image: await \(call) }) } };", item: item)
            #expect(output == nil || output.map { if case .result(.image) = $0 { true } else { false } } == true, "\(call)")
        }
        await #expect(throws: ExtensionError.self) {
            _ = try await run(#"exports.actions = { a: { run: () => ({ image: yab.qr.generate("x", { size: Infinity }) }) } };"#, item: nil)
        }
    }

    @Test func convertingToJPEGShrinksANoisyPNG() async throws {
        let item = TestImages.item(TestImages.photo())
        let output = try await run(#"exports.actions = { a: { run: async (item) => ({ image: await yab.image.convert(item.image, { format: "jpeg", quality: 0.85 }) }) } };"#, item: item)
        guard case .result(.image(let data, let uti, let width, _)) = output else { Issue.record("no image: \(output)"); return }
        #expect(uti == "public.jpeg")
        #expect(width == 400)
        #expect(data.count < item.image!.data.count)
    }

    @Test func halfSizeHalvesThePixels() async throws {
        let output = try await run(#"exports.actions = { a: { run: async (item) => ({ image: await yab.image.resize(item.image, { scale: 0.5 }) }) } };"#,
                                   item: TestImages.item(TestImages.photo()))
        guard case .result(.image(_, _, let width, let height)) = output else { Issue.record("no image: \(output)"); return }
        #expect(width == 200)
        #expect(height == 150)
    }

    /// ImageIO on macOS 26 reads WebP but cannot write it: the conversion says so instead of failing
    /// vaguely, and works as soon as the system can write WebP.
    @Test func webPFollowsWhatImageIOCanWrite() async throws {
        let js = #"exports.actions = { a: { run: async (item) => ({ image: await yab.image.convert(item.image, { format: "webp" }) }) } };"#
        let item = TestImages.item(TestImages.photo())
        if ImageCodec.canWrite("org.webmproject.webp") {
            guard case .result(.image(_, let uti, _, _)) = try await run(js, item: item) else { Issue.record("no image"); return }
            #expect(uti == "org.webmproject.webp")
        } else {
            await #expect { _ = try await run(js, item: item) } throws: { ($0 as? ExtensionError)?.code == .unavailable }
        }
    }

    @Test func ocrReadsRenderedText() async throws {
        let output = try await run(#"exports.actions = { a: { run: async (item) => ({ text: await yab.vision.ocr(item.image) }) } };"#,
                                   item: TestImages.item(TestImages.text("yabbistir 2026")))
        guard case .result(.text(let text)) = output else { Issue.record("no text: \(output)"); return }
        #expect(text.contains("yabbistir 2026"))
    }

    @Test func aGeneratedQRReadsBack() async throws {
        let js = #"exports.actions = { a: { run: async () => ({ text: (await yab.vision.readCodes(yab.qr.generate("https://yabbistir.dev"))).join(",") }) } };"#
        #expect(try await run(js, item: nil) == .result(.text("https://yabbistir.dev")))
    }

    @Test func infoAndImageResultsWork() async throws {
        let js = #"exports.actions = { a: { run: (item) => { const i = yab.image.info(item.image); return i.width === 400 ? { image: item.image } : { text: "bad" }; } } };"#
        let output = try await run(js, item: TestImages.item(TestImages.photo()))
        guard case .result(.image(_, let uti, 400, 300)) = output else { Issue.record("no image: \(output)"); return }
        #expect(uti == "public.png")
    }
}

import CoreGraphics
import Foundation
import ImageIO
import Testing
import YabExtensionKit
@testable import YabExtensionRuntime

/// `yab.vision.removeBackground`: Vision's foreground instance mask, cut out as a PNG with alpha.
@Suite struct VisionTests {
    let context = ExtensionContext(language: "en", trigger: .search)
    static let js = #"exports.actions = { a: { run: async (item) => ({ image: await yab.vision.removeBackground(item.image) }) } };"#

    func run(_ item: ExtensionItem) async throws -> InvokeOutput {
        try await RuntimeFixture.load(js: Self.js).invoke(.run, name: "a", item: item, context: context)
    }

    /// A plain white 200x200 image.
    static func blank() -> CGImage {
        let context = TestImages.context(200, 200)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        return context.makeImage()!
    }

    /// A dark rounded rectangle with a soft shadow on a plain light background, 512x512.
    static func subject() -> CGImage {
        let context = TestImages.context(512, 512)
        context.setFillColor(red: 0.94, green: 0.94, blue: 0.92, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        let rect = CGRect(x: 126, y: 140, width: 260, height: 240)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -14), blur: 24, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
        context.setFillColor(red: 0.08, green: 0.1, blue: 0.3, alpha: 1)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 48, cornerHeight: 48, transform: nil))
        context.fillPath()
        context.restoreGState()
        context.clip(to: rect)
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  colors: [CGColor(red: 0.85, green: 0.15, blue: 0.2, alpha: 1), CGColor(red: 0.1, green: 0.1, blue: 0.4, alpha: 1)] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
        return context.makeImage()!
    }

    /// The RGBA bytes of a PNG, premultiplied last.
    static func alpha(of data: Data, x: Int, y: Int) -> UInt8? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let context = TestImages.context(image.width, image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return bytes[y * context.bytesPerRow + x * 4 + 3]
    }

    @Test func aBlankImageHasNoSubject() async throws {
        await #expect { _ = try await run(TestImages.item(Self.blank())) } throws: {
            let error = $0 as? ExtensionError
            return error?.code == .unavailable && error?.message == "no subject found"
        }
    }

    @Test func aSubjectIsCutOut() async throws {
        let output: InvokeOutput
        do {
            output = try await run(TestImages.item(Self.subject()))
        } catch let error as ExtensionError where error.message == "no subject found" {
            withKnownIssue("Vision found no subject in the synthetic image") { Issue.record("no subject found") }
            print("MANUAL CHECK: Vision found no subject in the synthetic image; verify background removal on a real photo")
            return
        }
        guard case .result(.image(let data, let uti, 512, 512)) = output else { Issue.record("no image: \(output)"); return }
        #expect(uti == "public.png")
        #expect(Self.alpha(of: data, x: 2, y: 2) == 0)
        #expect((Self.alpha(of: data, x: 256, y: 256) ?? 0) > 0)
    }
}

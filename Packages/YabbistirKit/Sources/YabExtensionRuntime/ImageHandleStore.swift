import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import YabExtensionKit

/// Images an extension works with while its calls run. JavaScript only ever holds a handle,
/// `{ __image: "<id>", width, height }`; pixels never cross into the script.
final class ImageHandleStore: @unchecked Sendable {
    struct Entry {
        let image: CGImage
        /// The bytes as they are (a decoded item, a conversion's output); nil means "encode as PNG".
        let data: Data?
        let uti: String
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var activeCalls = 0

    func beginCall() {
        lock.withLock { activeCalls += 1 }
    }

    /// Handles live as long as some call is running; the last one to finish clears them.
    func endCall() {
        lock.withLock {
            activeCalls = max(0, activeCalls - 1)
            if activeCalls == 0 { entries = [:] }
        }
    }

    func add(_ image: CGImage, data: Data? = nil, uti: String = UTType.png.identifier) -> JSONValue {
        let id = UUID().uuidString
        lock.withLock { entries[id] = Entry(image: image, data: data, uti: uti) }
        return .object(["__image": .string(id), "width": .number(Double(image.width)), "height": .number(Double(image.height))])
    }

    func entry(_ handle: JSONValue?) -> Entry? {
        guard let id = handle?["__image"]?.stringValue else { return nil }
        return lock.withLock { entries[id] }
    }

    /// The handle's bytes for a result: kept bytes, or a PNG.
    func encoded(_ handle: JSONValue?) -> (data: Data, uti: String, width: Int, height: Int)? {
        guard let entry = entry(handle) else { return nil }
        if let data = entry.data { return (data, entry.uti, entry.image.width, entry.image.height) }
        guard let png = ImageCodec.encode(entry.image, as: UTType.png.identifier) else { return nil }
        return (png, UTType.png.identifier, entry.image.width, entry.image.height)
    }
}

/// ImageIO in and out.
enum ImageCodec {
    static let formats: [String: String] = [
        "jpeg": UTType.jpeg.identifier, "jpg": UTType.jpeg.identifier, "png": UTType.png.identifier,
        "webp": "org.webmproject.webp", "heic": UTType.heic.identifier,
    ]

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func canWrite(_ uti: String) -> Bool {
        (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(uti)
    }

    static func encode(_ image: CGImage, as uti: String, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, uti as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = max(0, min(1, quality)) }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

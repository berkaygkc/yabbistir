import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import JavaScriptCore
import Vision
import YabExtensionKit

/// `yab.image`, `yab.vision` and `yab.qr`: image work done natively, off the
/// extension's queue, answered through promises that resolve back on it (`ExtensionRuntime.promise`).
enum NativeAPI {
    static func install(in runtime: ExtensionRuntime) {
        let context = runtime.context
        let yab = context.objectForKeyedSubscript("yab")!

        let image = JSValue(newObjectIn: context)!
        let info: @convention(block) (JSValue?) -> JSValue? = { [weak runtime] handle in
            guard let runtime, let entry = runtime.images.entry(runtime.json(handle)) else { return notAHandle() }
            return runtime.jsValue(.object(["width": .number(Double(entry.image.width)), "height": .number(Double(entry.image.height)),
                                            "uti": .string(entry.uti)]))
        }
        let convert: @convention(block) (JSValue?, JSValue?) -> JSValue? = { [weak runtime] handle, options in
            guard let runtime, let entry = runtime.images.entry(runtime.json(handle)) else { return notAHandle() }
            let options = runtime.json(options)
            return runtime.promise {
                let format = options["format"]?.stringValue?.lowercased() ?? "png"
                guard let uti = ImageCodec.formats[format] else {
                    return .failure(ExtensionError(.badResult, "unknown image format \"\(format)\"; use jpeg, png, webp or heic"))
                }
                guard ImageCodec.canWrite(uti) else { return .failure(ExtensionError(.unavailable, "this Mac cannot write \(format) images")) }
                var source = entry.image
                if let maxSize = pixels(options["maxSize"]?.numberValue), max(source.width, source.height) > maxSize {
                    let scale = Double(maxSize) / Double(max(source.width, source.height))
                    source = ImageCodec.resized(source, width: max(1, Int((Double(source.width) * scale).rounded())),
                                                height: max(1, Int((Double(source.height) * scale).rounded()))) ?? source
                }
                guard let data = ImageCodec.encode(source, as: uti, quality: options["quality"]?.numberValue) else {
                    return .failure(ExtensionError(.unavailable, "the image could not be written as \(format)"))
                }
                return .success(runtime.images.add(source, data: data, uti: uti))
            }
        }
        let resize: @convention(block) (JSValue?, JSValue?) -> JSValue? = { [weak runtime] handle, options in
            guard let runtime, let entry = runtime.images.entry(runtime.json(handle)) else { return notAHandle() }
            let options = runtime.json(options)
            return runtime.promise {
                let scale = options["scale"]?.numberValue ?? 1
                let width = options["width"].map { pixels($0.numberValue) } ?? pixels(Double(entry.image.width) * scale)
                let height = options["height"].map { pixels($0.numberValue) } ?? pixels(Double(entry.image.height) * scale)
                guard let width, let height, let resized = ImageCodec.resized(entry.image, width: width, height: height) else {
                    return .failure(ExtensionError(.badResult, "resize takes a width, a height or a scale that gives 1 to \(maxPixels) pixels"))
                }
                return .success(runtime.images.add(resized))
            }
        }
        let fromBytes: @convention(block) (JSValue?, String?) -> JSValue? = { [weak runtime] bytes, uti in
            guard let runtime, let bytes, let data = typedArrayData(bytes, in: runtime.context), let decoded = ImageCodec.decode(data) else {
                return throwError("yab.image.fromBytes takes a Uint8Array of an image file", code: .badResult)
            }
            return runtime.jsValue(runtime.images.add(decoded, data: data, uti: uti ?? "public.png"))
        }
        for (name, function) in [("info", unsafeBitCast(info, to: AnyObject.self)), ("convert", unsafeBitCast(convert, to: AnyObject.self)),
                                 ("resize", unsafeBitCast(resize, to: AnyObject.self)), ("fromBytes", unsafeBitCast(fromBytes, to: AnyObject.self))] {
            image.setValue(function, forProperty: name)
        }
        yab.setValue(image, forProperty: "image")

        let vision = JSValue(newObjectIn: context)!
        let ocr: @convention(block) (JSValue?) -> JSValue? = { [weak runtime] handle in
            guard let runtime, let entry = runtime.images.entry(runtime.json(handle)) else { return notAHandle() }
            return runtime.promise {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["tr-TR", "en-US"]
                request.usesLanguageCorrection = true
                do {
                    try VNImageRequestHandler(cgImage: entry.image).perform([request])
                } catch {
                    return .failure(ExtensionError(.unavailable, "text recognition failed: \(error.localizedDescription)"))
                }
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                return .success(.string(lines.joined(separator: "\n")))
            }
        }
        let readCodes: @convention(block) (JSValue?) -> JSValue? = { [weak runtime] handle in
            guard let runtime, let entry = runtime.images.entry(runtime.json(handle)) else { return notAHandle() }
            return runtime.promise {
                let request = VNDetectBarcodesRequest()
                do {
                    try VNImageRequestHandler(cgImage: entry.image).perform([request])
                } catch {
                    return .failure(ExtensionError(.unavailable, "code reading failed: \(error.localizedDescription)"))
                }
                return .success(.array((request.results ?? []).compactMap(\.payloadStringValue).map(JSONValue.string)))
            }
        }
        let removeBackground: @convention(block) (JSValue?) -> JSValue? = { [weak runtime] handle in
            guard let runtime, let entry = runtime.images.entry(runtime.json(handle)) else { return notAHandle() }
            return runtime.promise {
                guard entry.image.width <= maxPixels, entry.image.height <= maxPixels else {
                    return .failure(ExtensionError(.badResult, "the image is larger than \(maxPixels) pixels"))
                }
                switch cutOutSubject(entry.image) {
                case .success(let cut): return .success(runtime.images.add(cut))
                case .failure(let error): return .failure(error)
                }
            }
        }
        vision.setValue(unsafeBitCast(removeBackground, to: AnyObject.self), forProperty: "removeBackground")
        vision.setValue(unsafeBitCast(ocr, to: AnyObject.self), forProperty: "ocr")
        vision.setValue(unsafeBitCast(readCodes, to: AnyObject.self), forProperty: "readCodes")
        yab.setValue(vision, forProperty: "vision")

        let qr = JSValue(newObjectIn: context)!
        let generate: @convention(block) (String, JSValue?) -> JSValue? = { [weak runtime] text, options in
            guard let runtime else { return nil }
            guard let size = pixels(runtime.json(options)["size"]?.numberValue ?? 512) else {
                return throwError("a QR code's size is 1 to \(maxPixels) pixels", code: .badResult)
            }
            guard let code = qrCode(text, size: size) else { return throwError("the text is too long for a QR code", code: .badResult) }
            return runtime.jsValue(runtime.images.add(code))
        }
        qr.setValue(unsafeBitCast(generate, to: AnyObject.self), forProperty: "generate")
        yab.setValue(qr, forProperty: "qr")
    }

    // MARK: Helpers

    /// The image with everything but its foreground instances made transparent. Vision's own error text
    /// never leaves: it can describe the image's internals, and the user can do nothing with it.
    static func cutOutSubject(_ image: CGImage) -> Result<CGImage, ExtensionError> {
        let failed = ExtensionError(.unavailable, "the background couldn\u{2019}t be removed")
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
                return .failure(ExtensionError(.unavailable, "no subject found"))
            }
            let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
            let ciImage = CIImage(cvPixelBuffer: buffer)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let cut = CIContext().createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: space) else { return .failure(failed) }
            return .success(cut)
        } catch {
            return .failure(failed)
        }
    }

    /// The largest side an extension may ask for.
    static let maxPixels = 16_384

    /// A pixel count from JavaScript: finite, whole after rounding, 1…maxPixels; nil otherwise
    /// (Infinity, NaN or 1e300 never reach an Int conversion).
    static func pixels(_ value: Double?) -> Int? {
        guard let value, value.isFinite else { return nil }
        let rounded = value.rounded()
        guard rounded >= 1, rounded <= Double(maxPixels) else { return nil }
        return Int(rounded)
    }

    /// A JavaScript Error that carries the ExtensionError code back to Swift.
    static func errorValue(_ error: ExtensionError, in context: JSContext) -> JSValue {
        let value = JSValue(newErrorFromMessage: error.message, in: context)!
        value.setValue(error.code.rawValue, forProperty: "code")
        return value
    }

    static func throwError(_ message: String, code: ExtensionError.Code) -> JSValue? {
        let context = JSContext.current()!
        context.exception = errorValue(ExtensionError(code, message), in: context)
        return JSValue(undefinedIn: context)
    }

    private static func notAHandle() -> JSValue? {
        throwError("expected an image handle (item.image or the result of a yab.image call)", code: .badResult)
    }

    static func typedArrayData(_ value: JSValue, in context: JSContext) -> Data? {
        let globalContext = context.jsGlobalContextRef
        var exception: JSValueRef?
        guard let object = JSValueToObject(globalContext, value.jsValueRef, &exception),
              let pointer = JSObjectGetTypedArrayBytesPtr(globalContext, object, &exception) else { return nil }
        let length = JSObjectGetTypedArrayByteLength(globalContext, object, &exception)
        return Data(bytes: pointer, count: length)
    }

    /// A QR code on white with a quiet zone, scaled with hard edges.
    private static func qrCode(_ text: String, size: Int) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let side = max(64, size)
        let quietZone = Double(side) * 0.08
        let scale = (Double(side) - 2 * quietZone) / output.extent.width
        let scaled = output.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let code = CIContext().createCGImage(scaled, from: scaled.extent),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .none
        context.draw(code, in: CGRect(x: quietZone, y: quietZone, width: Double(code.width), height: Double(code.height)))
        return context.makeImage()
    }
}

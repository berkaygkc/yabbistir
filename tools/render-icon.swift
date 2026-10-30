// Renders the app icon the way Finder shows it (system squircle mask, edge highlight, shadow) to a transparent PNG.
// Usage: swift tools/render-icon.swift <path/to/yabbistir.app> <out.png> [size=1024]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: render-icon.swift <app> <out.png> [size]"); exit(64) }
let side = Int(args.count > 3 ? args[3] : "1024") ?? 1024
let app = URL(fileURLWithPath: args[1])
guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) else {
    print("render-icon: no app at \(app.path)"); exit(66)
}
let icon = NSWorkspace.shared.icon(forFile: app.path)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
// The default (light) icon, whatever the Mac's appearance.
NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
}
let srgb = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
guard let png = srgb.representation(using: .png, properties: [:]) else { print("render-icon: no PNG"); exit(70) }
do { try png.write(to: URL(fileURLWithPath: args[2])) } catch { print("render-icon: \(error.localizedDescription)"); exit(73) }
print("\(args[2]): \(side)×\(side)")

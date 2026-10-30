import Foundation

/// A #RRGGBB color with the RGB and HSL readouts the preview shows.
public struct ColorValue: Equatable, Sendable {
    public let red: Int
    public let green: Int
    public let blue: Int

    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        red = value >> 16 & 0xFF
        green = value >> 8 & 0xFF
        blue = value & 0xFF
    }

    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    /// Hue in degrees, saturation and lightness in percent, rounded.
    public var hsl: (h: Int, s: Int, l: Int) {
        let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        let lightness = (high + low) / 2
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        var hue = 0.0
        if delta != 0 {
            switch high {
            case r: hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            case g: hue = (b - r) / delta + 2
            default: hue = (r - g) / delta + 4
            }
            hue = (hue * 60 + 360).truncatingRemainder(dividingBy: 360)
        }
        return (Int(hue.rounded()), Int((saturation * 100).rounded()), Int((lightness * 100).rounded()))
    }

    public var rgbText: String { "\(red), \(green), \(blue)" }
    public var hslText: String { "\(hsl.h)°, \(hsl.s)%, \(hsl.l)%" }
}

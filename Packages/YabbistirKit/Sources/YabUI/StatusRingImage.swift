import AppKit

/// The menu bar icon while jobs run: the app's glyph steps back
/// to 0.62 inside a thin ring. The arc is the running jobs' combined progress from 12 o'clock,
/// clockwise, over a 26% track; when no job can say how far it is, a 24% segment sits at
/// `spinPhase`. A template image, so it takes the menu bar's color.
public enum StatusRingImage {
    /// The status item's glyph (`StatusItemController` shows it at rest).
    public static let glyphName = "list.clipboard"

    static let size = NSSize(width: 22, height: 22)
    static let radius: CGFloat = 8.4
    static let lineWidth: CGFloat = 1.6
    static let trackOpacity: CGFloat = 0.26
    static let glyphScale: CGFloat = 0.62
    static let spinLength = 0.24

    /// Looked up once: the ring is drawn up to 30 times a second while it moves.
    @MainActor private static let glyph = NSImage(systemSymbolName: glyphName, accessibilityDescription: nil)

    /// `fraction`: 0…1, or nil while unknown. `spinPhase`: where the unknown-progress segment
    /// starts, in turns clockwise from 12 o'clock (one turn a second).
    /// `presence`: how far the ring has come in (`StatusRingMotion`); at 0 it is the plain glyph at
    /// full size, at 1 the glyph steps back to 0.62 inside the full ring.
    @MainActor public static func image(fraction: Double?, spinPhase: Double, presence: Double = 1) -> NSImage {
        let presence = CGFloat(min(1, max(0, presence)))
        let glyph = Self.glyph
        let image = NSImage(size: size, flipped: false) { bounds in
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor.black.withAlphaComponent(trackOpacity * presence).setStroke()
            track.stroke()

            // Turns clockwise from 12 o'clock, in AppKit's counterclockwise degrees.
            let (start, length) = fraction.map { (0.0, min(1, max(0, $0))) } ?? (spinPhase, spinLength)
            if length > 0, presence > 0 {
                let arc = NSBezierPath()
                let from = 90 - start * 360
                arc.appendArc(withCenter: center, radius: radius, startAngle: from, endAngle: from - length * 360, clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                NSColor.black.withAlphaComponent(presence).setStroke()
                arc.stroke()
            }

            if let glyph {
                let scale = 1 - (1 - glyphScale) * presence
                let drawn = NSSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
                glyph.draw(in: NSRect(x: center.x - drawn.width / 2, y: center.y - drawn.height / 2, width: drawn.width, height: drawn.height))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "yabbistir"
        return image
    }
}

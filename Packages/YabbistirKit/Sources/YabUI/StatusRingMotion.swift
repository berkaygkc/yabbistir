import AppKit
import SwiftUI

/// The menu bar icon over time (design.json `status-ring`): when jobs start, the glyph steps back
/// to 0.62 and the ring fades in (0.3 s, the panel's ease-out), and the reverse when the last one
/// ends; the arc eases to each new combined share (0.35 s, linear); while no job can say how far it
/// is, a segment turns once a second. `StatusRingImage` draws one moment of it; the status item
/// draws a frame every `frameInterval` and none once nothing moves.
///
/// Times are seconds on any steady clock. With Reduce Motion every change lands at once and the
/// unknown-progress segment rests at 12 o'clock.
public struct StatusRingMotion: Sendable {
    static let presenceDuration = 0.3
    static let arcDuration = 0.35
    /// Frames while something eases, and while the segment spins (12 frames a second: a turn a
    /// second in 30° steps).
    static let easingInterval = 1.0 / 30
    static let spinInterval = 1.0 / 12
    private static let ease = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.16, y: 1), endControlPoint: UnitPoint(x: 0.3, y: 1))

    private struct Tween: Sendable {
        let from: Double, to: Double, start: Double, duration: Double
        func value(at now: Double, curve: (Double) -> Double) -> Double {
            let t = min(1, max(0, (now - start) / duration))
            return t >= 1 ? to : from + (to - from) * curve(t)
        }
        func isDone(at now: Double) -> Bool { now - start >= duration }
    }

    public private(set) var isBusy = false
    /// 0: the plain glyph; 1: the glyph stepped back inside the full ring.
    public private(set) var presence: Double = 0
    /// The share the arc shows now; nil while the segment spins.
    public private(set) var fraction: Double?
    /// Where the spinning segment starts, in turns from 12 o'clock.
    public private(set) var spinPhase: Double = 0

    private let reduceMotion: Bool
    private var presenceTween: Tween?
    private var arcTween: Tween?
    private var spinStart: Double?

    public init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
    }

    /// Nothing to draw: the status item shows its plain glyph.
    public var isAtRest: Bool { !isBusy && presence == 0 }

    /// How long until the next frame; nil when nothing moves.
    public var frameInterval: Double? {
        guard !reduceMotion, !isAtRest else { return nil }
        if presenceTween != nil || arcTween != nil { return Self.easingInterval }
        return fraction == nil ? Self.spinInterval : nil
    }

    /// The moment to draw now.
    @MainActor public var image: NSImage {
        StatusRingImage.image(fraction: fraction, spinPhase: spinPhase, presence: presence)
    }

    /// The jobs changed: `busy` while any waits or runs; `target`, their combined share, nil while
    /// none can say. Once the last job ends the ring fades with what it last showed. The share is
    /// taken to the whole percent: a download reports many times a
    /// second, mostly within the same percent. True when the icon has something new to show
    /// (false: an update within the same percent, or one that only changed the time left).
    @discardableResult
    public mutating func set(busy: Bool, fraction target: Double?, at now: Double) -> Bool {
        advance(to: now)
        var changed = false
        if busy, isAtRest {
            // A new appearance: the arc starts from nothing, not from what the last jobs left.
            (fraction, spinStart, arcTween, spinPhase) = (nil, nil, nil, 0)
        }
        if busy != isBusy {
            isBusy = busy
            presenceTween = Tween(from: presence, to: busy ? 1 : 0, start: now, duration: Self.presenceDuration)
            changed = true
        }
        if busy, aim(at: target.map(Self.wholePercent), now: now) { changed = true }
        if reduceMotion { settle(at: now) }
        return changed
    }

    /// 0.426 → 0.43, kept within 0…1.
    static func wholePercent(_ share: Double) -> Double {
        (min(1, max(0, share)) * 100).rounded() / 100
    }

    /// Moves every animation on to `now`.
    public mutating func advance(to now: Double) {
        if let tween = presenceTween {
            presence = tween.value(at: now) { Double(Self.ease.value(at: $0)) }
            if tween.isDone(at: now) { presenceTween = nil }
        }
        if let tween = arcTween {
            fraction = tween.value(at: now) { $0 }
            if tween.isDone(at: now) { arcTween = nil }
        }
        if fraction == nil, let spinStart, !reduceMotion {
            spinPhase = (now - spinStart).truncatingRemainder(dividingBy: 1)
        }
    }

    /// True when the arc changes course.
    private mutating func aim(at target: Double?, now: Double) -> Bool {
        guard let target else {
            // Unknown: the segment spins, from where a spin would be at this moment.
            guard fraction != nil || spinStart == nil else { return false }
            arcTween = nil
            fraction = nil
            spinStart = now
            spinPhase = 0
            return true
        }
        // From a spin the arc grows out of the segment's length at 12 o'clock; on first showing, from nothing.
        let from = fraction ?? (spinStart == nil ? 0 : StatusRingImage.spinLength)
        let current = arcTween?.to ?? fraction
        spinStart = nil
        spinPhase = 0
        guard current != target else { return false }
        fraction = from
        arcTween = Tween(from: from, to: target, start: now, duration: Self.arcDuration)
        return true
    }

    private mutating func settle(at now: Double) {
        if let tween = presenceTween { presence = tween.to }
        if let tween = arcTween { fraction = tween.to }
        presenceTween = nil
        arcTween = nil
        spinPhase = 0
    }
}

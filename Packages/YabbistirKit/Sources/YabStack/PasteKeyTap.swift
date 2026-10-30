import CoreGraphics
import YabPasteboard

/// Hears the user's own ⌘V in any app so the stack can advance, and holds one back while the
/// previous paste settles (the stack replays it). Holding needs Accessibility; with only Input
/// Monitoring the tap listens without holding.
@MainActor
public final class PasteKeyTap {
    /// Decides a user ⌘V (`isRepeat`: a key repeat from holding it down); false holds it back.
    private let onPaste: @MainActor (_ isRepeat: Bool) -> Bool
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pasteKeyCode: CGKeyCode = 9
    /// False when the tap could only be created listen-only.
    public private(set) var holdsKeystrokes = false

    public init(onPaste: @escaping @MainActor (_ isRepeat: Bool) -> Bool) {
        self.onPaste = onPaste
    }

    isolated deinit {
        stop()
    }

    /// Only ⌘ (no ⇧, ⌥ or ⌃) on the layout's V key, and not a keystroke yabbistir posted itself.
    public nonisolated static func isUserPaste(keyCode: Int64, flags: CGEventFlags, userData: Int64, pasteKeyCode: CGKeyCode) -> Bool {
        keyCode == Int64(pasteKeyCode)
            && flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]) == .maskCommand
            && userData != SyntheticEvent.marker
    }

    /// False when neither Accessibility nor Input Monitoring is granted.
    public func start() -> Bool {
        if tap != nil { return true }
        // Read on every start: the user may have switched layouts since the last stack.
        pasteKeyCode = KeyCodeResolver.currentASCIICapable().keyCode(for: "v") ?? 9
        for options in [CGEventTapOptions.defaultTap, .listenOnly] {
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: options,
                                              eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                              callback: pasteKeyTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
            else { continue }
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.tap = tap
            self.source = source
            holdsKeystrokes = options == .defaultTap
            return true
        }
        return false
    }

    public func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        holdsKeystrokes = false
    }

    /// True lets the event through.
    fileprivate func handle(_ type: CGEventType, keyCode: Int64, flags: CGEventFlags, userData: Int64, isRepeat: Bool) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .keyDown:
            guard Self.isUserPaste(keyCode: keyCode, flags: flags, userData: userData, pasteKeyCode: pasteKeyCode) else { return true }
            return onPaste(isRepeat)
        default:
            return true
        }
    }
}

/// The tap's run loop source sits on the main run loop, so this always runs on the main thread.
/// Returning nil holds the keystroke back (ignored for a listen-only tap).
private func pasteKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<PasteKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let userData = event.getIntegerValueField(.eventSourceUserData)
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let passes = MainActor.assumeIsolated {
        tap.handle(type, keyCode: keyCode, flags: flags, userData: userData, isRepeat: isRepeat)
    }
    return passes ? Unmanaged.passUnretained(event) : nil
}

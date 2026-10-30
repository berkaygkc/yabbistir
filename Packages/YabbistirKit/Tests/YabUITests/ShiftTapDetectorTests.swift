import AppKit
import Testing
import YabUI

@Suite struct ShiftTapDetectorTests {
    @Test func aBareShiftTapIsATap() {
        var detector = ShiftTapDetector()
        let result1 = detector.flagsChanged(.shift, at: 0)
        #expect(!result1)
        let result2 = detector.flagsChanged([], at: 0.2)
        #expect(result2)
    }

    @Test func shiftWithAKeyIsNot() {
        var detector = ShiftTapDetector()
        _ = detector.flagsChanged(.shift, at: 0)
        detector.keyDown()
        let result3 = detector.flagsChanged([], at: 0.1)
        #expect(!result3)
    }

    @Test func aLongShiftIsNot() {
        var detector = ShiftTapDetector()
        _ = detector.flagsChanged(.shift, at: 0)
        let result4 = detector.flagsChanged([], at: 0.6)
        #expect(!result4)
    }

    @Test func shiftWithAnotherModifierIsNot() {
        var detector = ShiftTapDetector()
        _ = detector.flagsChanged(.shift, at: 0)
        _ = detector.flagsChanged([.shift, .command], at: 0.05)
        _ = detector.flagsChanged(.shift, at: 0.1)
        let result5 = detector.flagsChanged([], at: 0.15)
        #expect(!result5)
    }

    @Test func typingBeforeATapDoesNotSpoilIt() {
        var detector = ShiftTapDetector()
        detector.keyDown()
        _ = detector.flagsChanged(.shift, at: 1)
        let tapped = detector.flagsChanged([], at: 1.1)
        #expect(tapped)
    }

    @Test func capsLockDoesNotSpoilATap() {
        var detector = ShiftTapDetector()
        _ = detector.flagsChanged([.shift, .capsLock], at: 0)
        let result6 = detector.flagsChanged(.capsLock, at: 0.1)
        #expect(result6)
    }
}

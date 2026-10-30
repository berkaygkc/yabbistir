import AppKit
import SwiftUI
import Testing
@testable import YabUI

@Suite struct MotionTests {
    @MainActor @Test func reduceMotionCollapsesAnimations() {
        Tokens.Motion.reduceMotion = { true }
        defer { Tokens.Motion.reduceMotion = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion } }
        #expect(Tokens.Motion.resolved(Tokens.Motion.selectionSlide) == nil)
    }

    @MainActor @Test func motionPlaysWhenNotReduced() {
        Tokens.Motion.reduceMotion = { false }
        defer { Tokens.Motion.reduceMotion = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion } }
        #expect(Tokens.Motion.resolved(Tokens.Motion.selectionSlide) == Tokens.Motion.selectionSlide)
    }
}

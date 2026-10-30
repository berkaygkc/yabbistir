import AppKit
import SwiftUI
import YabCore

/// Design tokens. Dark is the base, `-light` the light-theme sibling.
public enum Tokens {
    public enum Colors {
        public static let surface = Color(light: rgba(251, 251, 252, 0.86), dark: rgba(29, 29, 32, 0.84))
        public static let surfaceSolid = Color(light: rgba(251, 251, 252, 1), dark: rgba(30, 30, 33, 1))
        public static let text = Color(light: rgba(0, 0, 0, 0.86), dark: rgba(255, 255, 255, 0.93))
        public static let textSecondary = Color(light: rgba(60, 60, 67, 0.7), dark: rgba(235, 235, 245, 0.64))
        public static let textTertiary = Color(light: rgba(60, 60, 67, 0.42), dark: rgba(235, 235, 245, 0.38))
        public static let selection = Color(light: rgba(0, 0, 0, 0.058), dark: rgba(255, 255, 255, 0.085))
        public static let rowHover = Color(light: rgba(0, 0, 0, 0.035), dark: rgba(255, 255, 255, 0.05))
        public static let keycapFill = Color(light: rgba(0, 0, 0, 0.065), dark: rgba(255, 255, 255, 0.1))
        public static let footerTint = Color(light: rgba(0, 0, 0, 0.022), dark: rgba(255, 255, 255, 0.025))
        public static let tile = Color(light: rgba(0, 0, 0, 0.05), dark: rgba(255, 255, 255, 0.07))
        public static let hairline = Color(light: rgba(0, 0, 0, 0.075), dark: rgba(255, 255, 255, 0.085))
        public static let edge = Color(light: rgba(0, 0, 0, 0.07), dark: rgba(255, 255, 255, 0.13))
        public static let rimTop = Color(light: rgba(255, 255, 255, 0.95), dark: rgba(255, 255, 255, 0.2))
        public static let rimBody = Color(light: rgba(0, 0, 0, 0.1), dark: rgba(255, 255, 255, 0.07))
        /// Native selected-text color; follows the user's accent color.
        public static let textSelection = Color(nsColor: .selectedTextBackgroundColor)
        public static let accentSoft = Color(light: rgba(0, 122, 255, 0.16), dark: rgba(10, 132, 255, 0.22))
        public static let danger = Color(light: rgba(255, 59, 48, 1), dark: rgba(255, 69, 58, 1))
        public static let matchHighlight = Color(light: rgba(255, 204, 0, 0.38), dark: rgba(255, 214, 10, 0.28))
        /// The body of a dragged stack row.
        public static let surfaceLifted = Color(light: rgba(250, 250, 252, 0.84), dark: rgba(34, 34, 40, 0.78))
        /// Preview syntax colors: keyword, string, number, comment.
        public static let syntaxKeyword = Color(light: rgba(173, 61, 164, 1), dark: rgba(255, 122, 178, 1))
        public static let syntaxString = Color(light: rgba(196, 26, 22, 1), dark: rgba(252, 106, 93, 1))
        public static let syntaxNumber = Color(light: rgba(28, 0, 207, 1), dark: rgba(217, 201, 124, 1))
        public static let syntaxComment = Color(light: rgba(112, 127, 140, 1), dark: rgba(127, 140, 152, 1))
        /// Category dots: muted hues, never used as fills.
        public static func category(_ color: CategoryColor) -> Color {
            switch color {
            case .slate: Color(light: rgba(86, 103, 137, 1), dark: rgba(147, 163, 194, 1))
            case .sage: Color(light: rgba(76, 125, 73, 1), dark: rgba(159, 202, 156, 1))
            case .clay: Color(light: rgba(177, 85, 54, 1), dark: rgba(232, 156, 126, 1))
            case .ochre: Color(light: rgba(154, 115, 15, 1), dark: rgba(233, 195, 100, 1))
            case .plum: Color(light: rgba(122, 79, 166, 1), dark: rgba(198, 163, 232, 1))
            case .teal: Color(light: rgba(44, 125, 120, 1), dark: rgba(127, 209, 203, 1))
            }
        }
        public static let appMarkTop = rgba(245, 140, 198, 1)
        public static let appMarkBottom = rgba(194, 52, 127, 1)
    }

    public enum Metrics {
        /// 360 pt, slightly wider than the 340 pt a column once had.
        public static let columnWidth: CGFloat = 360
        public static let panelHeight: CGFloat = 476
        public static let searchHeight: CGFloat = 56
        public static let columnHeaderHeight: CGFloat = 32
        public static let rowHeight: CGFloat = 40
        public static let footerHeight: CGFloat = 42
        public static let panelRadius: CGFloat = 16
        public static let rowRadius: CGFloat = 8
        public static let controlRadius: CGFloat = 8
        public static let keycapRadius: CGFloat = 5
        public static let menuRadius: CGFloat = 12
        public static let menuRowRadius: CGFloat = 7
        public static let iconSize: CGFloat = 20
    }

    public enum Fonts {
        public static let search = Font.system(size: 17)
        public static let searchTracking: CGFloat = -0.015 * 17
        public static let row = Font.system(size: 13.5)
        public static let mono = Font.system(size: 12.3, design: .monospaced)
        public static let label = Font.system(size: 12)
        public static let labelStrong = Font.system(size: 12.5, weight: .semibold)
        public static let section = Font.system(size: 11.5, weight: .semibold)
        public static let columnHeader = Font.system(size: 12, weight: .semibold)
        public static let keycap = Font.system(size: 11.5, weight: .medium)
        public static let body = Font.system(size: 13)
    }

    public enum Motion {
        /// cubic-bezier(.16,1,.3,1): the default expo-like ease-out.
        public static func ease(_ duration: Double) -> Animation { .timingCurve(0.16, 1, 0.3, 1, duration: duration) }
        /// cubic-bezier(.34,1.32,.64,1): slight overshoot for arrival and growth.
        public static func spring(_ duration: Double) -> Animation { .timingCurve(0.34, 1.32, 0.64, 1, duration: duration) }
        public static let selectionSlide = ease(0.2)
        public static let panelEnter = ease(0.34)

        /// System Reduce Motion; replaceable in tests.
        @MainActor public static var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

        /// Every animation goes through here: with Reduce Motion on, transitions collapse to ~0 ms.
        @MainActor public static func resolved(_ animation: Animation) -> Animation? {
            reduceMotion() ? nil : animation
        }
    }
}

func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
}

extension Color {
    /// A color that resolves per appearance (light / dark), like an asset-catalog color.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}

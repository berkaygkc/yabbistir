import Testing
@testable import YabCore

@Suite struct ColorValueTests {
    /// Reference values.
    @Test func purpleConvertsToSpecValues() throws {
        let c = try #require(ColorValue(hex: "#6E56CF"))
        #expect(c.rgbText == "110, 86, 207")
        #expect(c.hslText == "252°, 56%, 57%")
        #expect(ColorValue(hex: "#6E56C") == nil)
    }

    @Test func greyHasNoHueOrSaturation() throws {
        let c = try #require(ColorValue(hex: "#808080"))
        #expect(c.hslText == "0°, 0%, 50%")
    }
}

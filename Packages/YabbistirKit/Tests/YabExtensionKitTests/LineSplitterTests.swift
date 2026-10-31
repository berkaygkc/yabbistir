import Foundation
import Testing
import YabExtensionKit

@Suite struct LineSplitterTests {
    @Test func linesArriveWholeWhateverTheChunks() {
        let splitter = LineSplitter()
        #expect(splitter.append(Data("ab".utf8)).isEmpty)
        #expect(splitter.append(Data("c\nde\n\nf".utf8)) == [Data("abc".utf8), Data("de".utf8)])
        #expect(splitter.append(Data("\n".utf8)) == [Data("f".utf8)])
    }

    /// A big line in pipe-sized chunks costs one pass, not one pass per chunk.
    @Test func aLongLineSplitsInLinearTime() {
        let splitter = LineSplitter()
        let chunk = Data(repeating: 0x41, count: 64 * 1024)
        let start = ContinuousClock.now
        for _ in 0..<160 { #expect(splitter.append(chunk).isEmpty) }
        let lines = splitter.append(Data([0x0A]))
        #expect(lines.first?.count == 160 * 64 * 1024)
        #expect(ContinuousClock.now - start < .seconds(1))
    }
}

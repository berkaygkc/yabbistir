import Testing
@testable import YabUI

@Suite struct SyntaxHighlighterTests {
    @Test func sqlLineTokens() {
        let kinds = SyntaxHighlighter.tokens("SELECT id FROM users WHERE name = 'İade' -- not").filter { $0.kind != .plain }
        #expect(kinds.map(\.kind) == [.keyword, .keyword, .keyword, .string, .comment])
    }

    @Test func jsonKeysAndNumbers() {
        let kinds = SyntaxHighlighter.tokens(#"{"limit": 20}"#).filter { $0.kind != .plain }.map(\.kind)
        #expect(kinds == [.string, .number])
    }

    @Test func tokensRebuildTheText() {
        let text = "let total = items.count // 3\nreturn \"ok\""
        #expect(SyntaxHighlighter.tokens(text).map(\.text).joined() == text)
    }
}

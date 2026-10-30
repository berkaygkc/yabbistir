import Foundation

public struct SyntaxToken: Equatable, Sendable {
    public enum Kind: Sendable { case keyword, string, number, comment, plain }
    public var text: String
    public var kind: Kind
}

/// A small, language-agnostic highlighter for the preview: SQL, shell, Swift/JS-like code and
/// JSON. Comments run to the end of the line (--, //, #), strings are '…' or "…".
public enum SyntaxHighlighter {
    /// Only the head is highlighted; long code stays responsive.
    public static let limit = 20_000

    static let keywords: Set<String> = [
        "select", "from", "where", "insert", "into", "update", "set", "delete", "create", "table", "alter", "drop",
        "join", "on", "and", "or", "not", "null", "as", "order", "by", "group", "limit", "values", "returning",
        "true", "false", "let", "var", "func", "return", "if", "else", "for", "while", "import", "class", "struct",
        "enum", "const", "function", "async", "await",
    ]

    public static func tokens(_ text: String) -> [SyntaxToken] {
        let characters = Array(text.prefix(limit))
        var tokens: [SyntaxToken] = []
        var index = 0

        func append(_ text: String, _ kind: SyntaxToken.Kind) {
            if kind == .plain, let last = tokens.last, last.kind == .plain {
                tokens[tokens.count - 1].text += text
            } else {
                tokens.append(SyntaxToken(text: text, kind: kind))
            }
        }
        func scan(while condition: (Character) -> Bool) -> String {
            let start = index
            while index < characters.count, condition(characters[index]) { index += 1 }
            return String(characters[start..<index])
        }

        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if (character == "-" && next == "-") || (character == "/" && next == "/") || character == "#" {
                append(scan { !$0.isNewline }, .comment)
            } else if character == "'" || character == "\"" {
                let start = index
                index += 1
                while index < characters.count, characters[index] != character, !characters[index].isNewline {
                    index += characters[index] == "\\" ? 2 : 1
                }
                index = min(index + 1, characters.count)
                append(String(characters[start..<index]), .string)
            } else if character.isNumber {
                append(scan { $0.isNumber || $0 == "." }, .number)
            } else if character.isLetter || character == "_" {
                let word = scan { $0.isLetter || $0.isNumber || $0 == "_" }
                append(word, keywords.contains(word.lowercased()) ? .keyword : .plain)
            } else {
                append(String(character), .plain)
                index += 1
            }
        }
        return tokens
    }
}

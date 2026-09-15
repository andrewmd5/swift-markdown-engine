import Foundation

public struct MarkdownTag: Equatable, Sendable {
    public let name: String
    public let range: NSRange

    public init(name: String, range: NSRange) {
        self.name = name
        self.range = range
    }
}

public protocol MarkdownTagProvider: Sendable {
    func tags(in text: String) -> [MarkdownTag]
}

public enum MarkdownTagScanner {
    public static func tags(in text: String) -> [MarkdownTag] {
        tags(in: text, tokens: MarkdownTokenizer.parseTokensViaAST(in: text))
    }

    static func tags(in text: String, tokens: [MarkdownToken]) -> [MarkdownTag] {
        let excluded = tokens.flatMap { token -> [NSRange] in
            switch token.kind {
            case .codeBlock, .inlineCode, .imageEmbed, .imageLink, .blockLatex, .inlineLatex:
                return [token.range]
            case .link: return token.markerRanges
            case .backslashEscape: return [token.range]
            default: return []
            }
        }
        func isCharacter(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c.isSymbol || c == "_" || c == "-" || c == "/"
        }
        var result: [MarkdownTag] = []
        var index = text.startIndex
        while index < text.endIndex {
            defer { if index < text.endIndex { index = text.index(after: index) } }
            guard text[index] == "#",
                  index == text.startIndex || !isCharacter(text[text.index(before: index)]) else { continue }
            let start = text.index(after: index)
            var end = start
            while end < text.endIndex, isCharacter(text[end]) { end = text.index(after: end) }
            guard end > start else { continue }
            let name = String(text[start..<end])
            let range = NSRange(index..<end, in: text)
            guard name.contains(where: { !$0.isNumber }),
                  name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }),
                  !excluded.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
            result.append(MarkdownTag(name: name, range: range))
            index = text.index(before: end)
        }
        return result
    }
}

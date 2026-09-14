import AppKit

public struct UnderlineExtension: MarkdownExtension {
    public static let identifier = "underline"
    public init() {}
    public var id: String { Self.identifier }
    public var inline: InlineSyntax? { InlineSyntax(open: "<u>", close: "</u>") }
    public func contentAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] {
        [.underlineStyle: NSUnderlineStyle.single.rawValue]
    }
    public func html(childrenHTML: String) -> String { "<u>\(childrenHTML)</u>" }
}

import AppKit
import Testing
@testable import MarkdownEngine

struct MarkdownTagTests {
    @Test func scansNamesWithoutTreatingCodeOrDestinationsAsTags() {
        let source = "# Heading\n#旅行 #work/ideas #two-words #🙂 #123 name#suffix `#code` \\#escaped [site](https://example.com/#anchor) #broken/"
        #expect(MarkdownTagScanner.tags(in: source).map(\.name) == ["旅行", "work/ideas", "two-words", "🙂"])
        for tag in MarkdownTagScanner.tags(in: source) {
            #expect((source as NSString).substring(with: tag.range) == "#" + tag.name)
        }
    }

    @Test @MainActor func tagStyleKeepsTheWrittenTextAndUsesTheHostsClickHandler() {
        let source = "Keep #travel"
        var config = MarkdownEditorConfiguration()
        config.recognizesHashtags = true
        let styles = MarkdownStyler.styleAttributes(
            text: source, fontName: "Helvetica", fontSize: 15, caretLocation: 0,
            activeTokenIndices: [], configuration: config)
        let tag = styles.first { $0.1[.link] as? String == "markdown-tag:travel" }
        #expect(tag?.0 == NSRange(location: 5, length: 7))
        #expect(tag?.1[.foregroundColor] != nil)
        let coordinator = NativeTextViewCoordinator(
            text: .constant(source), fontName: "Helvetica", fontSize: 15, isWikiLinkActive: .constant(false),
            onLinkClick: nil, onInlineSelectionChange: nil)
        var opened: String?
        coordinator.onTagClick = { opened = $0 }
        #expect(coordinator.textView(NSTextView(), clickedOnLink: "markdown-tag:travel", at: 5))
        #expect(opened == "travel")
    }
}

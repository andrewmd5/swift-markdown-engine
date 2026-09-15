import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor @Suite("Scoped editor integration", .serialized)
struct EditorControllerTests {
  @Test("Subject-looking syntax in code and escaped text stays literal")
  func literalReferenceSyntax() {
    let literal =
      "`[[Alice|subject:id]]`\n\n```\n[[Alice|subject:id]]\n```\n\n\\[[Alice|subject:id]]"
    let displayed = WikiLinkService.makeDisplayState(from: literal) { _ in "Renamed" }
    #expect(displayed.display == literal)
    #expect(displayed.metadata.isEmpty)
    let stored = WikiLinkService.makeStorageState(
      from: displayed.display, existingMetadata: [:], textStorage: nil)
    #expect(stored.storage == literal)
  }

  @Test("Toolbar commands remain scoped to the owning editor")
  func scopedCommands() async throws {
    let first = EditorState(text: "First note")
    let second = EditorState(text: "Second note")
    let a = try EditorFixture(state: first)
    let b = try EditorFixture(state: second)
    defer {
      a.window.close()
      b.window.close()
    }
    await a.settle()
    await b.settle()
    first.controller.select(NSRange(location: 0, length: 5))
    second.controller.focus()
    first.controller.apply(.bold)
    await a.settle()
    await b.settle()
    #expect(first.text == "**First** note")
    #expect(second.text == "Second note")
    #expect(a.window.firstResponder === a.editor)
  }

  @Test("A newer caller replacement wins over a queued editor publication")
  func newerCallerReplacement() async throws {
    let state = EditorState(text: "First")
    let fixture = try EditorFixture(state: state)
    defer { fixture.window.close() }
    await fixture.settle()
    state.controller.select(NSRange(location: 0, length: 5))
    state.controller.apply(.bold)
    state.documentID = "replacement"
    state.text = "A different memory"
    await fixture.settle()
    #expect(state.text == "A different memory")
    #expect(fixture.editor.string == "A different memory")
  }

  @Test("Rapid edits publish the latest content")
  func rapidEdits() async throws {
    let state = EditorState(text: "")
    let fixture = try EditorFixture(state: state)
    defer { fixture.window.close() }
    await fixture.settle()
    for letter in ["A", "B", "C"] { state.controller.apply(.insertText(letter)) }
    await fixture.settle()
    #expect(state.text == "ABC")
  }

  @Test("Replacing the caller's document model refreshes the editor binding")
  func replacingDocumentModel() async throws {
    let first = EditorState(text: "First")
    let fixture = try EditorFixture(state: first)
    defer { fixture.window.close() }
    await fixture.settle()
    let second = EditorState(text: "Second")
    fixture.hosting.rootView = EditorTestView(state: second)
    await fixture.settle()
    second.controller.select(NSRange(location: 0, length: 6))
    second.controller.apply(.bold)
    await fixture.settle()
    #expect(first.text == "First")
    #expect(second.text == "**Second**")
    #expect(!first.controller.canEdit)
  }

  @Test("Double underscores underline, asterisks stay bold, and legacy underline still renders")
  func underlineSyntax() async throws {
    let state = EditorState(text: "__Underlined__ **Bold** <u>Legacy</u> `__literal__`")
    state.configuration.extensions = [UnderlineExtension(), HTMLUnderlineExtension()]
    let fixture = try EditorFixture(state: state)
    defer { fixture.window.close() }
    await fixture.settle()
    let coordinator = try #require(fixture.editor.delegate as? NativeTextViewCoordinator)
    let text = fixture.editor.string as NSString
    for word in ["Underlined", "Legacy"] {
      let range = text.range(of: word)
      #expect(coordinator.isSelectionUnderlined(in: text, range: range))
      #expect(!coordinator.isSelectionBold(in: text, range: range))
    }
    #expect(coordinator.isSelectionBold(in: text, range: text.range(of: "Bold")))
    #expect(!coordinator.isSelectionUnderlined(in: text, range: text.range(of: "literal")))
    state.controller.select(text.range(of: "Underlined"))
    state.controller.apply(.underline)
    await fixture.settle()
    #expect(state.text.hasPrefix("Underlined **Bold**"))
    try #require(fixture.editor.undoManager).undo()
    await fixture.settle()
    #expect(state.text.hasPrefix("__Underlined__"))
  }

  @Test("Unfinished subject completion has a caret anchor and Tab accepts through the host")
  func completionKeyboardAndAnchor() async throws {
    let state = EditorState(text: "Meet [[Ali")
    let fixture = try EditorFixture(state: state)
    defer { fixture.window.close() }
    await fixture.settle()
    let coordinator = try #require(fixture.editor.delegate as? NativeTextViewCoordinator)
    fixture.editor.setSelectedRange(NSRange(location: fixture.editor.string.utf16.count, length: 0))
    let rect = try #require(coordinator.inlinePreviewRect(in: fixture.editor))
    #expect(rect.height > 0)
    #expect(rect.minY >= 0)
    var pressed: InlinePreviewKey?
    coordinator.isWikiLinkActive = true
    coordinator.onInlinePreviewKey = { pressed = $0; return true }
    #expect(coordinator.textView(fixture.editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
    #expect(pressed == .confirm)
  }

  @Test("Table cells edit stored text, Tab appends a row, and structural edits undo")
  func tableCells() async throws {
    let state = EditorState(text: "")
    state.configuration.editsTablesInPlace = true
    let fixture = try EditorFixture(state: state)
    defer { fixture.window.close() }
    await fixture.settle()
    state.controller.apply(.insertTable)
    await fixture.settle()
    let native = try #require(fixture.editor as? NativeTextView)
    let overlay = try #require(native.editableTableOverlays.values.first)
    #expect(overlay.model.rows.count == 2)
    #expect(overlay.frame.height > 60)
    overlay.focus(row: 0, column: 0)
    let fieldEditor = try #require(fixture.window.firstResponder as? NSTextView)
    #expect(fieldEditor !== native)
    fieldEditor.insertText("Name", replacementRange: fieldEditor.selectedRange())
    await fixture.settle()
    #expect(state.text.contains("| Name |"))
    overlay.focus(row: 1, column: 1)
    overlay.focus(row: 1, column: 1)
    let cell = try #require(overlay.table.view(atColumn: 1, row: 1, makeIfNecessary: true) as? NSTableCellView)
    let field = try #require(cell.textField)
    let editor = try #require(field.currentEditor() as? NSTextView)
    #expect(overlay.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
    await fixture.settle()
    #expect(overlay.model.rows.count == 3)
    let beforeColumn = state.text
    state.controller.apply(.table(.addColumnAfter))
    await fixture.settle()
    #expect(overlay.model.columnCount == 3)
    try #require(native.undoManager).undo()
    await fixture.settle()
    #expect(state.text == beforeColumn)
    state.documentID = "another-table-document"
    state.text = "Plain text"
    await fixture.settle()
    #expect(native.editableTableOverlays.isEmpty)
  }

  @Test("Table edits retain subject identifiers and escaped pipes")
  func tableReferenceIdentity() async throws {
    let original = "| Name | Detail |\n| --- | --- |\n| [[Alice|person-id]] | before |\n"
    let state = EditorState(text: original)
    state.configuration.editsTablesInPlace = true
    let fixture = try EditorFixture(state: state)
    defer { fixture.window.close() }
    await fixture.settle()
    let native = try #require(fixture.editor as? NativeTextView)
    let overlay = try #require(native.editableTableOverlays.values.first)
    overlay.focus(row: 1, column: 1)
    let editor = try #require(fixture.window.firstResponder as? NSTextView)
    editor.insertText("a | b", replacementRange: editor.selectedRange())
    await fixture.settle()
    #expect(state.text.contains("[[Alice|person-id]]"))
    #expect(state.text.contains("a \\| b"))
    #expect(overlay.model.columnCount == 2)
    overlay.focus(row: 1, column: 1)
    let longEditor = try #require(fixture.window.firstResponder as? NSTextView)
    longEditor.insertText(String(repeating: "Words that wrap. ", count: 5), replacementRange: longEditor.selectedRange())
    await fixture.settle()
    #expect(overlay.frame.height > 100)
    #expect(try #require((overlay.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField?.font).pointSize > 10)
  }

  @Test("Typing keeps the insertion point inside a compact editor")
  func typingScrollsToCaret() async throws {
    let state = EditorState(text: "")
    state.configuration.overscroll = .init(percent: 0, maxPoints: 0, minPoints: 0)
    state.configuration.scrollers = .init(hasVerticalScroller: false, allowsScrollChaining: false)
    let fixture = try EditorFixture(state: state)
    defer { fixture.window.close() }
    await fixture.settle()
    for _ in 0..<18 {
      fixture.editor.insertText("A new paragraph with wrapped text.\n", replacementRange: fixture.editor.selectedRange())
      await fixture.settle()
    }
    let scroll = try #require(fixture.editor.enclosingScrollView)
    let caret = fixture.editor.firstRect(forCharacterRange: fixture.editor.selectedRange(), actualRange: nil)
    let local = scroll.contentView.convert(fixture.window.convertFromScreen(caret), from: nil)
    #expect(scroll.contentView.bounds.origin.y > 0)
    #expect(local.minY >= scroll.contentView.bounds.minY - 1)
    #expect(local.maxY <= scroll.contentView.bounds.maxY + 1)
  }

  @Test("A contained editor does not pass wheel events to its parent at either edge")
  func scrollBoundary() async throws {
    let state = EditorState(text: String(repeating: "Paragraph\n", count: 50))
    state.configuration.overscroll = .init(percent: 0, maxPoints: 0, minPoints: 0)
    state.configuration.scrollers = .init(hasVerticalScroller: false, allowsScrollChaining: false)
    let fixture = try EditorFixture(state: state)
    defer { fixture.window.close() }
    await fixture.settle()
    let scroll = try #require(fixture.editor.enclosingScrollView as? ClampedScrollView)
    let receiver = ScrollReceiver()
    scroll.nextResponder = receiver
    for (position, delta) in [(CGFloat(0), Int32(100)), (CGFloat(100000), Int32(-100))] {
      scroll.contentView.scroll(to: CGPoint(x: 0, y: position))
      scroll.clampToInsets()
      let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
        wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
      scroll.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
    }
    #expect(receiver.events == 0)
    scroll.fitsContent = true
    let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
      wheelCount: 1, wheel1: -20, wheel2: 0, wheel3: 0))
    scroll.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
    #expect(receiver.events == 1)
  }

}

@MainActor @Observable
private final class EditorState {
  var text: String
  var documentID = UUID().uuidString
  var isEnabled = true
  var configuration = MarkdownEditorConfiguration()
  let controller = MarkdownEditorController()
  init(text: String) { self.text = text }
}

private struct EditorTestView: View {
  @Bindable var state: EditorState
  var body: some View {
    NativeTextViewWrapper(
      text: $state.text, configuration: state.configuration, fontName: "Helvetica", fontSize: 14,
      documentId: state.documentID, controller: state.controller
    ).frame(width: 317, height: 160).disabled(!state.isEnabled)
  }
}

@MainActor
private struct EditorFixture {
  let window: NSWindow
  let hosting: NSHostingView<EditorTestView>
  let editor: NSTextView

  init(state: EditorState) throws {
    hosting = NSHostingView(rootView: EditorTestView(state: state))
    hosting.frame = CGRect(x: 0, y: 0, width: 317, height: 160)
    window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    editor = try #require(Self.textView(in: hosting))
    window.makeFirstResponder(editor)
  }

  func settle() async {
    hosting.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    try? await Task.sleep(for: .milliseconds(40))
    hosting.layoutSubtreeIfNeeded()
  }

  private static func textView(in view: NSView) -> NSTextView? {
    if let text = view as? NSTextView { return text }
    return view.subviews.lazy.compactMap { textView(in: $0) }.first
  }
}

@MainActor private final class ScrollReceiver: NSResponder {
  var events = 0
  override func scrollWheel(with event: NSEvent) { events += 1 }
}

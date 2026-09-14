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
}

@MainActor @Observable
private final class EditorState {
  var text: String
  var documentID = UUID().uuidString
  var isEnabled = true
  let controller = MarkdownEditorController()
  init(text: String) { self.text = text }
}

private struct EditorTestView: View {
  @Bindable var state: EditorState
  var body: some View {
    NativeTextViewWrapper(
      text: $state.text, fontName: "Helvetica", fontSize: 14,
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

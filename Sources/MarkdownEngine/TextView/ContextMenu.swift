//
//  ContextMenu.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 20.06.25.
//
//  Right-click menu with toggleable Markdown formatting actions.
//
//  Two rules here, both learned from silent data loss (25.07.26):
//
//  1. Never publish the binding. `didChangeText()` already enqueues the STORAGE
//     form; a handler enqueueing `self.text = tv.string` lands second on the
//     same queue and wins — and `tv.string` is the DISPLAY form, where every
//     `|UUID` has been moved out of the text into metadata.
//  2. Never rewrite retained text. Rebuilding a span from `tv.string` and
//     writing it back destroys `.wikiLinkID` on anything inside it, which is the
//     only copy of a link's UUID once its metadata range shifts. Use
//     `replacePreservingAttributes` or edit only the characters that change.
//

import Cocoa
import SwiftUI

extension NativeTextViewWrapper.Coordinator {
    // The engine ships no built-in menu (API-only). It hands the default NSMenu + the
    // current selection to the embedder's onBuildContextMenu hook, which returns the menu
    // to show. The didMarkdown* actions below stay so embedders can drive them via the bus.
    public func textView(_ textView: NSTextView,
                         menu: NSMenu,
                         for event: NSEvent,
                         at charIndex: Int) -> NSMenu? {
        // Drop the system rich-text "Font" submenu (Bold/Italic/Show Colors…). Those apply
        // NSFont traits/colors that do nothing in a markdown editor (the engine owns styling),
        // so showing them would mislead. Identified by its font-panel action (locale-independent),
        // with a title fallback.
        if let fontIndex = menu.items.firstIndex(where: { item in
            if item.title == "Font" { return true }
            return item.submenu?.items.contains { $0.action == Selector("orderFrontFontPanel:") } ?? false
        }) {
            menu.removeItem(at: fontIndex)
        }
        guard let build = onBuildContextMenu else { return menu }
        return build(menu, textView.selectedRange())
    }

    /// Returns the smallest bold or boldItalic token that fully contains the selection, or nil when the selection isn't enclosed by emphasis with a bold trait.
    func enclosingBoldToken(for selection: NSRange, in text: String) -> MarkdownToken? {
        let tokens = parsedDocument(for: text).tokens
        return tokens.first { token in
            (token.kind == .bold || token.kind == .boldItalic) && tokenEncloses(token, selection: selection)
        }
    }

    /// Returns the smallest italic or boldItalic token that fully contains the selection, or nil when the selection isn't enclosed by emphasis with an italic trait.
    func enclosingItalicToken(for selection: NSRange, in text: String) -> MarkdownToken? {
        let tokens = parsedDocument(for: text).tokens
        return tokens.first { token in
            (token.kind == .italic || token.kind == .boldItalic) && tokenEncloses(token, selection: selection)
        }
    }

    func isSelectionBold(in nsText: NSString, range: NSRange) -> Bool {
        return enclosingBoldToken(for: range, in: nsText as String) != nil
    }

    func isSelectionItalic(in nsText: NSString, range: NSRange) -> Bool {
        return enclosingItalicToken(for: range, in: nsText as String) != nil
    }

    /// Returns the smallest highlight token that fully contains the selection, or nil.
    /// Highlight is extension-supplied; without a registered `HighlightExtension`
    /// no such token exists and the toggle only wraps/unwraps literal `==`.
    func enclosingHighlightToken(for selection: NSRange, in text: String) -> MarkdownToken? {
        enclosingToken(of: .extensionSpan(HighlightExtension.identifier), for: selection, in: text)
    }

    func isSelectionHighlight(in nsText: NSString, range: NSRange) -> Bool {
        return enclosingHighlightToken(for: range, in: nsText as String) != nil
    }

    /// Strikethrough is extension-supplied; without a registered
    /// `StrikethroughExtension` no such token exists and the toggle only
    /// wraps/unwraps literal `~~`.
    func isSelectionStrikethrough(in nsText: NSString, range: NSRange) -> Bool {
        return enclosingToken(of: .extensionSpan(StrikethroughExtension.identifier), for: range, in: nsText as String) != nil
    }

    func isSelectionUnderlined(in nsText: NSString, range: NSRange) -> Bool {
        enclosingToken(of: .extensionSpan(UnderlineExtension.identifier), for: range, in: nsText as String) != nil
    }

    func toggleUnderline() {
        guard let tv = textView else { return }
        let selection = tv.selectedRange()
        if let token = enclosingToken(of: .extensionSpan(UnderlineExtension.identifier), for: selection, in: tv.string) {
            unwrapToken(token, leftReplacement: "", rightReplacement: "")
            return
        }
        let source = tv.string as NSString
        let range = selection.length == 0 ? wordRange(at: selection.location, in: source) ?? selection : selection
        let content = source.substring(with: range)
        guard replacePreservingAttributes(in: range, with: "<u>" + content + "</u>", retaining: range, at: 3) else { return }
        tv.setSelectedRange(NSRange(location: selection.location + 3, length: selection.length))
    }

    func applyChecklist() { applyList(prefix: "- [ ] ") }

    func isSelectionInlineCode(in nsText: NSString, range: NSRange) -> Bool {
        return enclosingToken(of: .inlineCode, for: range, in: nsText as String) != nil
    }

    /// Returns the smallest token of `kind` that fully contains the selection, or nil.
    private func enclosingToken(of kind: MarkdownTokenKind, for selection: NSRange, in text: String) -> MarkdownToken? {
        let tokens = parsedDocument(for: text).tokens
        return tokens.first { $0.kind == kind && tokenEncloses($0, selection: selection) }
    }

    /// Expands the given text location outward to the nearest alphanumeric
    /// + underscore word boundaries. Returns nil when no word characters
    /// are adjacent to the location.
    private func wordRange(at location: Int, in nsText: NSString) -> NSRange? {
        guard location >= 0, location <= nsText.length else { return nil }
        let charSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        var start = location
        while start > 0 {
            let ch = nsText.character(at: start - 1)
            guard let scalar = Unicode.Scalar(ch), charSet.contains(scalar) else { break }
            start -= 1
        }
        var end = location
        while end < nsText.length {
            let ch = nsText.character(at: end)
            guard let scalar = Unicode.Scalar(ch), charSet.contains(scalar) else { break }
            end += 1
        }
        let length = end - start
        return length > 0 ? NSRange(location: start, length: length) : nil
    }

    private func tokenEncloses(_ token: MarkdownToken, selection: NSRange) -> Bool {
        return selection.location >= token.range.location
            && NSMaxRange(selection) <= NSMaxRange(token.range)
    }

    /// Replace `range` with `newText`, carrying the attributes of `retained`
    /// onto its new home at `newOffset` within `newText`.
    ///
    /// `retained` is a subrange of the CURRENT storage whose characters survive
    /// verbatim. See the file header for why a plain replacement is unsafe.
    /// Returns false when the text view refused the edit, so callers can skip
    /// their selection update.
    @discardableResult
    private func replacePreservingAttributes(
        in range: NSRange,
        with newText: String,
        retaining retained: NSRange,
        at newOffset: Int
    ) -> Bool {
        guard let tv = textView, let storage = tv.textStorage else { return false }
        let replacement = NSMutableAttributedString(string: newText, attributes: tv.typingAttributes)
        let carried = storage.attributedSubstring(from: retained)
        let target = NSRange(location: newOffset, length: carried.length)
        // Defensive: a caller that miscomputes the offset would corrupt the
        // document rather than merely lose styling, so fall back to the plain
        // replacement instead of trapping on a bad range.
        if NSMaxRange(target) <= replacement.length {
            replacement.replaceCharacters(in: target, with: carried)
        }
        replaceFormatting(in: range, with: replacement)
        return true
    }

    private func replaceFormatting(in range: NSRange, with replacement: NSAttributedString,
                                   restoringSelection: NSRange? = nil) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let previous = storage.attributedSubstring(from: range)
        let previousSelection = tv.selectedRange()
        let document = documentId
        let undo = tv.undoManager
        let recordsUndo = undo?.isUndoRegistrationEnabled == true
        let wasProgrammatic = isProgrammaticEdit
        isProgrammaticEdit = true
        defer { isProgrammaticEdit = wasProgrammatic }
        if recordsUndo { undo?.disableUndoRegistration() }
        tv.insertText(replacement, replacementRange: range)
        if recordsUndo {
            undo?.enableUndoRegistration()
            undo?.registerUndo(withTarget: tv) { [weak self] _ in
                guard let self, self.documentId == document else { return }
                self.replaceFormatting(in: NSRange(location: range.location, length: replacement.length),
                                       with: previous, restoringSelection: previousSelection)
            }
        }
        if let restoringSelection { tv.setSelectedRange(restoringSelection) }
    }

    private func unwrapToken(_ token: MarkdownToken, leftReplacement: String, rightReplacement: String) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let content = nsText.substring(with: token.contentRange)
        let newText = leftReplacement + content + rightReplacement
        guard replacePreservingAttributes(
            in: token.range,
            with: newText,
            retaining: token.contentRange,
            at: (leftReplacement as NSString).length
        ) else { return }
        let newSelectionLocation = token.range.location + leftReplacement.count
        tv.setSelectedRange(NSRange(location: newSelectionLocation, length: content.utf16.count))
    }

    func isSelectionHeading(level: Int, in nsText: NSString, range: NSRange) -> Bool {
        let lineRange = nsText.lineRange(for: range)
        let line = nsText.substring(with: lineRange)
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedLine.hasPrefix(String(repeating: "#", count: level) + " ")
    }

    func isSelectionList(in nsText: NSString, range: NSRange) -> Bool {
        let lineRange = nsText.lineRange(for: range)
        let line = nsText.substring(with: lineRange)
        return line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
            || line.hasPrefix("\t• ") || line.hasPrefix("1. ")
    }

    func isSelectionBlockquote(in nsText: NSString, range: NSRange) -> Bool {
        let lineRange = nsText.lineRange(for: range)
        let line = nsText.substring(with: lineRange)
        return line.hasPrefix("> ")
    }

    private func applyHeading(level: Int) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        let lineRange = nsText.lineRange(for: range)
        let originalLine = nsText.substring(with: lineRange)
        let rawLine = originalLine.trimmingCharacters(in: .whitespacesAndNewlines)
        var content = rawLine
        while content.hasPrefix("#") { content.removeFirst() }
        content = content.trimmingCharacters(in: .whitespaces)
        let prefix = level == 0 ? "" : String(repeating: "#", count: level) + " "
        // lineRange(for:) includes the trailing line terminator; preserve it so
        // applying a heading to a non-final line doesn't swallow the newline and
        // merge the line with the next one (mirrors applyList's suffix handling).
        let suffix = originalLine.hasSuffix("\n") ? "\n" : ""
        let newLine = prefix + content + suffix
        // `content` is a verbatim slice of the line — locate it so its styling,
        // and any wiki link inside it, survives the rewrite.
        let contentRange = (originalLine as NSString).range(of: content)
        let retained = contentRange.location == NSNotFound
            ? NSRange(location: lineRange.location, length: 0)
            : NSRange(location: lineRange.location + contentRange.location, length: contentRange.length)
        guard replacePreservingAttributes(
            in: lineRange,
            with: newLine,
            retaining: retained,
            at: (prefix as NSString).length
        ) else { return }
        let newSel = NSRange(location: lineRange.location + prefix.utf16.count, length: content.utf16.count)
        tv.setSelectedRange(newSel)
    }

    @objc func didMarkdownHeading(_ sender: NSMenuItem) {
        applyHeading(level: sender.tag)
    }

    private func applyList(prefix: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let source = tv.string as NSString
        let selection = tv.selectedRange()
        let selectedContent = NSRange(location: selection.location, length: max(0, selection.length - 1))
        let range = source.lineRange(for: selectedContent)
        let replacement = NSMutableAttributedString(string: "")
        var location = range.location
        repeat {
            let line = source.lineRange(for: NSRange(location: location, length: 0))
            let value = source.substring(with: line) as NSString
            let indent = value.range(of: #"^[\t ]*"#, options: .regularExpression).length
            let body = value.substring(from: indent) as NSString
            let marker = body.range(of: #"^(?:[-+*] |[0-9]+[.)] )(?:\[[ xX]\] )?"#,
                                    options: .regularExpression)
            let contentStart = indent + (marker.location == NSNotFound ? 0 : marker.length)
            replacement.append(storage.attributedSubstring(from: NSRange(location: location, length: indent)))
            replacement.append(NSAttributedString(string: prefix, attributes: tv.typingAttributes))
            replacement.append(storage.attributedSubstring(from: NSRange(
                location: location + contentStart, length: line.length - contentStart)))
            location = NSMaxRange(line)
            if line.length == 0 { break }
        } while location < NSMaxRange(range)
        replaceFormatting(in: range, with: replacement)
        tv.setSelectedRange(NSRange(location: range.location + prefix.utf16.count,
                                    length: max(0, replacement.length - prefix.utf16.count)))
    }

    @objc func didMarkdownUnorderedList(_ sender: Any?) {
        applyList(prefix: "- ")
    }

    @objc func didMarkdownOrderedList(_ sender: Any?) {
        applyList(prefix: "1. ")
    }

    @objc func didMarkdownBold(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()

        if let token = enclosingBoldToken(for: range, in: tv.string) {
            // Toggle off: bold → plain, boldItalic → italic.
            let (left, right) = token.kind == .boldItalic ? ("*", "*") : ("", "")
            unwrapToken(token, leftReplacement: left, rightReplacement: right)
            return
        }

        if range.length == 0, let wr = wordRange(at: range.location, in: tv.string as NSString), wr.length > 0 {
            let cursorOffset = range.location - wr.location
            wrapWordRange(wr, with: "**", cursorOffset: cursorOffset)
            return
        }

        if range.length == 0 {
            insertEmptyMarkers("**")
            return
        }

        wrapSelection(with: "**")
    }

    @objc func didMarkdownItalic(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()

        if let token = enclosingItalicToken(for: range, in: tv.string) {
            // Toggle off: italic → plain, boldItalic → bold.
            let (left, right) = token.kind == .boldItalic ? ("**", "**") : ("", "")
            unwrapToken(token, leftReplacement: left, rightReplacement: right)
            return
        }

        if range.length == 0, let wr = wordRange(at: range.location, in: tv.string as NSString), wr.length > 0 {
            let cursorOffset = range.location - wr.location
            wrapWordRange(wr, with: "*", cursorOffset: cursorOffset)
            return
        }

        if range.length == 0 {
            insertEmptyMarkers("*")
            return
        }

        wrapSelection(with: "*")
    }

    @objc func didMarkdownHighlight(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()

        if let token = enclosingHighlightToken(for: range, in: tv.string) {
            unwrapToken(token, leftReplacement: "", rightReplacement: "")
            return
        }

        if range.length == 0 {
            insertEmptyMarkers("==")
            return
        }

        wrapSelection(with: "==")
    }

    @objc func didMarkdownStrikethrough(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()

        if let token = enclosingToken(of: .extensionSpan(StrikethroughExtension.identifier), for: range, in: tv.string) {
            unwrapToken(token, leftReplacement: "", rightReplacement: "")
            return
        }

        if range.length == 0, let wr = wordRange(at: range.location, in: tv.string as NSString), wr.length > 0 {
            let cursorOffset = range.location - wr.location
            wrapWordRange(wr, with: "~~", cursorOffset: cursorOffset)
            return
        }

        if range.length == 0 {
            insertEmptyMarkers("~~")
            return
        }

        wrapSelection(with: "~~")
    }

    @objc func didMarkdownInlineCode(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()

        if let token = enclosingToken(of: .inlineCode, for: range, in: tv.string) {
            unwrapToken(token, leftReplacement: "", rightReplacement: "")
            return
        }

        if range.length == 0, let wr = wordRange(at: range.location, in: tv.string as NSString), wr.length > 0 {
            let cursorOffset = range.location - wr.location
            wrapWordRange(wr, with: "`", cursorOffset: cursorOffset)
            return
        }

        if range.length == 0 {
            insertEmptyMarkers("`")
            return
        }

        wrapSelection(with: "`")
    }

    /// Toggles the `> ` prefix by editing only the prefix, leaving every
    /// attribute on the rest of the line untouched. It used to replace the whole
    /// line to add two characters, which is how it stripped wiki-link UUIDs.
    @objc func didMarkdownBlockquote(_ sender: Any?) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        let lineRange = nsText.lineRange(for: range)
        let originalLine = nsText.substring(with: lineRange)

        if originalLine.hasPrefix("> ") {
            let prefixRange = NSRange(location: lineRange.location, length: 2)
            if tv.shouldChangeText(in: prefixRange, replacementString: "") {
                tv.replaceCharacters(in: prefixRange, with: "")
                tv.didChangeText()
                let newLoc = max(lineRange.location, range.location - 2)
                tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            }
        } else {
            let insertRange = NSRange(location: lineRange.location, length: 0)
            if tv.shouldChangeText(in: insertRange, replacementString: "> ") {
                tv.replaceCharacters(in: insertRange, with: "> ")
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: range.location + 2, length: range.length))
            }
        }
    }

    @objc func didMarkdownLink(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let url = (sender as? NSNotification)?.userInfo?["url"] as? String ?? ""

        if range.length > 0 {
            let nsText = tv.string as NSString
            let selected = nsText.substring(with: range)
            let newText = "[\(selected)](\(url))"
            // The selected text becomes the link label and survives verbatim.
            guard replacePreservingAttributes(
                in: range,
                with: newText,
                retaining: range,
                at: 1 // past the opening "["
            ) else { return }
            tv.setSelectedRange(NSRange(location: range.location + newText.count, length: 0))
        } else {
            let insertion = "[](\(url))"
            if tv.shouldChangeText(in: range, replacementString: insertion) {
                tv.replaceCharacters(in: range, with: insertion)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: range.location + 1, length: 0))
            }
        }
    }

    @objc func didMarkdownCodeBlock(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let nsText = tv.string as NSString
        let lineRange = nsText.lineRange(for: range)
        let prefix = range.location > lineRange.location ? "\n" : ""
        let insertion = "\(prefix)```\n\n```\n"
        if tv.shouldChangeText(in: range, replacementString: insertion) {
            tv.replaceCharacters(in: range, with: insertion)
            tv.didChangeText()
            let cursorLoc = range.location + prefix.count + 4
            tv.setSelectedRange(NSRange(location: cursorLoc, length: 0))
        }
    }

    @objc func didMarkdownHorizontalRule(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let nsText = tv.string as NSString
        let lineRange = nsText.lineRange(for: range)
        let prefix = range.location > lineRange.location ? "\n" : ""
        let insertion = "\(prefix)---\n"
        if tv.shouldChangeText(in: range, replacementString: insertion) {
            tv.replaceCharacters(in: range, with: insertion)
            tv.didChangeText()
            let cursorLoc = range.location + insertion.count
            tv.setSelectedRange(NSRange(location: cursorLoc, length: 0))
        }
    }

    @objc func didMarkdownImage(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let url = (sender as? NSNotification)?.userInfo?["url"] as? String ?? ""
        let insertion = "![](\(url))"
        if tv.shouldChangeText(in: range, replacementString: insertion) {
            tv.replaceCharacters(in: range, with: insertion)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: range.location + insertion.count, length: 0))
        }
    }

    /// Wraps the range with markers while preserving the cursor's relative
    /// offset within the original text. For example `wo|rd` with `**`
    /// becomes `**wo|rd**`.
    private func wrapWordRange(_ range: NSRange, with marker: String, cursorOffset: Int) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let original = nsText.substring(with: range)
        let newText = marker + original + marker
        guard replacePreservingAttributes(
            in: range,
            with: newText,
            retaining: range,
            at: (marker as NSString).length
        ) else { return }
        tv.setSelectedRange(NSRange(location: range.location + marker.count + cursorOffset, length: 0))
    }

    private func insertEmptyMarkers(_ marker: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let insertion = marker + marker
        if tv.shouldChangeText(in: range, replacementString: insertion) {
            tv.replaceCharacters(in: range, with: insertion)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: range.location + marker.count, length: 0))
        }
    }

    private func wrapSelection(with marker: String) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        let original = nsText.substring(with: range)
        let leadingWS = original.prefix { $0.isWhitespace }.count
        let trailingWS = original.reversed().prefix { $0.isWhitespace }.count
        let coreStart = original.index(original.startIndex, offsetBy: leadingWS)
        let coreEnd = original.index(original.endIndex, offsetBy: -trailingWS)
        let core = coreStart <= coreEnd ? String(original[coreStart..<coreEnd]) : ""
        let leading = String(original[..<coreStart])
        let trailing = String(original[coreEnd...])
        let newText = leading + marker + core + marker + trailing
        // Only the markers are new; `core` is the user's text and keeps its
        // attributes, including a wiki link's UUID if the selection spans one.
        let coreOldRange = NSRange(location: range.location + (leading as NSString).length,
                                   length: (core as NSString).length)
        guard replacePreservingAttributes(
            in: range,
            with: newText,
            retaining: coreOldRange,
            at: (leading as NSString).length + (marker as NSString).length
        ) else { return }
        let newRange = NSRange(location: range.location + leading.utf16.count + marker.utf16.count, length: core.utf16.count)
        tv.setSelectedRange(newRange)
    }
}

// Menu Item Validation (checkmark state) removed together with the built-in menu —
// engine ships no UI. Expose the isSelection* checks as a query API if embedders
// need menu state.

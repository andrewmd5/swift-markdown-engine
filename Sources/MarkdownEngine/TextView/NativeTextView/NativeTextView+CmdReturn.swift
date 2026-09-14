//
//  NativeTextView+CmdReturn.swift
//  MarkdownEngine
//
//  ⌘↵ ("link & open") for the inline [[…]] preview. AppKit does NOT route ⌘+Return
//  through doCommandBy(insertNewline:), so we intercept it as a key equivalent — which
//  fires first for ⌘-combos — and forward `.confirmAndOpen` to the embedder.
//

import AppKit

extension NativeTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, isEditable, !hasMarkedText(),
           let controller = (delegate as? NativeTextViewCoordinator)?.controller {
            let action: MarkdownEditingAction?
            switch (modifiers, event.charactersIgnoringModifiers?.lowercased()) {
            case (.command, "b"): action = .bold
            case (.command, "i"): action = .italic
            case (.command, "u"): action = .underline
            case ([.command, .shift], "x"): action = .strikethrough
            default: action = nil
            }
            if let action { controller.apply(action); return true }
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.keyCode == 36 || event.keyCode == 76,            // Return / keypad Enter
           let coord = delegate as? NativeTextViewCoordinator,
           coord.isWikiLinkActive || coord.isImageEmbedActive,
           let handler = coord.onInlinePreviewKey,
           handler(.confirmAndOpen) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

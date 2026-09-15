import AppKit

extension NSAttributedString.Key {
    static let editableTableAnchor = NSAttributedString.Key("EditableTableAnchor")
}

extension NativeTextView {
    func updateEditableTableOverlays() {
        guard configuration.editsTablesInPlace, !configuration.rawSourceMode,
              let storage = textStorage, let coordinator = delegate as? NativeTextViewCoordinator,
              let bridge = layoutBridge, let container = textContainer else {
            for overlay in editableTableOverlays.values { overlay.removeFromSuperview() }
            editableTableOverlays.removeAll()
            activeTableEditor = nil
            return
        }
        let document = coordinator.documentId
        if editableTableDocumentID != document {
            for overlay in editableTableOverlays.values { overlay.removeFromSuperview() }
            editableTableOverlays.removeAll()
            activeTableEditor = nil
            editableTableDocumentID = document
        }
        let tokens = coordinator.parsedDocument(for: string).tokens.filter { $0.kind == .table }
        var seen: Set<Int> = []
        for token in tokens {
            let range = token.range
            guard NSMaxRange(range) <= storage.length,
                  storage.attribute(.editableTableAnchor, at: range.location, effectiveRange: nil) != nil,
                  let model = EditableMarkdownTable(storage.attributedSubstring(from: range)) else { continue }
            let anchor = NSRange(location: range.location, length: 1)
            if let manager = textLayoutManager,
               let start = manager.textContentManager?.location(manager.documentRange.location, offsetBy: anchor.location) {
                manager.ensureLayout(for: NSTextRange(location: start))
            }
            let rect = bridge.boundingRect(forCharacterRange: anchor, in: container)
            guard rect.height > 0 else { continue }
            seen.insert(range.location)
            let overlay: EditableTableOverlay
            if let existing = editableTableOverlays[range.location] {
                overlay = existing
                overlay.update(model: model, range: range)
            } else {
                overlay = EditableTableOverlay(owner: self, range: range, model: model)
                addSubview(overlay)
                editableTableOverlays[range.location] = overlay
            }
            let width = container.size.width
            let extra: CGFloat = model.width(in: width) > width + 0.5 ? 14 : 0
            overlay.frame = CGRect(x: rect.minX + textContainerOrigin.x,
                                   y: rect.minY + textContainerOrigin.y,
                                   width: width, height: model.height(in: width, font: overlay.baseFont, configuration: configuration) + extra)
        }
        for (location, overlay) in editableTableOverlays where !seen.contains(location) {
            if activeTableEditor === overlay { activeTableEditor = nil }
            overlay.removeFromSuperview()
            editableTableOverlays.removeValue(forKey: location)
        }
    }
}

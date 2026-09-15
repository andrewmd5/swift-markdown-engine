import AppKit

extension NativeTextView {
    override func didChangeText() {
        super.didChangeText()
        let documentID = (delegate as? NativeTextViewCoordinator)?.documentId
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder === self,
                  (self.delegate as? NativeTextViewCoordinator)?.documentId == documentID,
                  self.configuration.heightBehavior == .scrolls else { return }
            self.revealInsertionPoint()
        }
    }

    func revealInsertionPoint() {
        guard let manager = textLayoutManager,
              let scroll = enclosingScrollView,
              let location = manager.textContentManager?.location(
                manager.documentRange.location, offsetBy: selectedRange().location) else { return }
        let range = NSTextRange(location: location)
        manager.ensureLayout(for: range)
        recalcOverscroll(for: scroll, debugTag: "insertion")
        var caret: CGRect?
        manager.enumerateTextSegments(in: range, type: .standard, options: [.rangeNotRequired]) {
            _, rect, _, _ in
            caret = rect
            return false
        }
        guard let caret, caret.height > 0 else { return }
        revealEditingRect(caret.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y), from: self)
    }

    func revealEditingRect(_ frame: CGRect, from view: NSView) {
        guard let scroll = enclosingScrollView, let document = scroll.documentView else { return }
        let rect = document.convert(frame, from: view)
        let clip = scroll.contentView
        let visible = clip.bounds
        var y = visible.minY
        if rect.maxY > visible.maxY { y = rect.maxY - visible.height }
        if rect.minY < y { y = rect.minY }
        guard abs(y - visible.minY) > 0.5 else { return }
        (scroll as? ClampedScrollView)?.cancelPendingScrollRestore()
        clip.scroll(to: CGPoint(x: visible.minX, y: y))
        scroll.reflectScrolledClipView(clip)
        (scroll as? ClampedScrollView)?.clampToInsets()
    }
}

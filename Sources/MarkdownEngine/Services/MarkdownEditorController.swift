import AppKit
import Observation

public enum MarkdownEditingAction: Equatable, Sendable {
    case bold, italic, underline, strikethrough
    case heading(Int), unorderedList, orderedList, checklist
    case insertText(String), insertTable
}

public struct MarkdownEditorSelection: Equatable, Sendable {
    public var range = NSRange(location: 0, length: 0)
    public var isBold = false
    public var isItalic = false
    public var isUnderlined = false
    public var isStruckThrough = false
    public var headingLevel = 0
}

@MainActor @Observable
public final class MarkdownEditorController {
    public private(set) var selection = MarkdownEditorSelection()
    public private(set) var isFocused = false
    public private(set) var canEdit = false
    @ObservationIgnored private weak var coordinator: NativeTextViewCoordinator?
    @ObservationIgnored private var refreshScheduled = false

    public init() {}

    public func focus() {
        guard let view = coordinator?.textView else { return }
        view.window?.makeFirstResponder(view)
    }

    public func select(_ range: NSRange) {
        guard let view = coordinator?.textView, range.location != NSNotFound,
              range.location >= 0, range.length >= 0,
              range.location <= view.string.utf16.count,
              range.length <= view.string.utf16.count - range.location else { return }
        view.setSelectedRange(range)
        view.scrollRangeToVisible(range)
    }

    public func apply(_ action: MarkdownEditingAction) {
        guard let coordinator, let view = coordinator.textView,
              view.isEditable, !view.hasMarkedText() else { return }
        focus()
        view.breakUndoCoalescing()
        view.undoManager?.beginUndoGrouping()
        defer {
            view.undoManager?.endUndoGrouping()
            view.breakUndoCoalescing()
            scheduleRefresh()
        }
        switch action {
        case .bold: coordinator.didMarkdownBold(nil)
        case .italic: coordinator.didMarkdownItalic(nil)
        case .underline: coordinator.toggleUnderline()
        case .strikethrough: coordinator.didMarkdownStrikethrough(nil)
        case .heading(let level):
            guard (0...6).contains(level) else { return }
            let item = NSMenuItem()
            item.tag = level
            coordinator.didMarkdownHeading(item)
        case .unorderedList: coordinator.didMarkdownUnorderedList(nil)
        case .orderedList: coordinator.didMarkdownOrderedList(nil)
        case .checklist: coordinator.applyChecklist()
        case .insertText(let text): view.insertText(text, replacementRange: view.selectedRange())
        case .insertTable:
            let location = NSMaxRange(view.selectedRange())
            view.setSelectedRange(NSRange(location: location, length: 0))
            let source = view.string as NSString
            let prefix = location == 0 ? "" : source.character(at: location - 1) == 10 ? "\n" : "\n\n"
            view.insertText(prefix + "|  |  |\n| --- | --- |\n|  |  |\n", replacementRange: view.selectedRange())
            view.setSelectedRange(NSRange(location: location + prefix.utf16.count + 2, length: 0))
        }
    }

    func attach(to coordinator: NativeTextViewCoordinator) {
        self.coordinator = coordinator
        scheduleRefresh()
    }

    func detach(from coordinator: NativeTextViewCoordinator) {
        guard self.coordinator === coordinator else { return }
        self.coordinator = nil
        scheduleRefresh()
    }

    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        guard let coordinator, let view = coordinator.textView else {
            selection = MarkdownEditorSelection()
            isFocused = false
            canEdit = false
            return
        }
        let range = view.selectedRange()
        let source = view.string as NSString
        selection = MarkdownEditorSelection(
            range: range,
            isBold: coordinator.isSelectionBold(in: source, range: range),
            isItalic: coordinator.isSelectionItalic(in: source, range: range),
            isUnderlined: coordinator.isSelectionUnderlined(in: source, range: range),
            isStruckThrough: coordinator.isSelectionStrikethrough(in: source, range: range),
            headingLevel: (1...6).first { coordinator.isSelectionHeading(level: $0, in: source, range: range) } ?? 0)
        isFocused = view.window?.firstResponder === view
        canEdit = view.isEditable && !view.hasMarkedText()
    }
}

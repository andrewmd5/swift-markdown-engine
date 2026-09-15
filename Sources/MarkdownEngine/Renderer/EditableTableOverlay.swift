import AppKit

final class EditableTableOverlay: NSScrollView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    weak var owner: NativeTextView?
    var sourceRange: NSRange
    var model: EditableMarkdownTable
    let table = NSTableView()
    var selectedCell = (row: 0, column: 0)
    private var isCommitting = false
    private var committedSource: String?
    private var wasEditable = true
    private var measuredRows: [CGFloat] = []
    private var measuredWidth: CGFloat = 0
    private var measuredFont: NSFont?
    var baseFont: NSFont {
        guard let owner, let coordinator = owner.delegate as? NativeTextViewCoordinator else { return .systemFont(ofSize: 15) }
        return owner.configuration.resolvedFont(name: coordinator.fontName, size: coordinator.fontSize)
    }

    init(owner: NativeTextView, range: NSRange, model: EditableMarkdownTable) {
        self.owner = owner
        self.wasEditable = owner.isEditable
        self.sourceRange = range
        self.model = model
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = false
        hasHorizontalScroller = true
        autohidesScrollers = true
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        table.style = .plain
        table.headerView = nil
        table.rowHeight = 42
        table.intercellSpacing = NSSize(width: 1, height: 1)
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        updateColors()
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        documentView = table
        rebuildColumns()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = (owner?.configuration.theme.bodyText ?? NSColor.labelColor).withAlphaComponent(0.09)
            table.gridColor = color
            wantsLayer = true
            layer?.cornerRadius = 10
            layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
            layer?.borderColor = color.cgColor
            layer?.masksToBounds = true
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn.flatMap({ table.tableColumns.firstIndex(of: $0) }) else { return nil }
        let field = TableCellField()
        field.row = row
        field.column = column
        field.stringValue = model.rows[row][column].string.replacingOccurrences(of: "\\|", with: "|")
        field.isEditable = owner?.isEditable ?? false
        field.isSelectable = true
        field.isBezeled = false
        field.drawsBackground = false
        field.font = baseFont
        field.attributedStringValue = formattedCell(row: row, column: column)
        field.textColor = owner?.configuration.theme.bodyText
        field.delegate = self
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.cell?.isScrollable = true
        let cell = EditableTableCellView()
        cell.tint = owner?.configuration.theme.link ?? .controlAccentColor
        cell.fill = (owner?.configuration.theme.bodyText ?? .labelColor).withAlphaComponent(row == 0 ? 0.045 : 0)
        cell.textField = field
        cell.addSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            field.topAnchor.constraint(equalTo: cell.topAnchor, constant: 10),
            field.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -10),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let width = max(1, contentSize.width)
        let font = baseFont
        if measuredRows.isEmpty || measuredWidth != width || measuredFont != font {
            measuredRows = model.rowHeights(in: width, font: font, configuration: owner?.configuration ?? .default)
            measuredWidth = width
            measuredFont = font
        }
        return measuredRows.indices.contains(row) ? measuredRows[row] : 42
    }

    private func formattedCell(row: Int, column: Int) -> NSAttributedString {
        let configuration = owner?.configuration ?? .default
        return MarkdownStyler.formattedCellString(
            model.rows[row][column].string, baseFont: baseFont, header: row == 0,
            theme: configuration.theme, codeBackgroundColor: configuration.services.syntaxHighlighter.backgroundColor(),
            latex: configuration.services.latex, extensions: configuration.extensions)
    }

    override func layout() {
        super.layout()
        let width = model.width(in: contentSize.width)
        for column in table.tableColumns { column.width = (width - CGFloat(model.columnCount)) / CGFloat(model.columnCount) }
        table.frame.size = NSSize(width: width, height: model.height(in: width, font: baseFont, configuration: owner?.configuration ?? .default))
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) { super.scrollWheel(with: event) }
        else { owner?.enclosingScrollView?.scrollWheel(with: event) }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let cell = notification.object as? TableCellField else { return }
        selectedCell = (cell.row, cell.column)
        let raw = model.rows[cell.row][cell.column].string.replacingOccurrences(of: "\\|", with: "|")
        if let editor = cell.currentEditor() as? NSTextView, editor.string != raw {
            editor.string = raw
            editor.setSelectedRange(NSRange(location: 0, length: raw.utf16.count))
        }
        owner?.activeTableEditor = self
        (cell.superview as? EditableTableCellView)?.isEditing = true
        owner?.breakUndoCoalescing()
        (owner?.delegate as? NativeTextViewCoordinator)?.controller?.scheduleRefresh()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? TableCellField,
              (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        model.replaceCell(row: field.row, column: field.column, with: field.stringValue)
        commit()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        owner?.breakUndoCoalescing()
        if let cell = notification.object as? TableCellField,
           model.rows.indices.contains(cell.row), model.rows[cell.row].indices.contains(cell.column) {
            (cell.superview as? EditableTableCellView)?.isEditing = false
            cell.attributedStringValue = formattedCell(row: cell.row, column: cell.column)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let field = control as? TableCellField else { return false }
        let backwards = selector == #selector(NSResponder.insertBacktab(_:))
        let forwards = selector == #selector(NSResponder.insertTab(_:))
        let down = selector == #selector(NSResponder.insertNewline(_:))
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            leaveTable()
            return true
        }
        let upArrow = selector == #selector(NSResponder.moveUp(_:)) && textView.selectedRange().location == 0
        let downArrow = selector == #selector(NSResponder.moveDown(_:)) && NSMaxRange(textView.selectedRange()) == textView.string.utf16.count
        if upArrow || downArrow {
            let row = field.row + (upArrow ? -1 : 1)
            if model.rows.indices.contains(row) { focus(row: row, column: field.column) }
            else { leaveTable(before: upArrow) }
            return true
        }
        guard backwards || forwards || down else { return false }
        var index = field.row * model.columnCount + field.column + (backwards ? -1 : down ? model.columnCount : 1)
        if index < 0 { leaveTable(before: true); return true }
        if index >= model.rows.count * model.columnCount {
            model.rows.append(Array(repeating: NSAttributedString(string: ""), count: model.columnCount))
            commit()
            table.reloadData()
        }
        index = min(index, model.rows.count * model.columnCount - 1)
        focus(row: index / model.columnCount, column: index % model.columnCount)
        return true
    }

    func focus(row: Int, column: Int) {
        selectedCell = (row, column)
        owner?.activeTableEditor = self
        table.scrollRowToVisible(row)
        table.scrollColumnToVisible(column)
        owner?.revealEditingRect(table.rect(ofRow: row), from: table)
        guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    func applyInlineAction(_ action: MarkdownEditingAction) {
        guard let cell = table.view(atColumn: selectedCell.column, row: selectedCell.row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        window?.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView, !editor.hasMarkedText() else { return }
        if case .insertText(let text) = action {
            editor.insertText(text, replacementRange: editor.selectedRange())
            return
        }
        let marker: String
        switch action {
        case .bold: marker = "**"
        case .italic: marker = "*"
        case .underline: marker = "__"
        case .strikethrough: marker = "~~"
        default: return
        }
        let range = editor.selectedRange()
        let source = editor.string as NSString
        let count = marker.utf16.count
        if range.location >= count, NSMaxRange(range) + count <= source.length,
           source.substring(with: NSRange(location: range.location - count, length: count)) == marker,
           source.substring(with: NSRange(location: NSMaxRange(range), length: count)) == marker {
            editor.insertText(source.substring(with: range), replacementRange: NSRange(location: range.location - count, length: range.length + 2 * count))
            editor.setSelectedRange(NSRange(location: range.location - count, length: range.length))
        } else {
            editor.insertText(marker + source.substring(with: range) + marker, replacementRange: range)
            editor.setSelectedRange(NSRange(location: range.location + count, length: range.length))
        }
    }

    func apply(_ action: MarkdownTableAction) {
        let row = selectedCell.row
        let column = selectedCell.column
        switch action {
        case .addRowAbove: model.rows.insert(Array(repeating: NSAttributedString(string: ""), count: model.columnCount), at: row)
        case .addRowBelow: model.rows.insert(Array(repeating: NSAttributedString(string: ""), count: model.columnCount), at: row + 1)
        case .deleteRow:
            guard model.rows.count > 1 else { return }
            model.rows.remove(at: row)
        case .addColumnBefore, .addColumnAfter:
            let index = column + (action == .addColumnAfter ? 1 : 0)
            model.separators.insert("---", at: index)
            for indexRow in model.rows.indices { model.rows[indexRow].insert(NSAttributedString(string: ""), at: index) }
        case .deleteColumn:
            guard model.columnCount > 1 else { return }
            model.separators.remove(at: column)
            for indexRow in model.rows.indices { model.rows[indexRow].remove(at: column) }
        case .deleteTable:
            guard let owner else { return }
            window?.makeFirstResponder(owner)
            owner.insertText("", replacementRange: sourceRange)
            return
        }
        commit()
        rebuildColumns()
        focus(row: min(row, model.rows.count - 1), column: min(column, model.columnCount - 1))
    }

    func update(model: EditableMarkdownTable, range: NSRange, source: String) {
        sourceRange = range
        let editable = owner?.isEditable ?? false
        let changed = wasEditable != editable
        wasEditable = editable
        if !editable, owner?.activeTableEditor === self, let owner {
            window?.makeFirstResponder(owner)
        }
        guard !isCommitting, committedSource != source || changed else { return }
        guard self.model.source.string != model.source.string || changed else { return }
        committedSource = nil
        let structureChanged = self.model.rows.count != model.rows.count || self.model.columnCount != model.columnCount
        self.model = model
        selectedCell = (min(selectedCell.row, model.rows.count - 1), min(selectedCell.column, model.columnCount - 1))
        if structureChanged {
            let wasEditing = owner?.activeTableEditor === self
            rebuildColumns()
            if wasEditing, editable { focus(row: selectedCell.row, column: selectedCell.column) }
        } else {
            for row in model.rows.indices {
                for column in 0..<model.columnCount {
                    guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView,
                          let field = cell.textField else { continue }
                    field.isEditable = editable
                    if let editor = field.currentEditor() as? NSTextView {
                        let selection = editor.selectedRange()
                        let raw = model.rows[row][column].string.replacingOccurrences(of: "\\|", with: "|")
                        field.stringValue = raw
                        editor.string = raw
                        let start = min(selection.location, raw.utf16.count)
                        editor.setSelectedRange(NSRange(location: start, length: min(selection.length, raw.utf16.count - start)))
                    } else {
                        field.attributedStringValue = formattedCell(row: row, column: column)
                    }
                }
            }
            invalidateRowHeights()
        }
    }

    private func rebuildColumns() {
        measuredRows = []
        while let column = table.tableColumns.last { table.removeTableColumn(column) }
        for index in 0..<model.columnCount {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = String(index + 1)
            column.minWidth = 90
            table.addTableColumn(column)
        }
        table.reloadData()
        needsLayout = true
    }

    private func commit() {
        guard let owner, owner.isEditable,
              let storage = owner.textStorage, NSMaxRange(sourceRange) <= storage.length else { return }
        let source = model.source
        guard owner.shouldChangeText(in: sourceRange, replacementString: source.string) else { return }
        isCommitting = true
        committedSource = source.string
        storage.replaceCharacters(in: sourceRange, with: source)
        sourceRange.length = source.length
        owner.didChangeText()
        isCommitting = false
        invalidateRowHeights()
        (owner.delegate as? NativeTextViewCoordinator)?.controller?.scheduleRefresh()
    }

    private func invalidateRowHeights() {
        measuredRows = []
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<model.rows.count))
        needsLayout = true
    }

    private func leaveTable(before: Bool = false) {
        guard let owner else { return }
        owner.activeTableEditor = nil
        window?.makeFirstResponder(owner)
        owner.setSelectedRange(NSRange(location: before ? sourceRange.location : NSMaxRange(sourceRange), length: 0))
        owner.revealInsertionPoint()
    }
}

private final class TableCellField: NSTextField {
    var row = 0
    var column = 0
}

private final class EditableTableCellView: NSTableCellView {
    var tint: NSColor = .controlAccentColor
    var fill: NSColor = .clear
    var isEditing = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        (isEditing ? tint.withAlphaComponent(0.045) : fill).setFill()
        bounds.fill()
        if isEditing {
            tint.withAlphaComponent(0.6).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            ring.lineWidth = 1
            ring.stroke()
        }
    }
}

import AppKit

struct EditableMarkdownTable {
    var rows: [[NSAttributedString]]
    var separators: [String]
    let hasTrailingNewline: Bool

    init?(_ source: NSAttributedString) {
        let text = source.string as NSString
        var lines: [[NSAttributedString]] = []
        var offset = 0
        while offset < text.length {
            let line = text.lineRange(for: NSRange(location: offset, length: 0))
            var end = NSMaxRange(line)
            while end > offset, [9, 10, 13, 32].contains(text.character(at: end - 1)) { end -= 1 }
            var start = offset
            while start < end, text.character(at: start) == 32 { start += 1 }
            if start < end, text.character(at: start) == 124 { start += 1 }
            var stops: [Int] = []
            var escaped = false
            for index in start..<end {
                let character = text.character(at: index)
                if character == 124, !escaped { stops.append(index) }
                escaped = character == 92 && !escaped
            }
            if stops.last != end - 1 { stops.append(end) }
            var cells: [NSAttributedString] = []
            for stop in stops {
                var left = start
                var right = stop
                while left < right, text.character(at: left) == 32 { left += 1 }
                while right > left, text.character(at: right - 1) == 32 { right -= 1 }
                cells.append(source.attributedSubstring(from: NSRange(location: left, length: right - left)))
                start = stop + 1
            }
            if !cells.isEmpty { lines.append(cells) }
            offset = NSMaxRange(line)
        }
        guard lines.count >= 2, !lines[0].isEmpty else { return nil }
        separators = lines[1].map(\.string)
        rows = [lines[0]] + lines.dropFirst(2)
        let columns = separators.count
        rows = rows.map { Array($0.prefix(columns)) + Array(repeating: NSAttributedString(string: ""), count: max(0, columns - $0.count)) }
        hasTrailingNewline = source.string.hasSuffix("\n")
    }

    var columnCount: Int { separators.count }
    func rowHeights(in width: CGFloat, font: NSFont, configuration: MarkdownEditorConfiguration) -> [CGFloat] {
        let cellWidth = self.width(in: width) / CGFloat(columnCount) - 17
        return rows.enumerated().map { row, cells in
            cells.map { cell in
                let content = MarkdownStyler.formattedCellString(
                    cell.string, baseFont: font, header: row == 0, theme: configuration.theme,
                    codeBackgroundColor: configuration.services.syntaxHighlighter.backgroundColor(),
                    latex: configuration.services.latex, extensions: configuration.extensions)
                return max(35, ceil(content.boundingRect(with: NSSize(width: cellWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 16)
            }.max() ?? 35
        }
    }

    func height(in width: CGFloat, font: NSFont, configuration: MarkdownEditorConfiguration) -> CGFloat {
        rowHeights(in: width, font: font, configuration: configuration).reduce(2) { $0 + $1 + 1 }
    }
    func width(in available: CGFloat) -> CGFloat { max(available, CGFloat(columnCount) * 100) }

    var source: NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for (index, row) in rows.enumerated() {
            result.append(NSAttributedString(string: "| "))
            for (column, cell) in row.enumerated() {
                result.append(cell)
                result.append(NSAttributedString(string: column == row.count - 1 ? " |" : " | "))
            }
            if index == 0 {
                result.append(NSAttributedString(string: "\n| " + separators.joined(separator: " | ") + " |"))
            }
            if index < rows.count - 1 || hasTrailingNewline { result.append(NSAttributedString(string: "\n")) }
        }
        return result
    }

    mutating func replaceCell(row: Int, column: Int, with value: String) {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return }
        let old = rows[row][column]
        let escaped = value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        let before = Array(old.string)
        let after = Array(escaped)
        let prefix = zip(before, after).prefix(while: { $0 == $1 }).count
        let suffix = zip(before.dropFirst(prefix).reversed(), after.dropFirst(prefix).reversed()).prefix(while: { $0 == $1 }).count
        let start = String(before.prefix(prefix)).utf16.count
        let length = old.length - start - String(before.suffix(suffix)).utf16.count
        let updated = NSMutableAttributedString(attributedString: old)
        updated.replaceCharacters(in: NSRange(location: start, length: length),
                                  with: String(after.dropFirst(prefix).dropLast(suffix)))
        rows[row][column] = updated
    }
}

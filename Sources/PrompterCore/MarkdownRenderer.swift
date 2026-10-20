import AppKit

public struct RenderStyle {
    public var baseSize: CGFloat
    public var textColor: NSColor
    public var secondaryColor: NSColor
    /// Bar beside quotes, which in a script are usually the lines to say.
    public var accentColor: NSColor
    /// Subtitle-style band behind the glyphs, so light text stays crisp over
    /// whatever shows through the overlay; the gaps between lines stay clear.
    public var textBand: NSColor?
    /// Soft halo around the glyphs.
    public var textShadow: NSShadow?

    public init(baseSize: CGFloat, textColor: NSColor = .labelColor, secondaryColor: NSColor = .secondaryLabelColor,
                accentColor: NSColor = .controlAccentColor, textBand: NSColor? = nil, textShadow: NSShadow? = nil) {
        self.baseSize = baseSize
        self.textColor = textColor
        self.secondaryColor = secondaryColor
        self.accentColor = accentColor
        self.textBand = textBand
        self.textShadow = textShadow
    }
}

public struct Heading: Equatable, Sendable {
    /// Character offset where the heading paragraph starts in the rendered text.
    public let location: Int
    public let level: Int
    public let text: String
}

public struct RenderedDocument {
    public let text: NSAttributedString
    /// Headings in document order.
    public let headings: [Heading]
}

/// Renders the subset of Markdown that matters for reading notes aloud:
/// headings, lists, checkboxes, quotes, tables, rules, fenced code and inline emphasis.
public enum MarkdownRenderer {
    public static func render(_ markdown: String, style: RenderStyle) -> RenderedDocument {
        var renderer = Renderer(style: style)
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            renderer.consume(String(line))
        }
        return renderer.finish()
    }
}

private struct Renderer {
    let style: RenderStyle
    let out = NSMutableAttributedString()
    var headings: [Heading] = []
    var inCodeBlock = false
    var spaceBefore: CGFloat = 0
    /// One-column table holding consecutive quote paragraphs, one row each, so
    /// they draw as one continuous bar. (A plain NSTextBlock only applies to its
    /// first paragraph and draws no border in TextKit 1.)
    var quoteTable: NSTextTable?
    var quoteRows = 0
    /// An empty ">" line: a paragraph break inside the current quote.
    var quoteGap = false
    // Paragraphs inside blocks take no paragraphSpacingBefore (it misaligns
    // table rows); spacing goes into block margins and padding instead.
    /// Consecutive "|" lines, rendered as a table once the run ends.
    var tableLines: [String] = []

    var base: CGFloat { style.baseSize }
    var bodyFont: NSFont { .systemFont(ofSize: base) }

    init(style: RenderStyle) {
        self.style = style
    }

    mutating func consume(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if !inCodeBlock, trimmed.hasPrefix("|") {
            tableLines.append(trimmed)
            return
        }
        flushTable()
        if inCodeBlock || !trimmed.hasPrefix(">") { quoteTable = nil }

        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            inCodeBlock.toggle()
            return
        }
        if inCodeBlock {
            let font = NSFont.monospacedSystemFont(ofSize: base * 0.85, weight: .regular)
            append(NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: style.textColor.withAlphaComponent(0.85)]),
                   paragraph: paragraph())
            return
        }
        if trimmed.isEmpty {
            if out.length > 0 { spaceBefore = max(spaceBefore, base * 0.6) }
            return
        }
        if let (level, text) = heading(trimmed) {
            // A bare "##" (e.g. mid-stream, before its text arrives) has nothing to show.
            guard !text.isEmpty else { return }
            let scale: [CGFloat] = [1.5, 1.3, 1.15, 1.05, 1.0, 1.0]
            let font = NSFont.systemFont(ofSize: base * scale[level - 1], weight: level <= 2 ? .bold : .semibold)
            if out.length > 0 { spaceBefore = max(spaceBefore, base * 0.9) }
            let rendered = inline(text, font: font, color: style.textColor)
            headings.append(Heading(location: out.length, level: level, text: rendered.string))
            append(rendered, paragraph: paragraph())
            spaceBefore = base * 0.25
            return
        }
        if isRule(trimmed) {
            let para = paragraph()
            para.alignment = .center
            spaceBefore = max(spaceBefore, base * 0.4)
            append(NSAttributedString(string: "·  ·  ·", attributes: [.font: bodyFont, .foregroundColor: style.secondaryColor]),
                   paragraph: para)
            spaceBefore = base * 0.4
            return
        }
        if trimmed.hasPrefix(">") {
            let text = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            let table: NSTextTable
            if let quoteTable {
                table = quoteTable
            } else {
                table = NSTextTable()
                table.numberOfColumns = 1
                table.setContentWidth(100, type: .percentageValueType)
                table.setWidth(takeSpaceBefore(), type: .absoluteValueType, for: .margin, edge: .minY)
                quoteTable = table
                quoteRows = 0
                quoteGap = false
            }
            guard !text.isEmpty else {
                quoteGap = quoteRows > 0
                return
            }
            let cell = NSTextTableBlock(table: table, startingRow: quoteRows, rowSpan: 1, startingColumn: 0, columnSpan: 1)
            cell.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            cell.setBorderColor(style.accentColor, for: .minX)
            cell.setWidth(base * 0.7, type: .absoluteValueType, for: .padding, edge: .minX)
            cell.setWidth(quoteGap ? base * 0.5 : 1, type: .absoluteValueType, for: .padding, edge: .minY)
            cell.setWidth(1, type: .absoluteValueType, for: .padding, edge: .maxY)
            quoteRows += 1
            quoteGap = false
            append(inline(text, font: bodyFont, color: style.textColor), paragraph: blockParagraph(cell))
            return
        }
        if let item = listItem(line) {
            appendListItem(item)
            return
        }
        append(inline(trimmed, font: bodyFont, color: style.textColor), paragraph: paragraph())
    }

    mutating func finish() -> RenderedDocument {
        flushTable()
        if out.string.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return RenderedDocument(text: out, headings: headings)
    }

    // MARK: - Blocks

    private mutating func takeSpaceBefore() -> CGFloat {
        defer { spaceBefore = 0 }
        return spaceBefore
    }

    private func blockParagraph(_ block: NSTextBlock) -> NSMutableParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.15
        para.textBlocks = [block]
        return para
    }

    private mutating func flushTable() {
        guard !tableLines.isEmpty else { return }
        let lines = tableLines
        tableLines = []
        guard lines.count >= 2, Self.isTableSeparator(lines[1]) else {
            // Not a table after all: show the lines as written.
            for line in lines { append(inline(line, font: bodyFont, color: style.textColor), paragraph: paragraph()) }
            return
        }
        let rows = ([lines[0]] + lines.dropFirst(2)).map(Self.tableCells)
        let columns = rows[0].count
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        table.setWidth(takeSpaceBefore(), type: .absoluteValueType, for: .margin, edge: .minY)

        let cellFont = NSFont.systemFont(ofSize: base * 0.9)
        let headerFont = NSFont.systemFont(ofSize: base * 0.9, weight: .semibold)
        for (row, cells) in rows.enumerated() {
            for column in 0..<columns {
                let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setBorderColor(style.textColor.withAlphaComponent(0.18))
                block.setWidth(base * 0.35, type: .absoluteValueType, for: .padding)
                if row == 0 { block.backgroundColor = style.textColor.withAlphaComponent(0.08) }
                let para = blockParagraph(block)
                let text = column < cells.count ? cells[column] : ""
                append(inline(text, font: row == 0 ? headerFont : cellFont, color: style.textColor), paragraph: para)
            }
        }
        spaceBefore = max(spaceBefore, base * 0.4)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            let compact = cell.replacingOccurrences(of: " ", with: "")
            return compact.count >= 1 && compact.allSatisfy { "-:".contains($0) } && compact.contains("-")
        }
    }

    /// Splits "| a | b |" into ["a", "b"], keeping escaped "\|" inside a cell.
    private static func tableCells(_ line: String) -> [String] {
        var body = Substring(line.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") && !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var current = ""
        var previous: Character?
        for character in body {
            if character == "|" && previous != "\\" {
                cells.append(current)
                current = ""
            } else if character == "|" {
                current.removeLast()
                current.append(character)
            } else {
                current.append(character)
            }
            previous = character
        }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func heading(_ trimmed: String) -> (Int, String)? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Closing hashes ("## Title ##") are decoration.
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    private func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private struct ListItem {
        let indent: Int
        let marker: String
        let text: String
    }

    private func listItem(_ line: String) -> ListItem? {
        var indent = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            indent += line[index] == "\t" ? 4 : 1
            index = line.index(after: index)
        }
        let rest = line[index...]
        guard let space = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
        let token = String(rest[..<space])
        let text = rest[space...].trimmingCharacters(in: .whitespaces)

        let marker: String
        if token == "-" || token == "*" || token == "+" {
            marker = indent == 0 ? "•" : "◦"
        } else if let last = token.last, last == "." || last == ")",
                  (1...3).contains(token.count - 1), token.dropLast().allSatisfy(\.isNumber) {
            marker = token
        } else {
            return nil
        }
        return ListItem(indent: indent, marker: marker, text: text)
    }

    private mutating func appendListItem(_ item: ListItem) {
        var marker = item.marker
        var text = item.text
        for (box, symbol) in [("[ ]", "☐"), ("[x]", "☑"), ("[X]", "☑")] where text.hasPrefix(box + " ") || text == box {
            marker = symbol
            text = String(text.dropFirst(box.count)).trimmingCharacters(in: .whitespaces)
        }

        let indent = CGFloat(item.indent) * base * 0.45
        let markerWidth = base * 1.4
        let para = paragraph()
        para.firstLineHeadIndent = indent
        para.headIndent = indent + markerWidth
        para.tabStops = [NSTextTab(textAlignment: .left, location: indent + markerWidth)]

        let line = NSMutableAttributedString(string: marker + "\t",
                                             attributes: [.font: bodyFont, .foregroundColor: style.secondaryColor])
        line.append(inline(text, font: bodyFont, color: style.textColor))
        append(line, paragraph: para)
    }

    private mutating func paragraph() -> NSMutableParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.15
        para.paragraphSpacingBefore = spaceBefore
        spaceBefore = 0
        return para
    }

    private func append(_ content: NSAttributedString, paragraph: NSParagraphStyle) {
        let line = NSMutableAttributedString(attributedString: content)
        line.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
        line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
        let glyphs = NSRange(location: 0, length: line.length - 1)
        if let band = style.textBand { line.addAttribute(.backgroundColor, value: band, range: glyphs) }
        if let shadow = style.textShadow { line.addAttribute(.shadow, value: shadow, range: glyphs) }
        out.append(line)
    }

    // MARK: - Inline

    private func inline(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    runFont = .monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
                }
                if intent.contains(.stronglyEmphasized) { runFont = withTraits(runFont, .bold) }
                if intent.contains(.emphasized) { runFont = withTraits(runFont, .italic) }
                if intent.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.foregroundColor] = style.secondaryColor
                }
            }
            if run.link != nil {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            attributes[.font] = runFont
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }

    private func withTraits(_ font: NSFont, _ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}

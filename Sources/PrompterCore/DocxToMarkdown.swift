import Foundation

/// Converts a Word `.docx` package to the markdown subset `MarkdownRenderer`
/// reads: headings (the outline), paragraphs, lists, emphasis, quotes and
/// tables. Fonts, colors, images and page layout are dropped on purpose.
///
/// Headings come from paragraph styles (outline level, or a style named
/// "heading N"/"Title", resolved through `basedOn` chains). When a document
/// has no styled heading at all, short all-bold paragraphs larger than the
/// body text are treated as headings, ranked by size.
public enum DocxToMarkdown {
    public enum Failure: Error, Equatable {
        /// The bytes are not a zip package.
        case notZip
        /// The zip package is damaged or uses an unsupported feature.
        case corrupt(String)
        /// No main document part (`word/document.xml`).
        case missingDocument
        case malformedXML(part: String, detail: String)
    }

    public static func convert(docx data: Data) throws -> String {
        let zip = try mapping { try ZipArchive(data: data) }
        let documentPart = mainDocumentPart(in: zip)
        guard let document = try mapping({ try zip.contents(of: documentPart) }) else { throw Failure.missingDocument }
        let directory = documentPart.split(separator: "/").dropLast().joined(separator: "/")
        let prefix = directory.isEmpty ? "" : directory + "/"
        let styles = try mapping { try zip.contents(of: prefix + "styles.xml") }
        let numbering = try mapping { try zip.contents(of: prefix + "numbering.xml") }
        return try convert(documentXML: document, stylesXML: styles, numberingXML: numbering)
    }

    /// The conversion itself, on already extracted parts (used by tests).
    static func convert(documentXML: Data, stylesXML: Data?, numberingXML: Data?) throws -> String {
        let document = try parse(documentXML, part: "word/document.xml")
        let styles = Styles(root: try stylesXML.map { try parse($0, part: "word/styles.xml") })
        let numbering = Numbering(root: try numberingXML.map { try parse($0, part: "word/numbering.xml") })
        var converter = Converter(styles: styles, numbering: numbering)
        return converter.convert(body: document.child("body") ?? document)
    }

    private static func parse(_ data: Data, part: String) throws -> XMLElement {
        do {
            return try XMLElement.parse(data)
        } catch XMLElement.Failure.malformed(let detail) {
            throw Failure.malformedXML(part: part, detail: detail)
        }
    }

    private static func mapping<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch ZipArchive.Failure.notZip {
            throw Failure.notZip
        } catch ZipArchive.Failure.corrupt(let detail) {
            throw Failure.corrupt(detail)
        } catch ZipArchive.Failure.unsupported(let detail) {
            throw Failure.corrupt("unsupported: \(detail)")
        }
    }

    /// The main part named by the package relationships; Word uses word/document.xml.
    private static func mainDocumentPart(in zip: ZipArchive) -> String {
        let fallback = "word/document.xml"
        guard let rels = try? zip.contents(of: "_rels/.rels"), let root = try? XMLElement.parse(rels) else { return fallback }
        for relationship in root.children("Relationship") {
            guard let type = relationship.attributes["Type"], type.hasSuffix("/officeDocument"),
                  var target = relationship.attributes["Target"] else { continue }
            if target.hasPrefix("/") { target.removeFirst() }
            return target
        }
        return fallback
    }
}

// MARK: - Styles and numbering

private struct Style {
    let name: String
    let basedOn: String?
    let outlineLevel: Int?
    let numbering: ListReference?
    let bold: Bool?
    let italic: Bool?
    /// Font size in half-points.
    let size: Int?
}

private struct ListReference {
    let numId: String
    let level: Int
}

private struct Styles {
    private var byId: [String: Style] = [:]
    let defaultSize: Int?

    init(root: XMLElement?) {
        defaultSize = Converter.integer(root?.child("docDefaults")?.child("rPrDefault")?.child("rPr")?.child("sz")?.val, in: Converter.sizeRange)
        for style in root?.children("style") ?? [] {
            guard let id = style.attributes["styleId"] else { continue }
            let pPr = style.child("pPr")
            let rPr = style.child("rPr")
            byId[id] = Style(
                name: style.child("name")?.val ?? "",
                basedOn: style.child("basedOn")?.val,
                outlineLevel: Converter.integer(pPr?.child("outlineLvl")?.val, in: Converter.outlineRange),
                numbering: pPr?.child("numPr").flatMap(Converter.listReference),
                bold: rPr?.child("b").map(Converter.flag),
                italic: rPr?.child("i").map(Converter.flag),
                size: Converter.integer(rPr?.child("sz")?.val, in: Converter.sizeRange))
        }
    }

    /// The styles from `id` up its `basedOn` chain (cycle-safe).
    func chain(_ id: String?) -> [Style] {
        var result: [Style] = []
        var current = id
        var seen: Set<String> = []
        while let id = current, !seen.contains(id), let style = byId[id] {
            seen.insert(id)
            result.append(style)
            current = style.basedOn
        }
        return result
    }

    func resolve<T>(_ id: String?, _ key: KeyPath<Style, T?>) -> T? {
        chain(id).lazy.compactMap { $0[keyPath: key] }.first
    }

    /// Heading level (1...6) of a paragraph style, or nil for body text.
    func headingLevel(of id: String?) -> Int? {
        let chain = chain(id)
        // An outline level anywhere in the chain decides; 9 means body text
        // (Word uses it to keep e.g. "TOC Heading" out of the outline).
        if let level = chain.lazy.compactMap(\.outlineLevel).first {
            return level < 9 ? min(level + 1, 6) : nil
        }
        for style in chain {
            let name = style.name.lowercased()
            if name == "title" { return 1 }
            if name.hasPrefix("heading "), let level = Converter.integer(String(name.dropFirst("heading ".count)), in: 1...9) {
                return min(level, 6)
            }
        }
        return nil
    }

    func isQuote(_ id: String?) -> Bool {
        chain(id).contains { ["quote", "intense quote"].contains($0.name.lowercased()) }
    }
}

private struct ListLevel {
    let format: String
    let start: Int
}

private struct Numbering {
    private var abstractLevels: [String: [Int: ListLevel]] = [:]
    private var abstractOf: [String: String] = [:]
    private var overrides: [String: [Int: ListLevel]] = [:]

    init(root: XMLElement?) {
        for abstract in root?.children("abstractNum") ?? [] {
            guard let id = abstract.attributes["abstractNumId"] else { continue }
            abstractLevels[id] = Self.levels(in: abstract)
        }
        for num in root?.children("num") ?? [] {
            guard let id = num.attributes["numId"] else { continue }
            abstractOf[id] = num.child("abstractNumId")?.val
            var levels: [Int: ListLevel] = [:]
            for override in num.children("lvlOverride") {
                guard let index = Converter.integer(override.attributes["ilvl"], in: Converter.listLevelRange) else { continue }
                if let lvl = override.child("lvl") {
                    levels[index] = Self.level(lvl)
                } else if let start = Converter.integer(override.child("startOverride")?.val, in: Converter.startRange) {
                    let base = abstractOf[id].flatMap { abstractLevels[$0]?[index] }
                    levels[index] = ListLevel(format: base?.format ?? "decimal", start: start)
                }
            }
            overrides[id] = levels
        }
    }

    func level(numId: String, index: Int) -> ListLevel? {
        if let level = overrides[numId]?[index] { return level }
        guard let abstract = abstractOf[numId] else { return nil }
        return abstractLevels[abstract]?[index]
    }

    private static func levels(in element: XMLElement) -> [Int: ListLevel] {
        var result: [Int: ListLevel] = [:]
        for lvl in element.children("lvl") {
            guard let index = Converter.integer(lvl.attributes["ilvl"], in: Converter.listLevelRange) else { continue }
            result[index] = level(lvl)
        }
        return result
    }

    private static func level(_ lvl: XMLElement) -> ListLevel {
        ListLevel(format: lvl.child("numFmt")?.val ?? "decimal",
                  start: Converter.integer(lvl.child("start")?.val, in: Converter.startRange) ?? 1)
    }
}

// MARK: - Document model

private struct Span {
    var text: String
    var bold: Bool
    var italic: Bool
    var strike: Bool

    var hasFormat: Bool { bold || italic || strike }
    func sameFormat(as other: Span) -> Bool { bold == other.bold && italic == other.italic && strike == other.strike }
}

private struct Paragraph {
    var spans: [Span] = []
    var styleId: String?
    /// Direct `outlineLvl` on the paragraph.
    var outlineLevel: Int?
    var list: ListReference?
    /// Non-blank characters per font size (half-points), for the heading fallback.
    var sizeWeights: [Int: Int] = [:]
    var allBold = true

    var plainText: String { spans.map(\.text).joined() }
    var isBlank: Bool { plainText.allSatisfy(\.isWhitespace) }
    var dominantSize: Int? { sizeWeights.max { $0.value < $1.value }?.key }
}

private enum Block {
    case paragraph(Paragraph)
    /// Rows of cells, each cell already inline markdown.
    case table([[String]])
}

// MARK: - Converter

private struct Converter {
    let styles: Styles
    let numbering: Numbering
    private var counters: [String: [Int: Int]] = [:]

    init(styles: Styles, numbering: Numbering) {
        self.styles = styles
        self.numbering = numbering
    }

    mutating func convert(body: XMLElement) -> String {
        var blocks: [Block] = []
        collect(body, into: &blocks)
        let levels = headingLevels(for: blocks)

        var lines: [String] = []
        /// Identity of the list the previous line belonged to, if any.
        var previousList: String?
        for (index, block) in blocks.enumerated() {
            switch block {
            case .table(let rows):
                guard let first = rows.first else { continue }
                if !lines.isEmpty { lines.append("") }
                lines.append("| " + first.joined(separator: " | ") + " |")
                lines.append("|" + String(repeating: " --- |", count: first.count))
                for row in rows.dropFirst() {
                    lines.append("| " + row.joined(separator: " | ") + " |")
                }
                previousList = nil
            case .paragraph(let paragraph):
                guard !paragraph.isBlank else { continue }
                if let level = levels[index] {
                    if !lines.isEmpty { lines.append("") }
                    let plain = paragraph.spans.map { Span(text: $0.text, bold: false, italic: false, strike: false) }
                    lines.append(String(repeating: "#", count: min(max(level, 1), 6)) + " " + Self.inline(plain, singleLine: true))
                    previousList = nil
                } else if let item = listItem(paragraph) {
                    if !lines.isEmpty, previousList != item.list { lines.append("") }
                    let text = Self.escapeBlockStart(Self.inline(item.spans, singleLine: true))
                    lines.append(String(repeating: " ", count: max(item.level, 0) * 4) + item.marker + " " + text)
                    previousList = item.list
                } else {
                    if !lines.isEmpty { lines.append("") }
                    let quote = styles.isQuote(paragraph.styleId)
                    for line in Self.inline(paragraph.spans, singleLine: false).split(separator: "\n", omittingEmptySubsequences: false) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if quote {
                            lines.append(trimmed.isEmpty ? ">" : "> " + Self.escapeBlockStart(trimmed))
                        } else if !trimmed.isEmpty {
                            lines.append(Self.escapeBlockStart(trimmed))
                        }
                    }
                    previousList = nil
                }
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private struct ListItem {
        let list: String
        let level: Int
        let marker: String
        let spans: [Span]
    }

    /// A Word list paragraph, or one that starts with a typed bullet glyph or
    /// a number and a tab (what textutil and pasted text produce).
    private mutating func listItem(_ paragraph: Paragraph) -> ListItem? {
        if let list = paragraph.list {
            guard let marker = marker(for: list) else { return nil }
            return ListItem(list: list.numId, level: list.level, marker: marker, spans: paragraph.spans)
        }
        let text = paragraph.plainText
        let body = text.drop { $0.isWhitespace }
        guard let first = body.first else { return nil }
        let marker: String
        var markerEnd = body.index(after: body.startIndex)
        if "•◦▪●○■‣".contains(first) {
            marker = "-"
        } else if first.isNumber {
            let digits = body.prefix { $0.isNumber }
            guard digits.count <= 3, body.dropFirst(digits.count).first == "\t" else { return nil }
            marker = digits + "."
            markerEnd = body.index(body.startIndex, offsetBy: digits.count)
        } else {
            return nil
        }
        guard markerEnd < body.endIndex, body[markerEnd].isWhitespace else { return nil }
        let prefix = text.distance(from: text.startIndex, to: markerEnd)
        var spans: [Span] = []
        var remaining = prefix
        for span in paragraph.spans {
            if remaining >= span.text.count {
                remaining -= span.text.count
            } else {
                var copy = span
                copy.text = String(span.text.dropFirst(remaining))
                remaining = 0
                spans.append(copy)
            }
        }
        return ListItem(list: marker == "-" ? "typed bullet" : "typed number", level: 0, marker: marker, spans: spans)
    }

    // MARK: Collecting blocks

    private func collect(_ element: XMLElement, into blocks: inout [Block]) {
        for child in element.children {
            switch child.name {
            case "p": blocks.append(.paragraph(paragraph(child)))
            case "tbl": blocks.append(.table(table(child)))
            case "sdt": if let content = child.child("sdtContent") { collect(content, into: &blocks) }
            case "del", "moveFrom", "sectPr", "altChunk", "pPr", "tblPr", "tblGrid", "trPr", "tcPr": continue
            default: collect(child, into: &blocks)
            }
        }
    }

    private func paragraph(_ p: XMLElement) -> Paragraph {
        let pPr = p.child("pPr")
        var paragraph = Paragraph()
        paragraph.styleId = pPr?.child("pStyle")?.val
        paragraph.outlineLevel = Self.integer(pPr?.child("outlineLvl")?.val, in: Self.outlineRange)
        let list = pPr?.child("numPr").flatMap(Self.listReference) ?? styles.resolve(paragraph.styleId, \.numbering)
        if let list, list.numId != "0" { paragraph.list = list }
        let paragraphBold = styles.resolve(paragraph.styleId, \.bold) ?? false
        let paragraphSize = styles.resolve(paragraph.styleId, \.size) ?? styles.defaultSize ?? 22
        collectRuns(p, into: &paragraph, paragraphBold: paragraphBold, paragraphSize: paragraphSize)
        return paragraph
    }

    private func collectRuns(_ element: XMLElement, into paragraph: inout Paragraph, paragraphBold: Bool, paragraphSize: Int) {
        for child in element.children {
            switch child.name {
            case "r":
                run(child, into: &paragraph, paragraphBold: paragraphBold, paragraphSize: paragraphSize)
            case "sdt":
                if let content = child.child("sdtContent") {
                    collectRuns(content, into: &paragraph, paragraphBold: paragraphBold, paragraphSize: paragraphSize)
                }
            case "oMath", "oMathPara":
                let text = mathText(child)
                if !text.isEmpty { paragraph.spans.append(Span(text: text, bold: false, italic: false, strike: false)) }
            case "pPr", "del", "moveFrom", "proofErr", "bookmarkStart", "bookmarkEnd", "commentRangeStart", "commentRangeEnd":
                continue
            default:
                // hyperlink, ins, moveTo, smartTag, fldSimple, customXml, dir, bdo
                collectRuns(child, into: &paragraph, paragraphBold: paragraphBold, paragraphSize: paragraphSize)
            }
        }
    }

    private func mathText(_ element: XMLElement) -> String {
        element.children.map { $0.name == "t" ? $0.text : mathText($0) }.joined()
    }

    private func run(_ r: XMLElement, into paragraph: inout Paragraph, paragraphBold: Bool, paragraphSize: Int) {
        let rPr = r.child("rPr")
        if let vanish = rPr?.child("vanish"), Self.flag(vanish) { return }
        let characterStyle = rPr?.child("rStyle")?.val
        var bold = styles.resolve(characterStyle, \.bold) ?? false
        var italic = styles.resolve(characterStyle, \.italic) ?? false
        var size = styles.resolve(characterStyle, \.size) ?? paragraphSize
        if let b = rPr?.child("b") { bold = Self.flag(b) }
        if let i = rPr?.child("i") { italic = Self.flag(i) }
        if let sz = Self.integer(rPr?.child("sz")?.val, in: Self.sizeRange) { size = sz }
        let strike = (rPr?.child("strike")).map(Self.flag) ?? (rPr?.child("dstrike")).map(Self.flag) ?? false

        var text = ""
        for child in r.children {
            switch child.name {
            case "t": text += child.text
            case "tab": text += "\t"
            case "br": text += child.attributes["type"] == "page" ? "" : "\n"
            case "cr": text += "\n"
            case "noBreakHyphen": text += "-"
            case "sym":
                // Symbol-font characters live in the private use area; nothing readable to show.
                if let hex = child.attributes["char"], let value = UInt32(hex, radix: 16),
                   !(0xF000...0xF0FF).contains(value), let scalar = Unicode.Scalar(value) {
                    text.append(Character(scalar))
                }
            default: continue // rPr, drawing, pict, footnoteReference, instrText, delText, fldChar, lastRenderedPageBreak
            }
        }
        guard !text.isEmpty else { return }
        paragraph.spans.append(Span(text: text, bold: bold, italic: italic, strike: strike))
        let visible = text.filter { !$0.isWhitespace }.count
        if visible > 0 {
            paragraph.sizeWeights[size, default: 0] += visible
            if !(bold || paragraphBold) { paragraph.allBold = false }
        }
    }

    private func table(_ tbl: XMLElement) -> [[String]] {
        var rows: [[String]] = []
        for tr in Self.descendants(of: tbl, named: "tr", through: ["sdt", "sdtContent", "customXml", "ins", "moveTo"]) {
            let cells = Self.descendants(of: tr, named: "tc", through: ["sdt", "sdtContent", "customXml", "ins", "moveTo"])
            rows.append(cells.map(cellText))
        }
        return rows.filter { !$0.isEmpty }
    }

    private func cellText(_ tc: XMLElement) -> String {
        var blocks: [Block] = []
        collect(tc, into: &blocks)
        var parts: [String] = []
        for block in blocks {
            switch block {
            case .paragraph(let paragraph) where !paragraph.isBlank:
                parts.append(Self.inline(paragraph.spans, singleLine: true, inCell: true))
            case .paragraph:
                continue
            case .table(let rows):
                parts.append(contentsOf: rows.flatMap { $0 }.filter { !$0.isEmpty })
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Children named `name`, looking through wrapper elements in `through`.
    private static func descendants(of element: XMLElement, named name: String, through: Set<String>) -> [XMLElement] {
        element.children.flatMap { child -> [XMLElement] in
            if child.name == name { return [child] }
            if through.contains(child.name) { return descendants(of: child, named: name, through: through) }
            return []
        }
    }

    // MARK: Headings

    /// Heading level per block index: styled headings, else the bold-and-larger fallback.
    private func headingLevels(for blocks: [Block]) -> [Int: Int] {
        var levels: [Int: Int] = [:]
        for (index, block) in blocks.enumerated() {
            guard case .paragraph(let paragraph) = block, !paragraph.isBlank else { continue }
            if let direct = paragraph.outlineLevel {
                if direct < 9 { levels[index] = min(direct + 1, 6) }
            } else if let level = styles.headingLevel(of: paragraph.styleId) {
                levels[index] = level
            }
        }
        guard levels.isEmpty else { return levels }

        var weights: [Int: Int] = [:]
        for case .paragraph(let paragraph) in blocks {
            for (size, weight) in paragraph.sizeWeights { weights[size, default: 0] += weight }
        }
        guard let bodySize = weights.max(by: { $0.value < $1.value })?.key else { return [:] }
        var candidates: [(index: Int, size: Int)] = []
        for (index, block) in blocks.enumerated() {
            guard case .paragraph(let paragraph) = block, !paragraph.isBlank, paragraph.list == nil,
                  paragraph.allBold, !styles.isQuote(paragraph.styleId),
                  let size = paragraph.dominantSize, size > bodySize else { continue }
            let text = paragraph.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count <= 100, !text.contains("\n") else { continue }
            candidates.append((index, size))
        }
        let ranks = Array(Set(candidates.map(\.size)).sorted(by: >).prefix(6))
        for candidate in candidates {
            if let rank = ranks.firstIndex(of: candidate.size) { levels[candidate.index] = rank + 1 }
        }
        return levels
    }

    // MARK: Lists

    private mutating func marker(for list: ListReference) -> String? {
        guard let level = numbering.level(numId: list.numId, index: list.level) else { return "-" }
        switch level.format {
        case "bullet": return "-"
        case "none": return nil
        default:
            var levels = counters[list.numId] ?? [:]
            let count = (levels[list.level] ?? level.start - 1) + 1
            levels[list.level] = count
            for deeper in levels.keys where deeper > list.level { levels[deeper] = nil }
            counters[list.numId] = levels
            return "\(count)."
        }
    }

    static func listReference(_ numPr: XMLElement) -> ListReference? {
        guard let numId = numPr.child("numId")?.val else { return nil }
        return ListReference(numId: numId, level: integer(numPr.child("ilvl")?.val, in: listLevelRange) ?? 0)
    }

    // Numeric attributes come from the file and are not trusted. Out-of-range
    // values read as absent; the ranges are what WordprocessingML allows.
    /// Outline levels 0...8 are headings, 9 is body text.
    static let outlineRange = 0...9
    /// List levels `ilvl` 0...8.
    static let listLevelRange = 0...8
    /// List start numbers; bounded so counters cannot overflow.
    static let startRange = 0...1_000_000
    /// Font sizes in half-points (1638 pt is Word's maximum).
    static let sizeRange = 1...3276

    static func integer(_ value: String?, in range: ClosedRange<Int>) -> Int? {
        guard let value, let number = Int(value.trimmingCharacters(in: .whitespaces)), range.contains(number) else { return nil }
        return number
    }

    /// A toggle property element: present means on unless `val` says otherwise.
    static func flag(_ element: XMLElement) -> Bool {
        !["0", "false", "off"].contains(element.val ?? "1")
    }

    // MARK: Inline markdown

    static func inline(_ spans: [Span], singleLine: Bool, inCell: Bool = false) -> String {
        var merged: [Span] = []
        for span in spans {
            if let last = merged.last, last.sameFormat(as: span) {
                merged[merged.count - 1].text += span.text
            } else {
                merged.append(span)
            }
        }
        var out = ""
        for span in merged {
            var text = span.text
            if singleLine { text = text.replacingOccurrences(of: "\n", with: " ") }
            let escaped = escape(text, inCell: inCell)
            guard span.hasFormat else {
                out += escaped
                continue
            }
            let lead = escaped.prefix { $0.isWhitespace }
            let trail = escaped.reversed().prefix { $0.isWhitespace }
            let core = escaped.dropFirst(lead.count).dropLast(trail.count)
            guard !core.isEmpty else {
                out += escaped
                continue
            }
            let open = (span.strike ? "~~" : "") + (span.bold ? "**" : "") + (span.italic ? "*" : "")
            let close = (span.italic ? "*" : "") + (span.bold ? "**" : "") + (span.strike ? "~~" : "")
            out += lead + open + core + close + String(trail.reversed())
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Escapes inline markdown that Word text may contain by accident.
    static func escape(_ text: String, inCell: Bool) -> String {
        let characters = Array(text)
        var out = ""
        for (index, character) in characters.enumerated() {
            switch character {
            case "\\", "*", "`", "~", "[":
                out += "\\" + String(character)
            case "_":
                let before = index > 0 ? characters[index - 1] : " "
                let after = index + 1 < characters.count ? characters[index + 1] : " "
                let intraword = (before.isLetter || before.isNumber) && (after.isLetter || after.isNumber)
                out += intraword ? "_" : "\\_"
            case "&":
                let rest = characters[(index + 1)...]
                let entity = rest.prefix { $0.isLetter || $0.isNumber || $0 == "#" }
                let isEntity = !entity.isEmpty && rest.dropFirst(entity.count).first == ";"
                out += isEntity ? "\\&" : "&"
            case "|" where inCell:
                out += "\\|"
            default:
                out.append(character)
            }
        }
        return out
    }

    /// Keeps a line that happens to start like a heading, quote, list, table
    /// row or rule from being read as one.
    static func escapeBlockStart(_ line: String) -> String {
        guard let first = line.first else { return line }
        switch first {
        case "#", ">", "|":
            return "\\" + line
        case "-", "+":
            let compact = line.replacingOccurrences(of: " ", with: "")
            let isRule = compact.count >= 3 && compact.allSatisfy { $0 == "-" }
            let isItem = line.count == 1 || line.dropFirst().first.map { $0 == " " || $0 == "\t" } == true
            return isRule || isItem ? "\\" + line : line
        default:
            let digits = line.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else { return line }
            let rest = line.dropFirst(digits.count)
            guard let punctuation = rest.first, punctuation == "." || punctuation == ")" else { return line }
            let after = rest.dropFirst()
            guard after.isEmpty || after.first == " " || after.first == "\t" else { return line }
            return digits + "\\" + rest
        }
    }
}

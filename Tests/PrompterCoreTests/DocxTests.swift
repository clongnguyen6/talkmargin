import AppKit
import Foundation
import Testing
@testable import PrompterCore

/// Fixtures: `word-notes.docx` mirrors Word's own package layout;
/// `direct-format.docx` is textutil output with no styles at all.
/// Sources and rebuild commands: Fixtures/src/README.md.
@MainActor
struct DocxTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "docx", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func markdown(_ name: String) throws -> String {
        try DocxToMarkdown.convert(docx: fixture(name))
    }

    private func rendered(_ name: String) throws -> RenderedDocument {
        MarkdownRenderer.render(try markdown(name), style: RenderStyle(baseSize: 20))
    }

    private func font(in doc: RenderedDocument, of substring: String) -> NSFont? {
        let range = (doc.text.string as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        return doc.text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
    }

    // MARK: Headings and outline

    @Test func styledHeadingsFeedTheOutline() throws {
        let doc = try rendered("word-notes")
        let outline = doc.headings.map { "\($0.level) \($0.text)" }
        #expect(outline == [
            "1 Meeting notes", "1 Opening", "2 Agenda", "2 Custom section", "3 Direct level three",
            "2 Inside a content control", "1 Risks",
        ])
        // Subtitle, "TOC Heading" (outline level 9), a heading inside a table
        // cell and a big bold paragraph are not headings.
        for text in ["Knowledge transfer", "Contents", "Cell heading", "Big bold"] {
            #expect(!doc.headings.contains { $0.text.contains(text) }, "\(text) must not be a heading")
            #expect(doc.text.string.contains(text), "\(text) must still be in the text")
        }
        #expect(Sections.sections(in: doc.headings).map(\.text) == ["Meeting notes", "Opening", "Risks"])
    }

    @Test func boldLargerParagraphsAreHeadingsWhenNothingIsStyled() throws {
        let doc = try rendered("direct-format")
        #expect(doc.headings.map { "\($0.level) \($0.text)" } == ["1 Opening", "2 Agenda"])
        #expect(Sections.sections(in: doc.headings).map(\.text) == ["Agenda"])
    }

    // MARK: Lists

    @Test func listsKeepNestingAndNumbers() throws {
        let lines = try markdown("word-notes").components(separatedBy: "\n")
        let agenda = try #require(lines.firstIndex(of: "## Agenda"))
        #expect(Array(lines[(agenda + 1)...].prefix(17)) == [
            "", "- first", "- second", "    - second point one", "- third", "", "Steps:", "",
            "1. one", "2. two", "    1. two a", "    2. two b", "3. three", "", "5. restart at five", "", "- styled bullet",
        ])
        let text = try rendered("word-notes").text.string
        #expect(text.contains("•\tfirst\n•\tsecond\n◦\tsecond point one\n•\tthird"))
        #expect(text.contains("3.\tthree\n5.\trestart at five\n•\tstyled bullet"))
    }

    @Test func typedBulletsAndNumbersBecomeListItems() throws {
        let lines = try markdown("direct-format").components(separatedBy: "\n")
        #expect(lines.contains("- first"))
        #expect(lines.contains("- second"))
        #expect(lines.contains("1. one"))
        #expect(lines.contains("2. two"))
        #expect(try rendered("direct-format").text.string.contains("•\tfirst\n•\tsecond\n1.\tone\n2.\ttwo"))
    }

    // MARK: Emphasis

    @Test func emphasisMergesRunsAndMovesSpacesOutside() throws {
        let markdown = try markdown("word-notes")
        #expect(markdown.contains("Hello **bold** and *italic* and ~~gone~~ text, **split bold** then **strong** and unbold.\n"))
        let doc = try rendered("word-notes")
        #expect(font(in: doc, of: "split bold")!.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(font(in: doc, of: "italic and")!.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(!font(in: doc, of: "unbold")!.fontDescriptor.symbolicTraits.contains(.bold))
        let gone = (doc.text.string as NSString).range(of: "gone")
        #expect(doc.text.attribute(.strikethroughStyle, at: gone.location, effectiveRange: nil) != nil)
    }

    // MARK: Tables and quotes

    @Test func tablesBecomeMarkdownTables() throws {
        let markdown = try markdown("word-notes")
        #expect(markdown.contains("""
            | Risk | Owner | Note |
            | --- | --- | --- |
            | Latency | An | **High** a \\| b |
            | Cell heading | p1 · p2 |  |
            """))
        let doc = try rendered("word-notes")
        let note = (doc.text.string as NSString).range(of: "High a | b")
        #expect(note.location != NSNotFound)
        let paragraph = doc.text.attribute(.paragraphStyle, at: note.location, effectiveRange: nil) as? NSParagraphStyle
        #expect(paragraph?.textBlocks.first is NSTextTableBlock)
    }

    @Test func quoteStyleBecomesQuote() throws {
        #expect(try markdown("word-notes").contains("\n> Say this slowly.\n"))
    }

    // MARK: Content fidelity

    @Test func wordTextThatLooksLikeMarkdownStaysText() throws {
        let text = try rendered("word-notes").text.string
        for literal in ["# not a heading", "1. not a list", "- not a bullet",
                        "*stars* and a_b and _under_ and R&D and &amp; and [x](y)"] {
            #expect(text.contains(literal))
        }
        #expect(!text.contains("•\tnot a bullet"))
    }

    @Test func revisionsHiddenTextControlsBreaksAndTabs() throws {
        let markdown = try markdown("word-notes")
        #expect(markdown.contains("See the plan and inserted.\n"))
        #expect(!markdown.contains("deleted"))
        #expect(!markdown.contains("hidden"))
        #expect(markdown.contains("## Inside a content control\n"))
        #expect(markdown.contains("\nLine one\nLine two\tafter tab\n"))
    }

    // MARK: Out-of-range numbers

    @Test func outOfRangeLevelsStartsAndSizesDoNotCrash() throws {
        let markdown = try markdown("bad-levels")
        let lines = markdown.components(separatedBy: "\n")
        #expect(lines.first == "# Real heading")
        // Invalid outline levels and heading names mean body text.
        for text in ["Negative outline level", "Outline level twelve", "Outline level overflow", "Outline level text",
                     "Negative style", "Huge heading name", "Minus heading name"] {
            #expect(lines.contains(text), "\(text) must be body text")
        }
        // Invalid list levels fall back to the top level; invalid starts to 1.
        #expect(lines.contains("1. negative list level"))
        #expect(lines.contains("2. list level ninety-nine"))
        #expect(lines.contains("    1. huge start"))
        #expect(lines.contains("1. overflowing override"))
        #expect(lines.contains("3. styled bad list"))
        #expect(lines.contains("- negative num id"))
        #expect(markdown.contains("**negative size** text size"))
        let doc = try rendered("bad-levels")
        #expect(doc.headings.map(\.text) == ["Real heading"])
    }

    @Test func claimedPartSizesAreBounded() throws {
        // Patch the central directory so word/document.xml claims 4 GB uncompressed.
        var data = try fixture("word-notes")
        let name = Data("word/document.xml".utf8)
        let signature = Data([0x50, 0x4B, 0x01, 0x02])
        var cursor = data.startIndex
        var patched = false
        while let hit = data[cursor...].range(of: signature) {
            if data[(hit.lowerBound + 46)...].starts(with: name) {
                data.replaceSubrange((hit.lowerBound + 24)..<(hit.lowerBound + 28), with: [0xF0, 0xFF, 0xFF, 0xFF])
                patched = true
                break
            }
            cursor = hit.upperBound
        }
        #expect(patched)
        #expect { try DocxToMarkdown.convert(docx: data) } throws: { error in
            if case DocxToMarkdown.Failure.corrupt(let detail) = error { return detail.contains("claims") }
            return false
        }
    }

    // MARK: Broken files

    @Test func brokenFilesFailWithAReason() throws {
        #expect(throws: DocxToMarkdown.Failure.notZip) { try DocxToMarkdown.convert(docx: Data()) }
        #expect(throws: DocxToMarkdown.Failure.notZip) { try DocxToMarkdown.convert(docx: Data("# markdown, not docx\n".utf8)) }
        #expect(throws: DocxToMarkdown.Failure.missingDocument) { try DocxToMarkdown.convert(docx: try fixture("no-document")) }

        let truncated = try fixture("word-notes").prefix(2000)
        #expect { try DocxToMarkdown.convert(docx: truncated) } throws: { error in
            if case DocxToMarkdown.Failure.corrupt = error { return true }
            return false
        }
        #expect { try DocxToMarkdown.convert(docx: try fixture("bad-xml")) } throws: { error in
            if case DocxToMarkdown.Failure.malformedXML(let part, _) = error { return part == "word/document.xml" }
            return false
        }
    }
}

private let wordResources = "/Applications/Microsoft Word.app/Contents/Resources"
private let wordTablesTemplate = wordResources + "/en.lproj/Document Elements/Tables.dotx"
private let wordNewsprintTemplate = wordResources + "/QuickStyles/Newsprint.dotx"

/// Real Word output: templates shipped inside Microsoft Word, when it is installed.
@MainActor
struct WordTemplateTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: wordTablesTemplate)))
    func wordTableBuildingBlocksConvert() throws {
        // The building blocks live in the glossary part; the main part is empty.
        let zip = try ZipArchive(data: Data(contentsOf: URL(fileURLWithPath: wordTablesTemplate)))
        let document = try #require(try zip.contents(of: "word/glossary/document.xml"))
        let styles = try zip.contents(of: "word/glossary/styles.xml")
        let markdown = try DocxToMarkdown.convert(documentXML: document, stylesXML: styles, numberingXML: nil)
        let lines = markdown.components(separatedBy: "\n")
        let header = try #require(lines.firstIndex(of: "| Letter name | Uppercase | Lowercase | Letter name | Uppercase | Lowercase |"))
        #expect(lines[header + 1] == "| --- | --- | --- | --- | --- | --- |")
        #expect(lines[header + 2].hasPrefix("| Alpha | Α | α |"))
        let doc = MarkdownRenderer.render(markdown, style: RenderStyle(baseSize: 20))
        let cell = (doc.text.string as NSString).range(of: "Letter name")
        let paragraph = doc.text.attribute(.paragraphStyle, at: cell.location, effectiveRange: nil) as? NSParagraphStyle
        #expect(paragraph?.textBlocks.first is NSTextTableBlock)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: wordNewsprintTemplate)))
    func wordNumberingAndStylesParse() throws {
        let zip = try ZipArchive(data: Data(contentsOf: URL(fileURLWithPath: wordNewsprintTemplate)))
        let numbering = try #require(try zip.contents(of: "word/numbering.xml"))
        #expect(numbering.starts(with: [0xEF, 0xBB, 0xBF]), "Word writes a byte order mark")
        let styles = try zip.contents(of: "word/styles.xml")
        let document = """
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Top</w:t></w:r></w:p>
            <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>bullet</w:t></w:r></w:p>
            <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="11"/></w:numPr></w:pPr><w:r><w:t>number</w:t></w:r></w:p>
            </w:body></w:document>
            """
        // In Newsprint, numId 1 is a bullet list and numId 11 a decimal one.
        let markdown = try DocxToMarkdown.convert(documentXML: Data(document.utf8), stylesXML: styles, numberingXML: numbering)
        #expect(markdown == "# Top\n\n- bullet\n\n1. number\n")
    }
}

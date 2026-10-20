import AppKit
import Testing
@testable import PrompterCore

@MainActor
struct MarkdownRendererTests {
    private func render(_ markdown: String) -> RenderedDocument {
        MarkdownRenderer.render(markdown, style: RenderStyle(baseSize: 20))
    }

    private func font(in doc: RenderedDocument, of substring: String) -> NSFont? {
        let range = (doc.text.string as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        return doc.text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
    }

    @Test func headingsAreRecordedInOrder() {
        let doc = render("# Mở đầu\nxin chào\n\n## Agenda\n- mục 1\n### Chi tiết ###")
        let starts = doc.headings.map { (doc.text.string as NSString).substring(from: $0.location).prefix(8) }
        #expect(starts == ["Mở đầu\nx", "Agenda\n•", "Chi tiết"])
        #expect(doc.headings.map(\.level) == [1, 2, 3])
        #expect(doc.headings.map(\.text) == ["Mở đầu", "Agenda", "Chi tiết"])
        #expect(font(in: doc, of: "Mở đầu")!.pointSize == 30)
    }

    @Test func emptyHeadingIsSkipped() {
        let doc = render("## Tóm tắt\n- x\n\n## ")
        #expect(doc.headings.map(\.text) == ["Tóm tắt"])
        #expect(doc.text.string == "Tóm tắt\n•\tx")
    }

    @Test func hashWithoutSpaceIsNotHeading() {
        let doc = render("#hashtag")
        #expect(doc.headings.isEmpty)
        #expect(doc.text.string == "#hashtag")
    }

    @Test func listsGetMarkersAndCheckboxes() {
        let doc = render("- một\n  * hai\n3. ba\n- [ ] việc\n- [x] xong")
        #expect(doc.text.string == "•\tmột\n◦\thai\n3.\tba\n☐\tviệc\n☑\txong")
    }

    @Test func inlineEmphasisMapsToFontTraits() {
        let doc = render("nói **rõ ràng** và *chậm* với `code`")
        #expect(doc.text.string == "nói rõ ràng và chậm với code")
        #expect(font(in: doc, of: "rõ ràng")!.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(font(in: doc, of: "chậm")!.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(font(in: doc, of: "code")!.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    @Test func codeFencesStayLiteral() {
        let doc = render("```\n# không phải heading\n- không phải list\n```")
        #expect(doc.headings.isEmpty)
        #expect(doc.text.string == "# không phải heading\n- không phải list")
    }

    @Test func blankLinesBecomeParagraphSpacing() {
        let doc = render("một\n\n\nhai")
        #expect(doc.text.string == "một\nhai")
        let location = (doc.text.string as NSString).range(of: "hai").location
        let para = doc.text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as! NSParagraphStyle
        #expect(para.paragraphSpacingBefore > 0)
    }

    private func blocks(in doc: RenderedDocument, at substring: String) -> [NSTextBlock] {
        let location = (doc.text.string as NSString).range(of: substring).location
        return (doc.text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks ?? []
    }

    @Test func consecutiveQuoteLinesShareOneBlockAtFullContrast() {
        let doc = render("> Hi everyone.\n>\n> Toan, go ahead.\n\nafter")
        #expect(doc.text.string == "Hi everyone.\nToan, go ahead.\nafter")
        let first = blocks(in: doc, at: "Hi everyone").first as? NSTextTableBlock
        let second = blocks(in: doc, at: "Toan").first as? NSTextTableBlock
        #expect(first?.table === second?.table && first?.startingRow == 0 && second?.startingRow == 1)
        #expect(blocks(in: doc, at: "after").isEmpty)
        let color = doc.text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == RenderStyle(baseSize: 20).textColor)
        #expect(!font(in: doc, of: "Hi everyone")!.fontDescriptor.symbolicTraits.contains(.italic))
    }

    @Test func tablesBecomeTextTables() {
        let doc = render("| Dòng log | Nói gì |\n|---|:--:|\n| `Processing` | Runs \\| one by one |\nafter")
        #expect(doc.text.string == "Dòng log\nNói gì\nProcessing\nRuns | one by one\nafter")
        let cell = blocks(in: doc, at: "Runs").first as? NSTextTableBlock
        #expect(cell?.startingRow == 1 && cell?.startingColumn == 1 && cell?.table.numberOfColumns == 2)
        #expect(font(in: doc, of: "Nói gì")!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func pipeLinesWithoutSeparatorStayText() {
        let doc = render("| not | a table |")
        #expect(doc.text.string == "| not | a table |")
    }

    @Test func rulesAndQuotes() {
        let doc = render("---\n> trích dẫn")
        #expect(doc.text.string == "·  ·  ·\ntrích dẫn")
    }
}

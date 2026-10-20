import Testing
@testable import PrompterCore

struct SectionsTests {
    private func headings(_ levels: [Int]) -> [Heading] {
        levels.enumerated().map { Heading(location: $0.offset * 10, level: $0.element, text: "h\($0.offset)") }
    }

    @Test func singleTitleUsesSecondLevel() {
        let sections = Sections.sections(in: headings([1, 2, 3, 2, 2]))
        #expect(sections.map(\.text) == ["h1", "h3", "h4"])
    }

    @Test func severalTopLevelHeadingsAreTheSections() {
        #expect(Sections.sections(in: headings([1, 2, 1, 1])).map(\.text) == ["h0", "h2", "h3"])
        #expect(Sections.sections(in: headings([2, 3, 2])).map(\.text) == ["h0", "h2"])
    }

    @Test func titleWithoutSubheadingsIsItsOwnSection() {
        #expect(Sections.sections(in: headings([1])).map(\.text) == ["h0"])
        #expect(Sections.sections(in: []).isEmpty)
    }
}

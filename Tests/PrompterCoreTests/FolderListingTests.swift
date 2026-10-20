import Testing
@testable import PrompterCore

struct FolderListingTests {
    private typealias Entry = FolderListing.Entry

    @Test func foldersFirstThenSupportedFilesSorted() {
        let rows = FolderListing.rows([
            Entry(name: "notes.md", isDirectory: false),
            Entry(name: "zeta", isDirectory: true),
            Entry(name: "Agenda.DOCX", isDirectory: false),
            Entry(name: "alpha", isDirectory: true),
            Entry(name: "script.py", isDirectory: false),
        ], supportedExtensions: ["md", "docx"])
        #expect(rows.map(\.name) == ["alpha", "zeta", "Agenda.DOCX", "notes.md"])
    }

    @Test func hiddenEntriesAreDropped() {
        let rows = FolderListing.rows([
            Entry(name: ".git", isDirectory: true),
            Entry(name: ".secret.md", isDirectory: false),
            Entry(name: "a.md", isDirectory: false),
        ], supportedExtensions: ["md"])
        #expect(rows.map(\.name) == ["a.md"])
    }

    @Test func numbersSortNaturally() {
        let rows = FolderListing.rows([
            Entry(name: "week10.md", isDirectory: false),
            Entry(name: "week2.md", isDirectory: false),
        ], supportedExtensions: ["md"])
        #expect(rows.map(\.name) == ["week2.md", "week10.md"])
    }
}

import Foundation
import Testing
@testable import PrompterCore

struct NotesLoaderTests {
    private func scratch(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mp-notes-\(UUID().uuidString)-\(name)")
    }

    @Test func markdownIsReturnedUnchanged() throws {
        let url = scratch("notes.md")
        let text = "# Mở đầu\n\n- [ ] việc\n\n| a | b |\n|---|---|\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try NotesLoader.load(url)
        #expect(doc.format == .markdown)
        #expect(doc.markdown == text)
    }

    @Test func unknownExtensionsAreReadAsText() throws {
        let url = scratch("notes.txt")
        try "plain".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try NotesLoader.load(url).markdown == "plain")
        #expect(NotesLoader.format(of: URL(fileURLWithPath: "/x/notes.DOCX")) == .docx)
        #expect(NotesLoader.isSupported(URL(fileURLWithPath: "/x/notes.markdown")))
        #expect(!NotesLoader.isSupported(URL(fileURLWithPath: "/x/notes.pages")))
    }

    @Test func docxIsConverted() throws {
        let source = try #require(Bundle.module.url(forResource: "word-notes", withExtension: "docx", subdirectory: "Fixtures"))
        let doc = try NotesLoader.load(source)
        #expect(doc.format == .docx)
        #expect(doc.markdown.hasPrefix("# Meeting notes\n"))
    }

    @Test func errorsAreReadable() throws {
        let missing = scratch("missing.md")
        #expect { try NotesLoader.load(missing) } throws: { error in
            (error as? NotesLoadError)?.errorDescription?.hasPrefix("Không đọc được file") == true
        }
        let fake = scratch("fake.docx")
        try "not a zip".write(to: fake, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fake) }
        #expect { try NotesLoader.load(fake) } throws: { error in
            (error as? NotesLoadError)?.errorDescription == "File không phải định dạng Word .docx (không phải gói zip)."
        }
        let empty = scratch("empty.docx")
        try Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: NotesLoadError.self) { try NotesLoader.load(empty) }
    }
}

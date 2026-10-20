import Foundation

/// What the overlay renders and what Claude receives as the notes.
public struct NotesDocument: Sendable {
    public enum Format: Sendable {
        case markdown
        case docx
    }

    public let url: URL
    public let format: Format
    /// Markdown for `MarkdownRenderer` and for the `<meeting_notes>` sent to Claude.
    public let markdown: String
}

public enum NotesLoadError: LocalizedError {
    case unreadable(URL, underlying: Error)
    case invalidDocx(URL, DocxToMarkdown.Failure)

    public var errorDescription: String? {
        switch self {
        case .unreadable(_, let underlying):
            return tr(.loadUnreadable, underlying.localizedDescription)
        case .invalidDocx(_, let failure):
            switch failure {
            case .notZip:
                return tr(.loadNotZip)
            case .corrupt(let detail):
                return tr(.loadCorrupt, detail)
            case .missingDocument:
                return tr(.loadMissingDocument)
            case .malformedXML(let part, let detail):
                return tr(.loadMalformedXML, part, detail)
            }
        }
    }
}

/// The one entry point that turns a notes file into markdown.
public enum NotesLoader {
    /// Lowercased extensions the loader accepts. Anything else is read as markdown text.
    public static let supportedExtensions = ["md", "markdown", "txt", "docx"]

    /// The notes of a `.docx` with no text. Claude receives it as is, whatever the interface
    /// language; the overlay shows `UIText.Key.emptyDocxNotes` in its place.
    public static let emptyDocxMarkdown = "*(Tài liệu không có nội dung văn bản.)*\n"

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    public static func format(of url: URL) -> NotesDocument.Format {
        url.pathExtension.lowercased() == "docx" ? .docx : .markdown
    }

    /// Reads the file. Markdown is returned as is; `.docx` is converted.
    /// Throws `NotesLoadError`, whose description is ready to show in the overlay.
    public static func load(_ url: URL) throws -> NotesDocument {
        switch format(of: url) {
        case .markdown:
            do {
                return NotesDocument(url: url, format: .markdown, markdown: try String(contentsOf: url, encoding: .utf8))
            } catch {
                throw NotesLoadError.unreadable(url, underlying: error)
            }
        case .docx:
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw NotesLoadError.unreadable(url, underlying: error)
            }
            do {
                let markdown = try DocxToMarkdown.convert(docx: data)
                return NotesDocument(url: url, format: .docx,
                                     markdown: markdown.isEmpty ? emptyDocxMarkdown : markdown)
            } catch let failure as DocxToMarkdown.Failure {
                throw NotesLoadError.invalidDocx(url, failure)
            }
        }
    }
}

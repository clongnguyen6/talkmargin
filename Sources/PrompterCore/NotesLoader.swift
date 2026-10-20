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
            return "Không đọc được file: \(underlying.localizedDescription)"
        case .invalidDocx(_, let failure):
            switch failure {
            case .notZip:
                return "File không phải định dạng Word .docx (không phải gói zip)."
            case .corrupt(let detail):
                return "File .docx bị hỏng hoặc không hỗ trợ: \(detail)"
            case .missingDocument:
                return "File .docx thiếu phần nội dung (word/document.xml)."
            case .malformedXML(let part, let detail):
                return "Nội dung .docx bị hỏng (\(part)): \(detail)"
            }
        }
    }
}

/// The one entry point that turns a notes file into markdown.
public enum NotesLoader {
    /// Lowercased extensions the loader accepts. Anything else is read as markdown text.
    public static let supportedExtensions = ["md", "markdown", "txt", "docx"]

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
                                     markdown: markdown.isEmpty ? "*(Tài liệu không có nội dung văn bản.)*\n" : markdown)
            } catch let failure as DocxToMarkdown.Failure {
                throw NotesLoadError.invalidDocx(url, failure)
            }
        }
    }
}

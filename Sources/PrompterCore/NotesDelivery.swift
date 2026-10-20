import CryptoKit
import Foundation

/// One version of a notes document.
public struct NotesVersion: Codable, Equatable, Sendable {
    public let path: String?
    /// SHA-256 of the full markdown.
    public let digest: String

    public init(path: String?, markdown: String) {
        self.path = path
        digest = SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    init(path: String?, digest: String) {
        self.path = path
        self.digest = digest
    }

    public var name: String { path.map { ($0 as NSString).lastPathComponent } ?? "ghi chú" }

    /// Same document (not necessarily the same version). Unsaved notes are told apart by content.
    func isSameDocument(as other: NotesVersion) -> Bool {
        path == other.path && (path != nil || digest == other.digest)
    }
}

/// What one Claude conversation has been given of the user's notes. Saved with it.
public struct NotesContext: Codable, Equatable, Sendable {
    /// The document Claude was last told is on screen.
    public var current: NotesVersion?
    /// Latest version of each document Claude has, most recent last.
    public var delivered: [NotesVersion] = []

    public init(current: NotesVersion? = nil, delivered: [NotesVersion] = []) {
        self.current = current
        self.delivered = delivered
    }
}

/// What to tell Claude about the notes with the next question.
public struct NotesPlan: Sendable {
    public enum Kind: Equatable, Sendable {
        /// Claude already has these notes as the current document.
        case none
        /// The whole document (first time, new document, or too many edits).
        case full
        /// A diff against the copy Claude has.
        case update
        /// A document Claude already has, unchanged; a short notice is enough.
        case switchBack
    }

    public let kind: Kind
    /// Prepended to the question; nil when nothing needs saying.
    public let message: String?
    /// The context once Claude has received `message`. Commit it only after a successful turn.
    public let context: NotesContext
    /// The text Claude then has for this version, to diff later edits against.
    public let sentText: String?
}

/// Decides how the notes on screen reach a conversation that may already hold
/// other documents or older versions, without resending what it has.
public enum NotesDelivery {
    /// Longest notes text sent, in characters.
    public static let limit = 60_000

    /// - Parameters:
    ///   - hasHistory: the conversation already has turns, so it may hold notes not recorded in `context`
    ///     (conversations saved before this was tracked, or after a compaction).
    ///   - sentText: the text Claude was given for a version digest, if still known.
    public static func plan(path: String?, markdown: String, context: NotesContext, hasHistory: Bool,
                            sentText: (String) -> String?) -> NotesPlan {
        guard !markdown.isEmpty else { return NotesPlan(kind: .none, message: nil, context: context, sentText: nil) }
        let version = NotesVersion(path: path, markdown: markdown)
        let text = String(markdown.prefix(limit))
        var next = context
        next.current = version
        next.delivered.removeAll { $0.isSameDocument(as: version) }
        next.delivered.append(version)

        if context.current == version {
            return NotesPlan(kind: .none, message: nil, context: context, sentText: nil)
        }
        let switching = context.current.map { !$0.isSameDocument(as: version) } ?? hasHistory
        let held = context.delivered.last { $0.isSameDocument(as: version) }

        if held == version {
            let message = "[Notes switched: the user is reading \(version.name) again, unchanged since you received it earlier in this conversation. Answer from it.]"
            return NotesPlan(kind: .switchBack, message: message, context: next, sentText: nil)
        }
        if let held, let old = sentText(held.digest) {
            let diff = NotesDiff.render(from: old, to: text)
            if diff.isEmpty {
                // Edited past the part Claude was sent.
                return NotesPlan(kind: .none, message: nil, context: next, sentText: text)
            }
            if diff.count <= text.count / 2 {
                let lead = switching
                    ? "[Notes switched: the user is reading \(version.name) again, which you received earlier; it has been edited since.]"
                    : "[Notes edited: the user changed \(version.name), which is on screen.]"
                let message = """
                \(lead) Apply these changes to your copy; line numbers are in the new version, "-" removed, "+" added, " " unchanged. Answer from the result.
                <meeting_notes_diff path="\(attribute(path))">
                \(diff)
                </meeting_notes_diff>
                """
                return NotesPlan(kind: .update, message: message, context: next, sentText: text)
            }
        }

        var parts: [String] = []
        if held != nil {
            parts.append("[Notes updated: the user edited \(version.name). This full copy replaces the one you have. Answer from it.]")
        } else if switching {
            let from = context.current.map { " instead of \($0.name)" } ?? ""
            parts.append("[Notes switched: the user is now reading \(version.name)\(from). Answer from these notes. Earlier notes and discussion in this conversation stay valid background.]")
        }
        var block = "<meeting_notes path=\"\(attribute(path))\">\n\(text)\n"
        if text.count < markdown.count {
            let shownLines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            let allLines = markdown.split(separator: "\n", omittingEmptySubsequences: false).count
            block += "[Truncated: only the first \(shownLines) of \(allLines) lines are included.]\n"
        }
        parts.append(block + "</meeting_notes>")
        return NotesPlan(kind: .full, message: parts.joined(separator: "\n"), context: next, sentText: text)
    }

    /// True when Claude already has these notes as the current document.
    public static func isCurrent(path: String?, markdown: String, in context: NotesContext?) -> Bool {
        markdown.isEmpty || context?.current == NotesVersion(path: path, markdown: markdown)
    }

    private static func attribute(_ path: String?) -> String {
        (path ?? "").replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Compact line diff for telling Claude about edits.
public enum NotesDiff {
    /// Hunks with one line of context, headed by the line number in `new`.
    /// Empty when the texts are equal.
    public static func render(from old: String, to new: String, context: Int = 1) -> String {
        let a = old.split(separator: "\n", omittingEmptySubsequences: false)
        let b = new.split(separator: "\n", omittingEmptySubsequences: false)
        let difference = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        guard !removed.isEmpty || !inserted.isEmpty else { return "" }

        // Edit script: (marker, text, line in new where the op sits).
        var ops: [(mark: Character, text: Substring, line: Int)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                ops.append(("-", a[i], j)); i += 1
            } else if j < b.count, inserted.contains(j) {
                ops.append(("+", b[j], j)); j += 1
            } else {
                ops.append((" ", b[j], j)); i += 1; j += 1
            }
        }

        let changed = ops.indices.filter { ops[$0].mark != " " }
        var hunks: [String] = []
        var start = changed[0], end = changed[0]
        func flush() {
            let lo = max(start - context, 0), hi = min(end + context, ops.count - 1)
            var lines = ["@@ line \(ops[lo].line + 1)"]
            lines += ops[lo...hi].map { "\($0.mark)\($0.text)" }
            hunks.append(lines.joined(separator: "\n"))
        }
        for index in changed.dropFirst() {
            if index - end > 2 * context + 1 {
                flush()
                start = index
            }
            end = index
        }
        flush()
        return hunks.joined(separator: "\n")
    }
}

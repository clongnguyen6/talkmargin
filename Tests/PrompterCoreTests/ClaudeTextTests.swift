import CryptoKit
import Foundation
import Testing
@testable import PrompterCore

/// What reaches Claude never depends on the interface language.
struct ClaudeTextTests {
    private func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Everything the app adds to a Claude request, built under one interface language.
    private func claudeInputs() -> [String] {
        let notes = "# Plan\n\n" + (1...20).map { "- point \($0)" }.joined(separator: "\n") + "\n"
        let full = NotesDelivery.plan(path: "/notes/a.md", markdown: notes, context: NotesContext(), hasHistory: false) { _ in nil }
        let edited = notes + "- three\n"
        let update = NotesDelivery.plan(path: "/notes/a.md", markdown: edited, context: full.context, hasHistory: true) { _ in notes }
        let other = NotesDelivery.plan(path: "/notes/b.md", markdown: "# B\n", context: full.context, hasHistory: true) { _ in nil }
        let back = NotesDelivery.plan(path: "/notes/a.md", markdown: notes, context: other.context, hasHistory: true) { _ in notes }
        let unsaved = NotesDelivery.plan(path: nil, markdown: notes, context: NotesContext(), hasHistory: true) { _ in nil }
        return [
            ClaudeText.systemPrompt,
            ClaudeText.prompt("What next?", notes: full.message),
            ClaudeText.prompt("What next?", notes: update.message),
            ClaudeText.prompt("What next?", notes: back.message),
            ClaudeText.prompt("What next?", notes: unsaved.message),
            ClaudeText.prompt("What next?", notes: nil),
            ClaudeText.forkName(sessionTitle: "Kestrel prep"),
            ClaudeText.forkName(sessionTitle: ClaudeText.untitledSession),
            ClaudeText.transcript(others: "What is the plan?", mine: "trả lời giúp tôi"),
            ClaudeText.transcript(others: "What is the plan?", mine: ""),
            ClaudeText.transcript(others: "", mine: "hello"),
            NotesLoader.emptyDocxMarkdown,
            NotesVersion(path: nil, markdown: notes).name,
        ]
    }

    @Test func identicalInBothLanguages() {
        let byLanguage = UILanguage.allCases.map { language in UIText.$override.withValue(language) { claudeInputs() } }
        #expect(byLanguage.count == 2)
        #expect(byLanguage[0] == byLanguage[1])
        // The plans above really carry notes, diffs and notices.
        let inputs = byLanguage[0]
        #expect(inputs[1].contains("<meeting_notes path=\"/notes/a.md\">"))
        #expect(inputs[2].contains("<meeting_notes_diff"))
        #expect(inputs[3].contains("again, unchanged"))
    }

    /// The same text as before the interface could be English (SHA-256 of main's literals).
    @Test func unchangedFromBefore() {
        #expect(sha256(ClaudeText.systemPrompt) == "60d614da02d5dc4deac19f11e2b83012d7e0c9006cc80902a5edc0591e8a55d0")
        #expect(sha256(ClaudeText.answerLanguage) == "5acef7587c21b0d9ca4fb1abf157d6dbfe6c94438d16f92baca25b8ec29c0676")
        #expect(ClaudeText.prompt("Q", notes: "N") == "N\n\nQ\n\n" + ClaudeText.answerLanguage)
        #expect(ClaudeText.prompt("Q", notes: nil) == "Q\n\n" + ClaudeText.answerLanguage)
        #expect(ClaudeText.forkName(sessionTitle: "T") == "🎙 Meeting · T")
        #expect(ClaudeText.untitledSession == "Session không tên")
        #expect(ClaudeText.transcript(others: "a", mine: "b") == "Others: a\nTôi: b")
        #expect(ClaudeText.transcript(others: "a", mine: "") == "Others: a")
        #expect(ClaudeText.transcript(others: "", mine: "b") == "b")
        #expect(NotesLoader.emptyDocxMarkdown == "*(Tài liệu không có nội dung văn bản.)*\n")
        #expect(NotesVersion(path: nil, markdown: "x").name == "ghi chú")
    }

    // MARK: - Source check

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources")

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.sources.appending(path: path), encoding: .utf8)
    }

    @Test func claudeTextNeverReadsTheLanguage() throws {
        let code = try source("PrompterCore/ClaudeText.swift").split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        #expect(code.firstMatch(of: /\btr\(|UIText|UILanguage/) == nil)
    }

    @Test func theChatSendsClaudeText() throws {
        let chat = try source("MeetingPrompter/ClaudeChat.swift")
        #expect(chat.contains("systemPrompt: ClaudeText.systemPrompt, prompt: ClaudeText.prompt(question, notes: plan.message)"))
        #expect(chat.contains("ClaudeText.forkName(sessionTitle: $0.title)"))
        #expect(try source("MeetingPrompter/Transcribers.swift").contains("ClaudeText.transcript(others: others, mine: mine)"))
        // The catalog's fallback title is part of fork names; only its display is translated.
        #expect(try source("MeetingPrompter/ClaudeSessions.swift").contains("?? ClaudeText.untitledSession"))
    }
}

import Foundation
import Testing
@testable import PrompterCore

struct NotesDeliveryTests {
    /// Plays one conversation: plans each question and commits it, as ClaudeChat does after a successful turn.
    struct Fork {
        var context = NotesContext()
        var hasHistory = false
        var texts: [String: String] = [:]

        mutating func ask(_ path: String?, _ markdown: String, succeeds: Bool = true) -> NotesPlan {
            let plan = NotesDelivery.plan(path: path, markdown: markdown, context: context, hasHistory: hasHistory) { texts[$0] }
            if succeeds {
                context = plan.context
                hasHistory = true
                if let text = plan.sentText { texts[NotesVersion(path: path, markdown: markdown).digest] = text }
            }
            return plan
        }
    }

    let docA = (1...40).map { "A line \($0)" }.joined(separator: "\n")
    let docB = "# Topic B\n\nThe answer is 42."

    @Test func firstQuestionSendsPlainNotes() throws {
        var fork = Fork()
        let plan = fork.ask("/n/a.md", docA)
        #expect(plan.kind == .full)
        let message = try #require(plan.message)
        #expect(message.hasPrefix("<meeting_notes path=\"/n/a.md\">\nA line 1\n"))
        #expect(!message.contains("[Notes"))
        #expect(fork.ask("/n/a.md", docA).kind == .none)
    }

    @Test func switchingSendsNewDocumentAndKeepsTheOld() throws {
        var fork = Fork()
        _ = fork.ask("/n/a.md", docA)
        let plan = fork.ask("/n/b.md", docB)
        #expect(plan.kind == .full)
        let message = try #require(plan.message)
        #expect(message.contains("now reading b.md instead of a.md"))
        #expect(message.contains("The answer is 42."))
        #expect(fork.context.current?.path == "/n/b.md")
        #expect(fork.context.delivered.map(\.path) == ["/n/a.md", "/n/b.md"])
    }

    @Test func switchingBackToAnUnchangedDocumentOnlySaysSo() throws {
        var fork = Fork()
        _ = fork.ask("/n/a.md", docA)
        _ = fork.ask("/n/b.md", docB)
        let plan = fork.ask("/n/a.md", docA)
        #expect(plan.kind == .switchBack)
        let message = try #require(plan.message)
        #expect(message.contains("a.md again, unchanged"))
        #expect(!message.contains("A line 1"))
        #expect(fork.context.delivered.map(\.path) == ["/n/b.md", "/n/a.md"])
    }

    @Test func smallEditSendsADiff() throws {
        var fork = Fork()
        _ = fork.ask("/n/a.md", docA)
        let edited = docA.replacingOccurrences(of: "A line 20", with: "A line twenty")
        let plan = fork.ask("/n/a.md", edited)
        #expect(plan.kind == .update)
        let message = try #require(plan.message)
        #expect(message.contains("[Notes edited: the user changed a.md"))
        #expect(message.contains("@@ line 19\n A line 19\n-A line 20\n+A line twenty\n A line 21"))
        #expect(!message.contains("A line 5\n"))
        #expect(fork.ask("/n/a.md", edited).kind == .none)
    }

    @Test func editedDocumentSwitchedBackToGetsADiffWithTheSwitchNotice() throws {
        var fork = Fork()
        _ = fork.ask("/n/a.md", docA)
        _ = fork.ask("/n/b.md", docB)
        let plan = fork.ask("/n/a.md", docA + "\nA line 41")
        #expect(plan.kind == .update)
        #expect(plan.message?.contains("reading a.md again, which you received earlier; it has been edited since") == true)
    }

    @Test func largeEditOrUnknownCopyResendsInFull() throws {
        var fork = Fork()
        _ = fork.ask("/n/a.md", docA)
        let rewritten = (1...40).map { "Rewritten \($0)" }.joined(separator: "\n")
        let plan = fork.ask("/n/a.md", rewritten)
        #expect(plan.kind == .full)
        #expect(plan.message?.hasPrefix("[Notes updated: the user edited a.md. This full copy replaces") == true)

        // After a relaunch the sent text is no longer known.
        fork.texts = [:]
        #expect(fork.ask("/n/a.md", rewritten + "\nmore").kind == .full)
    }

    @Test func failedTurnIsNotCommitted() {
        var fork = Fork()
        #expect(fork.ask("/n/a.md", docA, succeeds: false).kind == .full)
        #expect(fork.ask("/n/a.md", docA).kind == .full)
    }

    @Test func conversationWithUntrackedHistoryIsToldTheseAreCurrent() throws {
        // A conversation saved before notes were tracked, or after a compaction reset.
        var fork = Fork(hasHistory: true)
        let message = try #require(fork.ask("/n/b.md", docB).message)
        #expect(message.hasPrefix("[Notes switched: the user is now reading b.md. Answer from these notes."))
    }

    @Test func emptyNotesSendNothingAndKeepContext() {
        var fork = Fork()
        _ = fork.ask("/n/a.md", docA)
        let plan = fork.ask(nil, "")
        #expect(plan.kind == .none && plan.message == nil)
        #expect(fork.context.current?.path == "/n/a.md")
    }

    @Test func unsavedNotesAreToldApartByContent() {
        var fork = Fork()
        _ = fork.ask(nil, "first")
        #expect(fork.ask(nil, "second").kind == .full)
        #expect(fork.ask(nil, "first").kind == .switchBack)
    }

    @Test func longNotesAreCutAndSaySo() throws {
        let long = (1...20_000).map { "line \($0)" }.joined(separator: "\n")
        var fork = Fork()
        let plan = fork.ask("/n/long.md", long)
        let message = try #require(plan.message)
        #expect(plan.sentText?.count == NotesDelivery.limit)
        #expect(message.contains("[Truncated: only the first "))
        #expect(message.contains(" of 20000 lines are included.]"))
        // An edit beyond the cut changes nothing Claude was sent.
        let plan2 = fork.ask("/n/long.md", long + "\nline 20001")
        #expect(plan2.kind == .none && plan2.message == nil)
        #expect(NotesDelivery.isCurrent(path: "/n/long.md", markdown: long + "\nline 20001", in: fork.context))
    }

    @Test func contextDecodesWhenMissingFromOldFiles() throws {
        struct Saved: Codable { var notes: NotesContext? }
        #expect(try JSONDecoder().decode(Saved.self, from: Data("{}".utf8)).notes == nil)
        var fork = Fork()
        _ = fork.ask("/n/a.md", docA)
        let data = try JSONEncoder().encode(Saved(notes: fork.context))
        #expect(try JSONDecoder().decode(Saved.self, from: data).notes == fork.context)
    }

    @Test func diffGroupsNearbyChanges() {
        let old = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj"
        let new = "a\nB\nc\nd\ne\nf\ng\nh\nI\nj\nk"
        #expect(NotesDiff.render(from: old, to: new) == "@@ line 1\n a\n-b\n+B\n c\n@@ line 8\n h\n-i\n+I\n j\n+k")
        #expect(NotesDiff.render(from: old, to: old) == "")
    }
}

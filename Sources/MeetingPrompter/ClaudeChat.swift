import Foundation
import PrompterCore

/// Questions to Claude Code during a meeting, answered by a read-only fork of
/// the session the user linked, so the original session is never touched.
/// Conversations are saved, and the latest one for the linked session is
/// restored at launch so it can be read and continued.
///
/// Notes: each question carries whatever the conversation lacks of the notes on
/// screen when it was asked (`NotesDelivery`): the whole document, a diff of
/// edits, or a notice that the user switched back to a document it already has.
/// Switching documents never changes the linked session or the conversation shown.
@MainActor
final class ClaudeChat {
    private typealias Turn = Conversation.Turn
    typealias Notes = (path: String?, markdown: String)

    private let runner = ClaudeRunner()
    private let store: ConversationStore
    /// The notes on screen; empty markdown when no document is open.
    private let notes: () -> Notes

    private var conversation = Conversation()
    /// False until the first conversation is shown (restored at launch).
    private var isShowing = false
    /// Origin session picked by the user.
    var link: ClaudeSession? { conversation.link }
    /// The fork this conversation continues on; created by the first question.
    private var forkID: String? {
        get { conversation.forkID }
        set { conversation.forkID = newValue }
    }
    private var turns: [Turn] {
        get { conversation.turns }
        set { conversation.turns = newValue }
    }
    /// Questions waiting for the current turn, with the notes on screen when asked.
    private var queue: [(question: String, notes: Notes)] = []
    private var activeTurn: Int?
    /// Notes text sent to Claude by version digest, for diffing later edits (this launch only).
    private var sentTexts: [String: String] = [:]

    /// Called whenever the chat should be re-rendered.
    var onChange: (() -> Void)?

    init(store: ConversationStore = ConversationStore(), notes: @escaping () -> Notes) {
        self.store = store
        self.notes = notes
    }

    var hasConversation: Bool { !turns.isEmpty }
    /// A question is being answered; linking, opening and resetting are refused meanwhile.
    var isBusy: Bool { activeTurn != nil }

    /// The document Claude was last told is on screen in this conversation.
    var notesInContext: NotesVersion? { conversation.notes?.current }
    /// False when the next question will carry the notes on screen (new document or edits).
    var hasCurrentNotes: Bool {
        let notes = notes()
        return NotesDelivery.isCurrent(path: notes.path, markdown: notes.markdown, in: conversation.notes)
    }

    /// Where to continue this conversation in a terminal: the fork, in the linked repo.
    var terminalSession: (id: String, cwd: String)? {
        guard let link, let forkID else { return nil }
        return (forkID, link.cwd)
    }

    /// Name of the fork in `claude --resume`, so it is not mistaken for the original.
    private var forkName: String? {
        link.map { ClaudeText.forkName(sessionTitle: $0.title) }
    }

    /// Forks this app made for meeting conversations. Not sessions to answer from: the
    /// user picks the prepared session they came from.
    var meetingForkIDs: Set<String> {
        Set(store.conversations.compactMap(\.forkID) + [forkID].compactMap { $0 })
    }

    /// Links a session and shows its latest conversation, if any; re-picking the
    /// linked session keeps the conversation shown (`ConversationChoice`). Returns
    /// false (and changes nothing) while a question is being answered.
    @discardableResult
    func link(to session: ClaudeSession?) -> Bool {
        guard activeTurn == nil else { return false }
        if ConversationChoice.linkShowsLatest(isShowing: isShowing, linked: link?.id, chosen: session?.id) {
            show(store.latest(for: session) ?? Conversation(link: session))
        }
        return true
    }

    /// Starts a new conversation (the current one stays saved): the next question
    /// forks the linked session afresh.
    @discardableResult
    func reset() -> Bool {
        guard activeTurn == nil else { return false }
        show(Conversation(link: link))
        return true
    }

    /// Past conversations, newest first, for reopening.
    var savedConversations: [Conversation] { store.conversations }
    var currentConversationID: UUID { conversation.id }

    /// Session last used with this document, to suggest in a picker; never applied by itself.
    func suggestedSession(forDocument path: String) -> ClaudeSession? {
        store.latestSession(forDocument: path)
    }

    /// Reopens a saved conversation; returns its session so the caller can relink.
    @discardableResult
    func open(_ id: UUID) -> ClaudeSession? {
        guard activeTurn == nil, let saved = store.conversation(id) else { return link }
        show(saved)
        return saved.link
    }

    private func show(_ next: Conversation) {
        conversation = next
        isShowing = true
        queue = []
        onChange?()
    }

    private func persist() {
        conversation.updated = Date()
        store.save(conversation)
    }

    func ask(_ question: String) {
        queue.append((question, notes()))
        runNext()
    }

    private func runNext() {
        guard activeTurn == nil, !queue.isEmpty else { return }
        let (question, notes) = queue.removeFirst()
        let firstLine = question.split(separator: "\n").first.map(String.init) ?? question
        let short = firstLine.count > 48 ? String(firstLine.prefix(48)).trimmingCharacters(in: .whitespaces) + "…" : firstLine
        let time = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        // Planned before the turn is added, so a first question on a saved conversation counts its history.
        let plan = NotesDelivery.plan(path: notes.path, markdown: notes.markdown, context: conversation.notes ?? NotesContext(),
                                      hasHistory: !turns.isEmpty) { [sentTexts] in sentTexts[$0] }
        let version = notes.markdown.isEmpty ? nil : NotesVersion(path: notes.path, markdown: notes.markdown)
        // No status until Claude streams something: the chat then shows `chatAsking` in the current language.
        turns.append(Turn(title: "❓ \(short) · \(time)", quote: short == question ? nil : question, notes: version))
        let index = turns.count - 1
        activeTurn = index
        persist()
        onChange?()
        var compacted = false

        let isNewFork = forkID == nil && link != nil
        let request = ClaudeRunner.Request(
            workingDirectory: link.map { URL(fileURLWithPath: $0.cwd) } ?? Self.scratchDirectory,
            resume: forkID ?? link?.id, fork: isNewFork,
            systemPrompt: ClaudeText.systemPrompt, prompt: ClaudeText.prompt(question, notes: plan.message), readOnlyTools: link != nil,
            name: isNewFork ? forkName : nil)
        runner.run(request) { [weak self] event in
            guard let self else { return }
            switch event {
            case .session(let id):
                forkID = id
            case .text(let text):
                turns[index].answer += text
                turns[index].status = nil
            case .tool(let detail):
                turns[index].status = "🔎 \(detail)"
            case .compacted:
                compacted = true
            case .finished(let error):
                turns[index].status = nil
                turns[index].error = error
                // Claude has the notes only once the turn went through; a compacted fork may have lost them.
                if error == nil {
                    conversation.notes = compacted ? NotesContext() : plan.context
                    if let version, let text = plan.sentText { sentTexts[version.digest] = text }
                } else if compacted {
                    conversation.notes = NotesContext()
                }
                activeTurn = nil
                persist()
                runNext()
            }
            onChange?()
        }
    }

    // MARK: - Rendering

    var title: String {
        link.map { "Claude · \(($0.cwd as NSString).lastPathComponent)" } ?? "Claude"
    }

    /// Title of the newest turn, which the overlay keeps pinned at the top.
    var pinnedTitle: String? { turns.last?.title }

    var markdown: String {
        guard !turns.isEmpty else { return Self.emptyPage(link: link) }
        var shownNotes: NotesVersion?
        return turns.indices.map { index in
            let turn = turns[index]
            var block = "## \(turn.title)\n\n"
            // Names the document when it changes, so it is clear what each answer was based on.
            if let notes = turn.notes, notes.path != shownNotes?.path {
                block += "_📄 \(notes.path.map { ($0 as NSString).lastPathComponent } ?? tr(.chatUntitledNotes))_\n\n"
                shownNotes = notes
            }
            if let quote = turn.quote { block += Self.quoted(quote) + "\n\n" }
            if !turn.answer.isEmpty { block += Self.demoteHeadings(Self.clean(turn.answer)) + "\n\n" }
            if let status = turn.status ?? (index == activeTurn && turn.answer.isEmpty ? tr(.chatAsking) : nil) {
                block += "_\(status)_\n\n"
            }
            if let error = turn.error { block += "> ⚠️ \(error)\n" }
            return block
        }.joined(separator: "\n---\n\n")
    }

    private static func quoted(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
    }

    /// Drops Claude Code's internal citation markup (e.g. `<cc-memory …>`), keeping the text.
    private static func clean(_ answer: String) -> String {
        answer.replacingOccurrences(of: #"</?cc-[a-z-]+[^>]*>"#, with: "", options: .regularExpression)
    }

    /// Nests the answer's own headings under the turn title ("## x" becomes "### x").
    private static func demoteHeadings(_ answer: String) -> String {
        var inCode = false
        return answer.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle() }
            guard !inCode, trimmed.hasPrefix("#"), !trimmed.hasPrefix("######") else { return String(line) }
            return "#" + trimmed
        }.joined(separator: "\n")
    }

    private static func emptyPage(link: ClaudeSession?) -> String {
        let session = link.map { tr(.chatEmptyLinked, $0.displayTitle, $0.cwd) } ?? tr(.chatEmptyNotLinked)
        return tr(.chatEmptyPage, session)
    }

    private static let scratchDirectory: URL = {
        let url = FileManager.default.temporaryDirectory.appending(path: "MeetingPrompter")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

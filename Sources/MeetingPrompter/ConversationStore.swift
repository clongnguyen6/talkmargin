import Foundation
import os
import PrompterCore

/// One chat with Claude, persisted so it survives restarts and can be continued.
struct Conversation: Codable, Identifiable {
    struct Turn: Codable {
        let title: String
        /// The full question, shown under a shortened title.
        let quote: String?
        var answer = ""
        var error: String?
        /// Progress shown while answering; never saved.
        var status: String?
        /// The notes on screen when the question was asked.
        var notes: NotesVersion?

        private enum CodingKeys: String, CodingKey {
            case title, quote, answer, error, notes
        }
    }

    var id = UUID()
    var link: ClaudeSession?
    /// The fork this conversation continues on; created by its first question.
    var forkID: String?
    var turns: [Turn] = []
    var updated = Date()
    /// What the fork has of the notes; nil for conversations saved before this was tracked.
    var notes: NotesContext?

    /// Documents the questions were asked against, in first-use order.
    var documents: [NotesVersion] {
        turns.compactMap(\.notes).reduce(into: []) { list, version in
            if !list.contains(where: { $0.path == version.path }) { list.append(version) }
        }
    }

    /// Document paths as `NotesPath.lexical` (no disk at launch), so conversations saved with
    /// `/private/tmp/…` still match the document on screen.
    func withLexicalPaths() -> Conversation {
        var copy = self
        copy.turns = turns.map { turn in
            var turn = turn
            turn.notes = turn.notes?.mapPath(NotesPath.lexical)
            return turn
        }
        copy.notes = notes?.mapPaths(NotesPath.lexical)
        return copy
    }

    /// First question, for listing past conversations.
    var summary: String {
        turns.first.map { $0.quote ?? $0.title } ?? "Cuộc trò chuyện trống"
    }
}

/// Saves conversations to Application Support, newest first, keeping the most recent ones.
@MainActor
final class ConversationStore {
    private static let limit = 50
    private let log = Logger(subsystem: "MeetingPrompter", category: "conversations")
    private let file: URL
    private(set) var conversations: [Conversation] = []
    /// False when the saved file could not be read nor moved aside: never write over it.
    private var canSave = true

    /// `file` defaults to this build's folder in Application Support (`AppIdentity.dataFolderName`); tests pass a scratch file.
    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: AppIdentity.current.dataFolderName).appending(path: "conversations.json")
        do {
            try FileManager.default.createDirectory(at: self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            log.error("Could not create the conversations folder: \(error.localizedDescription)")
        }
        switch StoreFile.load([Conversation].self, from: self.file, decoder: .store) {
        case .value(let saved):
            conversations = saved.map { $0.withLexicalPaths() }
        case .missing:
            break
        case .setAside(let aside, let error):
            log.error("Unreadable conversations moved to \(aside.path): \(error.localizedDescription)")
        case .locked(let error):
            canSave = false
            log.error("Unreadable conversations left in place, not saving this launch: \(error.localizedDescription)")
        }
    }

    /// Adds or updates `conversation` (empty ones are not kept) and writes the file.
    func save(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        if !conversation.turns.isEmpty { conversations.insert(conversation, at: 0) }
        conversations = Array(conversations.prefix(Self.limit))
        guard canSave else { return }
        do {
            try JSONEncoder.store.encode(conversations).write(to: file, options: .atomic)
        } catch {
            log.error("Could not save conversations: \(error.localizedDescription)")
        }
    }

    /// The most recent conversation with this session (or with none).
    func latest(for link: ClaudeSession?) -> Conversation? {
        conversations.first { $0.link?.id == link?.id }
    }

    /// The session of the latest conversation that used this document. A hint only:
    /// never relink on it without the user choosing.
    func latestSession(forDocument path: String) -> ClaudeSession? {
        conversations.first { $0.link != nil && $0.turns.contains { $0.notes?.path == path } }?.link
    }

    func conversation(_ id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }
}

private extension JSONEncoder {
    static let store: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

private extension JSONDecoder {
    static let store: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

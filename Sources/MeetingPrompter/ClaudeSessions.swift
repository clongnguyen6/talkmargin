import Foundation

struct ClaudeSession: Equatable, Sendable, Codable {
    let id: String
    /// Directory the session was started in, used as the working directory when resuming.
    let cwd: String
    let title: String
    let modified: Date
}

extension ClaudeSession {
    /// Name prefix of the read-only forks the chat creates, as `claude --resume` lists them.
    static let meetingForkPrefix = "🎙 Meeting · "

    /// A fork this app made for a meeting conversation: by its name, or by a fork id
    /// a saved conversation recorded (in case the name was changed).
    func isMeetingFork(knownForks: Set<String>) -> Bool {
        title.hasPrefix(Self.meetingForkPrefix) || knownForks.contains(id)
    }
}

struct ClaudeProject: Sendable {
    let cwd: String
    let sessions: [ClaudeSession]
    var name: String { (cwd as NSString).lastPathComponent }

}

/// Reads Claude Code's local session transcripts (~/.claude/projects/*/<id>.jsonl).
enum ClaudeSessionCatalog {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")

    /// Most recently used projects first, each with its most recent sessions: `all` for the
    /// menu, and `prepared` without the app's meeting forks for the session picker. Forks
    /// share their origin's project and are newer, so they are skipped before the limit,
    /// or they would push the prepared session out of the list.
    static func recentProjects(projectLimit: Int = 8, sessionLimit: Int = 8,
                               knownForks: Set<String> = []) -> (all: [ClaudeProject], prepared: [ClaudeProject]) {
        let fm = FileManager.default
        guard let directories = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return ([], []) }

        var all: [String: [ClaudeSession]] = [:]
        var prepared: [String: [ClaudeSession]] = [:]
        for directory in directories {
            let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let recent = files
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { url -> (URL, Date)? in
                    guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
                    return (url, date)
                }
                .sorted { $0.1 > $1.1 }
            var seenAll = 0, seenPrepared = 0
            // Bounded: a project full of forks does not read every transcript.
            for (url, date) in recent.prefix(sessionLimit * 4) where seenAll < sessionLimit || seenPrepared < sessionLimit {
                guard let session = session(at: url, modified: date) else { continue }
                if seenAll < sessionLimit {
                    all[session.cwd, default: []].append(session)
                    seenAll += 1
                }
                if seenPrepared < sessionLimit, !session.isMeetingFork(knownForks: knownForks) {
                    prepared[session.cwd, default: []].append(session)
                    seenPrepared += 1
                }
            }
        }
        return (projects(all, projectLimit: projectLimit, sessionLimit: sessionLimit),
                projects(prepared, projectLimit: projectLimit, sessionLimit: sessionLimit))
    }

    private static func projects(_ byCwd: [String: [ClaudeSession]], projectLimit: Int, sessionLimit: Int) -> [ClaudeProject] {
        byCwd
            .map { ClaudeProject(cwd: $0.key, sessions: Array($0.value.sorted { $0.modified > $1.modified }.prefix(sessionLimit))) }
            .sorted { ($0.sessions.first?.modified ?? .distantPast) > ($1.sessions.first?.modified ?? .distantPast) }
            .prefix(projectLimit)
            .map { $0 }
    }

    /// Reads only the head (for cwd and the first prompt) and the tail (for the
    /// latest title), since transcripts can be many megabytes.
    private static func session(at url: URL, modified: Date) -> ClaudeSession? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunk = 256 * 1024
        let head = (try? handle.read(upToCount: chunk)) ?? Data()
        let size = (try? handle.seekToEnd()) ?? 0
        var tail = Data()
        if size > UInt64(chunk) {
            try? handle.seek(toOffset: size - UInt64(chunk))
            tail = (try? handle.readToEnd()) ?? Data()
        }

        let headLines = jsonLines(head)
        guard let cwd = headLines.lazy.compactMap({ $0["cwd"] as? String }).first else { return nil }
        let title = (jsonLines(tail) + headLines).reversed().lazy.compactMap(Self.title(from:)).first
            ?? headLines.lazy.compactMap(Self.firstPrompt(from:)).first
            ?? "Session không tên"
        return ClaudeSession(id: url.deletingPathExtension().lastPathComponent, cwd: cwd, title: title, modified: modified)
    }

    private static func jsonLines(_ data: Data) -> [[String: Any]] {
        data.split(separator: UInt8(ascii: "\n")).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any]
        }
    }

    private static func title(from line: [String: Any]) -> String? {
        switch line["type"] as? String {
        case "custom-title": line["customTitle"] as? String
        case "ai-title": line["aiTitle"] as? String
        case "summary": line["summary"] as? String
        default: nil
        }
    }

    private static func firstPrompt(from line: [String: Any]) -> String? {
        guard line["type"] as? String == "user", line["isMeta"] as? Bool != true,
              let message = line["message"] as? [String: Any] else { return nil }
        let text: String? = if let content = message["content"] as? String {
            content
        } else {
            (message["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        guard let text, !text.hasPrefix("<") else { return nil }
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }
}

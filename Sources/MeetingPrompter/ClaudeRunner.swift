import Foundation
import os

/// Runs one headless Claude Code turn (`claude -p`) and streams its output.
@MainActor
final class ClaudeRunner {
    struct Request {
        let workingDirectory: URL
        /// Session to continue; nil starts a new one.
        let resume: String?
        /// Branch off `resume` into a new session instead of appending to it.
        let fork: Bool
        let systemPrompt: String
        let prompt: String
        /// Allow Read/Grep/Glob; otherwise no tools at all.
        let readOnlyTools: Bool
        /// Display name for a new or forked session, shown in `claude --resume`.
        var name: String?
    }

    enum Event: Sendable {
        case session(String)
        case text(String)
        case tool(String)
        /// Claude Code compacted the conversation; earlier messages are now a summary.
        case compacted
        case finished(error: String?)
    }

    private let log = Logger(subsystem: "MeetingPrompter", category: "claude")
    private var process: Process?

    var isRunning: Bool { process?.isRunning ?? false }

    func cancel() {
        process?.terminate()
    }

    func run(_ request: Request, onEvent: @escaping @MainActor (Event) -> Void) {
        guard let executable = Self.claudeExecutable else {
            onEvent(.finished(error: "Không tìm thấy lệnh `claude`. Cài Claude Code hoặc thêm nó vào PATH."))
            return
        }
        var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                         "--strict-mcp-config", "--append-system-prompt", request.systemPrompt]
        if let resume = request.resume {
            arguments += ["--resume", resume]
            if request.fork { arguments.append("--fork-session") }
        }
        if let name = request.name {
            arguments += ["--name", name]
        }
        if request.readOnlyTools {
            arguments += ["--tools", "Read,Grep,Glob", "--allowedTools", "Read,Grep,Glob"]
        } else {
            arguments += ["--tools", ""]
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = request.workingDirectory
        process.environment = Self.environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // DispatchQueue.main keeps events in order, which separate Tasks would not guarantee.
        let parser = StreamParser { event in
            DispatchQueue.main.async { MainActor.assumeIsolated { onEvent(event) } }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                parser.consume(data)
            }
        }
        process.terminationHandler = { [weak self] finished in
            let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Drain what is left on stdout before deciding whether a result arrived.
                    stdout.fileHandleForReading.readabilityHandler = nil
                    parser.consume(stdout.fileHandleForReading.readDataToEndOfFile())
                    if !parser.sawResult {
                        let detail = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        onEvent(.finished(error: detail.isEmpty ? "claude thoát với mã \(status)." : String(detail.suffix(600))))
                    }
                    self?.process = nil
                }
            }
        }

        do {
            try process.run()
            self.process = process
            stdin.fileHandleForWriting.write(Data(request.prompt.utf8))
            try stdin.fileHandleForWriting.close()
        } catch {
            onEvent(.finished(error: error.localizedDescription))
        }
    }

    // MARK: - Environment

    /// PATH from the user's login shell, so `claude` and any hooks it runs resolve
    /// the same way as in a terminal (apps launched from Finder get a minimal PATH).
    private static let environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: environment["SHELL"] ?? "/bin/zsh")
        shell.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        if (try? shell.run()) != nil {
            shell.waitUntilExit()
            if let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), !path.isEmpty {
                environment["PATH"] = path
            }
        }
        return environment
    }()

    static let claudeExecutable: URL? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
            + ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }()
}

/// Turns stream-json lines into events. Called from the pipe's reader thread.
private final class StreamParser: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var hasText = false
    private var resultSeen = false
    private let emit: (ClaudeRunner.Event) -> Void

    var sawResult: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resultSeen
    }

    init(emit: @escaping (ClaudeRunner.Event) -> Void) {
        self.emit = emit
    }

    func consume(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] {
                handle(object)
            }
        }
    }

    private func handle(_ object: [String: Any]) {
        switch object["type"] as? String {
        case "system" where object["subtype"] as? String == "init":
            if let id = object["session_id"] as? String { emit(.session(id)) }
        case "system" where object["subtype"] as? String == "compact_boundary":
            emit(.compacted)
        case "stream_event":
            guard let event = object["event"] as? [String: Any] else { return }
            switch event["type"] as? String {
            case "message_start" where hasText:
                emit(.text("\n\n"))
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    hasText = true
                    emit(.text(text))
                }
            default:
                break
            }
        case "assistant":
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_use" {
                let name = block["name"] as? String ?? "tool"
                let input = block["input"] as? [String: Any] ?? [:]
                let target = (input["file_path"] ?? input["pattern"] ?? input["path"]) as? String
                emit(.tool(target.map { "\(name) \($0)" } ?? name))
            }
        case "result":
            resultSeen = true
            let isError = object["is_error"] as? Bool ?? false
            emit(.finished(error: isError ? (object["result"] as? String ?? "Lỗi không rõ") : nil))
        default:
            break
        }
    }
}

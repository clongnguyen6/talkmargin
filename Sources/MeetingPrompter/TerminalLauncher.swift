import AppKit

/// Hands a `claude --resume` command to the user's terminal: the command goes on
/// the clipboard and the terminal comes to the front, ready for a new tab and paste.
@MainActor
enum TerminalLauncher {
    private static let terminals = ["com.mitchellh.ghostty", "com.apple.Terminal"]

    static func resume(sessionID: String, in directory: String) {
        let claude = ClaudeRunner.claudeExecutable?.path ?? "claude"
        let command = "cd \(shellQuoted(directory)) && \(shellQuoted(claude)) --resume \(sessionID)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)

        for bundleID in terminals {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                running.activate()
                return
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

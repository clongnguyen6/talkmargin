import AppKit
import PrompterCore

/// The system open dialog for notes files, enabling exactly what `NotesLoader`
/// reads (a content-type filter would also admit every plain-text type), kept out
/// of screen sharing and brief about focus.
///
/// Keyboard: macOS activates an app only for user interaction it is handling
/// (cooperative activation). A right-⌥ shortcut is consumed by the tap and never
/// reaches the app as an event, and the dialog starts from a timer, so activation
/// is refused there (D6). The dialog is therefore a non-activating panel, like the
/// overlay's question box: it takes the keyboard while the meeting app stays
/// frontmost, and the keyboard goes back to that app when it closes.
@MainActor
enum OpenNotesDialog {
    private static var isScheduled = false
    /// The app that had the keyboard before the dialog.
    private static var previous: NSRunningApplication?
    private(set) static var isRunning = false

    /// Runs the dialog once the current run loop pass is over, then calls `chosen` with the file.
    /// Callers may be a shortcut action, delivered as a run loop block with others behind it:
    /// a modal loop started inside that block would hold those back (and keep the shortcut tap
    /// swallowing every right-⌥ key) until the dialog closed. A timer starts outside any block.
    static func present(startingAt directory: URL?, above overlay: OverlayPanel, chosen: @escaping @MainActor (URL) -> Void) {
        guard !isScheduled, !isRunning else { return }
        isScheduled = true
        // Best effort, in the caller's context (a click or menu choice is user interaction;
        // from the timer it was refused). The dialog takes the keyboard either way.
        let front = NSWorkspace.shared.frontmostApplication
        previous = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        NSApp.activate()
        let start = Timer(timeInterval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                isScheduled = false
                if let url = run(startingAt: directory, above: overlay) { chosen(url) }
            }
        }
        RunLoop.main.add(start, forMode: .common)
    }

    /// `overlay` is lowered under the dialog while it is up: `runModal` (via
    /// `beginModalSession`) forces the dialog to the `.modalPanel` level (8), so a
    /// level set on the dialog is overwritten and it would sit under the overlay
    /// at `.statusBar` (25). Dropping the overlay to `.floating` (3) meanwhile keeps
    /// it visible with the dialog on top; its level is restored afterwards.
    /// Only from a timer, event or menu callback; use `present` elsewhere.
    private static func run(startingAt directory: URL?, above overlay: OverlayPanel) -> URL? {
        // Shortcuts still run while the dialog is up; a second dialog would nest modal loops.
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }
        let panel = NSOpenPanel()
        panel.styleMask.insert(.nonactivatingPanel)
        let filter = SupportedNotesFilter()
        panel.delegate = filter
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = directory
        panel.sharingType = OverlayPanel.captureSharingType
        let overlayLevel = overlay.level
        overlay.level = .floating
        defer { overlay.level = overlayLevel }
        let result = panel.runModal() == .OK ? panel.url : nil
        // As the question box does: if the app did activate, this hands activation back;
        // if not, the meeting app is still frontmost and gets the keyboard back as the dialog closes.
        previous?.activate()
        previous = nil
        withExtendedLifetime(filter) {}
        return result
    }
}

/// Folders stay enabled for navigation; files follow `NotesLoader.isSupported`.
private final class SupportedNotesFilter: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return true }
        return NotesLoader.isSupported(url)
    }
}

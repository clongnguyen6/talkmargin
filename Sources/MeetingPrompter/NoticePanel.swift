import AppKit

/// A short notice for a launch that does not start (another copy runs, the lock is unusable).
/// Non-activating and not modal: the meeting app keeps the keyboard, nothing blocks the main
/// thread (the launch's timers keep running), and it is excluded from screen capture like the
/// overlay. Closes on OK or after `timeout`, then calls `done` once.
@MainActor
final class NoticePanel: NSPanel {
    private var done: (() -> Void)?

    static func show(_ text: String, timeout: Double, done: @escaping () -> Void) -> NoticePanel {
        let panel = NoticePanel(text: text)
        panel.done = done
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak panel] in
            MainActor.assumeIsolated { panel?.close(reason: "timeout") }
        }
        return panel
    }

    private init(text: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 140),
                   styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "TalkMargin"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        sharingType = OverlayPanel.captureSharingType
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        let ok = HeaderButton(title: "OK", target: nil, action: nil)
        ok.bezelStyle = .rounded
        ok.target = self
        ok.action = #selector(okClicked)
        let stack = NSStackView(views: [label, ok])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 20, bottom: 16, right: 20)
        label.widthAnchor.constraint(equalToConstant: 380).isActive = true
        contentView = stack
        setContentSize(stack.fittingSize)
        if let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screen.midX - frame.width / 2, y: screen.maxY - frame.height - 40))
        }
    }

    // Never the key window: the meeting app keeps the keyboard; the button takes the first click.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    @objc private func okClicked() {
        close(reason: "ok")
    }

    private func close(reason: String) {
        guard let done else { return }
        self.done = nil
        orderOut(nil)
        done()
    }
}

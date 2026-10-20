import AppKit
import PrompterCore

/// A floating panel that stays above every app (including full-screen meeting
/// apps and all Spaces), never steals focus, and is excluded from screen capture.
final class OverlayPanel: NSPanel {
    /// Height of the drag/title strip at the top of the panel.
    static let headerHeight: CGFloat = 28

    /// Called on a double-click in the header strip (outside its buttons).
    var onHeaderDoubleClick: (() -> Void)?
    /// Called before a click lands in an editable text view, which needs the keyboard.
    var onKeyboardRequest: (() -> Void)?
    /// Called with the view under every left mouse-down, before it is delivered.
    var onMouseDown: ((NSView?) -> Void)?

    /// Hidden from screen capture. Only a dev or verification build started with MP_ALLOW_CAPTURE=1 is
    /// capturable (`CapturePolicy`); production ignores it. Every window the app creates uses this.
    static let captureSharingType: NSWindow.SharingType =
        CapturePolicy.allowsCapture(identity: .current, environment: ProcessInfo.processInfo.environment) ? .readOnly : .none

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 220),
                   styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }

        // isFloatingPanel resets the level, so it must be set before `level`.
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        sharingType = Self.captureSharingType

        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        appearance = NSAppearance(named: .vibrantDark)
        minSize = NSSize(width: 280, height: 110)
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    // Handled here rather than via zoom(_:), which depends on the user's
    // title bar double-click preference and on the panel being key.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let content = contentView {
            let hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
            onMouseDown?(hit)
            if event.clickCount == 2, event.locationInWindow.y >= frame.height - Self.headerHeight, !(hit is NSButton) {
                onHeaderDoubleClick?()
                return
            }
            if let textView = hit as? NSTextView, textView.isEditable {
                onKeyboardRequest?()
                makeKey()
            }
        }
        super.sendEvent(event)
    }

    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        0.2
    }

    /// Only while typing a question; otherwise never take keyboard focus from the meeting app.
    var acceptsKeyboard = false

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
}

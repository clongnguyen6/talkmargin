import AppKit

/// Dark rounded box dropped down from the overlay header, drawn inside the overlay
/// window: pickers and the display settings use it instead of popovers or menus,
/// which are separate windows that screen sharing captures. Hidden until shown.
/// Opaque, so the notes never show through whatever the backdrop setting.
/// Size and position constraints of a dropdown must stay below
/// `.windowSizeStayPut`: they hold even while hidden and would grow the window.
class DropdownBox: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 14
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            return shadow
        }()
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

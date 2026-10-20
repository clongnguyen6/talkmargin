import AppKit

/// Shows a hint while the pointer rests on a view, by text inside the panel
/// instead of an AppKit tooltip (a separate window that screen sharing captures).
@MainActor
final class HoverHint: NSResponder {
    var text: String
    private weak var view: NSView?
    private let onChange: (String?) -> Void
    private var tracking: NSTrackingArea?

    init(view: NSView, text: String, onChange: @escaping (String?) -> Void) {
        self.view = view
        self.text = text
        self.onChange = onChange
        super.init()
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        view.addTrackingArea(area)
        tracking = area
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func mouseEntered(with event: NSEvent) {
        guard view?.isHiddenOrHasHiddenAncestor == false else { return }
        onChange(text)
    }

    override func mouseExited(with event: NSEvent) {
        onChange(nil)
    }
}

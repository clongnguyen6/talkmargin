import AppKit

/// Borderless header button that works on the first click, even though the
/// overlay never becomes the key window.
final class HeaderButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Scroll view with a clean top edge and a fading bottom edge. The top band is
/// fully masked, so the line above a line-aligned stop never shows through;
/// the bottom fades so a cut-off last line dissolves.
final class FadingScrollView: NSScrollView {
    static let fadeHeight: CGFloat = 12

    private let fadeMask = CAGradientLayer()
    /// Called when the user scrolls with a trackpad or mouse wheel.
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        fadeMask.colors = [NSColor.clear, .clear, .black, .black, .clear].map(\.cgColor)
        // Location 0 is the top edge.
        fadeMask.startPoint = CGPoint(x: 0.5, y: isFlipped ? 0 : 1)
        fadeMask.endPoint = CGPoint(x: 0.5, y: isFlipped ? 1 : 0)
        layer?.mask = fadeMask
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        let edge = bounds.height > 0 ? Double(Self.fadeHeight / bounds.height) : 0
        fadeMask.locations = [0, edge, edge, 1 - edge, 1].map { NSNumber(value: $0) }
        CATransaction.commit()
    }
}

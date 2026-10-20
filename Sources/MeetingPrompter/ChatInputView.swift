import AppKit

/// Multi-line question box: Enter sends, Shift+Enter adds a line, Esc cancels.
/// Grows with its content up to a few lines.
final class ChatInputView: NSView, NSTextViewDelegate {
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let textView = InputTextView(usingTextLayoutManager: false)
    private let scrollView = NSScrollView()
    private var heightConstraint: NSLayoutConstraint!
    private static let maxLines: CGFloat = 5
    private static let inset = NSSize(width: 8, height: 6)

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            textView.setSelectedRange(NSRange(location: (newValue as NSString).length, length: 0))
            updateHeight()
            textView.needsDisplay = true
        }
    }

    var placeholder: String {
        get { textView.placeholder }
        set {
            textView.placeholder = newValue
            updateHeight()
            textView.needsDisplay = true
        }
    }

    /// While recording, the box shows live text but cannot be edited.
    var isRecording = false {
        didSet {
            textView.isEditable = !isRecording
            layer?.borderColor = (isRecording ? NSColor.systemRed.withAlphaComponent(0.7) : NSColor.white.withAlphaComponent(0.14)).cgColor
        }
    }

    /// The text view that should become first responder.
    var editor: NSView { textView }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        // Dark enough for white text even when the backdrop is see-through.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor

        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        // Completion, correction and replacement bubbles are separate windows that screen sharing captures.
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = Self.inset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.delegate = self
        textView.owner = self

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        heightConstraint = heightAnchor.constraint(equalToConstant: Self.lineHeight + Self.inset.height * 2)
        // Below the window's own size: a short overlay squeezes the box instead of growing.
        heightConstraint.priority = .dragThatCannotResizeWindow
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.lineHeight + Self.inset.height * 2),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightConstraint,
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private static var lineHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: 13)
        return ceil(font.ascender - font.descender + font.leading)
    }

    func textDidChange(_ notification: Notification) {
        updateHeight()
    }

    override func layout() {
        super.layout()
        updateHeight()
    }

    private func updateHeight() {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        // An empty box fits its wrapped placeholder, so the hint is never cut off in a narrow column.
        let shown = textView.string.isEmpty ? textView.placeholderRect.height : layoutManager.usedRect(for: container).height
        let used = max(shown, Self.lineHeight)
        let height = min(used, Self.lineHeight * Self.maxLines) + Self.inset.height * 2
        if abs(heightConstraint.constant - height) > 0.5 { heightConstraint.constant = height }
    }

    fileprivate func submit() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRecording else { return }
        onSubmit?(text)
    }

    fileprivate func cancel() {
        onCancel?()
    }
}

private final class InputTextView: NSTextView {
    weak var owner: ChatInputView?
    var placeholder = ""

    override func keyDown(with event: NSEvent) {
        // Let input methods (e.g. Vietnamese Telex) finish composing first.
        guard !hasMarkedText() else { return super.keyDown(with: event) }
        switch Int(event.keyCode) {
        case 36 where !event.modifierFlags.contains(.shift), 76 where !event.modifierFlags.contains(.shift):
            owner?.submit()
        case 53:
            owner?.cancel()
        default:
            super.keyDown(with: event)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Context menus and the Look Up panel are windows of other processes that screen sharing captures.
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func quickLook(with event: NSEvent) {}

    private var placeholderText: NSAttributedString {
        NSAttributedString(string: placeholder, attributes: [.font: font ?? .systemFont(ofSize: 13),
                                                             .foregroundColor: NSColor.tertiaryLabelColor])
    }

    /// The placeholder wrapped to the text width, in view coordinates.
    var placeholderRect: NSRect {
        guard !placeholder.isEmpty else { return .zero }
        let width = max(textContainer?.size.width ?? bounds.width, 1)
        let size = placeholderText.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        return NSRect(origin: textContainerOrigin, size: NSSize(width: width, height: ceil(size.height)))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        placeholderText.draw(with: placeholderRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

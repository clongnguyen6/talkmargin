import AppKit
import PrompterCore

/// A scrollable, read-only rendered Markdown view with line-aligned stepping,
/// heading jumps, and a reading anchor that survives reflow on resize.
@MainActor
final class MarkdownPane: NSObject {
    enum Position {
        case top
        case offset(CGFloat)
        /// Keep the line currently at the top, e.g. when the font size changes.
        case keepReadingPosition
    }

    let scrollView = FadingScrollView()
    private(set) var headings: [Heading] = []
    /// Called after every scroll, including programmatic ones.
    var onScroll: (() -> Void)?

    private let textView = CopyOnSelectTextView(usingTextLayoutManager: false)
    private var fontSize: CGFloat = 20
    private var holdTimer: Timer?
    private var animatingTo: CGFloat?
    /// First visible character; kept at the top while the text reflows.
    private var anchorCharacter = 0
    private var resizeDepth = 0
    /// A reading position that survives reflow: the top character, or the end of
    /// the text when scrolled all the way down (which is not line-aligned).
    private struct Place: Equatable {
        let character: Int
        let atEnd: Bool
    }

    /// Places left by jumps, for back / forward.
    private var backStack: [Place] = []
    private var forwardStack: [Place] = []
    /// The heading last jumped to; it stays "current" until the reader scrolls
    /// by hand, even if it could not reach the top (e.g. near the end).
    private var jumpedHeading: Int?
    /// Heading kept at the top through reflows, until the reader scrolls by hand.
    private var pinnedHeading: String?

    override init() {
        super.init()
        textView.textContainer?.replaceLayoutManager(SelectionLayoutManager())
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 18, height: FadingScrollView.fadeHeight)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.onUserScroll = { [weak self] in
            self?.jumpedHeading = nil
            self?.pinnedHeading = nil
        }
        // Re-pin whenever the visible width or height changes, whatever caused it.
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportDidResize),
                                               name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollDidChange),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    /// Selecting text copies it to the clipboard as plain text, with no keyboard
    /// needed, so the overlay never takes focus from the meeting app. Called with
    /// the number of characters copied.
    var onCopySelection: ((Int) -> Void)? {
        didSet {
            textView.isSelectable = onCopySelection != nil
            textView.onSelectionFinished = onCopySelection == nil ? nil : { [weak self] in self?.copySelection() }
        }
    }

    private func copySelection() {
        let text = textView.selectedRanges
            .map { (textView.string as NSString).substring(with: $0.rangeValue) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A stray click selects nothing or a single character; leave the clipboard alone.
        guard text.count >= 2 else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onCopySelection?(text.count)
    }

    var textInset: CGFloat {
        get { textView.textContainerInset.width }
        set { textView.textContainerInset = NSSize(width: newValue, height: FadingScrollView.fadeHeight) }
    }

    // MARK: - Content

    /// Forgets jump history, e.g. when a different file is opened.
    func clearHistory() {
        backStack = []
        forwardStack = []
    }

    func render(_ markdown: String, fontSize: CGFloat, position: Position) {
        let anchor = topCharacter()
        self.fontSize = fontSize
        let doc = MarkdownRenderer.render(markdown, style: style(fontSize))
        if doc.headings != headings { jumpedHeading = nil }
        textView.textStorage?.setAttributedString(doc.text)
        headings = doc.headings
        layoutText()
        switch position {
        case .top:
            setOffset(0, animated: false)
        case .offset(let y):
            setOffset(y, animated: false)
        case .keepReadingPosition:
            anchorCharacter = anchor
            restoreAnchor()
        }
    }

    private func layoutText() {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        textView.sizeToFit()
    }

    /// Applies on the next render.
    var appearance = TextAppearance()

    private func style(_ fontSize: CGFloat) -> RenderStyle {
        RenderStyle(baseSize: fontSize, textColor: appearance.textColor, secondaryColor: appearance.secondaryColor,
                    accentColor: NSColor.controlAccentColor.withAlphaComponent(0.9),
                    textBand: appearance.band, textShadow: appearance.shadow)
    }

    // MARK: - Resizing

    /// Brackets a size change: reflow-driven scrolling does not move the anchor,
    /// and the anchored line is put back at the top afterwards.
    func resizing(_ change: () -> Void) {
        resizeDepth += 1
        change()
        resizeDepth -= 1
        restoreAnchor()
    }

    func beginLiveResize() { resizeDepth += 1 }

    func endLiveResize() {
        resizeDepth = max(0, resizeDepth - 1)
        restoreAnchor()
    }

    func restoreAnchor() {
        guard let layoutManager = textView.layoutManager, layoutManager.numberOfGlyphs > 0 else { return }
        // Split views resize their panes lazily; settle widths before measuring lines.
        scrollView.window?.layoutIfNeeded()
        layoutText()
        let index = min(anchorCharacter, (textView.string as NSString).length - 1)
        setOffset(anchorCharacter == 0 ? 0 : offset(forLineAtGlyph: layoutManager.glyphIndexForCharacter(at: index)),
                  animated: false)
    }

    // MARK: - Scrolling

    private var clipView: NSClipView { scrollView.contentView }
    var currentOffset: CGFloat { clipView.bounds.origin.y }
    private var maxOffset: CGFloat { max(0, textView.frame.height - clipView.bounds.height) }

    var progress: Int {
        maxOffset > 0 ? Int((currentOffset / maxOffset * 100).rounded()) : 100
    }

    func setOffset(_ y: CGFloat, animated: Bool) {
        let target = NSPoint(x: 0, y: (min(max(0, y), maxOffset)).rounded())
        guard animated else {
            animatingTo = nil
            clipView.setBoundsOrigin(target)
            scrollView.reflectScrolledClipView(clipView)
            return
        }
        animatingTo = target.y
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clipView.animator().setBoundsOrigin(target)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.animatingTo == target.y else { return }
                self.animatingTo = nil
                self.scrollView.reflectScrolledClipView(self.clipView)
            }
        })
    }

    /// Press: jump about a third of the view to a line boundary. Hold: keep scrolling smoothly until released.
    func beginHoldScroll(direction: CGFloat) {
        endHoldScroll()
        jumpedHeading = nil
        let start = animatingTo ?? currentOffset
        setOffset(lineAlignedOffset(from: start, to: start + direction * clipView.bounds.height * 0.35), animated: true)
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.startContinuousScroll(direction: direction) }
        }
    }

    func endHoldScroll() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func startContinuousScroll(direction: CGFloat) {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setOffset(self.currentOffset + direction * self.fontSize * 0.4, animated: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    func jumpToHeading(forward: Bool) {
        let current = animatingTo ?? currentOffset
        let offsets = headings.map { yOffset(ofCharacter: $0.location) }
        let index = forward ? offsets.firstIndex { $0 > current + 4 } : offsets.lastIndex { $0 < current - 4 }
        jump(to: index.map { offsets[$0] } ?? (forward ? maxOffset : 0), heading: index)
    }

    /// Jumps to the n-th section (1-based).
    func jumpToSection(_ number: Int) {
        let sections = Sections.sections(in: headings)
        guard sections.indices.contains(number - 1) else { return }
        let section = sections[number - 1]
        jump(to: yOffset(ofCharacter: section.location), heading: headings.firstIndex(of: section))
    }

    /// Jumps to `headings[index]`, e.g. from the outline.
    func jumpToHeading(at index: Int) {
        guard headings.indices.contains(index) else { return }
        jump(to: yOffset(ofCharacter: headings[index].location), heading: index)
    }

    /// Scrolls to `offset`, remembering where the reader was so they can go back.
    private func jump(to offset: CGFloat, heading: Int?) {
        let here = currentPlace
        if backStack.last != here { backStack.append(here) }
        forwardStack = []
        jumpedHeading = heading
        setOffset(offset, animated: true)
    }

    private var currentPlace: Place {
        let offset = animatingTo ?? currentOffset
        return Place(character: topCharacter(), atEnd: maxOffset > 0 && offset >= maxOffset - 1)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// The heading of the section `goBack()` would return to.
    var backSection: Heading? {
        backStack.last.flatMap { place in headings.last { $0.location <= place.character } }
    }

    func goBack() {
        guard let target = backStack.popLast() else { return }
        jumpedHeading = nil
        forwardStack.append(currentPlace)
        scroll(to: target)
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        jumpedHeading = nil
        backStack.append(currentPlace)
        scroll(to: target)
    }

    private func scroll(to place: Place) {
        guard let layoutManager = textView.layoutManager, layoutManager.numberOfGlyphs > 0 else { return }
        if place.atEnd { return setOffset(maxOffset, animated: true) }
        let index = min(place.character, (textView.string as NSString).length - 1)
        setOffset(offset(forLineAtGlyph: layoutManager.glyphIndexForCharacter(at: index)), animated: true)
    }

    /// Index of the heading whose section is at the top of the view.
    var currentHeadingIndex: Int? {
        if let jumpedHeading, headings.indices.contains(jumpedHeading) { return jumpedHeading }
        let line = (animatingTo ?? currentOffset) + min(clipView.bounds.height * 0.25, 60)
        return headings.indices.last { yOffset(ofCharacter: headings[$0].location) <= line }
    }

    /// Keeps the last heading with this exact text at the top, also after later
    /// resizes, until the reader scrolls by hand. Nil releases the pin.
    /// A heading is kept at the top (`pin(toHeading:)`) and the reader has not scrolled away by hand.
    var isPinned: Bool { pinnedHeading != nil }

    func pin(toHeading text: String?) {
        pinnedHeading = text
        applyPin()
    }

    private func applyPin() {
        guard let pinnedHeading, let heading = headings.last(where: { $0.text == pinnedHeading }) else { return }
        layoutText()
        setOffset(yOffset(ofCharacter: heading.location), animated: false)
    }

    @objc private func viewportDidResize() {
        applyPin()
    }

    // MARK: - Geometry

    /// Scroll offset that puts the paragraph at `index` just below the top fade.
    private func yOffset(ofCharacter index: Int) -> CGFloat {
        guard let layoutManager = textView.layoutManager, layoutManager.numberOfGlyphs > 0 else { return 0 }
        return offset(forLineAtGlyph: layoutManager.glyphIndexForCharacter(at: index))
    }

    /// Snaps `target` to the start of a line so the top line is never cut in half,
    /// always moving at least one line away from `start`.
    private func lineAlignedOffset(from start: CGFloat, to target: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
              layoutManager.numberOfGlyphs > 0 else { return target }
        let point = NSPoint(x: 0, y: target + FadingScrollView.fadeHeight - textView.textContainerOrigin.y)
        var glyph = layoutManager.glyphIndex(for: point, in: container)
        var lineRange = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
        let aligned = offset(forLineAtGlyph: glyph)
        if target > start, aligned <= start + 1 {
            glyph = min(NSMaxRange(lineRange), layoutManager.numberOfGlyphs - 1)
        } else if target < start, aligned >= start - 1 {
            glyph = max(lineRange.location - 1, 0)
        } else {
            return aligned
        }
        return offset(forLineAtGlyph: glyph)
    }

    private func offset(forLineAtGlyph glyph: Int) -> CGFloat {
        guard let layoutManager = textView.layoutManager, let storage = textView.textStorage,
              layoutManager.numberOfGlyphs > 0 else { return 0 }
        var lineRange = NSRange()
        let line = layoutManager.lineFragmentRect(forGlyphAt: min(glyph, layoutManager.numberOfGlyphs - 1),
                                                  effectiveRange: &lineRange)
        // Paragraph spacing sits inside the first line's fragment; skip past it.
        let first = layoutManager.characterIndexForGlyph(at: lineRange.location)
        let startsParagraph = first == 0 || (storage.string as NSString).character(at: first - 1) == 0x0A
        let style = storage.attribute(.paragraphStyle, at: first, effectiveRange: nil) as? NSParagraphStyle
        let spacing = startsParagraph ? style?.paragraphSpacingBefore ?? 0 : 0
        return line.minY + spacing + textView.textContainerOrigin.y - FadingScrollView.fadeHeight
    }

    /// Character at the top of the visible text. Probes a little below the edge,
    /// since animated scrolls can stop half a point above a line.
    private func topCharacter() -> Int {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
              layoutManager.numberOfGlyphs > 0 else { return 0 }
        let point = NSPoint(x: 0, y: currentOffset + FadingScrollView.fadeHeight + 2 - textView.textContainerOrigin.y)
        return layoutManager.characterIndexForGlyph(at: layoutManager.glyphIndex(for: point, in: container))
    }

    @objc private func scrollDidChange() {
        // While resizing, text reflows; keep the anchor fixed so it can be restored.
        if resizeDepth == 0 && !(scrollView.window?.inLiveResize ?? false) { anchorCharacter = topCharacter() }
        onScroll?()
    }
}

/// Text view whose selection is finished when the mouse goes up; it works on the
/// first click, since the overlay is never the key window.
private final class CopyOnSelectTextView: NSTextView {
    var onSelectionFinished: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isSelectable }

    // Context menus and the Look Up panel are windows of other processes that screen sharing captures.
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func quickLook(with event: NSEvent) {}

    override func mouseDown(with event: NSEvent) {
        // NSTextView tracks the drag (and double / triple clicks) until the mouse goes up.
        super.mouseDown(with: event)
        onSelectionFinished?()
    }
}

/// Paints the text selection in the accent color. AppKit uses a faint gray for the
/// selection of a window that is not key, which the overlay never is.
final class SelectionLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        // System selection colors ("selectedTextBackgroundColor", "unemphasizedSelectedContent…")
        // don't compare equal reliably, so match them by catalog name.
        let isSelection = color.type == .catalog && color.colorNameComponent.localizedCaseInsensitiveContains("selected")
        guard isSelection else {
            return super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        }
        // AppKit fills with the current fill color; `color` is only informational.
        NSColor.controlAccentColor.withAlphaComponent(0.55).setFill()
        for index in 0..<rectCount { rectArray[index].fill(using: .sourceOver) }
    }
}

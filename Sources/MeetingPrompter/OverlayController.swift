import AppKit
import PrompterCore

/// The overlay window: an optional outline, the prepared notes, and an optional
/// Claude chat column on the right.
@MainActor
final class OverlayController: NSObject, NSWindowDelegate, NSSplitViewDelegate {
    let panel = OverlayPanel()
    private(set) var fileURL: URL?
    private(set) var clickThrough = false
    private(set) var isExpanded = false
    var isChatVisible: Bool { !chatColumn.isHidden }
    var isVisible: Bool { panel.isVisible }
    /// Notes for Claude: the loaded file content, or the help text. Empty after a
    /// failed load, so the error page never replaces Claude's copy of the notes.
    var notesMarkdown: String { loadFailed ? "" : notesSource }
    /// Called when a question is sent from the chat input.
    var onSubmitQuestion: ((String) -> Void)?
    /// Called by the terminal button in the chat header.
    var onContinueInTerminal: (() -> Void)?
    /// Called by "Mở file khác…" in the document picker.
    var onOpenOtherFile: (() -> Void)?
    /// Called with the session chosen in the session picker (nil: none).
    var onLinkSession: ((ClaudeSession?) -> Void)?
    /// Called when the session picker opens, so the catalog can be re-read.
    var onSessionPickerOpened: (() -> Void)?
    /// Session last used with a document; shown as a hint in the session picker, never applied.
    var suggestedSession: ((String) -> ClaudeSession?)?

    private let settings: Settings
    private let notes = MarkdownPane()
    private let outline = OutlineSidebar()
    private var outlineWidth: NSLayoutConstraint!
    private let outlineHandle = SidebarResizeHandle()
    private var dragStartWidth: CGFloat = 0
    private let chat = MarkdownPane()
    private let split = OverlaySplitView()
    private let chatColumn = NSView()
    private let chatTitle = NSTextField(labelWithString: "")
    private let terminalButton = HeaderButton()
    private var hints: [ObjectIdentifier: HoverHint] = [:]
    private lazy var fileTitle = HeaderTitle(titleLabel)
    private lazy var chatHeaderTitle = HeaderTitle(chatTitle)
    private let input = ChatInputView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let expandButton = HeaderButton()
    private let outlineButton = HeaderButton()
    private let displayButton = HeaderButton()
    private let backButton = HeaderButton()
    private let chatButton = HeaderButton()
    /// File name plus a chevron; clicking it drops down the document picker.
    private let titleGroup = NSStackView()
    private let titleButton = HeaderButton()
    /// Chat title plus a chevron; clicking it drops down the session picker.
    private let chatTitleGroup = NSStackView()
    private let chatTitleButton = HeaderButton()
    private let documentPicker = OverlayPicker()
    private let sessionPicker = OverlayPicker()
    private var claudeProjects: [ClaudeProject] = []
    private var catalogLoaded = false
    private var linkedSession: ClaudeSession?
    private var chatBusy = false
    /// Document Claude was last told is on screen.
    private var claudeDocumentPath: String?
    /// Visible only when the overlay is capturable (a dev or verification build with MP_ALLOW_CAPTURE=1).
    private let captureLabel = NSTextField(labelWithString: "● ĐANG CHO CHỤP MÀN HÌNH")
    /// Back button, capture label and progress, right-aligned; hidden ones take no room.
    private let headerTrailing = NSStackView()
    private let blur = NSVisualEffectView()
    private let backdrop = NSView()
    private var notesSource = ""
    private var loadFailed = false
    private var notesTitle = ""
    private var chatSource = ""
    private var chatPin: String?
    private var watcher: FileWatcher?
    private var isAdjustingFrame = false
    /// The chat expanded a compact overlay; closing the chat shrinks it back.
    private var expandedForChat = false
    /// Unsent question text that a new push-to-talk recording continues from.
    private var recordingBase = ""
    /// App to hand the keyboard back to after typing a question.
    private var previousApp: NSRunningApplication?

    init(settings: Settings) {
        self.settings = settings
        super.init()
        buildContent()
        panel.delegate = self
        panel.onHeaderDoubleClick = { [weak self] in self?.toggleExpanded() }
        panel.onKeyboardRequest = { [weak self] in self?.takeKeyboard() }
        panel.onMouseDown = { [weak self] in self?.mouseDown(on: $0) }
        notes.onScroll = { [weak self] in self?.notesDidScroll() }
        outline.onSelect = { [weak self] in self?.notes.jumpToHeading(at: $0) }
        restoreFrame()
        applyAppearance()
        NotificationCenter.default.addObserver(self, selector: #selector(screensDidChange),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: - Notes

    /// Every way in (recents, folder browser, open dialog, Finder, last file) lands here;
    /// the canonical path is the file's key for recents, reading position and Claude.
    func open(_ url: URL) {
        let url = NotesPath.canonical(url)
        // The document on screen again (e.g. two launches with the same file): keep its history and
        // position; the file watcher already reloads edits.
        if url == fileURL, !loadFailed { return closePickers() }
        closePickers()
        saveScrollPosition()
        notes.clearHistory()
        watcher?.stop()
        fileURL = url
        settings.noteOpened(url)
        watcher = FileWatcher(url: url) { [weak self] in self?.reload() }
        load(offset: settings.scrollOffset(for: url.path))
    }

    func reload() {
        load(offset: notes.currentOffset)
    }

    func showMarkdown(_ markdown: String, title: String) {
        closePickers()
        saveScrollPosition()
        watcher?.stop()
        watcher = nil
        fileURL = nil
        notesSource = markdown
        loadFailed = false
        notesTitle = title
        fileTitle.base = title
        notes.clearHistory()
        renderNotes(position: .top)
    }

    private func renderNotes(position: MarkdownPane.Position) {
        notes.render(notesSource, fontSize: settings.fontSize, position: position)
        outline.setHeadings(notes.headings)
        notesDidScroll()
    }

    private func load(offset: CGFloat) {
        guard let url = fileURL else { return }
        do {
            notesSource = try NotesLoader.load(url).markdown
            loadFailed = false
        } catch {
            notesSource = "## Không đọc được file\n\n`\(url.path)`\n\n\(error.localizedDescription)"
            loadFailed = true
        }
        notesTitle = url.lastPathComponent
        fileTitle.base = notesTitle
        renderNotes(position: .offset(offset))
    }

    private func notesDidScroll() {
        updateProgress()
        saveScrollPosition()
        outline.setCurrent(notes.currentHeadingIndex)
        updateBackButton()
    }

    func saveScrollPosition() {
        guard let path = fileURL?.path else { return }
        settings.setScrollOffset(notes.currentOffset, for: path)
    }

    /// ⌥↓ / ⌥↑ move the highlight while a picker is open.
    func beginHoldScroll(direction: CGFloat) {
        if let picker = openPicker { return picker.moveHighlight(by: direction > 0 ? 1 : -1) }
        notes.beginHoldScroll(direction: direction)
    }
    func endHoldScroll() { notes.endHoldScroll() }
    func jumpToHeading(forward: Bool) { notes.jumpToHeading(forward: forward) }
    /// ⌥1…⌥9 choose the Nth row while a picker is open.
    func jumpToSection(_ number: Int) {
        if let picker = openPicker { return picker.pick(ordinal: number) }
        notes.jumpToSection(number)
    }
    func goBack() { notes.goBack() }
    func goForward() { notes.goForward() }

    // MARK: - Outline

    var isOutlineVisible: Bool { !outline.view.isHidden }

    func toggleOutline() {
        setOutlineVisible(!isOutlineVisible)
    }

    func setOutlineVisible(_ visible: Bool) {
        guard visible != isOutlineVisible else { return }
        notes.resizing {
            outline.view.isHidden = !visible
            outlineHandle.isHidden = !visible
            outlineWidth.constant = visible ? settings.outlineWidth : 0
            panel.contentView?.layoutSubtreeIfNeeded()
        }
        settings.outlineVisible = visible
        updateOutlineButton()
    }

    /// Widest the outline may get while leaving the notes readable.
    private var maxOutlineWidth: CGFloat {
        let available = panel.frame.width - (isChatVisible ? chatColumn.frame.width : 0) - 240
        return max(Settings.outlineWidthRange.lowerBound, min(Settings.outlineWidthRange.upperBound, available))
    }

    private func resizeOutline(to width: CGFloat) {
        outlineWidth.constant = min(max(width, Settings.outlineWidthRange.lowerBound), maxOutlineWidth)
        panel.contentView?.layoutSubtreeIfNeeded()
        notes.restoreAnchor()
    }

    private func setUpOutlineHandle() {
        outlineHandle.onBegin = { [weak self] in
            guard let self else { return }
            dragStartWidth = outlineWidth.constant
            notes.beginLiveResize()
        }
        outlineHandle.onDrag = { [weak self] in
            guard let self else { return }
            resizeOutline(to: dragStartWidth + $0)
        }
        outlineHandle.onEnd = { [weak self] in
            guard let self else { return }
            settings.outlineWidth = outlineWidth.constant
            notes.endLiveResize()
        }
        outlineHandle.onReset = { [weak self] in
            guard let self else { return }
            notes.resizing { resizeOutline(to: Settings.defaultOutlineWidth) }
            settings.outlineWidth = outlineWidth.constant
        }
    }

    private func updateOutlineButton() {
        outlineButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        outlineButton.contentTintColor = isOutlineVisible ? .labelColor : .secondaryLabelColor
        hint(outlineButton, isOutlineVisible ? "Ẩn mục lục (⌥O bên phải)" : "Hiện mục lục (⌥O bên phải)")
    }

    @objc private func outlineButtonClicked() {
        toggleOutline()
    }

    /// "↩ <section>" while there is a place to go back to.
    private func updateBackButton() {
        guard notes.canGoBack else {
            backButton.isHidden = true
            return
        }
        let name = notes.backSection?.text ?? "Quay lại"
        let short = name.count > 22 ? String(name.prefix(22)).trimmingCharacters(in: .whitespaces) + "…" : name
        backButton.attributedTitle = NSAttributedString(string: "↩ " + short, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.controlAccentColor])
        hint(backButton, "Quay lại: \(name) (⌥← bên phải)")
        backButton.isHidden = false
    }

    @objc private func backButtonClicked() {
        notes.goBack()
    }

    // MARK: - Chat column

    private var chatFontSize: CGFloat { max(11, (settings.fontSize * 0.85).rounded()) }

    /// Replaces the chat, keeping the last heading titled `pin` at the top.
    func setAssistant(markdown: String, title: String, pin: String?) {
        chatSource = markdown
        chatPin = pin
        chatHeaderTitle.base = title
        chat.render(markdown, fontSize: chatFontSize, position: .offset(chat.currentOffset))
        chat.pin(toHeading: pin)
    }

    private func confirmCopied(_ count: Int, in title: HeaderTitle) {
        title.showNotice("✓ Đã copy \(count) ký tự", seconds: 1.4)
    }

    /// A notice in the file name's place in the header, inside the overlay (invisible to screen sharing).
    func showNotice(_ text: String, seconds: Double) {
        fileTitle.showNotice(text, seconds: seconds)
    }

    /// Brief notice in the chat title, e.g. when the chat refused a change while answering.
    /// Survives the chat re-rendering underneath it.
    func flashChatTitle(_ text: String) {
        chatHeaderTitle.showNotice(text, seconds: 2.2)
    }

    /// Hint text shown in the panel while hovering `view`: in the chat title for
    /// chat-column controls, otherwise in the file name. Never an AppKit tooltip,
    /// which is a separate window visible to screen sharing.
    private func hint(_ view: NSView, _ text: String) {
        let key = ObjectIdentifier(view)
        if let existing = hints[key] {
            existing.text = text
            return
        }
        hints[key] = HoverHint(view: view, text: text) { [weak self, weak view] hint in
            guard let self, let view else { return }
            (view.isDescendant(of: chatColumn) ? chatHeaderTitle : fileTitle).showHint(hint)
        }
    }

    /// Shows the "continue in terminal" button once the conversation has a session to resume.
    func setTerminalAvailable(_ available: Bool) {
        terminalButton.isHidden = !available
    }

    @objc private func terminalButtonClicked() {
        onContinueInTerminal?()
    }

    /// Brief confirmation on the terminal button after the command was copied.
    func confirmTerminalCommandCopied() {
        setTerminalButtonTitle("✓ Đã copy lệnh")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.setTerminalButtonTitle(" Terminal") }
        }
    }

    private func setTerminalButtonTitle(_ title: String) {
        terminalButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
    }

    func toggleChat() {
        setChatVisible(!isChatVisible)
    }

    func setChatVisible(_ visible: Bool) {
        guard visible != isChatVisible else { return }
        if visible, !isExpanded {
            setExpanded(true)
            expandedForChat = true
        }
        notes.resizing {
            chatColumn.isHidden = !visible
            split.adjustSubviews()
            if visible { split.setPosition(split.bounds.width * settings.chatRatio, ofDividerAt: 0) }
        }
        if visible { chat.pin(toHeading: chatPin) }
        if !visible {
            endKeyboard()
            sessionPicker.isHidden = true
            if expandedForChat {
                expandedForChat = false
                setExpanded(false)
            }
        }
        settings.chatVisible = visible
        updateChatButton()
    }

    /// Opens the chat and puts the cursor in the question box.
    func focusInput() {
        setChatVisible(true)
        show()
        takeKeyboard()
        panel.makeKey()
        panel.makeFirstResponder(input.editor)
    }

    /// Shows push-to-talk text live in the question box, after any unsent text already there.
    func showRecording(_ preview: String, placeholder: String) {
        setChatVisible(true)
        show()
        if !input.isRecording {
            recordingBase = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
            input.isRecording = true
        }
        input.placeholder = placeholder
        input.text = Self.appending(preview, to: recordingBase)
    }

    /// Leaves the recognized text in the box to review, edit and send.
    func finishRecording(_ text: String) {
        input.isRecording = false
        input.placeholder = Self.inputPlaceholder
        input.text = Self.appending(text, to: recordingBase)
        recordingBase = ""
        focusInput()
    }

    private static func appending(_ text: String, to base: String) -> String {
        [base, text].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static let inputPlaceholder = "Hỏi Claude…  Enter gửi · Esc huỷ · giữ ⌥ / để nói"

    /// The panel only takes the keyboard while the question box is in use,
    /// and hands it back to the previous app afterwards.
    private func takeKeyboard() {
        if !panel.acceptsKeyboard {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        }
        panel.acceptsKeyboard = true
    }

    private func endKeyboard() {
        guard panel.acceptsKeyboard else { return }
        // resignKey() calls windowDidResignKey synchronously, which clears previousApp: read it first.
        let previous = previousApp
        previousApp = nil
        panel.makeFirstResponder(nil)
        panel.acceptsKeyboard = false
        panel.resignKey()
        previous?.activate()
    }

    func windowDidResignKey(_ notification: Notification) {
        panel.acceptsKeyboard = false
        previousApp = nil
    }

    // MARK: - Header

    private func updateProgress() {
        progressLabel.stringValue = (clickThrough ? "xuyên chuột  ·  " : "") + "\(notes.progress)%"
    }

    private func updateChatButton() {
        let symbol = isChatVisible ? "chevron.left.2" : "chevron.right.2"
        chatButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        hint(chatButton, isChatVisible ? "Đóng khung Claude (⌥A bên phải)" : "Mở khung Claude (⌥A bên phải)")
    }

    @objc private func chatButtonClicked() {
        toggleChat()
    }

    // MARK: - Visibility & appearance

    func show() {
        ensureOnScreen()
        panel.orderFrontRegardless()
        settings.overlayVisible = true
    }

    func hide() {
        closePickers()
        notes.endHoldScroll()
        endKeyboard()
        panel.orderOut(nil)
        settings.overlayVisible = false
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func setClickThrough(_ enabled: Bool) {
        clickThrough = enabled
        panel.ignoresMouseEvents = enabled
        updateProgress()
    }

    /// Applies the display settings: backdrop darkness, blur, text band, text opacity.
    func applyAppearance() {
        let blurred = settings.blurBehind
        blur.isHidden = !blurred
        // The blur material is already dark, so blurred backdrops start from a floor.
        let density = settings.opacity
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(blurred ? 0.25 + 0.65 * density : 0.9 * density).cgColor
        // A window shadow around bare glyphs looks like smudges.
        panel.hasShadow = blurred || density >= 0.4
        panel.invalidateShadow()

        let appearance = TextAppearance(textOpacity: settings.textOpacity, bandOpacity: settings.textBand, halo: !blurred)
        let chip = blurred ? nil : appearance.band
        for view in [titleGroup, progressLabel, chatTitleGroup, backButton, expandButton, outlineButton, displayButton,
                     chatButton, terminalButton] as [NSView] {
            view.wantsLayer = true
            view.shadow = appearance.shadow
            // A dark rounded chip behind header text and icons, like the notes' text bands.
            view.layer?.backgroundColor = chip?.cgColor
            view.layer?.cornerRadius = 4
        }
        guard appearance != notes.appearance else { return }
        notes.appearance = appearance
        chat.appearance = appearance
        outline.appearance = appearance
        if !notesSource.isEmpty { renderNotes(position: .keepReadingPosition) }
        chat.render(chatSource, fontSize: chatFontSize, position: .offset(chat.currentOffset))
    }

    // MARK: - Display settings

    private lazy var displaySettings = DisplaySettingsController(settings: settings) { [weak self] change in
        guard let self else { return }
        switch change {
        case .appearance, .reset: applyAppearance()
        case .fontSize(let delta): changeFontSize(by: delta)
        }
    }
    /// Drawn inside the overlay (a popover would be a separate window, unprotected
    /// until its `sharingType` could be set). Scrolls when the overlay is short.
    private let displayBox = DropdownBox()

    func showDisplaySettings() {
        if !displayBox.isHidden { return closePickers() }
        closePickers()
        show()
        displaySettings.refresh()
        displayBox.isHidden = false
    }

    @objc private func displayButtonClicked() {
        showDisplaySettings()
    }

    private func setUpDisplayBox() {
        let content = displaySettings.view
        let scroll = NSScrollView()
        scroll.documentView = content
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        displayBox.addSubview(scroll)
        let size = displaySettings.preferredContentSize
        let height = displayBox.heightAnchor.constraint(equalToConstant: size.height)
        height.priority = .dragThatCannotResizeWindow
        let width = displayBox.widthAnchor.constraint(equalToConstant: size.width)
        width.priority = .dragThatCannotResizeWindow
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: displayBox.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: displayBox.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: displayBox.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: displayBox.trailingAnchor),
            width,
            height,
        ])
    }

    // MARK: - Pickers

    private static let openOtherID = "\u{0}open-other"
    private static let browseID = "\u{0}browse"
    private static let recentsID = "\u{0}recents"
    private static let parentID = "\u{0}parent"
    private static let folderPrefix = "\u{0}dir:"
    /// Folder the document picker is browsing; nil shows the recent files.
    private var browseFolder: URL?
    private static let noSessionID = "\u{0}no-session"

    var isPickerOpen: Bool { openPicker != nil }
    private var openPicker: OverlayPicker? { [documentPicker, sessionPicker].first { !$0.isHidden } }
    /// Every dropdown with the header control that opens it.
    private var dropdowns: [(box: DropdownBox, anchor: NSView)] {
        [(documentPicker, titleButton), (sessionPicker, chatTitleButton), (displayBox, displayButton)]
    }

    /// Drops the recent-documents list down from the file name (⌥D).
    func toggleDocumentPicker() {
        if !documentPicker.isHidden { return closePickers() }
        closePickers()
        show()
        browseFolder = nil
        refreshDocumentPicker()
        documentPicker.isHidden = false
    }

    /// Drops the Claude session list down from the chat title (⌥S), opening the chat if needed.
    func toggleSessionPicker() {
        if !sessionPicker.isHidden { return closePickers() }
        closePickers()
        setChatVisible(true)
        show()
        refreshSessionPicker()
        sessionPicker.isHidden = false
        onSessionPickerOpened?()
    }

    /// Closes every dropdown: both pickers and the display settings.
    func closePickers() {
        for dropdown in dropdowns { dropdown.box.isHidden = true }
    }

    /// ⌥↩ while a picker is open.
    func confirmPicker() {
        openPicker?.pickHighlighted()
    }

    func setClaudeProjects(_ projects: [ClaudeProject]) {
        claudeProjects = projects
        catalogLoaded = true
        if !sessionPicker.isHidden { refreshSessionPicker() }
    }

    func setLinkedSession(_ session: ClaudeSession?) {
        linkedSession = session
        if !sessionPicker.isHidden { refreshSessionPicker() }
    }

    /// Whether Claude is answering (linking is refused meanwhile) and which document it has.
    func setClaudeContext(busy: Bool, documentPath: String?) {
        guard busy != chatBusy || documentPath != claudeDocumentPath else { return }
        chatBusy = busy
        claudeDocumentPath = documentPath
        if !sessionPicker.isHidden { refreshSessionPicker() }
        if !documentPicker.isHidden { refreshDocumentPicker() }
    }

    private func refreshDocumentPicker() {
        if let browseFolder { return showFolder(browseFolder) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let recents = settings.openableRecentFiles
        var rows: [OverlayPicker.Row] = recents.map { path in
            var detail = PathLabel.folder(of: path, home: home)
            if path == claudeDocumentPath { detail += "  ·  Claude đang có tài liệu này" }
            return .item(id: path, title: (path as NSString).lastPathComponent, detail: detail, isCurrent: path == fileURL?.path)
        }
        if rows.isEmpty { rows.append(.header("Chưa mở file nào")) }
        // Browsing stays inside the overlay; the system dialog's menus are drawn by another process
        // and show up in screen sharing, so it is for use outside a share.
        rows.append(.action(id: Self.browseID, title: "Duyệt thư mục…", symbol: "folder"))
        rows.append(.action(id: Self.openOtherID, title: "Hộp thoại mở file… (ngoài lúc share)", symbol: "macwindow"))
        // Start on the most recent other document, the usual target of a switch; else on browsing.
        let highlight = recents.firstIndex { $0 != fileURL?.path } ?? rows.count - 2
        documentPicker.setRows(rows, title: "Tài liệu", highlight: highlight)
    }

    /// Lists `folder` in the document picker: subfolders to enter, supported files to open.
    private func showFolder(_ folder: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var rows: [OverlayPicker.Row] = [.action(id: Self.recentsID, title: "Gần đây", symbol: "clock.arrow.circlepath")]
        let parent = folder.deletingLastPathComponent()
        if parent.path != folder.path {
            rows.append(.action(id: Self.parentID, title: "Thư mục cha · \(PathLabel.abbreviated(parent.path, home: home))", symbol: "arrow.up"))
        }
        let highlight = rows.count
        let found = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let entries = found.map {
            FolderListing.Entry(name: $0.lastPathComponent,
                                isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        }
        for entry in FolderListing.rows(entries, supportedExtensions: NotesLoader.supportedExtensions) {
            let path = folder.appending(path: entry.name).path
            rows.append(entry.isDirectory
                ? .action(id: Self.folderPrefix + path, title: entry.name, symbol: "folder")
                : .item(id: path, title: entry.name, detail: nil, isCurrent: path == fileURL?.path))
        }
        if rows.count == highlight { rows.append(.header("Không có thư mục con hay file mở được")) }
        documentPicker.setRows(rows, title: "📁 " + PathLabel.abbreviated(folder.path, home: home),
                               highlight: min(highlight, rows.count - 1))
    }

    private func refreshSessionPicker() {
        var rows: [OverlayPicker.Row] = [
            .item(id: Self.noSessionID, title: "Không liên kết session", detail: nil, isCurrent: linkedSession == nil),
        ]
        var highlight: Int? = linkedSession == nil ? 0 : nil
        let suggested = fileURL.flatMap { suggestedSession?($0.path) }
        func add(_ session: ClaudeSession) {
            if session.id == linkedSession?.id { highlight = rows.count }
            // The id tells apart sessions whose titles truncate alike; first, so middle truncation keeps it.
            var detail = String(session.id.prefix(8)) + "  ·  " + session.modified.formatted(.relative(presentation: .named))
            if session.id == suggested?.id, let name = fileURL?.lastPathComponent { detail += "  ·  đã dùng với \(name)" }
            rows.append(.item(id: session.id, title: session.title, detail: detail, isCurrent: session.id == linkedSession?.id))
        }
        // The linked session stays visible even when it is no longer among the recent ones.
        if let linkedSession, !claudeProjects.contains(where: { $0.sessions.contains { $0.id == linkedSession.id } }) {
            rows.append(.header("Đang liên kết · \((linkedSession.cwd as NSString).lastPathComponent)"))
            add(linkedSession)
        }
        if claudeProjects.isEmpty {
            rows.append(.header(catalogLoaded ? "Không tìm thấy session nào trong ~/.claude/projects" : "Đang đọc ~/.claude/projects…"))
        }
        for project in claudeProjects {
            rows.append(.header(project.name))
            project.sessions.forEach(add)
        }
        let title = chatBusy ? "⏳ Claude đang trả lời · đổi session sau khi xong" : "Session Claude trả lời câu hỏi"
        sessionPicker.setRows(rows, title: title, highlight: highlight)
    }

    private func pickDocument(_ id: String) {
        switch id {
        case Self.browseID:
            browseFolder = fileURL?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
            refreshDocumentPicker()
        case Self.recentsID:
            browseFolder = nil
            refreshDocumentPicker()
        case Self.parentID:
            browseFolder = browseFolder?.deletingLastPathComponent()
            refreshDocumentPicker()
        case let id where id.hasPrefix(Self.folderPrefix):
            browseFolder = URL(fileURLWithPath: String(id.dropFirst(Self.folderPrefix.count)), isDirectory: true)
            refreshDocumentPicker()
        case Self.openOtherID:
            closePickers()
            onOpenOtherFile?()
        default:
            closePickers()
            open(URL(fileURLWithPath: id))
            show()
        }
    }

    private func pickSession(_ id: String) {
        closePickers()
        if id == Self.noSessionID {
            onLinkSession?(nil)
            return
        }
        let known = claudeProjects.lazy.flatMap(\.sessions).first { $0.id == id }
        guard let session = known ?? (linkedSession?.id == id ? linkedSession : nil) else { return }
        onLinkSession?(session)
    }

    /// A click anywhere else in the overlay closes an open dropdown (the click still lands).
    private func mouseDown(on view: NSView?) {
        guard let open = dropdowns.first(where: { !$0.box.isHidden }) else { return }
        if let view, view.isDescendant(of: open.box) || view === open.anchor { return }
        closePickers()
    }

    @objc private func titleButtonClicked() {
        toggleDocumentPicker()
    }

    @objc private func chatTitleButtonClicked() {
        toggleSessionPicker()
    }

    func changeFontSize(by delta: Double) {
        settings.fontSize += delta
        renderNotes(position: .keepReadingPosition)
        chat.render(chatSource, fontSize: chatFontSize, position: .keepReadingPosition)
    }

    // MARK: - Compact / expanded

    func toggleExpanded() {
        setExpanded(!isExpanded)
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        closePickers()
        expandedForChat = false
        settings.setFrame(panel.frame, expanded: isExpanded)
        isExpanded = expanded
        settings.expanded = expanded
        updateExpandButton()
        let target = onScreen(settings.frame(expanded: expanded)) ?? defaultFrame(expanded: expanded)
        resizeFrame { panel.setFrame(target, display: true, animate: panel.isVisible) }
    }

    /// Top-center of the screen that has the camera, right under the menu bar,
    /// so reading keeps your eyes near the webcam. Resets the current mode's size.
    func moveToWebcam() {
        resizeFrame { panel.setFrame(defaultFrame(expanded: isExpanded), display: true) }
        saveFrame()
    }

    private func resizeFrame(_ change: () -> Void) {
        isAdjustingFrame = true
        notes.resizing { chat.resizing(change) }
        isAdjustingFrame = false
        chat.pin(toHeading: chatPin)
    }

    private func defaultFrame(expanded: Bool) -> NSRect {
        guard let visible = Self.cameraScreen()?.visibleFrame else { return panel.frame }
        let size = expanded
            ? NSSize(width: min(max(900, visible.width * 0.55), visible.width - 40),
                     height: min(max(420, visible.height * 0.6), visible.height))
            : NSSize(width: min(620, visible.width * 0.6), height: 210)
        return NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// Returns `frame` if it is still meaningfully visible on some screen.
    private func onScreen(_ frame: NSRect?) -> NSRect? {
        guard let frame else { return nil }
        let visible = NSScreen.screens.contains {
            let overlap = $0.visibleFrame.intersection(frame)
            return overlap.width > 80 && overlap.height > 40
        }
        return visible ? frame : nil
    }

    private func updateExpandButton() {
        let symbol = isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        expandButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        hint(expandButton, isExpanded ? "Thu gọn (⌥E bên phải)" : "Mở rộng (⌥E bên phải)")
    }

    @objc private func expandButtonClicked() {
        toggleExpanded()
    }

    private static func cameraScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let notched = screens.first(where: { $0.safeAreaInsets.top > 0 }) { return notched }
        if let builtIn = screens.first(where: {
            guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }) { return builtIn }
        return NSScreen.main ?? screens.first
    }

    private func restoreFrame() {
        isExpanded = settings.expanded
        updateExpandButton()
        panel.setFrame(onScreen(settings.frame(expanded: isExpanded)) ?? defaultFrame(expanded: isExpanded), display: false)
        outline.view.isHidden = !settings.outlineVisible
        outlineHandle.isHidden = !settings.outlineVisible
        outlineWidth.constant = settings.outlineVisible ? settings.outlineWidth : 0
        updateOutlineButton()
        chatColumn.isHidden = !(settings.chatVisible && isExpanded)
        split.adjustSubviews()
        if isChatVisible { split.setPosition(split.bounds.width * settings.chatRatio, ofDividerAt: 0) }
        updateChatButton()
    }

    private func ensureOnScreen() {
        if onScreen(panel.frame) == nil { moveToWebcam() }
    }

    @objc private func screensDidChange() {
        ensureOnScreen()
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        notes.beginLiveResize()
        chat.beginLiveResize()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        notes.endLiveResize()
        chat.endLiveResize()
        chat.pin(toHeading: chatPin)
    }

    func windowDidResize(_ notification: Notification) {
        if panel.inLiveResize { notes.restoreAnchor() }
        saveFrame()
    }

    private func saveFrame() {
        guard !isAdjustingFrame else { return }
        settings.setFrame(panel.frame, expanded: isExpanded)
    }

    // MARK: - NSSplitViewDelegate

    func splitViewWillResizeSubviews(_ notification: Notification) {
        notes.beginLiveResize()
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        notes.endLiveResize()
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        max(proposed, 260)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        min(proposed, splitView.bounds.width - 240)
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        // Only a divider drag reaches here with a mouse drag; remember the ratio the user chose.
        if NSApp.currentEvent?.type == .leftMouseDragged, splitView.bounds.width > 0 {
            settings.chatRatio = proposed / splitView.bounds.width
        }
        return proposed
    }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
                   ofDividerAt dividerIndex: Int) -> NSRect {
        // The drawn divider is 1pt; give it a comfortable grab area.
        proposedEffectiveRect.insetBy(dx: -4, dy: 0)
    }

    // MARK: - View setup

    private func buildContent() {
        let background = NSView()
        panel.contentView = background
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.frame = background.bounds
        blur.autoresizingMask = [.width, .height]
        background.addSubview(blur)
        backdrop.wantsLayer = true
        backdrop.frame = background.bounds
        backdrop.autoresizingMask = [.width, .height]
        background.addSubview(backdrop)

        for button in [expandButton, outlineButton, displayButton, chatButton, backButton] {
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(button)
        }
        expandButton.action = #selector(expandButtonClicked)
        outlineButton.action = #selector(outlineButtonClicked)
        displayButton.action = #selector(displayButtonClicked)
        displayButton.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Hiển thị")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        hint(displayButton, "Tuỳ chỉnh hiển thị: nền, làm mờ, nền sau chữ, độ đậm và cỡ chữ")
        backButton.action = #selector(backButtonClicked)
        backButton.contentTintColor = .controlAccentColor
        backButton.isHidden = true
        backButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        outline.view.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(outline.view)
        outlineWidth = outline.view.widthAnchor.constraint(equalToConstant: 0)
        chatButton.action = #selector(chatButtonClicked)

        for label in [titleLabel, progressLabel, chatTitle] {
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        for (group, label, button, action) in [
            (titleGroup, titleLabel, titleButton, #selector(titleButtonClicked)),
            (chatTitleGroup, chatTitle, chatTitleButton, #selector(chatTitleButtonClicked)),
        ] {
            let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .bold)) ?? NSImage())
            chevron.contentTintColor = .secondaryLabelColor
            group.orientation = .horizontal
            group.spacing = 4
            group.alignment = .centerY
            group.addArrangedSubview(label)
            group.addArrangedSubview(chevron)
            // The label truncates (compression below) rather than the group clipping it.
            label.setContentCompressionResistancePriority(Self.titleCompression, for: .horizontal)
            group.translatesAutoresizingMaskIntoConstraints = false
            // Transparent button over the group: the whole title is the drop-down handle.
            // No title and no hugging, so it never sizes the group (its default "Button" squeezed the name).
            button.title = ""
            button.isBordered = false
            button.isTransparent = true
            button.setContentHuggingPriority(.init(1), for: .horizontal)
            button.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        // The chevrons mark the titles as drop-downs; a hover hint here would hide the title itself.
        background.addSubview(titleGroup)
        background.addSubview(titleButton)
        // A capturable instance (dev or verification build, MP_ALLOW_CAPTURE=1) must look different from a protected one.
        captureLabel.font = .systemFont(ofSize: 10, weight: .bold)
        captureLabel.textColor = .systemRed
        captureLabel.lineBreakMode = .byTruncatingTail
        captureLabel.isHidden = OverlayPanel.captureSharingType == .none
        // Header priorities, all below the window's own size so the header never grows the
        // window: the capture warning and progress stay whole, then the file name, then the back button.
        captureLabel.setContentCompressionResistancePriority(.init(495), for: .horizontal)
        progressLabel.setContentCompressionResistancePriority(.dragThatCannotResizeWindow, for: .horizontal)
        backButton.setContentCompressionResistancePriority(.init(Self.titleCompression.rawValue - 40), for: .horizontal)
        backButton.lineBreakMode = .byTruncatingTail
        headerTrailing.orientation = .horizontal
        headerTrailing.alignment = .centerY
        headerTrailing.spacing = 8
        headerTrailing.detachesHiddenViews = true
        headerTrailing.translatesAutoresizingMaskIntoConstraints = false
        backButton.removeFromSuperview()
        for view in [backButton, captureLabel, progressLabel] as [NSView] { headerTrailing.addArrangedSubview(view) }
        background.addSubview(headerTrailing)
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progressLabel.textColor = .tertiaryLabelColor
        progressLabel.alignment = .right
        chatTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        chatTitle.lineBreakMode = .byTruncatingTail

        chat.textInset = 12
        chat.onCopySelection = { [weak self] count in
            guard let self else { return }
            confirmCopied(count, in: chatHeaderTitle)
        }
        notes.onCopySelection = { [weak self] count in
            guard let self else { return }
            confirmCopied(count, in: fileTitle)
        }
        chatColumn.wantsLayer = true
        chatColumn.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        input.translatesAutoresizingMaskIntoConstraints = false
        input.placeholder = Self.inputPlaceholder
        input.onSubmit = { [weak self] text in
            guard let self else { return }
            input.text = ""
            endKeyboard()
            onSubmitQuestion?(text)
        }
        input.onCancel = { [weak self] in
            self?.input.text = ""
            self?.endKeyboard()
        }
        terminalButton.isBordered = false
        terminalButton.contentTintColor = .secondaryLabelColor
        // A neutral terminal glyph: the button works with any terminal, not only Apple's Terminal.
        terminalButton.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Tiếp tục trong terminal")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        terminalButton.imagePosition = .imageLeading
        setTerminalButtonTitle(" Terminal")
        hint(terminalButton, "Copy lệnh claude --resume của cuộc trò chuyện này và mở terminal (⌘T, ⌘V, Enter)")
        terminalButton.target = self
        terminalButton.action = #selector(terminalButtonClicked)
        terminalButton.isHidden = true
        terminalButton.setContentCompressionResistancePriority(.init(Self.titleCompression.rawValue + 10), for: .horizontal)
        terminalButton.translatesAutoresizingMaskIntoConstraints = false
        chatColumn.addSubview(terminalButton)
        chatColumn.addSubview(chatTitleGroup)
        chatColumn.addSubview(chatTitleButton)
        chatColumn.addSubview(chat.scrollView)
        chatColumn.addSubview(input)

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(notes.scrollView)
        split.addArrangedSubview(chatColumn)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        background.addSubview(split)
        // Above the split view so it can straddle the outline's edge.
        hint(outlineHandle, "Kéo để đổi độ rộng mục lục, double-click để về mặc định")
        outlineHandle.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(outlineHandle)
        setUpOutlineHandle()

        // Dropdowns are plain subviews on top of everything: no extra window to leak into screen sharing.
        documentPicker.onPick = { [weak self] in self?.pickDocument($0) }
        sessionPicker.onPick = { [weak self] in self?.pickSession($0) }
        setUpDisplayBox()
        for dropdown in dropdowns { background.addSubview(dropdown.box) }
        // Preferred positions give way to the panel edges and never move the header or the window.
        let documentCenter = documentPicker.centerXAnchor.constraint(equalTo: titleGroup.centerXAnchor)
        let sessionLeading = sessionPicker.leadingAnchor.constraint(equalTo: chatColumn.leadingAnchor, constant: 6)
        let displayLeading = displayBox.leadingAnchor.constraint(equalTo: displayButton.leadingAnchor)
        for anchor in [documentCenter, sessionLeading, displayLeading] { anchor.priority = Self.dropdownAnchor }
        var dropdownEdges: [NSLayoutConstraint] = []
        for dropdown in dropdowns {
            dropdownEdges += [
                dropdown.box.topAnchor.constraint(equalTo: background.topAnchor, constant: OverlayPanel.headerHeight - 2),
                dropdown.box.leadingAnchor.constraint(greaterThanOrEqualTo: background.leadingAnchor, constant: 10),
                dropdown.box.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -10),
                dropdown.box.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor, constant: -10),
            ]
        }
        NSLayoutConstraint.activate(dropdownEdges)
        // The collapsed chat column is 0 x 0 pt: its contents give way at the far edges instead of conflicting.
        let chatColumnFarEdges = [
            chatTitleGroup.trailingAnchor.constraint(lessThanOrEqualTo: terminalButton.leadingAnchor, constant: -8),
            terminalButton.trailingAnchor.constraint(equalTo: chatColumn.trailingAnchor, constant: -10),
            chat.scrollView.trailingAnchor.constraint(equalTo: chatColumn.trailingAnchor),
            input.trailingAnchor.constraint(equalTo: chatColumn.trailingAnchor, constant: -10),
            input.bottomAnchor.constraint(equalTo: chatColumn.bottomAnchor, constant: -8),
        ]
        for constraint in chatColumnFarEdges { constraint.priority = .required - 1 }
        // Centered when there is room; a long name or the back button shifts it instead of squeezing it.
        let titleCenter = titleGroup.centerXAnchor.constraint(equalTo: background.centerXAnchor)
        titleCenter.priority = .init(Self.titleCompression.rawValue - 100)

        NSLayoutConstraint.activate([
            expandButton.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            expandButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            expandButton.widthAnchor.constraint(equalToConstant: 20),
            expandButton.heightAnchor.constraint(equalToConstant: 20),

            chatButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            chatButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            chatButton.widthAnchor.constraint(equalToConstant: 20),
            chatButton.heightAnchor.constraint(equalToConstant: 20),

            titleCenter,
            titleGroup.centerYAnchor.constraint(equalTo: background.topAnchor, constant: OverlayPanel.headerHeight / 2),
            titleGroup.leadingAnchor.constraint(greaterThanOrEqualTo: displayButton.trailingAnchor, constant: 10),
            titleGroup.trailingAnchor.constraint(lessThanOrEqualTo: headerTrailing.leadingAnchor, constant: -8),
            titleButton.leadingAnchor.constraint(equalTo: titleGroup.leadingAnchor, constant: -6),
            titleButton.trailingAnchor.constraint(equalTo: titleGroup.trailingAnchor, constant: 6),
            titleButton.topAnchor.constraint(equalTo: background.topAnchor),
            titleButton.heightAnchor.constraint(equalToConstant: OverlayPanel.headerHeight),

            documentCenter, sessionLeading, displayLeading,

            outlineButton.leadingAnchor.constraint(equalTo: expandButton.trailingAnchor, constant: 4),
            outlineButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            outlineButton.widthAnchor.constraint(equalToConstant: 20),
            outlineButton.heightAnchor.constraint(equalToConstant: 20),

            displayButton.leadingAnchor.constraint(equalTo: outlineButton.trailingAnchor, constant: 4),
            displayButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            displayButton.widthAnchor.constraint(equalToConstant: 20),
            displayButton.heightAnchor.constraint(equalToConstant: 20),

            headerTrailing.trailingAnchor.constraint(equalTo: chatButton.leadingAnchor, constant: -6),
            headerTrailing.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            split.topAnchor.constraint(equalTo: background.topAnchor, constant: OverlayPanel.headerHeight - 4),
            outline.view.topAnchor.constraint(equalTo: split.topAnchor),
            outline.view.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            outline.view.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            outlineWidth,
            split.leadingAnchor.constraint(equalTo: outline.view.trailingAnchor),
            outlineHandle.centerXAnchor.constraint(equalTo: outline.view.trailingAnchor),
            outlineHandle.widthAnchor.constraint(equalToConstant: 8),
            outlineHandle.topAnchor.constraint(equalTo: outline.view.topAnchor),
            outlineHandle.bottomAnchor.constraint(equalTo: outline.view.bottomAnchor),
            split.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4),

            chatTitleGroup.topAnchor.constraint(equalTo: chatColumn.topAnchor, constant: 6),
            chatTitleGroup.leadingAnchor.constraint(equalTo: chatColumn.leadingAnchor, constant: 12),
            chatTitleButton.leadingAnchor.constraint(equalTo: chatTitleGroup.leadingAnchor, constant: -6),
            chatTitleButton.trailingAnchor.constraint(equalTo: chatTitleGroup.trailingAnchor, constant: 6),
            chatTitleButton.topAnchor.constraint(equalTo: chatColumn.topAnchor),
            chatTitleButton.bottomAnchor.constraint(equalTo: chat.scrollView.topAnchor),
            terminalButton.centerYAnchor.constraint(equalTo: chatTitle.centerYAnchor),

            chat.scrollView.topAnchor.constraint(equalTo: chatTitle.bottomAnchor, constant: 2),
            chat.scrollView.leadingAnchor.constraint(equalTo: chatColumn.leadingAnchor),

            input.topAnchor.constraint(equalTo: chat.scrollView.bottomAnchor, constant: 6),
            input.leadingAnchor.constraint(equalTo: chatColumn.leadingAnchor, constant: 10),
        ] + chatColumnFarEdges)
    }

    /// File name and chat title keep their width ahead of the back button, below the window size.
    private static let titleCompression = NSLayoutConstraint.Priority(300)
    /// Below the title's centering (titleCompression - 100).
    private static let dropdownAnchor = NSLayoutConstraint.Priority(150)
}

/// Split view with a faint divider that never drags the window.
final class OverlaySplitView: NSSplitView {
    override var dividerColor: NSColor { NSColor.white.withAlphaComponent(0.1) }
    override var mouseDownCanMoveWindow: Bool { false }
}

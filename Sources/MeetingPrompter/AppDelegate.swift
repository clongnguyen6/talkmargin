import AppKit
import Carbon.HIToolbox
import os
import PrompterCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings()
    private lazy var overlay = OverlayController(settings: settings)
    private let capture = AudioCapture()
    private lazy var clip = ClipTranscriber(capture: capture)
    // Empty markdown when no document is open: the help page is not notes.
    private lazy var chat = ClaudeChat { [unowned self] in
        (overlay.fileURL?.path, overlay.fileURL == nil ? "" : overlay.notesMarkdown)
    }
    private var statusItem: NSStatusItem?
    private var claudeProjects: [ClaudeProject] = []
    /// Held for the life of the process: this is the one running instance. Nil only when the
    /// lock could not be used at all (the user was told).
    private let instanceLock: InstanceLock?
    /// Verification builds only (`TestHooks`); production and dev always run with `.none`.
    private let hooks: TestHooks
    private let log = Logger(subsystem: "MeetingPrompter", category: "documents")

    init(instanceLock: InstanceLock?, hooks: TestHooks = .none) {
        self.instanceLock = instanceLock
        self.hooks = hooks
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        watchForConflictingCopies()
        // Headless verification runs: no status item, shortcut tap (no Accessibility prompt) or Claude catalog.
        if !hooks.headless {
            setUpStatusItem()
            registerHotKeys()
            refreshClaudeSessions()
        }
        setUpChat()
        if overlay.fileURL == nil {
            if let path = settings.lastFile, FileManager.default.fileExists(atPath: path) {
                overlay.open(URL(fileURLWithPath: path))
            } else {
                showHelp()
            }
        }
        if settings.overlayVisible { present() }
    }

    // MARK: - Conflicting copies

    private var conflictWatch: NSKeyValueObservation?
    /// Pids already scheduled for a check, so repeated changes never warn twice.
    private var watchedPIDs: Set<Int32> = []

    /// Launch-time detection misses a copy started later, e.g. an old build opened by hand. Key-value
    /// observation of the running apps (the launch notification is not posted for menu-bar-only apps
    /// like this one); a conflicting copy still alive after a second launch's lifetime is not a
    /// forwarding launch, so the user is warned in the overlay header (invisible to sharing).
    private func watchForConflictingCopies() {
        guard conflictWatch == nil else { return }
        conflictWatch = Self.observeRunningApps()
    }

    /// Built outside the main actor: the change handler may run on another thread, and a closure
    /// written in this main-actor class would carry a main-thread check that traps there.
    private nonisolated static func observeRunningApps() -> NSKeyValueObservation {
        NSWorkspace.shared.observe(\.runningApplications, options: [.initial, .new]) { _, change in
            let apps = (change.newValue ?? []).map { ($0.processIdentifier, $0.bundleIdentifier) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let delegate = NSApp.delegate as? AppDelegate else { return }
                    for (pid, bundleID) in apps { delegate.copyLaunched(pid: pid, bundleID: bundleID) }
                }
            }
        }
    }

    private func copyLaunched(pid: Int32, bundleID: String?) {
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier,
              AppIdentity.current.conflicts(with: bundleID), watchedPIDs.insert(pid).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + LegacyInstances.secondLaunchLifetime) {
            MainActor.assumeIsolated {
                // Only a build from before the lock: a current build's second launch (e.g. showing a notice) is not one.
                guard let delegate = NSApp.delegate as? AppDelegate,
                      !LegacyInstances.stillRunning([pid]).isEmpty,
                      let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                      LegacyInstances.Other(app).isLegacyBuild else { return }
                delegate.log.error("Another copy runs next to this instance: pid \(pid, privacy: .public) (\(bundleID ?? "?", privacy: .public))")
                delegate.overlay.showNotice("⚠️ Một bản TalkMargin khác đang chạy (pid \(pid)): hãy thoát một bản", seconds: 12)
            }
        }
    }

    /// Shows the overlay, except in headless verification runs.
    private func present() {
        guard !hooks.headless else { return }
        overlay.show()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.last else { return }
        openNotes(url)
    }

    /// Same rule as the open dialog and the recents: only what `NotesLoader` reads.
    private func openNotes(_ url: URL) {
        guard NotesLoader.isSupported(url) else {
            overlay.showMarkdown("## Không hỗ trợ loại file\n\n`\(url.path)`\n\nMở được: \(Self.fileTypes).", title: "Không mở được")
            present()
            return
        }
        overlay.open(url)
        if hooks.headless {
            log.info("Opened document: \(self.overlay.fileURL?.path ?? "-", privacy: .public)")
        } else {
            log.info("Opened document: \(self.overlay.fileURL?.path ?? "-", privacy: .private)")
        }
        present()
    }

    // MARK: - Claude

    private func setUpChat() {
        chat.onChange = { [unowned self] in
            overlay.setAssistant(markdown: chat.markdown, title: chat.title, pin: chat.pinnedTitle)
            overlay.setTerminalAvailable(chat.terminalSession != nil)
            overlay.setLinkedSession(chat.link)
            overlay.setClaudeContext(busy: chat.isBusy, documentPath: chat.notesInContext?.path)
        }
        overlay.suggestedSession = { [unowned self] in chat.suggestedSession(forDocument: $0) }
        // Restores the latest saved conversation for this session.
        chat.link(to: settings.linkedSession)
        overlay.onSubmitQuestion = { [unowned self] in chat.ask($0) }
        overlay.onContinueInTerminal = { [unowned self] in continueInTerminal() }
        overlay.onOpenOtherFile = { [unowned self] in openFile() }
        overlay.onLinkSession = { [unowned self] in link($0) }
        overlay.onSessionPickerOpened = { [unowned self] in refreshClaudeSessions() }
        clip.onPreview = { [unowned self] in overlay.showRecording($0, placeholder: recordingPlaceholder) }
    }

    private var recordingPlaceholder: String {
        clip.notice.map { "🎙 \($0)" } ?? "🎙 Đang nghe cuộc họp và micro… nhả ⌥ / để dừng"
    }

    private func beginClip() {
        clip.begin()
        overlay.showRecording("", placeholder: recordingPlaceholder)
    }

    private func endClip() {
        Task {
            overlay.showRecording("", placeholder: "Đang chuyển thành chữ…")
            let text = await clip.end()
            overlay.finishRecording(text)
        }
    }

    private func askQuestion() {
        overlay.focusInput()
    }

    /// Reads session files off the main thread; the menu and the picker show the last loaded list.
    /// The picker leaves out the app's own meeting forks: it is for choosing a prepared session.
    private func refreshClaudeSessions() {
        let knownForks = chat.meetingForkIDs
        Task.detached(priority: .utility) {
            let projects = ClaudeSessionCatalog.recentProjects(knownForks: knownForks)
            await MainActor.run { [weak self] in
                self?.claudeProjects = projects.all
                self?.overlay.setClaudeProjects(projects.prepared)
            }
        }
    }

    /// The chat refuses while answering; settings follow only when it accepted.
    private func link(_ session: ClaudeSession?) {
        guard chat.link(to: session) else { return overlay.flashChatTitle(Self.busyNotice) }
        settings.linkedSession = session
    }

    private static let busyNotice = "⏳ Claude đang trả lời, thử lại sau"

    func applicationWillTerminate(_ notification: Notification) {
        overlay.saveScrollPosition()
    }

    // MARK: - Hot keys

    private func registerHotKeys() {
        let keys = RightOptionKeys.shared
        keys.register(keyCode: kVK_ANSI_P, onPress: { [unowned self] in overlay.toggle() })
        keys.register(keyCode: kVK_DownArrow, when: .overlayVisible,
                      onPress: { [unowned self] in overlay.beginHoldScroll(direction: 1) },
                      onRelease: { [unowned self] in overlay.endHoldScroll() })
        keys.register(keyCode: kVK_UpArrow, when: .overlayVisible,
                      onPress: { [unowned self] in overlay.beginHoldScroll(direction: -1) },
                      onRelease: { [unowned self] in overlay.endHoldScroll() })
        keys.register(keyCode: kVK_ANSI_RightBracket, when: .overlayVisible,
                      onPress: { [unowned self] in overlay.jumpToHeading(forward: true) })
        keys.register(keyCode: kVK_ANSI_LeftBracket, when: .overlayVisible,
                      onPress: { [unowned self] in overlay.jumpToHeading(forward: false) })
        keys.register(keyCode: kVK_ANSI_Equal, when: .overlayVisible,
                      onPress: { [unowned self] in overlay.changeFontSize(by: 2) })
        keys.register(keyCode: kVK_ANSI_Minus, when: .overlayVisible,
                      onPress: { [unowned self] in overlay.changeFontSize(by: -2) })
        keys.register(keyCode: kVK_ANSI_E, when: .overlayVisible,
                      onPress: { [unowned self] in overlay.toggleExpanded() })
        keys.register(keyCode: kVK_ANSI_T, when: .overlayVisible,
                      onPress: { [unowned self] in overlay.setClickThrough(!overlay.clickThrough) })
        keys.register(keyCode: kVK_ANSI_K, when: .overlayVisible, onPress: { [unowned self] in askQuestion() })
        keys.register(keyCode: kVK_ANSI_A, when: .overlayVisible, onPress: { [unowned self] in overlay.toggleChat() })
        keys.register(keyCode: kVK_ANSI_O, when: .overlayVisible, onPress: { [unowned self] in overlay.toggleOutline() })
        keys.register(keyCode: kVK_ANSI_D, when: .overlayVisible, onPress: { [unowned self] in overlay.toggleDocumentPicker() })
        keys.register(keyCode: kVK_ANSI_S, when: .overlayVisible, onPress: { [unowned self] in overlay.toggleSessionPicker() })
        // Only while a picker is open; otherwise ⌥↩ reaches the focused app.
        keys.register(keyCode: kVK_Return, when: .pickerOpen,
                      onPress: { [unowned self] in overlay.confirmPicker() })
        keys.register(keyCode: kVK_LeftArrow, when: .overlayVisible, onPress: { [unowned self] in overlay.goBack() })
        keys.register(keyCode: kVK_RightArrow, when: .overlayVisible, onPress: { [unowned self] in overlay.goForward() })
        keys.register(keyCode: kVK_ANSI_Slash, onPress: { [unowned self] in beginClip() },
                      onRelease: { [unowned self] in endClip() })
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (index, keyCode) in digits.enumerated() {
            keys.register(keyCode: keyCode, when: .overlayVisible, onPress: { [unowned self] in overlay.jumpToSection(index + 1) })
        }
        keys.start(state: { [unowned self] in
            TapState.Snapshot(overlayVisible: overlay.isVisible, pickerOpen: overlay.isPickerOpen)
        }) { [unowned self] in
            // Drop the permission notice once shortcuts work.
            if overlay.fileURL == nil { showHelp() }
        }
    }

    // MARK: - Menu bar

    /// The bundle's template glyph at 18 x 18 pt, or the SF Symbol when the bundle has none (e.g. `swift run`).
    static func menuBarImage() -> NSImage? {
        if let named = NSImage(named: "MenuBarIconTemplate")?.copy() as? NSImage {
            named.size = NSSize(width: 18, height: 18)
            named.isTemplate = true
            named.accessibilityDescription = "TalkMargin"
            return named
        }
        return NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "TalkMargin")
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarImage()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !RightOptionKeys.shared.isActive {
            menu.addItem(item("Cấp quyền Accessibility để bật phím tắt…", nil, #selector(openAccessibilitySettings)))
            menu.addItem(.separator())
        }

        menu.addItem(item(overlay.isVisible ? "Ẩn overlay" : "Hiện overlay", "p", #selector(toggleOverlay)))
        menu.addItem(item(overlay.isExpanded ? "Thu gọn" : "Mở rộng", "e", #selector(toggleExpanded)))
        menu.addItem(item(overlay.isOutlineVisible ? "Ẩn mục lục" : "Hiện mục lục", "o", #selector(toggleOutline)))
        menu.addItem(item(overlay.isChatVisible ? "Đóng khung Claude" : "Mở khung Claude", "a", #selector(toggleChat)))
        menu.addItem(.separator())
        menu.addItem(item("Hỏi Claude…", "k", #selector(askQuestionAction)))
        let talk = item("Giữ để nói câu hỏi", "/", #selector(askQuestionAction), enabled: false)
        talk.toolTip = "Giữ ⌥ / bên phải: thu âm thanh cuộc họp và micro, nhả ra để xem lại rồi Enter"
        menu.addItem(talk)
        menu.addItem(item("Chọn session Claude…", "s", #selector(showSessionPicker)))
        menu.addItem(claudeSessionItem())
        menu.addItem(item("Copy lệnh tiếp tục trong terminal", nil, #selector(continueInTerminal), enabled: chat.terminalSession != nil))
        menu.addItem(item("Cuộc trò chuyện mới", nil, #selector(newConversation), enabled: chat.hasConversation))
        menu.addItem(pastConversationsItem())
        menu.addItem(.separator())
        menu.addItem(item("Đổi tài liệu…", "d", #selector(showDocumentPicker)))
        menu.addItem(item("Mở file…", nil, #selector(openFile)))
        menu.addItem(recentFilesItem())
        let hasFile = overlay.fileURL != nil
        menu.addItem(item("Sửa file trong editor", nil, #selector(editFile), enabled: hasFile))
        menu.addItem(item("Tải lại", nil, #selector(reloadFile), enabled: hasFile))
        menu.addItem(.separator())
        menu.addItem(item("Chữ to hơn", "=", #selector(biggerFont)))
        menu.addItem(item("Chữ nhỏ hơn", "-", #selector(smallerFont)))
        menu.addItem(item("Tuỳ chỉnh hiển thị…", nil, #selector(showDisplaySettings)))
        let clickThrough = item("Click xuyên qua overlay", "t", #selector(toggleClickThrough))
        clickThrough.state = overlay.clickThrough ? .on : .off
        menu.addItem(clickThrough)
        menu.addItem(item("Đưa về sát webcam", nil, #selector(moveToWebcam)))
        menu.addItem(.separator())
        let launchAtLogin = item("Mở cùng macOS", nil, #selector(toggleLaunchAtLogin))
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLogin)
        menu.addItem(item("Phím tắt & hướng dẫn", nil, #selector(showHelp)))
        menu.addItem(item("Thoát", nil, #selector(quit)))
    }

    /// `shortcut` mirrors a global right-⌥ shortcut so the menu shows it natively.
    private func item(_ title: String, _ shortcut: String?, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: shortcut ?? "")
        item.keyEquivalentModifierMask = [.option]
        item.target = self
        return item
    }

    func menuDidClose(_ menu: NSMenu) {
        refreshClaudeSessions()
    }

    private func claudeSessionItem() -> NSMenuItem {
        let title = chat.link.map { "Session Claude: \(($0.cwd as NSString).lastPathComponent) · \($0.title)" }
            ?? "Session Claude: chưa liên kết"
        let parent = NSMenuItem(title: title.count > 60 ? String(title.prefix(60)) + "…" : title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let none = item("Không liên kết", nil, #selector(linkSession(_:)))
        none.state = chat.link == nil ? .on : .off
        submenu.addItem(none)
        submenu.addItem(.separator())
        if claudeProjects.isEmpty {
            submenu.addItem(NSMenuItem(title: "Không tìm thấy session nào trong ~/.claude/projects", action: nil, keyEquivalent: ""))
        }
        for project in claudeProjects {
            let projectItem = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
            projectItem.toolTip = project.cwd
            let sessions = NSMenu()
            for session in project.sessions {
                let entry = item("\(session.title)  ·  \(session.modified.formatted(.relative(presentation: .named)))",
                                 nil, #selector(linkSession(_:)))
                entry.representedObject = session.id
                entry.toolTip = session.id
                entry.state = chat.link?.id == session.id ? .on : .off
                if entry.state == .on { projectItem.state = .mixed }
                sessions.addItem(entry)
            }
            projectItem.submenu = sessions
            submenu.addItem(projectItem)
        }
        parent.submenu = submenu
        return parent
    }

    private func pastConversationsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Cuộc trò chuyện trước", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let saved = chat.savedConversations.prefix(15)
        for conversation in saved {
            var summary = conversation.summary.replacingOccurrences(of: "\n", with: " ")
            if summary.count > 50 { summary = String(summary.prefix(50)) + "…" }
            let date = conversation.updated.formatted(.dateTime.day().month(.abbreviated).hour().minute())
            let project = conversation.link.map { " · \(($0.cwd as NSString).lastPathComponent)" } ?? ""
            let entry = item("\(summary)  ·  \(date)\(project)", nil, #selector(openConversation(_:)))
            entry.representedObject = conversation.id.uuidString
            entry.toolTip = conversation.summary
            entry.state = conversation.id == chat.currentConversationID ? .on : .off
            submenu.addItem(entry)
        }
        if saved.isEmpty {
            submenu.addItem(NSMenuItem(title: "Chưa có cuộc trò chuyện nào", action: nil, keyEquivalent: ""))
        }
        parent.submenu = submenu
        return parent
    }

    private func recentFilesItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Mở gần đây", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let recents = settings.openableRecentFiles
        for path in recents {
            let entry = NSMenuItem(title: (path as NSString).lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = path
            entry.toolTip = path
            entry.state = path == overlay.fileURL?.path ? .on : .off
            submenu.addItem(entry)
        }
        if recents.isEmpty {
            submenu.addItem(NSMenuItem(title: "Chưa có file nào", action: nil, keyEquivalent: ""))
        } else {
            submenu.addItem(.separator())
            submenu.addItem(item("Xoá danh sách", nil, #selector(clearRecents)))
        }
        parent.submenu = submenu
        return parent
    }

    // MARK: - Actions

    @objc private func toggleOverlay() { overlay.toggle() }
    @objc private func toggleChat() { overlay.toggleChat(); overlay.show() }
    @objc private func toggleOutline() { overlay.toggleOutline(); overlay.show() }
    @objc private func askQuestionAction() { askQuestion() }
    @objc private func newConversation() {
        if !chat.reset() { overlay.flashChatTitle(Self.busyNotice) }
    }

    @objc private func openConversation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        settings.linkedSession = chat.open(id)
        overlay.setChatVisible(true)
        overlay.show()
    }

    @objc private func continueInTerminal() {
        guard let session = chat.terminalSession else { return }
        TerminalLauncher.resume(sessionID: session.id, in: session.cwd)
        overlay.confirmTerminalCommandCopied()
    }

    @objc private func linkSession(_ sender: NSMenuItem) {
        let id = sender.representedObject as? String
        link(claudeProjects.lazy.flatMap(\.sessions).first { $0.id == id })
    }

    @objc private func showDocumentPicker() { overlay.toggleDocumentPicker() }
    @objc private func showSessionPicker() { overlay.toggleSessionPicker() }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            overlay.showMarkdown("## ⚠️ Không đổi được \"Mở cùng macOS\"\n\n\(error.localizedDescription)", title: "Lỗi")
            overlay.show()
        }
    }
    @objc private func toggleExpanded() { overlay.toggleExpanded(); overlay.show() }
    @objc private func reloadFile() { overlay.reload() }
    @objc private func biggerFont() { overlay.changeFontSize(by: 2) }
    @objc private func smallerFont() { overlay.changeFontSize(by: -2) }
    @objc private func toggleClickThrough() { overlay.setClickThrough(!overlay.clickThrough) }
    @objc private func moveToWebcam() { overlay.moveToWebcam(); overlay.show() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func clearRecents() { settings.recentFiles = [] }

    @objc private func showDisplaySettings() { overlay.showDisplaySettings() }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openNotes(URL(fileURLWithPath: path))
    }

    @objc private func editFile() {
        guard let url = overlay.fileURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openFile() {
        OpenNotesDialog.present(startingAt: overlay.fileURL?.deletingLastPathComponent(), above: overlay.panel) { [unowned self] in
            openNotes($0)
        }
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func showHelp() {
        let notice = RightOptionKeys.shared.isActive ? "" : Self.permissionNotice
        overlay.showMarkdown(notice + Self.helpText, title: "Hướng dẫn")
        present()
    }

    private static var fileTypes: String {
        NotesLoader.supportedExtensions.map { "`.\($0)`" }.joined(separator: ", ")
    }

    private static let helpText = """
    # TalkMargin

    Bấm **tên file trên header** (hoặc `⌥D`) để đổi tài liệu (\(AppDelegate.fileTypes)): file mở gần đây, hoặc **Duyệt thư mục…** để mở file khác ngay trong overlay, kể cả khi đang share màn hình. **Hộp thoại mở file…** của macOS chỉ dùng khi không share: menu trong hộp thoại đó hiện lên với người xem. Khi bạn sửa và lưu file trong editor hoặc Word, overlay tự cập nhật.

    ## Phím tắt (giữ ⌥ bên phải)
    - `⌥P` ẩn / hiện overlay
    - `⌥↓` / `⌥↑` cuộn xuống / lên, giữ phím để cuộn liên tục
    - `⌥]` / `⌥[` nhảy tới heading sau / trước
    - `⌥1` … `⌥9` nhảy tới phần thứ N
    - `⌥O` hoặc nút `☰` hiện / ẩn mục lục, click heading để nhảy tới
    - `⌥←` quay lại chỗ đang đọc dở trước khi nhảy (nút `↩` trên header), `⌥→` đi tới lại
    - `⌥E` mở rộng / thu gọn overlay
    - `⌥=` / `⌥-` chữ to / nhỏ hơn
    - `⌥T` bật / tắt click xuyên qua overlay
    - `⌥D` đổi tài liệu, `⌥S` chọn session Claude. Trong danh sách: `⌥↓` `⌥↑` chọn, `⌥↩` mở, `⌥1`…`⌥9` mở nhanh dòng thứ N

    ⌥ bên trái vẫn hoạt động bình thường trong các app khác.

    ## Hỏi Claude
    - `⌥A` hoặc nút `>>` mở / đóng khung Claude bên phải (kéo thanh chia để đổi tỉ lệ)
    - Giữ `⌥ /` để thu âm thanh cuộc họp và micro, nhả ra để xem lại chữ rồi Enter. Giữ thêm lần nữa để nối tiếp.
    - `⌥K` gõ câu hỏi cho Claude, Enter gửi, Shift+Enter xuống dòng

    Bấm **tiêu đề khung Claude** (hoặc `⌥S`) để chọn session Claude Code, để Claude hiểu project.

    ## Mẹo
    - Kéo thanh trên cùng để di chuyển, kéo mép để đổi kích thước. Chế độ thu gọn và mở rộng nhớ kích thước riêng.
    - Double-click thanh trên cùng hoặc bấm nút góc trái cũng để mở rộng / thu gọn.
    - Overlay không hiện khi bạn share màn hình, và không lấy focus của app họp.
    - Dùng heading `##` cho từng phần để nhảy nhanh bằng `⌥]`.
    """

    private static let permissionNotice = """
    ## ⚠️ Phím tắt chưa hoạt động
    Vào **System Settings → Privacy & Security → Accessibility** và bật **TalkMargin**. Phím tắt sẽ tự bật ngay sau đó.

    """
}

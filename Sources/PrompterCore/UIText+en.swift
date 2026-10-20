extension UIText {
    static let english: Table = [
        // Status menu
        .menuGrantAccessibility: "Grant Accessibility to enable shortcuts…",
        .menuShowOverlay: "Show overlay",
        .menuHideOverlay: "Hide overlay",
        .menuExpand: "Expand",
        .menuCompact: "Compact",
        .menuShowOutline: "Show outline",
        .menuHideOutline: "Hide outline",
        .menuOpenChat: "Open Claude column",
        .menuCloseChat: "Close Claude column",
        .menuAskClaude: "Ask Claude…",
        .menuHoldToTalk: "Hold to speak a question",
        .menuHoldToTalkHint: "Hold right ⌥ /: records the meeting and your mic; release to review, then Enter",
        .menuChooseSession: "Choose Claude session…",
        .menuSessionLinked: "Claude session: {0} · {1}",
        .menuSessionNotLinked: "Claude session: not linked",
        .menuNotLinked: "Not linked",
        .menuNoSessions: "No sessions found in ~/.claude/projects",
        .menuCopyResumeCommand: "Copy command to continue in terminal",
        .menuNewConversation: "New conversation",
        .menuPastConversations: "Past conversations",
        .menuNoConversations: "No conversations yet",
        .menuSwitchDocument: "Switch document…",
        .menuOpenFile: "Open file…",
        .menuOpenRecent: "Open recent",
        .menuNoRecentFiles: "No files yet",
        .menuClearRecents: "Clear list",
        .menuEditFile: "Edit file in editor",
        .menuReload: "Reload",
        .menuLargerText: "Larger text",
        .menuSmallerText: "Smaller text",
        .menuDisplaySettings: "Display settings…",
        .menuClickThrough: "Click through overlay",
        .menuMoveToWebcam: "Move next to webcam",
        .menuLaunchAtLogin: "Open at login",
        .menuHelp: "Shortcuts & help",
        .menuQuit: "Quit",

        // Pages shown in the notes pane
        .pageHelpTitle: "Help",
        .pageHelp: """
        # TalkMargin

        Click the **file name in the header** (or `⌥D`) to switch documents ({0}): recent files, or **Browse folders…** to open another file right in the overlay, even while sharing your screen. Use the macOS **Open dialog…** only when not sharing: its menus are visible to viewers. When you edit and save the file in an editor or Word, the overlay updates.

        ## Shortcuts (hold right ⌥)
        - `⌥P` show / hide the overlay
        - `⌥↓` / `⌥↑` scroll down / up, hold to keep scrolling
        - `⌥]` / `⌥[` next / previous heading
        - `⌥1` … `⌥9` jump to section N
        - `⌥O` or the `☰` button shows / hides the outline; click a heading to jump to it
        - `⌥←` back to where you were before a jump (the `↩` header button), `⌥→` forward again
        - `⌥E` expand / compact the overlay
        - `⌥=` / `⌥-` larger / smaller text
        - `⌥T` click-through on / off
        - `⌥D` switch document, `⌥S` choose the Claude session. In a list: `⌥↓` `⌥↑` select, `⌥↩` open, `⌥1`…`⌥9` open row N

        Left ⌥ keeps working normally in other apps.

        ## Ask Claude
        - `⌥A` or the `>>` button opens / closes the Claude column on the right (drag the divider to resize)
        - Hold `⌥ /` to record the meeting audio and your mic, release to review the text, then Enter. Hold again to add more.
        - `⌥K` type a question for Claude, Enter sends, Shift+Enter adds a line

        Click the **Claude column title** (or `⌥S`) to choose a Claude Code session, so Claude knows the project.

        ## Tips
        - Drag the top bar to move, drag an edge to resize. Compact and expanded views remember their own size.
        - Double-click the top bar or click the top-left button to expand / compact.
        - The overlay is hidden from screen sharing and never takes focus from the meeting app.
        - Use a `##` heading for each part to jump quickly with `⌥]`.
        - Interface language: the slider button in the header, **Language** (VI | EN).
        """,
        .pagePermissionNotice: """
        ## ⚠️ Shortcuts are not working yet
        Open **System Settings → Privacy & Security → Accessibility** and turn on **TalkMargin**. Shortcuts start right after.

        """,
        .pageErrorTitle: "Error",
        .pageLaunchAtLoginFailed: "⚠️ Could not change \"{0}\"",
        .pageCannotOpenTitle: "Cannot open",
        .pageUnsupportedType: "Unsupported file type",
        .pageSupportedTypes: "Supported: {0}.",
        .pageCannotRead: "Cannot read the file",
        .emptyDocxNotes: "*(The document has no text.)*\n",

        // Header, hints and notices
        .hintShowOutline: "Show outline (right ⌥O)",
        .hintHideOutline: "Hide outline (right ⌥O)",
        .hintBack: "Back to: {0} (right ⌥←)",
        .backFallback: "Back",
        .hintOpenChat: "Open Claude column (right ⌥A)",
        .hintCloseChat: "Close Claude column (right ⌥A)",
        .hintExpand: "Expand (right ⌥E)",
        .hintCompact: "Compact (right ⌥E)",
        .hintDisplay: "Display: backdrop, blur, text band, opacity, font size and language",
        .hintTerminal: "Copy this conversation's claude --resume command and open the terminal (⌘T, ⌘V, Enter)",
        .hintOutlineHandle: "Drag to resize the outline, double-click to reset",
        .accessibilityDisplay: "Display",
        .accessibilityTerminal: "Continue in terminal",
        .captureAllowed: "● CAPTURE ALLOWED",
        .clickThroughProgress: "click-through",
        .noticeCopied: "✓ Copied {0} characters",
        .noticeCommandCopied: "✓ Command copied",
        .noticeClaudeBusy: "⏳ Claude is answering, try again later",
        .noticeOtherCopyRunning: "⚠️ Another TalkMargin is running (pid {0}): quit one of them",

        // Question box and push-to-talk
        .inputPlaceholder: "Ask Claude…  Enter send · Esc cancel · hold ⌥ / to talk",
        .recordingListening: "🎙 Recording meeting and mic… release ⌥ / to stop",
        .recordingTranscribing: "Transcribing…",
        .recordingNoAudio: "Could not capture audio: {0}",
        .recordingVietnameseDownloading: "Downloading the Vietnamese model; English only this time.",
        .speechUnsupported: "This Mac has no on-device {0} speech recognition.",
        .speechEnglish: "English",
        .speechVietnamese: "Vietnamese",
        .audioNoDisplay: "No display found to capture system audio.",

        // Pickers
        .pickerKeys: "⌥↓ ⌥↑ select  ·  ⌥↩ open  ·  ⌥1…9 quick open",
        .pickerDocuments: "Documents",
        .pickerNoFiles: "No files opened yet",
        .pickerClaudeHasDocument: "Claude has this document",
        .pickerBrowse: "Browse folders…",
        .pickerOpenDialog: "Open dialog… (not while sharing)",
        .pickerRecent: "Recent",
        .pickerParentFolder: "Parent folder · {0}",
        .pickerEmptyFolder: "No subfolders or files to open",
        .pickerSessions: "Claude session that answers",
        .pickerSessionsBusy: "⏳ Claude is answering · switch when done",
        .pickerNoSession: "No linked session",
        .pickerLinked: "Linked · {0}",
        .pickerUsedWith: "used with {0}",
        .pickerReadingSessions: "Reading ~/.claude/projects…",

        // Display settings
        .displayTitle: "Display",
        .displayBackdrop: "Backdrop",
        .displayBlur: "Blur apps behind",
        .displayTextBand: "Text band",
        .displayTextOpacity: "Text opacity",
        .displayFontSize: "Font size",
        .displayLanguage: "Language",
        .displayHint: "Turn blur off to see through (e.g. a shared screen); raise \"{0}\" to keep text clear on light backgrounds.",
        .displayOff: "Off",
        .displayDefaults: "Defaults",

        // Claude chat
        .chatAsking: "Asking Claude…",
        .chatEmptyLinked: "Linked: **{0}** in `{1}`. Click the **Claude column title** (or `⌥S`) to change the session.",
        .chatEmptyNotLinked: "No Claude session linked. Click the **Claude column title** (or `⌥S`) to choose a Claude Code session, so Claude knows the project.",
        .chatEmptyPage: """
        ## Ask Claude

        {0}

        - Claude answers from the open document. Switching documents (`⌥D`) keeps the session and the conversation: the next question carries the new document.
        - Hold `⌥ /` to record the meeting audio and your mic, release, then review the text before Enter. Hold again to add more.
        - `⌥K` types a question, Shift+Enter adds a line.
        - `⌥A` or the `>>` button opens / closes this column.
        """,
        .chatEmptyConversation: "Empty conversation",
        .chatUntitledNotes: "notes",
        .sessionUntitled: "Untitled session",
        .claudeNotFound: "Command `claude` not found. Install Claude Code or add it to PATH.",
        .claudeExited: "claude exited with code {0}.",
        .claudeUnknownError: "Unknown error",

        // Notes files
        .loadUnreadable: "Cannot read the file: {0}",
        .loadNotZip: "The file is not a Word .docx (not a zip package).",
        .loadCorrupt: "The .docx file is damaged or not supported: {0}",
        .loadMissingDocument: "The .docx file has no content part (word/document.xml).",
        .loadMalformedXML: "The .docx content is damaged ({0}): {1}",

        // Launch notices
        .launchLegacyRunning: "An old build of the app (Meeting Prompter) is running. Quit it first (its menu bar icon → Thoát), then open TalkMargin again.",
        .launchNotForwarded: "TalkMargin could not hand the document to the running copy. It is now first in the recent files.",
        .launchOtherRunning: "Another TalkMargin{0} is running, so this one does not open. Quit the other one first.",
        .launchUnbundled: "unbundled build",
        .launchNoLock: "TalkMargin cannot use its single-instance lock ({0}).",
        .launchNoLockOtherRunning: "Another copy is running, so this one does not open.",
        .launchNoLockAlone: "The app still runs, but do not open a second copy.",
        .launchDocumentsKept: "The document you just opened is now first in the recent files.",
    ]
}

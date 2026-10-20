extension UIText {
    /// One case per interface string. `{0}`, `{1}`… are filled by `tr(_:_:)`.
    public enum Key: String, CaseIterable, Sendable {
        // Status menu
        case menuGrantAccessibility, menuShowOverlay, menuHideOverlay, menuExpand, menuCompact
        case menuShowOutline, menuHideOutline, menuOpenChat, menuCloseChat
        case menuAskClaude, menuHoldToTalk, menuHoldToTalkHint, menuChooseSession
        case menuSessionLinked, menuSessionNotLinked, menuNotLinked, menuNoSessions
        case menuCopyResumeCommand, menuNewConversation, menuPastConversations, menuNoConversations
        case menuSwitchDocument, menuOpenFile, menuOpenRecent, menuNoRecentFiles, menuClearRecents
        case menuEditFile, menuReload, menuLargerText, menuSmallerText, menuDisplaySettings
        case menuClickThrough, menuMoveToWebcam, menuLaunchAtLogin, menuHelp, menuQuit

        // Pages shown in the notes pane
        case pageHelpTitle, pageHelp, pagePermissionNotice
        case pageErrorTitle, pageLaunchAtLoginFailed
        case pageCannotOpenTitle, pageUnsupportedType, pageSupportedTypes, pageCannotRead
        case emptyDocxNotes

        // Header, hints and notices
        case hintShowOutline, hintHideOutline, hintBack, backFallback, hintOpenChat, hintCloseChat
        case hintExpand, hintCompact, hintDisplay, hintTerminal, hintOutlineHandle
        case accessibilityDisplay, accessibilityTerminal
        case captureAllowed, clickThroughProgress
        case noticeCopied, noticeCommandCopied, noticeClaudeBusy, noticeOtherCopyRunning

        // Question box and push-to-talk
        case inputPlaceholder, recordingListening, recordingTranscribing
        case recordingNoAudio, recordingVietnameseDownloading, speechUnsupported
        case speechEnglish, speechVietnamese, audioNoDisplay

        // Pickers
        case pickerKeys, pickerDocuments, pickerNoFiles, pickerClaudeHasDocument
        case pickerBrowse, pickerOpenDialog, pickerRecent, pickerParentFolder, pickerEmptyFolder
        case pickerSessions, pickerSessionsBusy, pickerNoSession, pickerLinked, pickerUsedWith
        case pickerReadingSessions

        // Display settings
        case displayTitle, displayBackdrop, displayBlur, displayTextBand, displayTextOpacity
        case displayFontSize, displayLanguage, displayHint, displayOff, displayDefaults

        // Claude chat
        case chatAsking, chatEmptyLinked, chatEmptyNotLinked, chatEmptyPage
        case chatEmptyConversation, chatUntitledNotes, sessionUntitled
        case claudeNotFound, claudeExited, claudeUnknownError

        // Notes files
        case loadUnreadable, loadNotZip, loadCorrupt, loadMissingDocument, loadMalformedXML

        // Launch notices
        case launchLegacyRunning, launchNotForwarded, launchOtherRunning, launchUnbundled
        case launchNoLock, launchNoLockOtherRunning, launchNoLockAlone, launchDocumentsKept
    }
}

extension UIText {
    static let vietnamese: Table = [
        // Status menu
        .menuGrantAccessibility: "Cấp quyền Accessibility để bật phím tắt…",
        .menuShowOverlay: "Hiện overlay",
        .menuHideOverlay: "Ẩn overlay",
        .menuExpand: "Mở rộng",
        .menuCompact: "Thu gọn",
        .menuShowOutline: "Hiện mục lục",
        .menuHideOutline: "Ẩn mục lục",
        .menuOpenChat: "Mở khung Claude",
        .menuCloseChat: "Đóng khung Claude",
        .menuAskClaude: "Hỏi Claude…",
        .menuHoldToTalk: "Giữ để nói câu hỏi",
        .menuHoldToTalkHint: "Giữ ⌥ / bên phải: thu âm thanh cuộc họp và micro, nhả ra để xem lại rồi Enter",
        .menuChooseSession: "Chọn session Claude…",
        .menuSessionLinked: "Session Claude: {0} · {1}",
        .menuSessionNotLinked: "Session Claude: chưa liên kết",
        .menuNotLinked: "Không liên kết",
        .menuNoSessions: "Không tìm thấy session nào trong ~/.claude/projects",
        .menuCopyResumeCommand: "Copy lệnh tiếp tục trong terminal",
        .menuNewConversation: "Cuộc trò chuyện mới",
        .menuPastConversations: "Cuộc trò chuyện trước",
        .menuNoConversations: "Chưa có cuộc trò chuyện nào",
        .menuSwitchDocument: "Đổi tài liệu…",
        .menuOpenFile: "Mở file…",
        .menuOpenRecent: "Mở gần đây",
        .menuNoRecentFiles: "Chưa có file nào",
        .menuClearRecents: "Xoá danh sách",
        .menuEditFile: "Sửa file trong editor",
        .menuReload: "Tải lại",
        .menuLargerText: "Chữ to hơn",
        .menuSmallerText: "Chữ nhỏ hơn",
        .menuDisplaySettings: "Tuỳ chỉnh hiển thị…",
        .menuClickThrough: "Click xuyên qua overlay",
        .menuMoveToWebcam: "Đưa về sát webcam",
        .menuLaunchAtLogin: "Mở cùng macOS",
        .menuHelp: "Phím tắt & hướng dẫn",
        .menuQuit: "Thoát",

        // Pages shown in the notes pane
        .pageHelpTitle: "Hướng dẫn",
        .pageHelp: """
        # TalkMargin

        Bấm **tên file trên header** (hoặc `⌥D`) để đổi tài liệu ({0}): file mở gần đây, hoặc **Duyệt thư mục…** để mở file khác ngay trong overlay, kể cả khi đang share màn hình. **Hộp thoại mở file…** của macOS chỉ dùng khi không share: menu trong hộp thoại đó hiện lên với người xem. Khi bạn sửa và lưu file trong editor hoặc Word, overlay tự cập nhật.

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
        - Ngôn ngữ giao diện: nút thanh trượt trên header, mục **Ngôn ngữ** (VI | EN).
        """,
        .pagePermissionNotice: """
        ## ⚠️ Phím tắt chưa hoạt động
        Vào **System Settings → Privacy & Security → Accessibility** và bật **TalkMargin**. Phím tắt sẽ tự bật ngay sau đó.

        """,
        .pageErrorTitle: "Lỗi",
        .pageLaunchAtLoginFailed: "⚠️ Không đổi được \"{0}\"",
        .pageCannotOpenTitle: "Không mở được",
        .pageUnsupportedType: "Không hỗ trợ loại file",
        .pageSupportedTypes: "Mở được: {0}.",
        .pageCannotRead: "Không đọc được file",
        .emptyDocxNotes: "*(Tài liệu không có nội dung văn bản.)*\n",

        // Header, hints and notices
        .hintShowOutline: "Hiện mục lục (⌥O bên phải)",
        .hintHideOutline: "Ẩn mục lục (⌥O bên phải)",
        .hintBack: "Quay lại: {0} (⌥← bên phải)",
        .backFallback: "Quay lại",
        .hintOpenChat: "Mở khung Claude (⌥A bên phải)",
        .hintCloseChat: "Đóng khung Claude (⌥A bên phải)",
        .hintExpand: "Mở rộng (⌥E bên phải)",
        .hintCompact: "Thu gọn (⌥E bên phải)",
        .hintDisplay: "Tuỳ chỉnh hiển thị: nền, làm mờ, nền sau chữ, độ đậm, cỡ chữ và ngôn ngữ",
        .hintTerminal: "Copy lệnh claude --resume của cuộc trò chuyện này và mở terminal (⌘T, ⌘V, Enter)",
        .hintOutlineHandle: "Kéo để đổi độ rộng mục lục, double-click để về mặc định",
        .accessibilityDisplay: "Hiển thị",
        .accessibilityTerminal: "Tiếp tục trong terminal",
        .captureAllowed: "● ĐANG CHO CHỤP MÀN HÌNH",
        .clickThroughProgress: "xuyên chuột",
        .noticeCopied: "✓ Đã copy {0} ký tự",
        .noticeCommandCopied: "✓ Đã copy lệnh",
        .noticeClaudeBusy: "⏳ Claude đang trả lời, thử lại sau",
        .noticeOtherCopyRunning: "⚠️ Một bản TalkMargin khác đang chạy (pid {0}): hãy thoát một bản",

        // Question box and push-to-talk
        .inputPlaceholder: "Hỏi Claude…  Enter gửi · Esc huỷ · giữ ⌥ / để nói",
        .recordingListening: "🎙 Đang nghe cuộc họp và micro… nhả ⌥ / để dừng",
        .recordingTranscribing: "Đang chuyển thành chữ…",
        .recordingNoAudio: "Không thu được âm thanh: {0}",
        .recordingVietnameseDownloading: "Đang tải model tiếng Việt, lần này chỉ nhận dạng tiếng Anh.",
        .speechUnsupported: "Máy không hỗ trợ nhận dạng giọng nói {0} on-device.",
        .speechEnglish: "tiếng Anh",
        .speechVietnamese: "tiếng Việt",
        .audioNoDisplay: "Không tìm thấy màn hình để thu âm thanh hệ thống.",

        // Pickers
        .pickerKeys: "⌥↓ ⌥↑ chọn  ·  ⌥↩ mở  ·  ⌥1…9 mở nhanh",
        .pickerDocuments: "Tài liệu",
        .pickerNoFiles: "Chưa mở file nào",
        .pickerClaudeHasDocument: "Claude đang có tài liệu này",
        .pickerBrowse: "Duyệt thư mục…",
        .pickerOpenDialog: "Hộp thoại mở file… (ngoài lúc share)",
        .pickerRecent: "Gần đây",
        .pickerParentFolder: "Thư mục cha · {0}",
        .pickerEmptyFolder: "Không có thư mục con hay file mở được",
        .pickerSessions: "Session Claude trả lời câu hỏi",
        .pickerSessionsBusy: "⏳ Claude đang trả lời · đổi session sau khi xong",
        .pickerNoSession: "Không liên kết session",
        .pickerLinked: "Đang liên kết · {0}",
        .pickerUsedWith: "đã dùng với {0}",
        .pickerReadingSessions: "Đang đọc ~/.claude/projects…",

        // Display settings
        .displayTitle: "Hiển thị",
        .displayBackdrop: "Nền",
        .displayBlur: "Làm mờ app phía sau",
        .displayTextBand: "Nền sau chữ",
        .displayTextOpacity: "Độ đậm chữ",
        .displayFontSize: "Cỡ chữ",
        .displayLanguage: "Ngôn ngữ",
        .displayHint: "Tắt làm mờ để nhìn xuyên (ví dụ màn hình đang share); tăng \"{0}\" để chữ vẫn rõ trên nền sáng.",
        .displayOff: "Tắt",
        .displayDefaults: "Mặc định",

        // Claude chat
        .chatAsking: "Đang hỏi Claude…",
        .chatEmptyLinked: "Đang liên kết: **{0}** trong `{1}`. Bấm **tiêu đề khung Claude** (hoặc `⌥S`) để đổi session.",
        .chatEmptyNotLinked: "Chưa liên kết session Claude. Bấm **tiêu đề khung Claude** (hoặc `⌥S`) để chọn session Claude Code, để Claude hiểu project.",
        .chatEmptyPage: """
        ## Hỏi Claude

        {0}

        - Claude trả lời theo tài liệu đang mở. Đổi tài liệu (`⌥D`) không đổi session hay cuộc trò chuyện: câu hỏi kế tiếp gửi kèm tài liệu mới.
        - Giữ `⌥ /` để thu âm thanh cuộc họp và micro, nhả ra rồi xem lại chữ trước khi Enter. Giữ thêm lần nữa để nối tiếp.
        - `⌥K` gõ câu hỏi, Shift+Enter xuống dòng.
        - `⌥A` hoặc nút `>>` mở / đóng khung này.
        """,
        .chatEmptyConversation: "Cuộc trò chuyện trống",
        .chatUntitledNotes: "ghi chú",
        .sessionUntitled: "Session không tên",
        .claudeNotFound: "Không tìm thấy lệnh `claude`. Cài Claude Code hoặc thêm nó vào PATH.",
        .claudeExited: "claude thoát với mã {0}.",
        .claudeUnknownError: "Lỗi không rõ",

        // Notes files
        .loadUnreadable: "Không đọc được file: {0}",
        .loadNotZip: "File không phải định dạng Word .docx (không phải gói zip).",
        .loadCorrupt: "File .docx bị hỏng hoặc không hỗ trợ: {0}",
        .loadMissingDocument: "File .docx thiếu phần nội dung (word/document.xml).",
        .loadMalformedXML: "Nội dung .docx bị hỏng ({0}): {1}",

        // Launch notices
        .launchLegacyRunning: "Bản cũ của ứng dụng (Meeting Prompter) đang chạy. Hãy thoát bản đó trước (biểu tượng của nó trên thanh menu → Thoát), rồi mở lại TalkMargin.",
        .launchNotForwarded: "TalkMargin không chuyển được tài liệu sang bản đang chạy. Tài liệu đã được đưa lên đầu danh sách mở gần đây.",
        .launchOtherRunning: "Một bản TalkMargin khác{0} đang chạy, nên bản này không mở. Hãy thoát bản kia trước.",
        .launchUnbundled: "bản không đóng gói",
        .launchNoLock: "TalkMargin không dùng được khoá chống mở hai lần ({0}).",
        .launchNoLockOtherRunning: "Một bản khác đang chạy, nên bản này không mở.",
        .launchNoLockAlone: "Ứng dụng vẫn chạy, nhưng đừng mở thêm bản thứ hai.",
        .launchDocumentsKept: "Tài liệu bạn vừa mở đã được đưa lên đầu danh sách mở gần đây.",
    ]
}

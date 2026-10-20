# Changelog

## [0.1.0] - 2026-10-20

First release.

**Reading**

- A menu-bar app with an overlay that stays above every window, full-screen apps and every Space. It never takes keyboard focus from the meeting app, and it is excluded from screen capture, within the limits in [docs/privacy.md](docs/privacy.md).
- Markdown, plain text and Word `.docx` notes. The overlay reloads when the file is saved, remembers the reading position of each file, and never writes to your notes.
- Headings, lists, checkboxes, tables and code render as such. Quotes (`>`), the lines to say, get an accent bar.
- Compact and expanded views, each with its own size and position. **Move next to the webcam** puts the overlay at the top of the screen that has the camera.
- An outline sidebar that highlights the current section; it can be resized. Every jump can be undone with `↩` (`⌥←`) and redone (`⌥→`).
- Display settings drawn inside the overlay: backdrop darkness, blur, a subtitle-style band behind the text, text opacity and font size.
- Selecting text copies it at once, with no `⌘C` and no focus change.

**Shortcuts**

- Right-Option shortcuts that leave left Option alone: show or hide, scroll and hold-to-scroll, next or previous heading, sections 1 to 9, back and forward, expand, font size, click-through.

**Switching documents**

- A document list under the file name (`⌥D`): recent files, a folder browser that is safe to use while sharing, and the macOS open dialog for use outside a share.
- Only one TalkMargin runs per user. A document opened while it runs, from Finder, Open With, `open` or the app icon, goes to the running overlay.

**Claude (optional)**

- A Claude column that answers from a read-only fork of a Claude Code session you link (`⌥S`). The original session is never changed, and Claude can only read and search files.
- Claude answers from the document on screen. After a switch or an edit it gets the new notes, or only a diff of the edits.
- Conversations are saved and restored at launch. A Terminal button copies the command that continues the fork in a terminal.
- Push-to-talk (hold `⌥ /`): the meeting audio and your microphone are transcribed on-device (English for the meeting; English and Vietnamese for you). You review the text before sending it. Microphone text that only echoes the meeting is dropped.

**Install and update**

- A disk image with `Install.command`, or `scripts/build-app.sh --install` from source. Both install to `~/Applications` with `scripts/update.sh`. It refuses while the app runs, verifies the version and the signature, and rolls back on any failure.
- Launch at login from the menu.

Known limitations: see the [README](README.md#known-limitations).

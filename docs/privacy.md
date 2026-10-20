# Privacy

TalkMargin reads your notes and shows them on your Mac. It makes no network requests of its own. The optional Claude chat sends data through the Claude Code CLI; see [claude.md](claude.md) for exactly what is sent.

## Hidden from screen sharing, within limits

Every window the app creates sets `NSWindow.sharingType = .none`, which asks macOS to leave it out of screen capture. Production builds always do this. Dev and verification builds can opt in to being captured with `MP_ALLOW_CAPTURE=1`, for screenshots while testing; the header then shows a red **CAPTURE ALLOWED** (**ĐANG CHO CHỤP MÀN HÌNH**) label. What the evidence covers:

| | Result |
|---|---|
| ScreenCaptureKit and the window list, macOS 26.6.2 | The overlay and its pickers are not captured. |
| Microsoft Teams, receiving end (one user test, a second account as viewer) | The overlay was not visible in either whole-screen or single-window sharing. Only the reading overlay was on screen. |
| Interaction states with a real receiver: pickers, question box, chat, display settings, open dialog | Not tested |
| Legacy `CGDisplayStream` API | **Captures the overlay.** A sharing or recording app that uses it shows your notes. |
| Menu-bar menu | A system window, visible to whole-screen sharing |
| Menus inside the macOS open dialog (**Open dialog…**) | Drawn by a macOS service, visible to whole-screen sharing. Use the folder browser inside the overlay while sharing. |
| Zoom, Google Meet, other apps; other macOS versions | Not tested |

Before you rely on it, run a test call with a second device as the viewer.

The overlay draws its own hover hints and lists instead of tooltips and popovers, because those are separate windows. Its text views have no context menu or Look Up panel, because those come from other processes.

## Permissions

| Permission | Used for | Not used for |
|---|---|---|
| **Accessibility** | A keyboard event tap that finds right-Option shortcuts and consumes them. | Every other key event passes through unchanged. Key events are not logged, stored or sent. |
| **Screen & System Audio Recording** | Push-to-talk: system audio (the meeting) while you hold `⌥ /`. The capture API also needs a video stream; it is 2 × 2 pixels at 1 frame per second and is discarded. | No screen images are kept. Nothing is captured while the key is up. |
| **Microphone** | Push-to-talk: your voice while you hold `⌥ /`. | Nothing is recorded while the key is up. |

The app never requests a Speech Recognition permission, and its Info.plist has no `NSSpeechRecognitionUsageDescription`. It is untested whether macOS asks for one on some setups.

Speech recognition runs on-device (`SpeechAnalyzer`): English (US) for the meeting audio, English and Vietnamese for the microphone. macOS downloads the language models the first time, which needs the network once. Audio stays in memory for the length of one recording and is never written to disk. The text goes into the question box and is sent only if you press Enter with the Claude chat in use.

Without headphones, your microphone also hears the meeting. Microphone text that repeats the meeting audio is dropped. If others should not hear you, mute yourself in the meeting app.

## Where data lives

| What | Where |
|---|---|
| Settings: font and display settings, window frames, outline width, chat width, linked Claude session, up to 10 recent file paths, last file, reading position per file | `~/Library/Preferences/com.long.meetingprompter.plist` (`defaults read com.long.meetingprompter`) |
| Claude conversations (questions, answers, document paths and digests, not the notes text) | `~/Library/Application Support/MeetingPrompter/conversations.json`. An unreadable file is moved aside to `conversations.unreadable-<date>.json`. |
| Single-instance lock, holding the running process id | `~/Library/Application Support/MeetingPrompter/instance.lock` |
| Claude Code sessions and forks (read to list sessions; forks written by Claude Code) | `~/.claude/projects/` |
| Text you select in the notes or chat (copy-on-select), and the Terminal command | The general clipboard. Clipboard managers and Universal Clipboard see it like any other copy. |
| Logs | The unified log, subsystem `MeetingPrompter`. Document paths are logged as private values, which macOS redacts by default. |

The dev build uses `com.long.meetingprompter.dev` and `~/Library/Application Support/MeetingPrompter Dev/`.

Your notes files are only read, never written. To remove everything: turn off **Open at login** if it is on, quit the app, delete `~/Applications/TalkMargin.app`, the folder `~/Library/Application Support/MeetingPrompter/`, and the settings (`defaults delete com.long.meetingprompter`). Then remove TalkMargin from the Privacy & Security lists. Forks in `~/.claude/projects/` belong to Claude Code; delete them there if you want.

## Reporting a security issue

See [SECURITY.md](../SECURITY.md).

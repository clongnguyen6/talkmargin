# TalkMargin: agent notes

Native macOS overlay (Swift 6, AppKit, TextKit 1) for reading meeting notes, with a Claude Code side chat. User-facing names, the bundle (`TalkMargin.app`) and the executable are TalkMargin. Bundle ids (`com.long.meetingprompter`, `.dev`, `.verify-*`), the settings domain, the data folder (`~/Library/Application Support/MeetingPrompter/`), the lock and the Swift targets use the `meetingprompter` names. Overview: [README.md](README.md). Components: [docs/architecture.md](docs/architecture.md). Contributing: [CONTRIBUTING.md](CONTRIBUTING.md).

## Commands

- `swift test`: PrompterCore unit tests (renderer, sections, echo filter, single instance, scripts). Keep them green.
- `./scripts/build-app.sh`: dev build, `build/TalkMargin Dev.app` (id `com.long.meetingprompter.dev`, no document types, own settings and data folder). Use it for on-device tests. It refuses to start while another TalkMargin runs (one instance per user): quit the installed app first.
- `MP_ALLOW_CAPTURE=1 "build/TalkMargin Dev.app/Contents/MacOS/TalkMargin" &`: run the dev build with the overlay visible to screenshots (it is excluded from capture otherwise). Not `.build/...`: the bare binary has its own settings and data.
- `./scripts/build-app.sh --install`: stage a stamped production bundle and install it into `~/Applications` with `scripts/update.sh --app` (refuses while any copy runs). Test it in a sandbox: `MP_UPDATE_SANDBOX=<root with .mp-update-sandbox> scripts/build-app.sh --install --verify-id com.long.meetingprompter.verify-<name> --dest <root>/home/Applications`, by absolute path.
- `./scripts/build-app.sh --out <dir> [--verify-id …]`: stage-only bundle (production for `make-dmg.sh`, or a verification build).

## Conventions

- UI strings are Vietnamese; code, comments, commit messages and docs are English.
- Never use the em dash in any text; use `-` or `·`.
- Swift 6 strict concurrency: UI types are `@MainActor`; callbacks from AppKit/C use `MainActor.assumeIsolated`; audio-thread classes are `@unchecked Sendable` with a lock.
- Pure, testable logic goes in `PrompterCore` with Swift Testing tests.
- The overlay must never take keyboard focus from the meeting app except while the question box is in use (`OverlayPanel.acceptsKeyboard`).

## Testing on a Mac

Follow [docs/e2e-testing.md](docs/e2e-testing.md). Single-instance and install behaviour is verified headless with **verification builds** (ids `com.long.meetingprompter.verify-<name>`, from `scripts/build-app.sh --out <dir> --verify-id …`): only they honour `MP_LOCK_PATH` (a sandbox lock file; without it they use a lock of their own id in the temporary folder, never the shared one) and `MP_HEADLESS=1` (no tap, status item, window or permission prompt; opened documents are logged). Production and dev builds ignore both.

- Right-Option shortcuts are swallowed by the app and safe to send; plain keystrokes and Enter go to whatever app is frontmost. Confirm the target (screenshot) before sending them.
- Back up and restore the clipboard, `defaults export com.long.meetingprompter.dev`, and any file you touch.
- Use throwaway Claude sessions in a scratch directory and delete their `~/.claude/projects/*` directories afterwards.

## Gotchas found the hard way

- `NSPanel.isFloatingPanel = true` resets `level`; set it before `level`.
- `NSApp.activate()` is cooperative: macOS honours it only while handling user interaction with the app (a click, a menu choice), not from a timer or a right-⌥ shortcut (the tap consumes the key; the app never sees an event). Windows that need the keyboard are non-activating panels instead (question box, open dialog). The unified log shows the decision: `SetFrontProcessWithInfo` in `com.apple.SkyLight.processes:Focus`.
- `runModal` sets the modal window's level to `.modalPanel` (8), below the overlay; lower the overlay instead of raising the dialog (`OpenNotesDialog`). The dialog's menus are drawn by the Open and Save Panel Service and leak into screen sharing: the picker's folder browser is the in-share way to open files.
- `NSWindow.resignKey()` calls `windowDidResignKey` synchronously; read any state that callback clears before calling it.
- Carbon hot keys cannot tell left from right Option; use the CGEvent tap and device bits `0x40`/`0x20`.
- TextKit 1: a plain `NSTextBlock` applies only to its first paragraph and draws no border. Quotes are one-column `NSTextTable`s. Paragraphs inside blocks must not use `paragraphSpacingBefore` (it misaligns table rows); use block margins/padding.
- A heading with no text at the end of streamed markdown crashed glyph lookups; the renderer skips empty headings and the pane clamps glyph indexes.
- Selection in a non-key window is painted with `unemphasizedSelectedContentBackgroundColor`; system colors do not compare with `==`, and `fillBackgroundRectArray` ignores its `color` argument (it fills with the current color). See `SelectionLayoutManager`.
- `SpeechTranscriber` supports English only; Vietnamese uses `DictationTranscriber` (model downloads on first use).
- `claude -p --resume X --fork-session --name N` forks without touching session X; the fork is named N in `claude --resume`.
- Ghostty runs `-e` commands only as a new instance and asks for confirmation each time, so the Terminal button copies the command instead.
- Auto Layout grows a window to satisfy any constraint above `.windowSizeStayPut` (500), even on hidden views: preferred sizes and positions of dropdowns and header items stay at 490 or below, or saved frames are ignored. A transparent `NSButton()` keeps the title "Button" and its hugging sizes whatever it is pinned to; clear the title. Lay out headless with a scratch binary (copy the sources, never show the window) and read `log show` for "Unable to simultaneously satisfy constraints".
- Never run a modal loop (`runModal`) inside a main-queue block or a main actor task: the main queue and every main actor job wait until it closes. Not inside a run loop block either: the rest of that batch waits (shortcut actions arrive as such blocks). Start modal UI from a common-mode timer (`OpenNotesDialog.present`). Timers that must run during dialogs, menus and drags go in `.common` modes.
- A CGEvent tap whose callback stalls is disabled by the system and lets keystrokes through; `RightOptionKeys` taps on its own thread and never runs actions in the callback.
- A closure written inside a `@MainActor` type and handed to a C/ObjC API is main-actor isolated, and Swift 6 checks that at run time: called on another thread it traps (`dispatch_assert_queue_fail`; this crashed the tap on every keystroke). Code for other threads goes in a non-isolated type as `static let` closures (`TapState`). Unit tests do not catch it; check with an off-main harness or by scanning the release binary for `swift_task_isCurrentExecutor` calls (`otool -tvV`).
- LaunchServices registers any app bundle it notices (even one that was only built) and "Open With" picks among copies with the same bundle id by path; a document sent to a different copy than the running one starts a second process. Only `~/Applications/TalkMargin.app` may carry the production id; scratch and test builds use the dev or verification ids. `SingleInstance.swift` holds the lock that makes a second launch forward its documents and exit.
- `lsregister -u` cannot remove the record of a bundle that no longer exists (error -10814; `-gc` keeps it too). Unregister bundles before deleting them; `scripts/registrations.sh stale <id>` clears old records with a placeholder bundle.
- In one shell command, `cd <dir> && … && job &` backgrounds the `cd` with the job; what follows runs in the old directory. Call scripts that install or delete by absolute path.
- File keys (recents, reading positions, Claude's document identity) are `NotesPath.canonical`: the open dialog returns `/private/tmp/…` for `/tmp/…`. It resolves the folder only; a symlinked file keeps its own name. No disk access at launch for saved keys (`NotesPath.lexical`): a stale network volume would hang it.
- Popovers, menus, tooltips and `NSOpenPanel` are separate windows and are captured by screen sharing unless their `sharingType` is set; prefer UI drawn inside the overlay (`OverlayPicker`). Never set `toolTip` on anything in the overlay; use `HoverHint`. The window list is in [docs/architecture.md](docs/architecture.md).
- Offscreen rendering (`cacheDisplay`) of the overlay: macOS 26 scroll-edge views (`NSScrollPocket`, `BackdropView`) draw opaque over the text, and layer background colors are not drawn; see `docs/images/src/Shots.swift`. `CFFIXED_USER_HOME` moves the home folder but not `UserDefaults`.

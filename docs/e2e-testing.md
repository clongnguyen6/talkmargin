# Testing on your own Mac

Unit tests (`swift test`) cover `PrompterCore`. The overlay, shortcuts, audio and Claude are tested on a real Mac, the way you would use them. This page is how to do that without disturbing your installed copy or your data.

## Setup

1. Build the dev bundle: `./scripts/build-app.sh` writes `build/TalkMargin Dev.app` (id `com.long.meetingprompter.dev`).
   - It has its own settings (`com.long.meetingprompter.dev`) and data (`~/Library/Application Support/MeetingPrompter Dev/`), so your installed app's conversations and reading positions are never touched.
   - Only one TalkMargin runs per user: quit the installed app first, or the dev build exits.
   - It claims no document types. Documents opened from Finder go to the installed app; open test documents from the overlay's picker instead.
   - It needs its own Accessibility grant, and Microphone and Screen & System Audio Recording for push-to-talk, the first time.
2. To take screenshots of the overlay, run it capturable: `MP_ALLOW_CAPTURE=1 "build/TalkMargin Dev.app/Contents/MacOS/TalkMargin" &`. The header then shows a red **CAPTURE ALLOWED** (**ĐANG CHO CHỤP MÀN HÌNH**) label, because that instance is visible to screen sharing. Quit it by its pid when you are done (`pkill -x TalkMargin` would also match the installed app).
3. Save what a test may change, and restore it afterwards:
   - `defaults export com.long.meetingprompter.dev <scratch>/prefs.plist` (restore with `defaults import`);
   - `pbpaste > <scratch>/clip` (restore with `pbcopy < <scratch>/clip`).
4. For Claude features, use a throwaway session in a scratch directory (`echo "..." | claude -p --output-format json`) and link it with `defaults write com.long.meetingprompter.dev linkedSession -dict id <id> cwd <dir> title "Demo"`. Afterwards delete `~/.claude/projects/*<scratch-dir-name>` and the test entries in the dev `conversations.json`.

The terminal that runs the tools below needs Accessibility (to post events) and Screen Recording (for `screencapture`).

## Headless verification runs

Single-instance, document forwarding and install behaviour can be checked without any window, focus or permission:

- Build each copy with `scripts/build-app.sh --out <sandbox>/<X> --verify-id com.long.meetingprompter.verify-<name>` (that id, no document types: never an Open With candidate). For a case that needs older code, `git archive <commit>` into the sandbox, add the same headless switches, build there, and give it a verification id.
- Launch with `open -g -j --env MP_LOCK_PATH=<sandbox>/instance.lock --env MP_HEADLESS=1 --env CFFIXED_USER_HOME=<sandbox>/home -a <copy> <doc>`: in the background, hidden, with a sandbox lock and data under the sandbox home. Production and dev builds ignore `MP_LOCK_PATH` and `MP_HEADLESS`.
- Verification builds treat only their own id as a conflicting copy; separate runs use separate ids and lock files.
- Read results from `ps`, `lsof` (the open document is held by the file watcher), and the log restricted to the sandbox: `log show --predicate 'processImagePath CONTAINS "/<sandbox>/" AND (category == "instance" OR category == "documents")'`.
- Install cases run only in test mode: `MP_UPDATE_SANDBOX=<sandbox with .mp-update-sandbox> scripts/build-app.sh --install --verify-id … --dest <sandbox>/home/Applications`, by absolute path.
- Afterwards: quit the test instances, `MP_UPDATE_SANDBOX=<sandbox> scripts/registrations.sh unregister` each bundle before deleting it, then `registrations.sh stale <id>` for each verification id.

## Tools

In `scripts/dev/` (compile with `swiftc -O <file>.swift -o <out>`, or run with `swift <file>.swift`):

| Tool | Use |
|---|---|
| `key.swift <keycode> <seconds> <right\|left>` | Right-Option shortcuts. Codes: P 35, / 44, O 31, A 0, E 14, T 17, K 40, [ 33, ] 30, 1 18, 3 20, arrows 123-126 |
| `mouse.swift click\|drag\|move\|wheel …` | Clicks, double-clicks, drag selection, scroll wheel |
| `windows.swift` | Overlay frame and display bounds in global points |
| `make-docx.sh <src-dir> <out.docx>` | Packs an unzipped Office Open XML folder into a `.docx` |

Coordinates are global points with the origin at the main display's top-left; a display above it has negative y. `screencapture -x a.png b.png` writes one file per display; convert with the display bounds from `windows.swift`, and account for 2x pixels on Retina.

Offscreen renders of the overlay without any window on screen: `docs/images/src/render.sh` (used for the README screenshots).

## Safety

- Right-Option shortcuts are consumed by the app, so they are safe to send. **Plain keystrokes (typing, Enter, Esc) go to the frontmost app.** Send them only after a screenshot shows the question box has focus.
- Clicks and drags aimed at the overlay move your pointer; keep automated sessions short.

## Recipes

- **Push-to-talk:** hold `⌥ /` with `key.swift 44 6 right &`, play speech with `say "…"` meanwhile, then screenshot the question box. Without headphones the microphone hears the speakers; that echo should be dropped.
- **Sending a question:** after the screenshot check, press Enter, then poll `conversations.json` until the last turn has an answer and the conversation has a `forkID`.
- **Scroll and jumps:** scroll offsets are saved per file under `scrollOffsets` in the defaults; read them instead of judging by eye.
- **Copy-on-select:** `mouse.swift drag` across a line, then `pbpaste`; sample screenshot pixels to confirm the selection color is visible.
- **Readability:** put a bright window with text behind the overlay (a floating `NSWindow` from a small Swift script) and screenshot each display setting.

## Shell pitfalls

- `wait` without a pid also waits for the app you launched with `&`; use `wait $PID`.
- `osascript` calls to TextEdit sometimes hang; read its text through System Events instead.
- `cd <dir> && … && job &` backgrounds the `cd` with the job; call scripts by absolute path.

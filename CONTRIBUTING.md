# Contributing

Issues and pull requests are welcome on `https://github.com/clongnguyen6/talkmargin`. Report security issues privately ([SECURITY.md](SECURITY.md)).

## Build and test

Needs macOS 26 on Apple silicon, and Xcode with the macOS 26 SDK and Swift 6.2 or later (`swift-tools-version: 6.2`). Tested with Xcode 27.1 / Swift 6.4; the minimum Xcode version is unknown.

```sh
swift test                 # PrompterCore unit tests and script tests; keep them green
./scripts/build-app.sh     # dev build: build/TalkMargin Dev.app
```

The Swift package has two targets: `PrompterCore` (pure logic, unit tested with Swift Testing) and `MeetingPrompter` (the AppKit app, executable `TalkMargin` in the bundle). See [docs/architecture.md](docs/architecture.md).

## Dev bundle versus installed app

| | Dev build | Installed app |
|---|---|---|
| Made by | `./scripts/build-app.sh` | `./scripts/build-app.sh --install`, or a release dmg |
| Path | `build/TalkMargin Dev.app` | `~/Applications/TalkMargin.app` |
| Bundle id | `com.long.meetingprompter.dev` | `com.long.meetingprompter` |
| Settings | `com.long.meetingprompter.dev` | `com.long.meetingprompter` |
| Data | `~/Library/Application Support/MeetingPrompter Dev/` | `~/Library/Application Support/MeetingPrompter/` |
| Document types | none (Finder never sends it files) | `.md`, `.markdown`, `.txt`, `.docx` |

Use the dev build for testing. Run it with `MP_ALLOW_CAPTURE=1 "build/TalkMargin Dev.app/Contents/MacOS/TalkMargin" &` to allow screenshots; the header then shows a red warning label. Not `.build/...`: the bare binary has its own settings and data. Every build is stamped (`VERSION`, `BUILD_NUMBER`, commit) and signed last; `MP_SIGN_IDENTITY` picks the signing identity.

`build-app.sh --out <dir>` stages a production bundle without installing it (for `make-dmg.sh`). Delete it afterwards with `scripts/registrations.sh unregister <dir>/TalkMargin.app` before `rm -r`, so LaunchServices keeps no stale record.

## One instance, and the test hooks

Only one TalkMargin runs per user, whichever build: an exclusive lock on `~/Library/Application Support/MeetingPrompter/instance.lock`. A second production launch hands its documents to the running copy and exits. The dev build refuses to start while another copy runs, so quit the installed app before testing.

**Verification builds** (`scripts/build-app.sh --out <dir> --verify-id com.long.meetingprompter.verify-<name>`) are the only builds that honour two environment switches:

- `MP_LOCK_PATH=<file>`: a sandbox lock instead of the shared one;
- `MP_HEADLESS=1`: no event tap, status item, window or permission prompt; opened documents are logged.

Installs are tested only in sandbox mode (`MP_UPDATE_SANDBOX=<dir containing .mp-update-sandbox>`), which `update.sh` and `build-app.sh` refuse to leave. `scripts/dev/test-update-*.sh` are simulations with a dummy bundle id. Details and recipes: [docs/e2e-testing.md](docs/e2e-testing.md).

## Bundle id

A fork that ships its own builds should replace `com.long.meetingprompter` (and its `.dev` and `.verify-` variants) everywhere it is defined:

- `Resources/Info.plist` (`CFBundleIdentifier`)
- `Sources/PrompterCore/SingleInstance.swift` (`AppIdentity`)
- `scripts/build-app.sh` (`PROD_ID`, `DEV_ID`, `VERIFY_PREFIX`)
- `scripts/update.sh` (`PROD_ID`)
- `scripts/release.sh` (`PROD_ID`)
- `scripts/registrations.sh` (`PLACEHOLDER_ID`)
- the tests in `Tests/PrompterCoreTests/` that name it

The settings domain and permission grants follow the id, so a fork with a new id starts with fresh settings and asks for permissions again.

## Conventions

- UI strings are in Vietnamese and English: add each one to both `PrompterCore/UIText+vi.swift` and `UIText+en.swift` and read it with `tr(.key)`. Keep English short so layouts hold. Text that reaches Claude goes in `ClaudeText` and is never translated. Code, comments, commit messages and docs are English.
- No em dash in any text; use `-` or `·`.
- Swift 6 strict concurrency: UI types are `@MainActor`; callbacks from AppKit and C use `MainActor.assumeIsolated`; audio-thread classes are `@unchecked Sendable` with a lock. Code that runs on another thread goes in a non-isolated type: a closure written inside a `@MainActor` type traps when called off the main thread.
- Pure, testable logic goes in `PrompterCore` with Swift Testing tests.
- The overlay never takes keyboard focus from the meeting app, except while the question box is in use (`OverlayPanel.acceptsKeyboard`).
- Everything the user sees stays out of screen sharing: new UI is drawn inside the overlay, never as a popover, menu or tooltip window. Every window sets `sharingType` from `OverlayPanel.captureSharingType`.
- [AGENTS.md](AGENTS.md) lists AppKit, TextKit, LaunchServices and event-tap pitfalls found while building the app. Read it before changing windows, input or install scripts.

## Pull requests

- One topic per pull request; `swift test` green.
- For UI changes, say how you checked them on a Mac (dev build), and whether the change adds a window.
- Update the docs that describe the behaviour you change (README, [docs/architecture.md](docs/architecture.md), [docs/privacy.md](docs/privacy.md), [docs/claude.md](docs/claude.md)) and add a user-facing line to [CHANGELOG.md](CHANGELOG.md).
- Screenshots in `docs/images/` are rendered with `docs/images/src/render.sh` from synthetic notes. Never commit screenshots of real notes or sessions.

## Releases

Versioning, the dmg, `update.sh` and signing are described in [docs/distribution.md](docs/distribution.md). The release steps are in [docs/release.md](docs/release.md).

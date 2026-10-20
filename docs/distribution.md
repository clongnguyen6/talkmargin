# Distribution: dmg, versions, updates

How TalkMargin is versioned, packaged and installed on other Macs. Releases are signed with an Apple Development certificate. Developer ID, notarization and Sparkle are options (below), not set up.

Files: `VERSION`, `BUILD_NUMBER`, `scripts/dist.conf`, `scripts/build-app.sh`, `scripts/make-dmg.sh`, `scripts/update.sh`, `scripts/release.sh`, `scripts/make-icns.sh`.

## Names and compatibility

- `scripts/dist.conf` holds `APP_NAME` (TalkMargin) and `VOLUME_NAME` (TalkMargin): the only names `make-dmg.sh` uses. `update.sh` takes the new name from the app it installs and the old names from `LEGACY_APP_NAMES` (MeetingPrompter) at its top.
- Unchanged by the rename: bundle id `com.long.meetingprompter`, the defaults domain, and `~/Library/Application Support/MeetingPrompter/`. Settings and history survive because the bundle id never changes.

## Versioning and stamping

- `CFBundleVersion`: the `BUILD_NUMBER` file, a whole number that does not depend on git history. `update.sh` compares it, so it only has to rise for each release; [release.md](release.md) describes the rule `release.sh` enforces (higher than every earlier release tag's `BUILD_NUMBER`, and higher than 61, the highest build made before this repository's history began).
- `CFBundleShortVersionString`: the `VERSION` file (`X.Y.Z`), bumped by hand for a named release and tagged `vX.Y.Z`.
- `MPGitCommit` (custom plist key): short SHA, `-dirty` suffix for an uncommitted tree. It is for traceability and tells two builds with the same build number apart.
- The build script writes all three into the built plist, not into `Resources/Info.plist`. An app with an integer `CFBundleVersion` and a non-empty `MPGitCommit` is **stamped**; anything else is unstamped and cannot be compared.
- `make-dmg.sh` refuses an unstamped app, a commit that is not in the repository, and a `CFBundleVersion` that is not the `BUILD_NUMBER` recorded at that commit (the working-tree `BUILD_NUMBER` for a `-dirty` build). It also refuses a dirty tree (`--allow-dirty`) and an ad-hoc signature (`--allow-adhoc`).
- `update.sh` refuses to install an unstamped app. It refuses to compare unstamped installed copies (builds made before stamping existed) unless `--allow-unstamped-install` says to install over them.
- Dmg name: `<APP_NAME>-<short>-<build>-<commit>.dmg` plus `<name>.dmg.sha256` in `build/dist/` (ignored by git). Dmgs are not reproducible: packing the same app twice gives different hashes. The sidecar identifies one file, not a build.

## Install location

One place: `~/Applications`. No admin rights needed. A copy in `/Applications` is a second copy of the same app: `update.sh` retires it (see below) instead of leaving two. `update.sh` is the only install routine; `build-app.sh --install` stages the bundle and calls it with `--app`.

A dmg cannot link to `~/Applications` (a symlink does not expand `~`), so the image has no drag target. It holds the app, `update.sh` and `Install.command`, which runs `update.sh --app ./TalkMargin.app` on the app beside it. Quit the app first. `Install.command` is a script: in a dmg downloaded with a browser (quarantine flag on the dmg), double-clicking it is blocked by Gatekeeper, as is an app run from the image (see Signing). The same script run from Terminal is not assessed, and the copy that `update.sh` installs has no quarantine flag.

## Flow

1. Build and sign the app: `scripts/build-app.sh --out <folder>` writes a stamped, signed `<folder>/TalkMargin.app` without installing anything.
2. `scripts/make-dmg.sh <App.app>` writes the dmg and sha256 and verifies the image with `hdiutil verify`.
3. Move both files to the other Mac without quarantine: scp, USB, a shared or synced folder, or `gh release download` / `curl` from a GitHub release. AirDrop, browser downloads and Messages add the quarantine flag.
4. On that Mac: open the dmg and double-click `Install.command`, or run `scripts/update.sh <dmg-or-folder>` (a folder picks the highest build number). Eject the dmg afterwards.
5. Developer Mac: `build-app.sh --install` runs `update.sh --app <staged.app>`.

Rollback: run `update.sh --allow-downgrade` on an older dmg. Keep old dmgs. Data written by a newer build may not load in an older one.

Public releases: the same dmg goes out as an asset of a GitHub release, built and verified by `scripts/release.sh`; the procedure, the publish command (placeholders only) and the facts a fresh Mac meets are in [release.md](release.md). The app does not check for or download updates; an upgrade is always this installer, run by the user after quitting the app.

## update.sh

Sources: a dmg or folder of dmgs (sha256 sidecar required, image attached read-only at a `/tmp` mountpoint with `-nobrowse -noautoopen`), or `--app <App.app>` (no dmg, no sha256, same checks; the staged app is copied, never moved, and must not be an installed copy).

**Checks, in order; the first failure stops with nothing changed:**

1. Sandbox guard (test mode, below).
2. The new app has the production bundle id, is stamped, and has a valid signature.
3. No leftover `.<name>.old` or `.<name>.new` in any standard folder (exit 1): an interrupted run may have left the only copy of the previous app there. The script names the path and never deletes it.
4. Every copy of the bundle id is found: `~/Applications` and `/Applications`, new name and old names. A same-name copy with another bundle id stops the run and is never touched; an old-name copy with another bundle id is ignored.
5. Unstamped copies block unless `--allow-unstamped-install` (exit 3).
6. Version: the newest stamped copy anywhere is the baseline. A lower build needs `--allow-downgrade` (exit 3). Same build and commit with a single installed copy and a non-dirty commit is "already current" (exit 0). A `-dirty` build, or a leftover old-name copy, always proceeds.
7. Identity: the new app must satisfy the designated requirement of every copy, not only the destination (`--allow-identity-change`, exit 3). Ad-hoc copies are skipped with a note.
8. Running instance: any process whose bundle has the production id, at any path, under any name (matched by the bundle's `CFBundleIdentifier`; executable names only when a plist cannot be read), exits 4 before any change. The message names the running app and asks you to quit it first. A running app is never removed, replaced or swapped; the check runs again right before the installed app is moved aside, right before the new copy goes into place, and before each other copy is retired, because the copy and signature steps take seconds (an app that starts in that window aborts the update with exit 4 and the same rollback; if it is the new app itself, that copy is left in place and the previous app is reported at `.<name>.old`). It does not stage: the swap takes under a second, nothing exists to apply a staged copy at next launch, and a live bundle replaced under a running process invites a second instance.
9. Same-name copies in the other standard folder need `--remove-other-copies` (exit 3). Old-name copies are retired without a flag.
10. `--check` stops here and reports.

**Changes, in this order:**

1. Copy the new app to `.<name>.new` (not an `.app` suffix, so LaunchServices ignores it) and verify its signature.
2. Move the installed app aside to `.<name>.old`, move the new copy into place, verify it.
3. Only now retire the other copies: for each, `lsregister -u` while it still exists, then move it aside to `.<old name>.old`. Then check the `lsregister -dump` no longer lists any of those paths.
4. Delete the `.old` copies made by this run.
5. Register the installed app with `lsregister -f`, so it claims its document types before the first launch. A failure is a warning, not a rollback. Test mode calls the stub only.

**Failure at any step undoes everything:** the new copy is removed, every moved copy goes back, restored old-name copies are registered again. If a restore itself fails, the script says where the previous app is (`.<name>.old`) and where it belongs, leaves it, and exits 1. The next run then refuses to start (check 3).

Exit codes: 0 done or current, 1 error or leftover, 2 refused by the sandbox guard, 3 blocked by a missing flag, 4 instance running.

The script never reads or writes the `com.long.meetingprompter` defaults or `~/Library/Application Support/MeetingPrompter/`.

**Test mode:** `MP_UPDATE_SANDBOX=<dir>` (the dir must hold a `.mp-update-sandbox` file). Before any change, every target (destination, standard folders, new, aside and retired paths, resolved through symlinks) must lie inside the sandbox; `~/Applications` and `/Applications` are refused explicitly, as is a sandbox root that contains or lies inside them. `--dest` is required, the standard folders become `<sandbox>/home/Applications` and `<sandbox>/Applications`, and `MP_UPDATE_LEGACY_NAMES` and `MP_UPDATE_LSREGISTER` (a stub) are honoured only in this mode.

## LaunchServices and mounted images

Several builds of the app can end up registered with LaunchServices at once (a build folder, `~/Applications`, temporary folders that were later deleted). The app declares document types, so every registered copy shows up in "Open With". The tooling is built to leave exactly one registered copy.

Simulation on macOS 26, dummy bundle id `com.example.mpdistprobe`, all under `/tmp`, counting `lsregister -dump` lines that match the dummy id or paths:

| Step | Hits |
|---|---|
| Baseline, and after building dummy bundles in `/tmp` | 0 |
| Sampled 19 times while and after `hdiutil create -srcfolder` ran | 0 in every sample |
| Dmg attached at a `/tmp` mountpoint (`-nobrowse -noautoopen -readonly`), checked at 8 s and 18 s, and after detach | 0, 0, 0 |
| Dmg with `update.sh` and `Install.command` inside, attached the same way, and after detach | 0, 0 |
| After the sandbox updates installed dummy apps into `/tmp` sandbox folders | 0 |

Not covered: a mount under `/Volumes` by Finder (double-click). Assume it registers the app until proven otherwise; eject after installing and never run the app from the image. `lsregister -u` and `-f` were not run against the real LaunchServices; the tests used a stub that models `-dump`, `-u` and `-f` over a file. Probe mounts, dmgs and dummy apps were removed afterwards.

## Signing and Gatekeeper

How the current build is signed, checked with read-only commands:

- It carries an Apple Development signature (a certificate from a free or paid Apple developer account, not a Developer ID). `codesign --verify --strict --deep` passes.
- Hardened runtime is off (`flags=0x0`), there are no entitlements and no secure timestamp.
- `spctl --assess --type execute` says rejected, with `origin=` naming the Apple Development certificate. `syspolicy_check distribution` reports one fatal finding: no notarization ticket is stapled.
- Architecture arm64, minimum macOS 26.

Other Mac (inferred, not tested on a second Mac):

| Case | Expected |
|---|---|
| App or dmg arrives without quarantine (scp, USB, shared folder) | Launches. The chain verifies to Apple's roots and there are no restricted entitlements. |
| Quarantined (browser, AirDrop, Messages) | Gatekeeper blocks the first open of a double-clicked `Install.command` and of the app as unverified. System Settings > Privacy & Security > Open Anyway once (macOS asks for an administrator password), or `xattr -dr com.apple.quarantine <file>`. `Install.command` run from Terminal is not assessed, and the copy `update.sh` installs has no quarantine flag (simulated). Apple's documented behaviour; the dialogs were not observed on a second Mac. |
| Accessibility, Screen & System Audio Recording, Microphone | Prompts or manual grants once per Mac: Accessibility on first launch, the other two the first time push-to-talk is used. No separate Speech Recognition permission is requested ([privacy.md](privacy.md)). Accessibility holds across updates only while the signing identity stays the same. |
| Needs | macOS 26 or later on Apple silicon (the build is arm64 only, see [release.md](release.md)). The `claude` command line tool, installed and logged in, only for the chat. |

`make-dmg.sh` strips extended attributes when staging, so no quarantine flag travels in the image (checked by `release.sh` on the mounted image). macOS itself adds `com.apple.provenance` to every file it writes into the image, including the volume root (15 of 15 files in a test image); it is not a quarantine flag and restricts nothing. A copy installed by `update.sh` from a quarantined test image had no quarantine flag (0 files; 12 provenance marks).

## Options for later

| Step | Cost | Gains | Needs / risk |
|---|---|---|---|
| Developer ID + notarization | Apple Developer Program, about $99 per year (check Apple's price). Effort about a day. | Double-click works on any Mac, no warnings, AirDrop is fine. | Hardened runtime, secure timestamp, an entitlements file with `com.apple.security.device.audio-input` (mic stops otherwise), `notarytool`, staple the dmg. The designated requirement changes, so Accessibility is asked once per Mac (`--allow-identity-change`). |
| Sparkle, self-hosted | An HTTPS host (cost and "publishing"), EdDSA key, appcast. Effort 2-3 days. | Automatic update checks. | Embedded third-party framework to sign, app changes, and it quits and relaunches the app by default, which kills a live session unless the delegate defers it. Hard to justify while the audience is small. |
| Build from source on each Mac | Free. | No dmg. | The macOS 26 SDK and Swift 6.2 or later on every Mac (tested with Xcode 27.1 / Swift 6.4; the minimum Xcode is unknown); each Mac signs with its own identity, so no shared Accessibility grant. |
| Self-signed shared certificate | Free. | Stable identity across Macs without Apple. | Gatekeeper still rejects quarantined copies; importing and trusting the cert per Mac is manual. |

## Icon

- App icon: keep a 1024 px PNG master with alpha; `scripts/make-icns.sh master.png` writes `Resources/AppIcon.icns` (sips + iconutil). The bundle needs the file in `Contents/Resources/` before `codesign`, and `CFBundleIconFile` = `AppIcon` in the plist. An Icon Composer `.icon` with `actool` is the alternative if macOS 26 shows the `.icns` inside a plate; unverified.
- Menu bar: a template image (black with alpha, vector PDF named `MenuBarIconTemplate.pdf` or 18/36 px PNGs), loaded with `NSImage(named:)`, `isTemplate = true`, SF Symbol `text.bubble` as fallback.
- Dmg volume icon: not done. `hdiutil create -srcfolder` does not carry the custom-icon flag of the staging folder (tested: `GetFileInfo` showed it unset). It would need a read-write image mounted at `/tmp`, `SetFile -a C`, then conversion. A dmg background needs a `.DS_Store` made through Finder and is not planned.
- Icon changes at an existing path can look stale in Finder or the Accessibility list; `touch` on the bundle (done by `update.sh`) usually refreshes it.

## Test evidence

All of it is simulation: dummy bundle id `com.example.mpdistprobe`, dummy apps (`MPNew.app`, old name `MPOld.app`), a sandbox under `/tmp`, signed with the Apple Development identity, LaunchServices replaced by a stub for the migration tests. Nothing ran against `~/Applications`, `/Applications` or the defaults. The tests live in `scripts/dev/` (`test-update-dedupe.sh`, `test-update-running.sh`, `test-release.sh`).

## Not verified

- Behaviour on a second Mac (all Gatekeeper and TCC rows above are inference).
- Finder mounts under `/Volumes`, and `lsregister -u` against the real LaunchServices (the stubbed tests cover the logic, not the tool).
- Whether the Accessibility grant survives the move from `~/Applications` under a new bundle name and path.

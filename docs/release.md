# Release procedure

How a maintainer builds, checks and publishes a TalkMargin release. The delivery channel is GitHub Releases: one versioned `.dmg`, its `.sha256`, and release notes taken from `CHANGELOG.md`. An upgrade is always the installer in the dmg (`Install.command`, which runs `update.sh`): it replaces the old app after the app has exited, keeps settings and history, and never restarts anything. The app itself does not check for or download updates. Signing and notarization are covered in [distribution.md](distribution.md); this page only says what a release is signed with today.

Steps 1 to 5 are local and publish nothing. Step 6, pushing and publishing, is the only part that is visible to others and needs the maintainer's GitHub account.

## Procedure

Start from a merged, tested `main`: `swift test` green, nothing uncommitted.

1. **Version and build number.** Put the new `X.Y.Z` in `VERSION` and a new whole number in `BUILD_NUMBER` (the file is not called `BUILD`: on a case-insensitive volume that name collides with the `build/` output folder). `CFBundleShortVersionString` comes from `VERSION`. `CFBundleVersion` comes from `BUILD_NUMBER`, not from git history, so it keeps rising even if the history is rewritten or restarted; the installer compares it. `scripts/release.sh` requires `BUILD_NUMBER` to be higher than the `BUILD_NUMBER` of every earlier release tag (read from the tag) and higher than 61, the highest build number made before this repository's history began, so a Mac that runs one of those earlier builds upgrades without a flag. The commit is still recorded in the app (`MPGitCommit`) for traceability.
2. **Changelog.** Add a section `## [X.Y.Z] - YYYY-MM-DD` to `CHANGELOG.md` with the user-visible changes. `release.sh` uses that section as the top of the release notes and refuses a missing or empty one.
3. **Commit and tag.**
   ```
   git add VERSION BUILD_NUMBER CHANGELOG.md
   git commit -m "Release X.Y.Z"
   git tag -a vX.Y.Z -m "TalkMargin X.Y.Z"
   ```
   The tag must be annotated and point at HEAD on `main`; the tree must be clean (untracked files count).
4. **Build, pack, verify, write the notes.**
   ```
   scripts/release.sh
   ```
   Output goes to `build/release/vX.Y.Z/` (git-ignored; it must not exist or be empty). `release.sh`:
   - checks branch `main`, clean tree, `VERSION` is `X.Y.Z`, `BUILD_NUMBER` is a whole number above the earlier releases' (step 1), the annotated tag on HEAD, and the changelog section;
   - builds with `scripts/build-app.sh --out <temp folder>` (stamped, signed with the configured identity), then checks the stamp: version equals `VERSION`, build equals `BUILD_NUMBER`, commit equals HEAD without `-dirty`, bundle id is the production id;
   - prints what the signature reveals about the signer, as anyone who downloads the dmg can read it (the `codesign` authority lines, the team identifier and the leaf certificate's subject fields), and warns that these become public with the release;
   - packs with `scripts/make-dmg.sh` (refuses ad-hoc signatures, unstamped apps and dirty trees);
   - verifies the dmg: `.sha256` matches, `hdiutil verify`, attaches it read-only inside the temp folder (not under `/Volumes`, `-nobrowse`), and checks the contents are exactly the app, `update.sh` and `Install.command`, the app's signature verifies (`codesign --verify --strict --deep`), stamp and bundle id equal the built app, `update.sh` equals `scripts/update.sh`, `Install.command` installs `./TalkMargin.app`, no quarantine flag is inside, and it reports the architectures (`lipo`), the minimum macOS (plist and Mach-O) and Gatekeeper's verdict;
   - writes `release-notes-vX.Y.Z.md` (changelog section plus the install steps and a build line), unregisters and deletes the temp app, and fails if LaunchServices still lists any path of the temp folder;
   - prints the publish commands below and publishes nothing. On any failed check it removes the dmg and notes it made and exits 1.
5. **Review.** Read the notes. Optionally dry-run the installer against the dmg without changing anything: `scripts/update.sh --check build/release/vX.Y.Z/<dmg>` (read-only, but it mounts the dmg inside `/tmp`). Installing it on a Mac is the maintainer's step.
6. **Publish (maintainer).** `<OWNER>` is the GitHub account or organization; nothing here is filled in for you. Push the tag first so `gh` can verify it, and create the release as a draft the first time.
   ```
   git push <remote> main vX.Y.Z
   gh release create vX.Y.Z \
     build/release/vX.Y.Z/<dmg-name>.dmg build/release/vX.Y.Z/<dmg-name>.dmg.sha256 \
     --repo <OWNER>/talkmargin --title "TalkMargin X.Y.Z" \
     --notes-file build/release/vX.Y.Z/release-notes-vX.Y.Z.md --verify-tag --draft
   gh release edit vX.Y.Z --repo <OWNER>/talkmargin --draft=false
   ```
7. **Check what was published.** In an empty folder: `gh release download vX.Y.Z --repo <OWNER>/talkmargin`, then `shasum -a 256 -c <dmg-name>.dmg.sha256`. To withdraw a release: `gh release delete vX.Y.Z --repo <OWNER>/talkmargin` and, if the tag must go too, `git push <remote> :refs/tags/vX.Y.Z` plus `git tag -d vX.Y.Z`.

The first public release may keep the version number of an earlier build (for example 0.1.0), but its `BUILD_NUMBER` must be higher than 61. That is what lets a Mac that runs an earlier 0.1.0 build upgrade without `--allow-downgrade`, and it keeps two different builds from sharing a build number. Between releases, development builds carry the last release's `BUILD_NUMBER` with their own commit stamp; the installer treats a different commit at the same build number as an update.

## What a fresh Mac meets (evidence)

Measured on a stamped build of this repository made in a temporary folder with a verification bundle id. Nothing was installed or launched.

| Question | Answer | Evidence |
|---|---|---|
| Architectures built | arm64 only | `lipo -info`: `Non-fat file … is architecture: arm64`; `file`: `Mach-O 64-bit executable arm64` |
| Minimum macOS | 26.0 | `Package.swift`: `.macOS(.v26)`; plist `LSMinimumSystemVersion` 26.0; `vtool -show-build`: `minos 26.0`, `sdk 26.0` |
| Universal build feasible | Compiles, not verified to run | `swift build -c release --arch arm64 --arch x86_64` finished in about 23 s and produced a fat binary (`lipo`: `x86_64 arm64`, `minos 26.0`); it links the same system frameworks |
| Cost to verify universal | An Intel Mac that macOS 26 supports (Apple's list is short, check it) | Rosetta can run the x86_64 slice on Apple silicon, but `swift test --arch x86_64` could not load the x86_64 test bundle in the native test runner, and running the package tests under `arch -x86_64` did not get further; neither covers speech models, the event tap or Accessibility anyway. The build script would also need `--arch` flags and the other product path (`out/Products/Release`). |
| Signature | Apple Development, hardened runtime off, no secure timestamp | `codesign -dvv` (`flags=0x0`) |
| Gatekeeper verdict | Rejected: not notarized | `spctl --assess --type execute -vv`: `rejected`, `origin=` the Apple Development certificate; `syspolicy_check distribution`: fatal "Notary Ticket Missing" |
| Dmg downloaded by a browser (quarantined) | Not a signed dmg; the app inside is judged unnotarized | `spctl --assess --type open --context context:primary-signature` on a dmg with the quarantine attribute set by hand: `rejected`, `source=no usable signature` |
| Quarantine inside the mounted image | Not copied onto the files; the flag stays on the dmg | 0 of 15 files had `com.apple.quarantine` (all had `com.apple.provenance`, which restricts nothing) |
| `Install.command` / `update.sh` under quarantine | A shell run from the mounted image is not assessed by Gatekeeper; the installer ran fine in a sandbox. The copy it installs has no quarantine flag. | Simulated: `update.sh --app` from the mounted quarantined image into a sandbox folder installed the app; the installed copy had 0 quarantine attributes (12 provenance). `spctl` still says "rejected" for it, as for any non-notarized app. |

Not observed, because nothing here may be launched and there is no second Mac: the dialogs themselves. From Apple's documented behaviour for macOS 15 and later: opening a quarantined, non-notarized app (or double-clicking `Install.command` from a quarantined dmg) is refused with "Apple could not verify…", the Control-click shortcut no longer overrides it, and the way through is System Settings > Privacy & Security > Open Anyway, which asks for an administrator password. Whether a copy that has no quarantine flag launches without a prompt is expected but unverified.

### Honest steps for a user on a fresh Mac

These are the steps in the release notes. The download route decides how much friction there is.

1. Needs macOS 26 or later on an Apple silicon Mac (arm64), and the `claude` command line tool for the chat.
2. Download the dmg and its `.sha256`. With a browser the download is quarantined; with `gh release download` or `curl -LO` it is not.
3. Check it: `shasum -a 256 -c <dmg-name>.dmg.sha256` in the folder holding both files.
4. Quit TalkMargin if it runs. The installer stops and changes nothing while any copy runs.
5. Open the dmg and double-click `Install.command`. If macOS refuses (quarantined download), use Privacy & Security > Open Anyway, or run `sh /Volumes/TalkMargin/Install.command` in Terminal.
6. Start the app. Grant Accessibility on first launch; Screen & System Audio Recording and Microphone are asked the first time you use push-to-talk. Accessibility is asked again only if the signing identity changes.
7. Eject the dmg. To update later, repeat from step 2; the installer replaces the old app and keeps settings and history.

## Signing and notarization (decision for the maintainer)

Today every release is signed with an Apple Development certificate and is not notarized, so every fresh Mac meets the Gatekeeper refusal above unless the dmg arrives without a quarantine flag. Options, with costs and steps only; nothing here is set up.

- **Stay as is.** Free. Honest user steps as above. Each Mac's Accessibility grant survives updates while the certificate stays the same.
- **Developer ID and notarization.** Apple Developer Program, about $99 per year (check Apple's price), about a day to set up. Steps: enroll; create a Developer ID Application certificate; sign with `--options runtime --timestamp` and an entitlements file that includes `com.apple.security.device.audio-input`; build the dmg; `xcrun notarytool submit <dmg> --wait` with stored credentials; `xcrun stapler staple` the app and the dmg; check with `spctl --assess` and `syspolicy_check distribution`; add the notarization step to `release.sh`. Effect: a double-click works on any Mac with no warning. Cost: the signing identity changes, so Accessibility is asked once per Mac and the installer needs `--allow-identity-change` for that one update; each release waits for Apple's service (usually minutes).
- **Self-signed shared certificate.** Free, keeps one identity across Macs, but Gatekeeper still rejects quarantined copies and each Mac must trust the certificate by hand. Not recommended for a public release.

## CI (proposal, not added)

A GitHub Actions workflow could run `swift test` on pull requests (needs a runner image with the macOS 26 SDK and Swift 6.2 or later; the project is tested with Xcode 27.1 / Swift 6.4 and the minimum Xcode is unknown, so check availability first). It must not build releases: CI cannot use the maintainer's signing certificate, and putting a personal certificate in CI secrets is not recommended. An ad-hoc signed CI artifact would reset Accessibility grants on every build, so it must never be published as a release. `scripts/release.sh` stays a local, maintainer-run step.

## Not verified

- Gatekeeper and Install.command dialogs on a real second Mac, and that a copy installed without quarantine launches without a prompt.
- A universal build running on an Intel Mac, and the speech and Accessibility features there.
- `gh release create` itself: the tests run with shims that fail any `gh` call or `git push`, so the publish commands are written down but never exercised.

#!/usr/bin/env bash
# Local steps of a release: check the tree, tag and changelog; build the stamped app; pack and verify the dmg;
# write the release notes. It stops there: no push, no gh call, nothing is published. docs/release.md has the rest.
# Usage: scripts/release.sh [--out DIR]          (default: build/release/v<VERSION>; must not exist or be empty)
# Test options (fixtures and verification bundles only):
#   --verify-id ID   build with build-app.sh --verify-id ID and expect that bundle id instead of the production one
#   --allow-adhoc    accept an ad-hoc signature (a real release never does)
# Exit: 0 assets and notes written and verified, 1 a check failed (nothing is left in the output folder).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$root"
. scripts/dist.conf

PROD_ID=com.long.meetingprompter
# Builds up to this number were made before this repository's history began and may be installed on Macs; a
# release must exceed it so those installs upgrade without a flag.
BUILD_FLOOR=61
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
PLISTBUDDY=/usr/libexec/PlistBuddy

die() { echo "release: $*" >&2; exit 1; }
step() { echo "release: $*"; }

out="" verify_id="" allow_adhoc=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out="${2:?--out needs a folder}"; shift 2 ;;
    --verify-id) verify_id="${2:?--verify-id needs an id}"; shift 2 ;;
    --allow-adhoc) allow_adhoc=1; shift ;;
    *) die "unknown option $1" ;;
  esac
done
expect_id="${verify_id:-$PROD_ID}"

# ---- 1. Tree, version, tag, changelog -------------------------------------------------------------------------
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || die "release from main (HEAD is $(git rev-parse --abbrev-ref HEAD))"
[[ -z "$(git status --porcelain)" ]] || die "the tree is not clean (tracked changes or untracked files); commit or remove them"
version=$(tr -d '[:space:]' < VERSION)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION '$version' is not X.Y.Z"
tag="v$version"
[[ "$(git cat-file -t "refs/tags/$tag" 2>/dev/null || true)" == tag ]] || die "no annotated tag $tag (git tag -a $tag -m 'TalkMargin $version')"
head_full=$(git rev-parse HEAD)
[[ "$(git rev-parse "$tag^{commit}")" == "$head_full" ]] || die "tag $tag does not point at HEAD ($(git rev-parse --short HEAD)); a release is built from the tagged commit"
commit=$(git rev-parse --short HEAD)

# Build number: the BUILD_NUMBER file, a whole number that must exceed every earlier release's (read from each earlier
# release tag) and the floor of the builds made before this history started.
build_number=$(tr -d '\r\n' < BUILD_NUMBER 2>/dev/null || true)
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || die "BUILD_NUMBER must hold one whole number (found '$build_number')"
highest=$BUILD_FLOOR highest_from="the floor of earlier builds"
while IFS= read -r t; do
  [[ -n "$t" && "$t" != "$tag" ]] || continue
  b=$(git show "$t:BUILD_NUMBER" 2>/dev/null | tr -d '\r\n' || true)
  [[ "$b" =~ ^[0-9]+$ ]] || continue
  if (( b > highest )); then highest=$b highest_from="tag $t"; fi
done < <(git tag --list 'v[0-9]*.[0-9]*.[0-9]*')
(( build_number > highest )) || die "BUILD_NUMBER $build_number must be higher than $highest ($highest_from); raise BUILD_NUMBER for this release"

[[ -f CHANGELOG.md ]] || die "no CHANGELOG.md"
body=$(awk -v v="$version" '
  /^## / {
    if (found) exit
    h = $0; sub(/^## +/, "", h); sub(/^\[/, "", h)
    if (index(h, v) == 1 && (length(h) == length(v) || substr(h, length(v) + 1, 1) ~ /[] ]/)) { found = 1; next }
  }
  found { print }' CHANGELOG.md | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' | sed '/./,$!d')
[[ -n "$body" ]] || die "CHANGELOG.md has no section (or an empty one) for $version"

out="${out:-$root/build/release/$tag}"
if [[ -e "$out" && -n "$(ls -A "$out" 2>/dev/null)" ]]; then die "$out is not empty; remove it or pass --out"; fi
step "version $version, tag $tag at $commit, build $build_number; changelog section found"

# ---- 2. Build ------------------------------------------------------------------------------------------------------
work=$(mktemp -d /tmp/mp-release.XXXXXX); work=$(cd "$work" && pwd -P)
mnt="$work/mnt"; attached=0
finish_work() {
  local a
  if [[ $attached == 1 ]]; then
    hdiutil detach -quiet "$mnt" 2>/dev/null || { sleep 2; hdiutil detach -quiet -force "$mnt" 2>/dev/null || true; }
    attached=0
  fi
  [[ -d "$work" ]] || return 0
  for a in "$work"/*.app; do
    [[ -d "$a" ]] || continue
    scripts/registrations.sh unregister "$a" >/dev/null 2>&1 || echo "release: could not unregister $a" >&2
  done
  rm -rf "$work"
}
cleanup_on_exit() { local rc=$?; finish_work; [[ $rc == 0 || ! -d "$out" ]] || rmdir "$out" 2>/dev/null || true; exit $rc; }
trap cleanup_on_exit EXIT

step "building the stamped app (swift build, signing with the configured identity)"
build_args=(--out "$work")
[[ -z "$verify_id" ]] || build_args+=(--verify-id "$verify_id")
scripts/build-app.sh "${build_args[@]}" > "$work/build.log" 2>&1 || { tail -20 "$work/build.log" >&2; die "build failed"; }
app="$work/$APP_NAME.app"
[[ -d "$app" ]] || die "the build did not produce $app"

plist() { "$PLISTBUDDY" -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }
[[ "$(plist "$app" CFBundleShortVersionString)" == "$version" ]] || die "built app version $(plist "$app" CFBundleShortVersionString) is not VERSION $version"
[[ "$(plist "$app" CFBundleVersion)" == "$build_number" ]] || die "built app build $(plist "$app" CFBundleVersion) is not BUILD_NUMBER $build_number"
[[ "$(plist "$app" MPGitCommit)" == "$commit" ]] || die "built app commit '$(plist "$app" MPGitCommit)' is not $commit (a -dirty stamp means the tree changed during the build)"
[[ "$(plist "$app" CFBundleIdentifier)" == "$expect_id" ]] || die "built app id $(plist "$app" CFBundleIdentifier) is not $expect_id"

# What anyone who downloads the dmg can read about the signer. It goes public with the release.
sig=$(codesign -dvv "$app" 2>&1)
if grep -q 'Signature=adhoc' <<<"$sig"; then
  step "signing identity: none (ad-hoc signature)"
else
  step "signing identity, exactly as a published dmg shows it:"
  grep -E '^(Identifier|Authority|TeamIdentifier)=' <<<"$sig" | sed 's/^/release:   /'
  mkdir -p "$work/certs"
  if codesign -d --extract-certificates="$work/certs/c" "$app" >/dev/null 2>&1 && [[ -f "$work/certs/c0" ]]; then
    openssl x509 -inform der -in "$work/certs/c0" -noout -subject -nameopt multiline 2>/dev/null | sed 's/^/release:   leaf certificate /' || true
  fi
  step "WARNING: the names, account ids and team id above become public with this release; check that you accept that"
fi

# ---- 3. Pack -------------------------------------------------------------------------------------------------------
mkdir -p "$out"
pack_args=("$app" --out "$out")
[[ $allow_adhoc == 0 ]] || pack_args+=(--allow-adhoc)
scripts/make-dmg.sh "${pack_args[@]}" > "$work/pack.log" 2>&1 || { cat "$work/pack.log" >&2; die "make-dmg failed"; }
dmg=$(ls "$out"/*.dmg 2>/dev/null | head -1 || true)
[[ -n "$dmg" && -f "$dmg.sha256" ]] || die "make-dmg left no dmg and sha256 in $out"
dmg_name=$(basename "$dmg")

# ---- 4. Verify the dmg as a user would receive it -------------------------------------------------------------------
fail() { rm -f "$out"/*.dmg "$out"/*.dmg.sha256 "$out"/release-notes-*.md; die "verification failed: $*"; }
(cd "$out" && shasum -a 256 -c "$dmg_name.sha256" >/dev/null 2>&1) || fail "sha256 sidecar does not match the dmg"
hdiutil verify -quiet "$dmg" || fail "hdiutil verify"
step "sha256 and image checksum ok"

# The image is attached read-only inside the work folder, not under /Volumes, away from Finder.
mkdir -p "$mnt"
hdiutil attach -quiet -nobrowse -noautoopen -readonly -mountpoint "$mnt" "$dmg" >/dev/null || fail "could not attach the dmg"
attached=1
listing=$(ls -A "$mnt" | grep -v -E '^(\.fseventsd|\.Trashes|\.Spotlight-V100|\.DS_Store)$' | sort | tr '\n' ' ')
expected=$(printf '%s\n' "$APP_NAME.app" Install.command update.sh | sort | tr '\n' ' ')
[[ "$listing" == "$expected" ]] || fail "contents are '$listing', expected '$expected'"
mapp="$mnt/$APP_NAME.app"
codesign --verify --strict --deep "$mapp" 2>/dev/null || fail "the app inside the dmg does not verify"
details=$(codesign -dvv "$mapp" 2>&1)
if grep -q 'Signature=adhoc' <<<"$details" && [[ $allow_adhoc == 0 ]]; then fail "the app inside the dmg is ad-hoc signed"; fi
authority=$(awk -F= '/^Authority=/ {print $2; exit}' <<<"$details")
for key in CFBundleShortVersionString CFBundleVersion MPGitCommit CFBundleIdentifier; do
  [[ "$(plist "$mapp" $key)" == "$(plist "$app" $key)" ]] || fail "$key differs between the built app and the app in the dmg"
done
cmp -s "$mnt/update.sh" scripts/update.sh || fail "update.sh in the dmg is not scripts/update.sh"
[[ -x "$mnt/update.sh" && -x "$mnt/Install.command" ]] || fail "update.sh or Install.command is not executable"
grep -q "update.sh --app \"./$APP_NAME.app\"" "$mnt/Install.command" || fail "Install.command does not install ./$APP_NAME.app"
# A quarantine flag must not travel in the image. com.apple.provenance is added by macOS to files it writes
# (tested: it is on every file of the image, including the volume root); it restricts nothing, so it is only counted.
attrs=$(xattr -lr "$mnt" 2>/dev/null || true)
grep -q 'com\.apple\.quarantine' <<<"$attrs" && fail "quarantine attribute inside the dmg"
provenance=$(grep -c 'com\.apple\.provenance' <<<"$attrs" || true)
exe="$mapp/Contents/MacOS/$(plist "$mapp" CFBundleExecutable)"
archs=$(lipo -archs "$exe" 2>/dev/null) || fail "lipo cannot read $exe"
minos_plist=$(plist "$mapp" LSMinimumSystemVersion)
minos_macho=$(vtool -show-build "$exe" 2>/dev/null | awk '/minos/ {print $2; exit}' || true)
step "dmg contents ok: $APP_NAME.app, update.sh, Install.command; signed by ${authority:-unknown}; archs: $archs; minimum macOS $minos_plist (Mach-O ${minos_macho:-unknown}); no quarantine flag ($provenance provenance marks, harmless)"
gatekeeper=$(spctl --assess --type execute -vv "$mapp" 2>&1 | head -2 | tr '\n' ' ' || true)
step "Gatekeeper (informational): ${gatekeeper:-no answer}"
hdiutil detach -quiet "$mnt" || fail "could not detach the dmg"
attached=0

# ---- 5. Notes ------------------------------------------------------------------------------------------------------
arch_text="Apple silicon Macs only (arm64)"
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] && arch_text="Apple silicon and Intel Macs (universal)"
[[ "$archs" == "x86_64" ]] && arch_text="Intel Macs only (x86_64)"
notes="$out/release-notes-$tag.md"
{
  printf '%s\n\n' "$body"
  cat <<NOTES
## Install

Needs macOS $minos_plist or later, $arch_text, and the \`claude\` command line tool for the chat.

This build is signed with an Apple Development certificate and is **not notarized**, so Gatekeeper does not recognise it.

1. Download \`$dmg_name\` and \`$dmg_name.sha256\` from this release. In the folder holding both, check the download: \`shasum -a 256 -c $dmg_name.sha256\`.
2. Quit $APP_NAME if it is running. The installer stops and changes nothing while any copy runs.
3. Open the dmg and double-click \`Install.command\`. If macOS refuses because the dmg came from a browser (it carries the quarantine flag), there are two ways past it: open System Settings > Privacy & Security, find the message about \`Install.command\` and choose Open Anyway, which asks for an administrator password; or, without admin rights, run \`sh /Volumes/$VOLUME_NAME/Install.command\` in Terminal, which Gatekeeper does not assess. Downloading with \`gh release download\` or \`curl -LO\` does not add the quarantine flag.
4. The installer puts $APP_NAME in \`~/Applications\`, replaces an older copy (including one under an older name) after checking it, and keeps your settings and history. It never restarts the app; start it yourself.
5. Eject the dmg.

Updating later is the same: download the new dmg, quit the app, run \`Install.command\`. $APP_NAME does not check for or download updates itself.

Build: version $version, build $build_number, commit $commit. sha256 of the dmg: \`$(cut -d' ' -f1 "$dmg.sha256")\`.
NOTES
} > "$notes"

# ---- 6. Leave no registration behind ----------------------------------------------------------------------------------
finish_work
left=$("$LSREGISTER" -dump 2>/dev/null | sed -n 's/^path: *//; s/ (0x[0-9a-f]*)$//p' | grep -F "$work/" || true)
[[ -z "$left" ]] || fail "LaunchServices still lists paths of the work folder: $left"
step "work folder removed; no LaunchServices record of it remains"

ls -l "$out" | sed 's/^/release:   /'
cat <<DONE

release: assets ready in $out
release: nothing was published. To publish (the maintainer's step, not run here; replace <OWNER>; the tag is pushed first):
  git push <remote> main $tag
  gh release create $tag "$dmg" "$dmg.sha256" --repo <OWNER>/talkmargin --title "$APP_NAME $version" --notes-file "$notes" --verify-tag --draft
  gh release edit $tag --repo <OWNER>/talkmargin --draft=false
DONE

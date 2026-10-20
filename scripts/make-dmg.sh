#!/usr/bin/env bash
# Pack a built, signed, stamped .app into build/dist/<name>.dmg plus a .sha256. Never mounts the image.
# The image holds the app, update.sh and Install.command (runs update.sh on the app beside it): the
# install location is ~/Applications, which a dmg cannot link to, so there is no drag target.
# Usage: scripts/make-dmg.sh <App.app> [--out DIR] [--allow-dirty] [--allow-adhoc]
# Name: <App>-<CFBundleShortVersionString>-<CFBundleVersion>-<commit>.dmg
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# APP_NAME and VOLUME_NAME; MP_DIST_CONF points at another file (probes with a dummy app).
. "${MP_DIST_CONF:-$root/scripts/dist.conf}"

die() { echo "make-dmg: $*" >&2; exit 1; }

app=""
out="$root/build/dist"
allow_dirty=0
allow_adhoc=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out="${2:?--out needs a folder}"; shift 2 ;;
    --allow-dirty) allow_dirty=1; shift ;;
    --allow-adhoc) allow_adhoc=1; shift ;;
    -*) die "unknown option $1" ;;
    *) [[ -z "$app" ]] || die "one app only"; app="${1%/}"; shift ;;
  esac
done
[[ -n "$app" ]] || die "usage: make-dmg.sh <App.app> [--out DIR] [--allow-dirty] [--allow-adhoc]"
[[ -f "$app/Contents/Info.plist" ]] || die "not an app bundle: $app"

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist" 2>/dev/null || true; }
short=$(plist CFBundleShortVersionString)
build=$(plist CFBundleVersion)
[[ -n "$short" && -n "$build" ]] || die "Info.plist lacks CFBundleShortVersionString or CFBundleVersion"
name=$(basename "$app" .app)
[[ "$name" == "$APP_NAME" ]] || die "app is $name.app but dist.conf says APP_NAME=$APP_NAME"

# Signature: valid, and not ad-hoc (an ad-hoc update resets the Accessibility grant on every Mac).
codesign --verify --strict --deep "$app" 2>/dev/null || die "signature of $app is not valid"
details=$(codesign -dvv "$app" 2>&1)
if grep -q 'Signature=adhoc' <<<"$details"; then
  [[ $allow_adhoc == 1 ]] || die "$app is ad-hoc signed; sign with a stable identity (or --allow-adhoc)"
fi
authority=$(awk -F= '/^Authority=/ {print $2; exit}' <<<"$details")

# Stamp: the build records its commit and its build number. The commit must exist here, and the number must be
# the BUILD_NUMBER file as of that commit (the working-tree BUILD_NUMBER for a -dirty build).
commit=$(plist MPGitCommit)
[[ -n "$commit" ]] || die "$app has no MPGitCommit; build it with the stamping build script"
[[ "$build" =~ ^[0-9]+$ ]] || die "CFBundleVersion '$build' is not an integer build number"
sha=${commit%-dirty}
git -C "$root" rev-parse --verify -q "$sha^{commit}" >/dev/null || die "commit $sha is not in this repository"
if [[ "$commit" == *-dirty ]]; then
  expected=$(tr -d '\r\n' < "$root/BUILD_NUMBER" 2>/dev/null || true)
else
  expected=$(git -C "$root" show "$sha:BUILD_NUMBER" 2>/dev/null | tr -d '\r\n' || true)
fi
[[ "$expected" =~ ^[0-9]+$ ]] || die "no build number (BUILD_NUMBER) at $sha"
[[ "$build" == "$expected" ]] || die "CFBundleVersion $build is not BUILD_NUMBER $expected at $sha"
dirty=$(git -C "$root" status --porcelain --untracked-files=no)
if [[ $allow_dirty == 0 ]]; then
  [[ -z "$dirty" ]] || die "working tree has uncommitted changes (--allow-dirty to pack anyway)"
  [[ "$commit" != *-dirty ]] || die "$app was built from a dirty tree ($commit)"
fi
if [[ -f "$root/VERSION" && "$short" != "$(tr -d '[:space:]' < "$root/VERSION")" ]]; then
  echo "make-dmg: warning: app version $short differs from VERSION $(cat "$root/VERSION")" >&2
fi

dmg_name="$name-$short-$build-$commit.dmg"
mkdir -p "$out"
stage=$(mktemp -d /tmp/mp-dmg-stage.XXXXXX)
tmp="$out/.$dmg_name.tmp.dmg"
trap 'rm -rf "$stage" "$tmp"' EXIT

# No extended attributes: a quarantine flag or provenance must not travel in the image.
ditto --noextattr --noqtn "$app" "$stage/$name.app"
codesign --verify --strict --deep "$stage/$name.app" || die "staged copy failed verification"
cp "$root/scripts/update.sh" "$stage/update.sh"
cat > "$stage/Install.command" <<INSTALL
#!/bin/bash
# Installs $name.app (beside this file) into ~/Applications with update.sh. Quit the app first.
cd "\$(dirname "\$0")"
./update.sh --app "./$name.app"
status=\$?
echo
read -r -p "Press Return to close. " _
exit \$status
INSTALL
chmod +x "$stage/update.sh" "$stage/Install.command"

hdiutil create -quiet -srcfolder "$stage" -volname "$VOLUME_NAME" -fs HFS+ -format UDZO \
  -imagekey zlib-level=9 -ov "$tmp"
hdiutil verify -quiet "$tmp"
mv -f "$tmp" "$out/$dmg_name"
(cd "$out" && shasum -a 256 "$dmg_name" > "$dmg_name.sha256")

echo "Packed $out/$dmg_name"
echo "  version $short ($build), commit $commit, signed by ${authority:-unknown}"
echo "  sha256  $(cut -d' ' -f1 "$out/$dmg_name.sha256")"

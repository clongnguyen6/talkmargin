#!/usr/bin/env bash
# Simulation of scripts/release.sh: a throwaway git repo under /tmp with the real release.sh, make-dmg.sh,
# update.sh, registrations.sh and a stub build-app.sh that makes a dummy stamped app (dummy bundle id, ad-hoc
# signed). Shims for gh and git prove nothing is published. No production-id bundle is ever built or registered.
# Usage: scripts/dev/test-release.sh
set -euo pipefail
src=$(cd "$(dirname "$0")/../.." && pwd -P)
work=$(mktemp -d /tmp/mp-release-test.XXXXXX); work=$(cd "$work" && pwd -P)
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
fx="$work/repo"; shims="$work/shims"; calls="$work/calls.log"
mkdir -p "$fx/scripts/lib" "$shims"; : > "$calls"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# Shims: any gh call, and any git push/remote/fetch, is recorded (the test fails if one happens).
cat > "$shims/gh" <<S
#!/bin/bash
echo "gh \$*" >> "$calls"
exit 1
S
cat > "$shims/git" <<S
#!/bin/bash
case "\$1" in push|remote|fetch|pull|clone) echo "git \$*" >> "$calls"; exit 1 ;; esac
exec /usr/bin/git "\$@"
S
chmod +x "$shims/gh" "$shims/git"

for f in release.sh make-dmg.sh update.sh registrations.sh; do cp "$src/scripts/$f" "$fx/scripts/$f"; done
cp "$src/scripts/lib/paths.sh" "$fx/scripts/lib/paths.sh"
mv "$fx/scripts/make-dmg.sh" "$fx/scripts/make-dmg.real.sh"
printf 'APP_NAME=MPNew\nVOLUME_NAME="MPNew Volume"\n' > "$fx/scripts/dist.conf"
printf 'int main(){return 0;}\n' > "$work/main.c"; clang -o "$work/exe" "$work/main.c"
cp "$work/exe" "$fx/scripts/exe.bin"

# make-dmg wrapper: the real packer, then an optional corruption.
cat > "$fx/scripts/make-dmg.sh" <<'S'
#!/bin/bash
root=$(cd "$(dirname "$0")/.." && pwd -P)
/bin/bash "$root/scripts/make-dmg.real.sh" "$@" || exit $?
if [[ "${FIXTURE_CORRUPT:-}" == sha ]]; then
  for f in "$root"/build/release/*/*.sha256 "$root"/../out*/*.sha256; do [[ -f "$f" ]] && echo "0000000000000000000000000000000000000000000000000000000000000000  x" > "$f"; done
fi
S
# Stub build: a dummy stamped app, registered with LaunchServices like a real build output can be.
cat > "$fx/scripts/build-app.sh" <<'S'
#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
out="" id=com.example.mpdistprobe.prod
while [[ $# -gt 0 ]]; do case "$1" in --out) out="$2"; shift 2 ;; --verify-id) id="$2"; shift 2 ;; *) exit 2 ;; esac; done
app="$out/MPNew.app"; mkdir -p "$app/Contents/MacOS"
cp "$root/scripts/exe.bin" "$app/Contents/MacOS/MPNew"
short=$(tr -d '[:space:]' < "$root/VERSION"); short="${FIXTURE_SHORT:-$short}"
commit=$(git -C "$root" rev-parse --short HEAD)
build=$(tr -d '[:space:]' < "$root/BUILD_NUMBER"); build="${FIXTURE_BUILD:-$build}"
cat > "$app/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$id</string>
<key>CFBundleExecutable</key><string>MPNew</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>CFBundleShortVersionString</key><string>$short</string>
<key>CFBundleVersion</key><string>$build</string>
<key>MPGitCommit</key><string>$commit</string>
</dict></plist>
P
codesign --force --sign - "$app" 2>/dev/null
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LS" -f "$app" >/dev/null 2>&1 || true
if [[ "${FIXTURE_LEAK:-}" == 1 ]]; then
  mkdir -p "$out/leak/Leak.app/Contents"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.example.mpdistprobe.leak" -c "Add :CFBundlePackageType string APPL" "$out/leak/Leak.app/Contents/Info.plist" >/dev/null
  "$LS" -f "$out/leak/Leak.app" >/dev/null 2>&1 || true
fi
S
chmod +x "$fx"/scripts/*.sh
printf 'build/\n' > "$fx/.gitignore"
# History: release 1.2.2 (build 65), then release 1.2.3 (build 70), the one under test.
printf '1.2.2\n' > "$fx/VERSION"; printf '65\n' > "$fx/BUILD_NUMBER"
printf '# Changelog\n\n## [1.2.2] - 2025-12-01\n\nOlder entry that must not appear in the notes.\n' > "$fx/CHANGELOG.md"
git -C "$fx" init -q -b main
git -C "$fx" add -A && git -C "$fx" commit -q -m "fixture 1.2.2"
git -C "$fx" tag -a v1.2.2 -m "fixture 1.2.2"
printf '1.2.3\n' > "$fx/VERSION"; printf '70\n' > "$fx/BUILD_NUMBER"
cat > "$fx/CHANGELOG.md" <<'S'
# Changelog

## [1.2.3] - 2026-01-01

First line of the notes.

- Second item.

## [1.2.2] - 2025-12-01

Older entry that must not appear in the notes.
S
git -C "$fx" add -A && git -C "$fx" commit -q -m "fixture 1.2.3"
git -C "$fx" tag -a v1.2.3 -m "fixture 1.2.3"
git -C "$fx" tag fixture-base

fails=0
leaks_before=$({ ls -d /tmp/mp-release.* 2>/dev/null || true; } | wc -l | tr -d ' ')
expect() { if [[ "$2" == "$3" ]]; then echo "PASS $1"; else echo "FAIL $1: expected '$3', got '$2'"; fails=$((fails + 1)); [[ ! -f "$work/out.txt" ]] || sed 's/^/     /' "$work/out.txt" | tail -12; fi; }
run() { # <out folder> [env assignments via env prefix in caller]; status in $rc
  rc=0
  PATH="$shims:$PATH" /bin/bash "$fx/scripts/release.sh" --verify-id com.example.mpdistprobe.v --allow-adhoc --out "$1" > "$work/out.txt" 2>&1 || rc=$?
}
reset_repo() { git -C "$fx" checkout -q main; git -C "$fx" reset -q --hard fixture-base; git -C "$fx" clean -q -fd; git -C "$fx" tag -d v1.2.3 >/dev/null 2>&1 || true; git -C "$fx" tag -a v1.2.3 -m "fixture 1.2.3"; git -C "$fx" tag -d v1.2.2 >/dev/null 2>&1 || true; git -C "$fx" tag -a v1.2.2 -m "fixture 1.2.2" fixture-base~1; }

echo "== 1. happy path"
run "$work/out1"
expect "exit 0" "$rc" 0
expect "the signer is reported (ad-hoc here: no identity fields)" "$(grep -c 'signing identity: none (ad-hoc signature)' "$work/out.txt")" 1
expect "dmg written" "$(ls "$work/out1" | grep -c '^MPNew-1.2.3-70-.*\.dmg$')" 1
expect "sha256 written" "$(ls "$work/out1" | grep -c '\.dmg\.sha256$')" 1
expect "notes written" "$(ls "$work/out1" | grep -c '^release-notes-v1.2.3.md$')" 1
expect "notes carry the changelog section" "$(grep -c -E '^(First line of the notes\.|- Second item\.)$' "$work/out1/release-notes-v1.2.3.md")" 2
expect "notes omit the older entry" "$(grep -c 'Older entry' "$work/out1/release-notes-v1.2.3.md")" 0
expect "notes say not notarized" "$(grep -c 'not notarized' "$work/out1/release-notes-v1.2.3.md")" 1
expect "notes state the architecture" "$(grep -c 'arm64' "$work/out1/release-notes-v1.2.3.md")" 1
expect "notes do not promise in-app updates" "$(grep -c -i -E 'checks for updates automatically|auto-?update|update available' "$work/out1/release-notes-v1.2.3.md")" 0
expect "publish commands use the placeholder (create and edit)" "$(grep -c '<OWNER>/talkmargin' "$work/out.txt")" 2
expect "no url or owner invented" "$(cat "$work/out.txt" "$work/out1/release-notes-v1.2.3.md" | grep -c -i -E 'https?://|github\.com')" 0
expect "nothing published (no gh, no git push)" "$(grep -c . "$calls")" 0
expect "work folder gone" "$({ ls -d /tmp/mp-release.* 2>/dev/null || true; } | wc -l | tr -d ' ')" "$leaks_before"
expect "no record of the work folder in LaunchServices" "$("$LSREGISTER" -dump 2>/dev/null | grep -c 'mp-release\.')" 0

echo "== 2. refusals leave no assets"
reset_repo; echo "x" >> "$fx/CHANGELOG.md"; run "$work/out2"
expect "dirty tracked file: exit 1" "$rc" 1; expect "  and no folder content" "$(ls -A "$work/out2" 2>/dev/null | wc -l | tr -d ' ')" 0
reset_repo; touch "$fx/untracked.txt"; run "$work/out2"
expect "untracked file: exit 1" "$rc" 1; rm -f "$fx/untracked.txt"
reset_repo; git -C "$fx" tag -d v1.2.3 >/dev/null; run "$work/out2"
expect "no tag: exit 1" "$rc" 1; expect "  says so" "$(grep -c 'no annotated tag' "$work/out.txt")" 1
reset_repo; git -C "$fx" tag -d v1.2.3 >/dev/null; git -C "$fx" tag v1.2.3; run "$work/out2"
expect "lightweight tag: exit 1" "$rc" 1
reset_repo; echo more >> "$fx/VERSION.txt"; git -C "$fx" add -A; git -C "$fx" commit -q -m "after the tag"; run "$work/out2"
expect "tag behind HEAD: exit 1" "$rc" 1; expect "  says so" "$(grep -c 'does not point at HEAD' "$work/out.txt")" 1
reset_repo; git -C "$fx" checkout -q -b other; run "$work/out2"
expect "not on main: exit 1" "$rc" 1; git -C "$fx" checkout -q main
reset_repo; printf '1.2\n' > "$fx/VERSION"; git -C "$fx" commit -q -am "bad version"; git -C "$fx" tag -d v1.2.3 >/dev/null; git -C "$fx" tag -a v1.2.3 -m x; run "$work/out2"
expect "VERSION not X.Y.Z: exit 1" "$rc" 1
reset_repo; sed -i '' 's/^## \[1.2.3\].*/## [1.2.4] - 2026-01-02/' "$fx/CHANGELOG.md"; git -C "$fx" commit -q -am "changelog for another version"; git -C "$fx" tag -d v1.2.3 >/dev/null; git -C "$fx" tag -a v1.2.3 -m x; run "$work/out2"
expect "changelog has no section for the version: exit 1" "$rc" 1; expect "  says so" "$(grep -c 'no section' "$work/out.txt")" 1
reset_repo; printf '# Changelog\n\n## [1.2.3] - 2026-01-01\n\n## [1.2.2]\n\nold\n' > "$fx/CHANGELOG.md"; git -C "$fx" commit -q -am "empty section"; git -C "$fx" tag -d v1.2.3 >/dev/null; git -C "$fx" tag -a v1.2.3 -m x; run "$work/out2"
expect "empty changelog section: exit 1" "$rc" 1

echo "== 2b. the build number is explicit (BUILD_NUMBER) and must rise"
retag() { git -C "$fx" commit -q -am "$1"; git -C "$fx" tag -d v1.2.3 >/dev/null; git -C "$fx" tag -a v1.2.3 -m x; }
reset_repo; printf '65\n' > "$fx/BUILD_NUMBER"; retag "same build as the previous release"; run "$work/out6"
expect "BUILD_NUMBER equal to the previous release's: exit 1" "$rc" 1; expect "  names the tag" "$(grep -c 'higher than 65 (tag v1.2.2)' "$work/out.txt")" 1
reset_repo; printf '64\n' > "$fx/BUILD_NUMBER"; retag "lower build"; run "$work/out6"
expect "BUILD_NUMBER below the previous release's: exit 1" "$rc" 1
reset_repo; git -C "$fx" tag -d v1.2.2 >/dev/null; printf '61\n' > "$fx/BUILD_NUMBER"; retag "at the floor"; run "$work/out6"
expect "no earlier release, BUILD_NUMBER at the floor (61): exit 1" "$rc" 1; expect "  names the floor" "$(grep -c 'higher than 61' "$work/out.txt")" 1
reset_repo; git -C "$fx" tag -d v1.2.2 >/dev/null; printf '62\n' > "$fx/BUILD_NUMBER"; retag "first release"; run "$work/out6"
expect "first release with BUILD_NUMBER 62: exit 0" "$rc" 0; expect "  the dmg carries build 62" "$(ls "$work/out6" | grep -c '^MPNew-1.2.3-62-.*\.dmg$')" 1
for bad in "" abc 0 "6 2" "-3"; do
  reset_repo; printf '%s\n' "$bad" > "$fx/BUILD_NUMBER"; retag "bad BUILD_NUMBER"; run "$work/out7"
  expect "BUILD_NUMBER '$bad' is refused: exit 1" "$rc" 1
done
reset_repo; git -C "$fx" rm -q BUILD_NUMBER; retag "no BUILD_NUMBER file"; run "$work/out7"
expect "missing BUILD_NUMBER file: exit 1" "$rc" 1
reset_repo; FIXTURE_BUILD=99 run "$work/out8"
expect "app stamped with another build: exit 1" "$rc" 1; expect "  says so" "$(grep -c 'is not BUILD_NUMBER 70' "$work/out.txt")" 1
# make-dmg itself: the stamp must equal the BUILD_NUMBER recorded at the stamped commit
reset_repo; mkdir -p "$work/stub"; FIXTURE_BUILD=99 /bin/bash "$fx/scripts/build-app.sh" --out "$work/stub" --verify-id com.example.mpdistprobe.v >/dev/null 2>&1
rc=0; /bin/bash "$fx/scripts/make-dmg.real.sh" "$work/stub/MPNew.app" --allow-adhoc --out "$work/out9" > "$work/out.txt" 2>&1 || rc=$?
expect "make-dmg refuses a stamp that differs from BUILD_NUMBER at the commit: exit 1" "$rc" 1; expect "  says so" "$(grep -c 'is not BUILD_NUMBER 70' "$work/out.txt")" 1
"$fx/scripts/registrations.sh" unregister "$work/stub/MPNew.app" >/dev/null 2>&1 || true

echo "== 3. verification failures remove the assets"
reset_repo; FIXTURE_SHORT=9.9.9 run "$work/out3"
expect "built version differs from VERSION: exit 1" "$rc" 1; expect "  says so" "$(grep -c 'is not VERSION' "$work/out.txt")" 1
reset_repo; FIXTURE_CORRUPT=sha run "$work/out3"
expect "wrong sha256 sidecar: exit 1" "$rc" 1; expect "  no dmg left" "$(ls "$work/out3" 2>/dev/null | grep -c dmg)" 0
reset_repo; mkdir -p "$work/out4"; touch "$work/out4/old.dmg"; run "$work/out4"
expect "output folder not empty: exit 1" "$rc" 1
reset_repo; FIXTURE_LEAK=1 run "$work/out5"
expect "a record left in LaunchServices is caught: exit 1" "$rc" 1; expect "  says so" "$(grep -c 'still lists' "$work/out.txt")" 1
expect "  no assets" "$(ls "$work/out5" 2>/dev/null | grep -c dmg)" 0
"$fx/scripts/registrations.sh" stale com.example.mpdistprobe.leak >/dev/null 2>&1 || true
expect "  test cleaned its own leak record" "$("$LSREGISTER" -dump 2>/dev/null | grep -c 'mp-release\.')" 0
expect "nothing published through all of it" "$(grep -c . "$calls")" 0
expect "no work folders left" "$({ ls -d /tmp/mp-release.* 2>/dev/null || true; } | wc -l | tr -d ' ')" "$leaks_before"

exit $((fails > 0))

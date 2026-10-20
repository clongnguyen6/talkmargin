#!/usr/bin/env bash
# Simulation: a name listed both as APP_NAME and in LEGACY_APP_NAMES must yield one copy, not two.
# Dummy bundle id, sandbox under /tmp, ad-hoc signing, lsregister stubbed. Touches nothing else.
# Usage: scripts/dev/test-update-dedupe.sh [path/to/update.sh]
set -euo pipefail
update="${1:-$(cd "$(dirname "$0")/.." && pwd)/update.sh}"
work=$(mktemp -d /tmp/mp-dedupe-test.XXXXXX)
trap 'rm -rf "$work"' EXIT
sb="$work/sb"; mkdir -p "$sb/home/Applications" "$sb/Applications"; touch "$sb/.mp-update-sandbox"
printf '#!/bin/bash\nexit 0\n' > "$work/lsstub"; chmod +x "$work/lsstub"
printf 'int main(){return 0;}\n' > "$work/main.c"

mkapp() { # <dir> <Name> <build> <commit>
  local app="$1/$2.app"; mkdir -p "$app/Contents/MacOS"
  clang -o "$app/Contents/MacOS/$2" "$work/main.c"
  cat > "$app/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.mpdistprobe</string>
<key>CFBundleExecutable</key><string>$2</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>$3</string>
<key>MPGitCommit</key><string>$4</string>
</dict></plist>
P
  codesign --force --sign - "$app" 2>/dev/null
}
run() { # <legacy names> <args...>; output in $work/out, status in $?
  local legacy=$1; shift
  MP_UPDATE_SANDBOX="$sb" MP_UPDATE_LEGACY_NAMES="$legacy" MP_UPDATE_LSREGISTER="$work/lsstub" \
    /bin/bash "$update" --dest "$sb/home/Applications" "$@" > "$work/out" 2>&1 && return 0 || return $?
}
fails=0
expect() { if [[ "$2" == "$3" ]]; then echo "PASS $1"; else echo "FAIL $1: expected '$3', got '$2'"; fails=$((fails + 1)); sed 's/^/     /' "$work/out"; fi; }

mkapp "$work/new" MPNew 12 ccc3333
mkapp "$work/new11" MPNew 11 bbb2222
mkapp "$work/old" MPOld 10 aaa1010

# 1. Update over one installed copy; the name is also a legacy name: listed once.
ditto "$work/new11/MPNew.app" "$sb/home/Applications/MPNew.app"
rc=0; run "MPNew" --check --app "$work/new/MPNew.app" || rc=$?
expect "one copy listed once (found lines)" "$(grep -c '^update: found:' "$work/out")" 1
expect "check exits 0" "$rc" 0

# 2. Same build and commit, single copy: already current (two entries used to defeat this).
rm -rf "$sb/home/Applications/MPNew.app"; ditto "$work/new/MPNew.app" "$sb/home/Applications/MPNew.app"
rc=0; run "MPNew" --app "$work/new/MPNew.app" || rc=$?
expect "already current" "$(grep -c 'already current' "$work/out")" 1
expect "already current exits 0" "$rc" 0

# 3. A different old name next to it is still found and retired.
ditto "$work/old/MPOld.app" "$sb/Applications/MPOld.app"
rc=0; run "MPNew MPOld" --check --app "$work/new/MPNew.app" || rc=$?
expect "two distinct copies listed" "$(grep -c '^update: found:' "$work/out")" 2
expect "old name retired" "$(grep -c '^update:   .*/MPOld.app$' "$work/out")" 1

exit $((fails > 0))

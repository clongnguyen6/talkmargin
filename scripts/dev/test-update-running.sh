#!/usr/bin/env bash
# Simulation: an app that starts while update.sh is copying or swapping must abort the update (exit 4) and
# leave the previous state. Dummy bundle id, sandbox under /tmp, ad-hoc signing, stubbed lsregister. PATH
# wrappers for ditto and codesign hold update.sh at a chosen step so a dummy process can be started "mid-run".
# Usage: scripts/dev/test-update-running.sh [path/to/update.sh]
set -euo pipefail
update="${1:-$(cd "$(dirname "$0")/.." && pwd)/update.sh}"
work=$(mktemp -d /tmp/mp-running-test.XXXXXX)
pids=""
cleanup() { for p in $pids; do kill "$p" 2>/dev/null || true; done; chmod -R u+w "$work" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
sb="$work/sb"; H="$sb/home/Applications"; A="$sb/Applications"
mkdir -p "$work/bin" "$H" "$A"; touch "$sb/.mp-update-sandbox"
phys=$(cd "$work" && pwd -P)

# lsregister stub: logs the calls.
cat > "$work/lsstub" <<S
#!/bin/bash
echo "\$*" >> "$work/ls.log"
[[ "\$1" == "-f" && -n "\${STUB_FAIL_F:-}" ]] && exit 1
exit 0
S
# ditto wrapper: after the copy, hold until $work/go1 exists (the copy "takes long").
cat > "$work/bin/ditto" <<S
#!/bin/bash
/usr/bin/ditto "\$@" || exit \$?
if [[ -n "\${HOLD_AFTER_COPY:-}" ]]; then
  touch "$work/reached1"
  for i in \$(seq 1 300); do [[ -e "$work/go1" ]] && break; sleep 0.1; done
fi
S
# codesign wrapper: hold the verification of the installed copy (after the swap) until $work/go2 exists.
cat > "$work/bin/codesign" <<S
#!/bin/bash
if [[ -n "\${HOLD_AFTER_PLACE:-}" && "\$1" == "--verify" && "\${@: -1}" == "$phys/sb/home/Applications/MPNew.app" ]]; then
  touch "$work/reached2"
  for i in \$(seq 1 300); do [[ -e "$work/go2" ]] && break; sleep 0.1; done
fi
exec /usr/bin/codesign "\$@"
S
chmod +x "$work/lsstub" "$work/bin/ditto" "$work/bin/codesign"
printf 'int main(){return 0;}\n' > "$work/quick.c"
printf '#include <unistd.h>\nint main(){sleep(300);return 0;}\n' > "$work/sleeper.c"

mkapp() { # <dir> <Name> <build> <commit> <quick|sleeper>
  local app="$1/$2.app"; rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
  clang -o "$app/Contents/MacOS/$2" "$work/$5.c"
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
  /usr/bin/codesign --force --sign - "$app" 2>/dev/null
}
build_of() { /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$1/Contents/Info.plist" 2>/dev/null || echo none; }
snap() { (cd "$sb" && find . | sort; find . -type f -exec shasum -a 256 {} + | sort) | shasum -a 256 | cut -c1-12; }
fails=0
expect() { if [[ "$2" == "$3" ]]; then echo "PASS $1"; else echo "FAIL $1: expected '$3', got '$2'"; fails=$((fails + 1)); sed 's/^/     /' "$work/out"; fi; }

mkapp "$work/new" MPNew 12 ccc3333 sleeper     # the new build's executable can be started as a process
mkapp "$work/old11" MPNew 11 bbb2222 sleeper
mkapp "$work/old10" MPOld 10 aaa1010 sleeper

reset() {
  chmod -R u+w "$sb" 2>/dev/null || true
  rm -rf "$H" "$A" "$work/reached1" "$work/reached2" "$work/go1" "$work/go2" "$work/ls.log"; mkdir -p "$H" "$A"
  ditto "$work/old11/MPNew.app" "$H/MPNew.app"; ditto "$work/old10/MPOld.app" "$A/MPOld.app"; : > "$work/ls.log"
}
# start <hold env> ; leaves update.sh running in the background: $upid
start() {
  env "$1=1" PATH="$work/bin:$PATH" MP_UPDATE_SANDBOX="$sb" MP_UPDATE_LEGACY_NAMES=MPOld MP_UPDATE_LSREGISTER="$work/lsstub" \
    /bin/bash "$update" --dest "$H" --app "$work/new/MPNew.app" > "$work/out" 2>&1 &
  upid=$!
}
waitfor() { for i in $(seq 1 300); do [[ -e "$1" ]] && return 0; sleep 0.1; done; echo "timeout waiting for $1"; return 1; }
launch() { "$1" >/dev/null 2>&1 & lastpid=$!; pids="$pids $lastpid"; disown "$lastpid"; sleep 0.5; }
leftovers() { find "$sb" -name '.MPNew.*' -o -name '.MPOld.*' | wc -l | tr -d ' '; }

echo "== 1. an app starts during the copy (before the swap)"
reset; before=$(snap)
start HOLD_AFTER_COPY; waitfor "$work/reached1"
launch "$H/MPNew.app/Contents/MacOS/MPNew"; touch "$work/go1"
rc=0; wait "$upid" || rc=$?
expect "exit 4" "$rc" 4
expect "says it started during the update" "$(grep -c 'started running during the update' "$work/out")" 1
expect "tree unchanged" "$(snap)" "$before"
expect "installed still build 11" "$(build_of "$H/MPNew.app")" 11
expect "no leftovers" "$(leftovers)" 0
expect "lsregister not called" "$(grep -c . "$work/ls.log")" 0
kill "$lastpid" 2>/dev/null || true; sleep 0.3

echo "== 2. an old-name copy starts after the swap, before it is retired"
reset
start HOLD_AFTER_PLACE; waitfor "$work/reached2"
launch "$A/MPOld.app/Contents/MacOS/MPOld"; touch "$work/go2"
rc=0; wait "$upid" || rc=$?
expect "exit 4" "$rc" 4
expect "says it started during the update" "$(grep -c 'started running during the update' "$work/out")" 1
expect "previous state restored" "$(grep -c 'previous state restored' "$work/out")" 1
expect "installed back to build 11" "$(build_of "$H/MPNew.app")" 11
expect "old-name copy untouched" "$(build_of "$A/MPOld.app")" 10
expect "no leftovers" "$(leftovers)" 0
expect "lsregister not called" "$(grep -c . "$work/ls.log")" 0
kill "$lastpid" 2>/dev/null || true; sleep 0.3

echo "== 3. the new app itself is started after the swap: it is never removed"
reset
start HOLD_AFTER_PLACE; waitfor "$work/reached2"
launch "$H/MPNew.app/Contents/MacOS/MPNew"; newpid=$lastpid; touch "$work/go2"
rc=0; wait "$upid" || rc=$?
expect "exit 4" "$rc" 4
expect "new app left in place" "$(grep -c 'is running, so it is left in place' "$work/out")" 1
expect "installed is the new build 12" "$(build_of "$H/MPNew.app")" 12
expect "process still alive" "$(kill -0 "$newpid" 2>/dev/null && echo yes || echo no)" yes
expect "previous app kept at .MPNew.old" "$(build_of "$H/.MPNew.old")" 11
expect "old-name copy untouched" "$(build_of "$A/MPOld.app")" 10
kill "$newpid" 2>/dev/null || true; sleep 0.3

echo "== 4. control: nothing starts, the same holds, the update completes"
reset
start HOLD_AFTER_COPY; waitfor "$work/reached1"; touch "$work/go1"
rc=0; wait "$upid" || rc=$?
expect "exit 0" "$rc" 0
expect "installed build 12" "$(build_of "$H/MPNew.app")" 12
expect "old-name copy retired" "$([[ -e "$A/MPOld.app" ]] && echo present || echo gone)" gone
expect "no leftovers" "$(leftovers)" 0
expect "installed app registered once" "$(grep -cxF -e "-f $phys/sb/home/Applications/MPNew.app" "$work/ls.log")" 1
expect "registered after the old copy was unregistered" "$(grep -n -e '^-u' -e '^-f' "$work/ls.log" | cut -d: -f2 | cut -c1-2 | tr '\n' ' ')" "-u -f "

echo "== 5. registration fails: warning only, the install stands"
reset
rc=0
env STUB_FAIL_F=1 PATH="$work/bin:$PATH" MP_UPDATE_SANDBOX="$sb" MP_UPDATE_LEGACY_NAMES=MPOld MP_UPDATE_LSREGISTER="$work/lsstub" \
  /bin/bash "$update" --dest "$H" --app "$work/new/MPNew.app" > "$work/out" 2>&1 || rc=$?
expect "exit 0" "$rc" 0
expect "warns" "$(grep -c 'warning: could not register' "$work/out")" 1
expect "installed build 12" "$(build_of "$H/MPNew.app")" 12
expect "old-name copy retired" "$([[ -e "$A/MPOld.app" ]] && echo present || echo gone)" gone

exit $((fails > 0))

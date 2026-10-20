#!/usr/bin/env bash
# The one install routine: put an app (from a dmg made by make-dmg.sh, or a staged .app) into
# ~/Applications. Never quits, replaces or removes a running app: if any copy runs it stops before
# changing anything. Never touches settings or history.
# Copies of the same bundle id elsewhere (/Applications, an old name in LEGACY_APP_NAMES) are all checked
# first; they are unregistered and removed only after the new app is in place and verified, and the whole
# change is undone if any step fails.
# Usage: scripts/update.sh [options] <file.dmg | folder of dmgs>
#        scripts/update.sh [options] --app <staged App.app>      (no dmg, no sha256; same checks)
#   --check                  verify and report only; change nothing
#   --dest DIR               install folder (default ~/Applications)
#   --allow-downgrade        install an older build
#   --allow-identity-change  accept another signing identity (Accessibility is asked again)
#   --allow-unstamped-install  install over copies without a build stamp (their versions cannot be compared)
#   --remove-other-copies    retire same-name copies in the other standard folder
# Exit: 0 installed or already current, 1 error (including leftovers of an interrupted run), 2 refused by
# the sandbox guard, 3 blocked (a flag is needed), 4 an instance is running.
# Test mode: MP_UPDATE_SANDBOX=<dir containing .mp-update-sandbox>. Every target must lie inside it;
# ~/Applications and /Applications are refused. See docs/distribution.md.
set -euo pipefail

PROD_ID=com.long.meetingprompter
LEGACY_APP_NAMES="MeetingPrompter"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

die() { echo "update: $*" >&2; exit 1; }
blocked() { echo "update: $*" >&2; exit 3; }
note() { echo "update: $*"; }
refuse() { echo "update: refused: $*" >&2; exit 2; }

dest="" staged="" src=""
check=0 downgrade=0 identity=0 unstamped_ok=0 remove_others=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) check=1; shift ;;
    --dest) dest="${2:?--dest needs a folder}"; shift 2 ;;
    --app) staged="${2:?--app needs an .app}"; staged="${staged%/}"; shift 2 ;;
    --allow-downgrade) downgrade=1; shift ;;
    --allow-identity-change) identity=1; shift ;;
    --allow-unstamped-install) unstamped_ok=1; shift ;;
    --remove-other-copies) remove_others=1; shift ;;
    -*) die "unknown option $1" ;;
    *) [[ -z "$src" ]] || die "one source only"; src="${1%/}"; shift ;;
  esac
done
if [[ -n "$staged" ]]; then
  [[ -z "$src" ]] || die "give either --app or a dmg, not both"
else
  [[ -n "$src" ]] || die "usage: update.sh [options] <file.dmg | folder of dmgs>  |  --app <App.app>"
fi

# Physical path of a path that may not exist yet (its folder must).
resolve() {
  if [[ -d "$1" ]]; then (cd "$1" && pwd -P); return; fi
  local d
  d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || { echo "$1"; return; }
  echo "$d/$(basename "$1")"
}

# Sandbox: set up and checked before anything else.
sandbox=""
real_home=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
[[ -n "$real_home" ]] || real_home="/Users/$(id -un)"
real_apps="$real_home/Applications"$'\n'"/Applications"
if [[ -n "${MP_UPDATE_SANDBOX:-}" ]]; then
  [[ -d "$MP_UPDATE_SANDBOX" ]] || refuse "sandbox root $MP_UPDATE_SANDBOX does not exist"
  sandbox=$(cd "$MP_UPDATE_SANDBOX" && pwd -P)
  while IFS= read -r a; do
    case "$sandbox/" in "$a"/*) refuse "sandbox root $sandbox is inside $a" ;; esac
    case "$a/" in "$sandbox"/*) refuse "sandbox root $sandbox contains $a" ;; esac
  done <<<"$real_apps"
  [[ "$sandbox" != / && "$sandbox" != "$real_home" ]] || refuse "sandbox root $sandbox is too broad"
  [[ -f "$sandbox/.mp-update-sandbox" ]] || refuse "sandbox root $sandbox has no .mp-update-sandbox marker"
  LEGACY_APP_NAMES="${MP_UPDATE_LEGACY_NAMES:-$LEGACY_APP_NAMES}"
  LSREGISTER="${MP_UPDATE_LSREGISTER:-$LSREGISTER}"
  std_dirs="$sandbox/home/Applications"$'\n'"$sandbox/Applications"
  [[ -n "$dest" ]] || refuse "test mode needs --dest inside $sandbox"
else
  std_dirs="$real_apps"
  [[ -n "$dest" ]] || dest="$real_home/Applications"
fi

# Every path that is moved, removed or unregistered goes through this first.
guard() {
  [[ -n "$1" && "$1" != / ]] || refuse "empty or root path"
  [[ -n "$sandbox" ]] || return 0
  local r a
  r=$(resolve "$1")
  while IFS= read -r a; do
    case "$r/" in "$a"/*) refuse "$1 is inside $a (test mode)" ;; esac
  done <<<"$real_apps"
  case "$r/" in "$sandbox"/*) ;; *) refuse "$1 is outside the sandbox $sandbox" ;; esac
}

guard "$dest"
dest=$(resolve "$dest")
while IFS= read -r d; do guard "$d"; done <<<"$std_dirs"
if [[ ! -d "$dest" ]]; then
  [[ -z "$sandbox" && "$dest" == "$real_home/Applications" ]] || die "install folder $dest does not exist"
fi

info() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }
# Stamped: an integer CFBundleVersion and a recorded commit. Anything else cannot be compared.
stamped() { [[ "$(info "$1" CFBundleVersion)" =~ ^[0-9]+$ && -n "$(info "$1" MPGitCommit)" ]]; }
label_of() {
  local c; c=$(info "$1" MPGitCommit)
  echo "$(info "$1" CFBundleShortVersionString) ($(info "$1" CFBundleVersion)${c:+, $c})"
}

mnt="" attached=0
cleanup() {
  if [[ $attached == 1 ]]; then
    hdiutil detach -quiet "$mnt" 2>/dev/null || { sleep 2; hdiutil detach -quiet -force "$mnt" 2>/dev/null || true; }
  fi
  [[ -z "$mnt" ]] || rmdir "$mnt" 2>/dev/null || true
}
trap cleanup EXIT

if [[ -n "$staged" ]]; then
  newapp="$staged"
  [[ -d "$newapp" ]] || die "no such app: $newapp"
  from="$(basename "$newapp") (staged)"
else
  # A folder: the dmg with the highest build number, newest file on a tie.
  dmg="$src"
  if [[ -d "$src" ]]; then
    dmg="" best=-1 best_time=0
    for f in "$src"/*.dmg; do
      [[ -f "$f" ]] || continue
      [[ $f =~ -([0-9]+)-[0-9a-f]+(-dirty)?\.dmg$ ]] || continue
      n=${BASH_REMATCH[1]}
      t=$(stat -f %m "$f")
      if (( n > best || (n == best && t > best_time) )); then dmg="$f" best=$n best_time=$t; fi
    done
    [[ -n "$dmg" ]] || die "no <name>-<version>-<build>-<commit>.dmg in $src"
  fi
  [[ -f "$dmg" ]] || die "no such file: $dmg"
  [[ -f "$dmg.sha256" ]] || die "missing $dmg.sha256 (it comes with the dmg)"
  (cd "$(dirname "$dmg")" && shasum -a 256 -c "$(basename "$dmg").sha256" >/dev/null 2>&1) \
    || die "sha256 mismatch for $dmg: the file is damaged or was changed"
  # The image goes under /tmp (the sandbox in test mode), away from /Volumes and Finder.
  mnt=$(mktemp -d "${sandbox:-/tmp}/mp-update-mnt.XXXXXX")
  hdiutil attach -quiet -nobrowse -noautoopen -readonly -mountpoint "$mnt" "$dmg" >/dev/null
  attached=1
  newapp=""
  for a in "$mnt"/*.app; do [[ -d "$a" ]] || continue; [[ -z "$newapp" ]] || die "more than one app in $dmg"; newapp="$a"; done
  [[ -n "$newapp" ]] || die "no app in $dmg"
  from="$(basename "$dmg")"
fi

name=$(basename "$newapp")
base="${name%.app}"
new_id=$(info "$newapp" CFBundleIdentifier)
exe=$(info "$newapp" CFBundleExecutable)
new_build=$(info "$newapp" CFBundleVersion)
new_commit=$(info "$newapp" MPGitCommit)
[[ -n "$new_id" && -n "$exe" ]] || die "$name from $from has no usable Info.plist"
[[ -n "$sandbox" || "$new_id" == "$PROD_ID" ]] || die "$name from $from has bundle id $new_id, not $PROD_ID"
stamped "$newapp" || die "$name from $from is not stamped (needs an integer CFBundleVersion and MPGitCommit); build it with the stamping build script"
codesign --verify --strict --deep "$newapp" 2>/dev/null || die "signature of $name from $from is not valid"
new_label=$(label_of "$newapp")

# Folders to look in: the destination and the standard ones, each once.
dirs="$dest"
while IFS= read -r d; do
  [[ -d "$d" ]] || continue
  p=$(cd "$d" && pwd -P)
  case "$dirs"$'\n' in *"$p"$'\n'*) ;; *) dirs="$dirs"$'\n'"$p" ;; esac
done <<<"$std_dirs"

# Leftovers of an interrupted run may hold the only copy of the previous app: do not start, do not delete.
names="$base $LEGACY_APP_NAMES"
while IFS= read -r d; do
  for n in $names; do
    for suffix in old new; do
      [[ -e "$d/.$n.$suffix" ]] && die "leftover of an interrupted update: $d/.$n.$suffix (the previous app may be in it). Inspect it, move or delete it yourself, then run this again."
    done
  done
done <<<"$dirs"

# Every copy with this bundle id, new name or old, in any standard folder.
installed="$dest/$name"
copies="" seen=""   # one entry per resolved path: APP_NAME may also be listed in LEGACY_APP_NAMES
while IFS= read -r d; do
  for n in $names; do
    p="$d/$n.app"
    [[ -d "$p" ]] || continue
    rp=$(resolve "$p")
    case "$seen" in *"|$rp|"*) continue ;; esac
    seen="$seen|$rp|"
    id=$(info "$p" CFBundleIdentifier)
    if [[ "$id" == "$new_id" ]]; then
      copies="$copies$p"$'\n'
    elif [[ "$n" == "$base" ]]; then
      die "$p has another bundle id (${id:-none}); not touching it"
    else
      note "ignoring $p: another bundle id"
    fi
  done
done <<<"$dirs"
[[ -z "$staged" ]] || while IFS= read -r p; do
  [[ -z "$p" || "$(resolve "$p")" != "$(resolve "$newapp")" ]] || die "the staged app is itself an installed copy: $p"
done <<<"$copies"

note "new: $new_label from $from"
unstamped="" base_build=-1 base_path="" count=0
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  count=$((count + 1))
  if stamped "$p"; then
    b=$(info "$p" CFBundleVersion)
    note "found: $(label_of "$p") at $p"
    if (( b > base_build )) || { (( b == base_build )) && [[ "$p" == "$installed" ]]; }; then base_build=$b base_path="$p"; fi
  else
    note "found: $(label_of "$p") at $p (no build stamp)"
    unstamped="$unstamped$p"$'\n'
  fi
done <<<"$copies"
[[ $count -gt 0 ]] || note "found: no installed copy"
if [[ -n "$unstamped" && $unstamped_ok == 0 ]]; then
  blocked "copies without a build stamp cannot be compared with the new build; pass --allow-unstamped-install to install over them anyway"
fi

# Version: the newest stamped copy anywhere is the baseline.
if [[ -n "$base_path" ]]; then
  old_commit=$(info "$base_path" MPGitCommit)
  if (( new_build < base_build )) && [[ $downgrade == 0 ]]; then
    blocked "the new build $new_build is older than $base_path ($base_build) (--allow-downgrade; history written by a newer build may not load)"
  fi
  if (( new_build == base_build )) && [[ $count == 1 && "$base_path" == "$installed" && "$new_commit" == "$old_commit" && "$new_commit" != *-dirty ]]; then
    note "already current"; exit 0
  fi
fi

# Identity: the new app must satisfy the designated requirement of every copy.
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  req=$(codesign -d -r- "$p" 2>&1 | sed -n 's/^designated => //p')
  if [[ -z "$req" || "$req" == *cdhash* ]]; then
    note "$p is ad-hoc signed or unsigned; signing identity not compared"
    continue
  fi
  rc=0
  verdict=$(codesign --verify -R="$req" "$newapp" 2>&1) || rc=$?
  if [[ $rc == 3 ]]; then
    [[ $identity == 1 ]] || blocked "the new app is signed by another identity than $p (--allow-identity-change; Accessibility will be asked again)"
    note "signing identity differs from $p; Accessibility will be asked again"
  elif [[ $rc != 0 ]]; then
    die "could not compare signing identities with $p: $verdict"
  fi
done <<<"$copies"

# Any running app with this bundle id, at any path, under any name, stops the update before any change.
# Executable names are the fallback when a bundle's plist cannot be read.
exes="$exe"
for l in $LEGACY_APP_NAMES; do exes="$exes $l"; done
find_running() {
  local pid path bundle id
  ps -axo pid=,comm= | while read -r pid path; do
    case "$path" in
      */Contents/MacOS/*) ;;
      *) continue ;;
    esac
    bundle=${path%/Contents/MacOS/*}
    id=$(info "$bundle" CFBundleIdentifier)
    if [[ -n "$id" ]]; then
      if [[ "$id" == "$new_id" ]]; then echo "$pid $path"; fi
    else
      case " $exes " in
        *" ${path##*/} "*) echo "$pid $path" ;;
      esac
    fi
  done
}
running=$(find_running)
if [[ -n "$running" ]]; then
  {
    echo "update: $(echo "$running" | awk '{p=$0; sub(/^[0-9]+ /,"",p); sub(/\/Contents\/MacOS\/.*/,"",p); n=split(p,a,"/"); print a[n]}' | sort -u | tr '\n' ' ')is running; nothing was changed. Quit it first, then run this again."
    echo "$running" | sed 's/^/update:   pid /'
  } >&2
  exit 4
fi

# Copies to retire after the install: old names always, same-name copies elsewhere with the flag.
retire=""
while IFS= read -r p; do
  [[ -n "$p" && "$p" != "$installed" ]] || continue
  if [[ "$(basename "$p")" == "$name" && $remove_others == 0 ]]; then
    echo "update: another copy exists, which would run next to the new one: $p" >&2
    blocked "remove it, or pass --remove-other-copies"
  fi
  retire="$retire$p"$'\n'
done <<<"$copies"
if [[ -n "$retire" ]]; then
  note "to retire after the install (unregistered, then removed):"
  printf '%s' "$retire" | sed 's/^/update:   /'
fi

if [[ $check == 1 ]]; then
  note "check only: would install $new_label into $dest"
  exit 0
fi

# ---- Changes start here, in this order: stage and verify the new copy; swap it in and verify; only then
# ---- retire the other copies. A failure undoes everything; anything it cannot undo is reported.
new="$dest/.$base.new"
placed=0
moved=""      # "original|aside" per line, in the order moved
aside_path() { echo "$(dirname "$1")/.$(basename "$1" .app).old"; }

# Processes of this bundle id whose executable lies inside the folder $1.
running_in() {
  local pid path d
  find_running | while read -r pid path; do
    d=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || continue
    case "$d/" in "$1"/*) echo "$pid $path" ;; esac
  done
}

rollback() {
  echo "update: $1; restoring the previous state" >&2
  local line orig aside failed=0 keep_new=0
  if [[ $placed == 1 ]]; then
    if [[ -n "$(running_in "$installed")" ]]; then
      keep_new=1   # never remove a running bundle
      echo "update: the new app at $installed is running, so it is left in place" >&2
    else
      guard "$installed"; rm -rf "$installed"
    fi
  fi
  [[ -d "$new" ]] && { guard "$new"; rm -rf "$new"; }
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    orig=${line%%|*}; aside=${line#*|}
    if [[ $keep_new == 1 && "$orig" == "$installed" ]]; then
      echo "update: the previous app is at $aside and belongs at $orig; move it back after quitting the app" >&2
      failed=1
    elif mv "$aside" "$orig" 2>/dev/null; then
      [[ "$orig" == "$installed" ]] || "$LSREGISTER" -f "$orig" >/dev/null 2>&1 || true
    else
      echo "update: ROLLBACK FAILED: the previous app is at $aside and belongs at $orig; move it back yourself" >&2
      failed=1
    fi
  done <<<"$(printf '%s' "$moved" | sed '1!G;h;$!d')"
  [[ $failed == 0 ]] && echo "update: previous state restored" >&2
  exit "${2:-1}"
}

# The copy and signature steps take seconds: look again right before every step that swaps or retires
# a bundle, and undo what was done if the app is running now (exit 4).
assert_idle() {
  local r
  r=$(find_running)
  [[ -z "$r" ]] && return 0
  echo "$r" | sed 's/^/update:   pid /' >&2
  rollback "the app started running during the update" 4
}

mkdir -p "$dest"
guard "$new"
ditto --noextattr --noqtn "$newapp" "$new" || { rm -rf "$new"; die "could not copy the new app; nothing was changed"; }
codesign --verify --strict --deep "$new" 2>/dev/null || { rm -rf "$new"; die "the copied app failed verification; nothing was changed"; }

assert_idle
if [[ -d "$installed" ]]; then
  guard "$installed"
  a=$(aside_path "$installed"); guard "$a"
  mv "$installed" "$a" || rollback "could not move $installed aside"
  moved="$moved$installed|$a"$'\n'
fi
assert_idle
mv "$new" "$installed" || rollback "could not move the new app into place"
placed=1
codesign --verify --strict --deep "$installed" 2>/dev/null || rollback "the installed copy failed verification"

# The new app is in place and verified. Now the other copies: unregister, then move aside.
if [[ -n "$retire" ]]; then
  [[ -x "$LSREGISTER" ]] || rollback "lsregister not found"
  retire_real=""
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    assert_idle
    guard "$p"
    real=$(resolve "$p")
    "$LSREGISTER" -u "$real" >/dev/null 2>&1 || rollback "could not unregister $p"
    retire_real="$retire_real$real"$'\n'
    a=$(aside_path "$p"); guard "$a"
    mv "$p" "$a" || rollback "could not move $p aside"
    moved="$moved$p|$a"$'\n'
  done <<<"$retire"
  listed=$("$LSREGISTER" -dump 2>/dev/null | sed -n 's/^path: *//; s/ (0x[0-9a-f]*)$//p') || true
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if grep -qxF "$p" <<<"$listed"; then rollback "$p is still registered with LaunchServices"; fi
  done <<<"$retire_real"
fi

# Done: the copies set aside by this run are deleted last.
leftover=""
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  aside=${line#*|}
  guard "$aside"
  rm -rf "$aside" || leftover="$leftover$aside "
done <<<"$moved"
touch "$installed"
# Claim the document types now; otherwise nothing opens .md/.docx until the first launch. A failure only warns.
# Test mode registers only through the stub, never the real LaunchServices.
if [[ -z "$sandbox" || -n "${MP_UPDATE_LSREGISTER:-}" ]]; then
  "$LSREGISTER" -f "$installed" >/dev/null 2>&1 || note "warning: could not register $installed with LaunchServices; it registers on first launch"
fi
note "installed $new_label in $dest"
if [[ -n "$retire" ]]; then
  while IFS= read -r p; do [[ -n "$p" ]] && note "unregistered and removed $p"; done <<<"$retire"
fi
[[ -z "$leftover" ]] || note "could not delete: $leftover(delete by hand; the next run refuses to start while they exist)"
note "settings and history were not touched; start the app when you are ready"

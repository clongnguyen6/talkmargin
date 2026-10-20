#!/usr/bin/env bash
# LaunchServices records for this app. Every target is checked before anything changes.
#
#   registrations.sh stale <bundle-id> [--check]   remove records of <bundle-id> whose bundle no longer exists
#   registrations.sh unregister <path.app>          unregister one existing bundle (e.g. a staging copy before
#                                                   it is deleted, so no stale record is left behind)
#
# A record of a deleted bundle cannot be removed with `lsregister -u` (it fails with -10814, "failed to
# scan") and `-gc` keeps it. It goes when a placeholder bundle (neutral id, never a document handler) is
# put at the same path, unregistered and deleted again; only folders created for it are removed.
# Records under ~/Applications or /Applications are never touched here (update.sh owns those). In normal
# mode only records under known temporary and build folders are cleared (/private/tmp, /private/var/folders,
# the build script's staging folders in ~/Library/Caches, this repository's build/); anything else (e.g. an
# ejected volume) is reported and left alone. A record that cannot be cleared is reported; the others go on.
#
# Test mode: MP_UPDATE_SANDBOX=<dir containing .mp-update-sandbox> (as update.sh). Every target must lie
# inside it; a missing or unmarked root, a root in or around an Applications folder, or any target outside
# the root is refused with exit 2 before any change. Exit: 0 done, 1 error (or some records not cleared),
# 2 refused.
set -euo pipefail

LSREGISTER="${MP_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
PLACEHOLDER_ID=com.long.meetingprompter.verify-placeholder

die() { echo "registrations: $*" >&2; exit 1; }
refuse() { echo "registrations: refused: $*" >&2; exit 2; }
note() { echo "registrations: $*"; }

cmd="${1:-}"; shift || true
case "$cmd" in
  stale) id="${1:?stale needs a bundle id}"; shift; check=0; [[ "${1:-}" == --check ]] && check=1 ;;
  unregister) target="${1:?unregister needs an .app path}"; target="${target%/}" ;;
  *) die "usage: registrations.sh stale <bundle-id> [--check] | unregister <path.app>" ;;
esac

repo=$(cd "$(dirname "$0")/.." && pwd -P)
. "$repo/scripts/lib/paths.sh"
resolve() { physical_path "$1"; }

real_home=$(real_home)
real_apps=("$(resolve "$real_home/Applications")" "$(resolve /Applications)")
# Normal mode: the only places a stale record is cleared (folder prefixes; the staging one is a name prefix).
known_roots=(/private/tmp/ /private/var/folders/ "$(resolve "$real_home/Library/Caches")/.MeetingPrompter-stage." "$(resolve "$repo/build")/")
known_root() {
  local r k; r=$(resolve "$1")
  for k in "${known_roots[@]}"; do case "$r" in "$k"*) return 0 ;; esac; done
  return 1
}

sandbox=""
if [[ -n "${MP_UPDATE_SANDBOX+set}" ]]; then
  [[ -n "$MP_UPDATE_SANDBOX" && -d "$MP_UPDATE_SANDBOX" ]] || refuse "sandbox root '${MP_UPDATE_SANDBOX}' does not exist"
  sandbox=$(cd "$MP_UPDATE_SANDBOX" && pwd -P)
  for a in "${real_apps[@]}"; do
    case "$sandbox/" in "$a"/*) refuse "sandbox root $sandbox is inside $a" ;; esac
    case "$a/" in "$sandbox"/*) refuse "sandbox root $sandbox contains $a" ;; esac
  done
  [[ "$sandbox" != / && "$sandbox" != "$(resolve "$real_home")" ]] || refuse "sandbox root $sandbox is too broad"
  [[ -f "$sandbox/.mp-update-sandbox" ]] || refuse "sandbox root $sandbox has no .mp-update-sandbox marker"
fi

# 0: may be changed. Refuses (test mode) or reports 1 (real mode) for anything else.
allowed() {
  local r a; r=$(resolve "$1")
  [[ -n "$r" && "$r" != / ]] || refuse "empty or root path"
  for a in "${real_apps[@]}"; do
    case "$r/" in "$a"/*)
      [[ -z "$sandbox" ]] || refuse "$1 is inside $a (test mode)"
      return 1 ;;
    esac
  done
  if [[ -n "$sandbox" ]]; then
    case "$r/" in "$sandbox"/*) ;; *) refuse "$1 is outside the sandbox $sandbox" ;; esac
  fi
  return 0
}

if [[ "$cmd" == unregister ]]; then
  allowed "$target" || die "$target is in an Applications folder; update.sh handles those"
  [[ -d "$target" ]] || die "no such bundle: $target"
  if "$LSREGISTER" -u "$target" 2>/dev/null; then note "unregistered $target"; exit 0; fi
  # -u also fails for a bundle that was never registered; that is fine if no record names it.
  if "$LSREGISTER" -dump 2>/dev/null | sed -n 's/^path: *//; s/ (0x[0-9a-f]*)$//p' | grep -qxF "$(resolve "$target")"; then
    die "could not unregister $target"
  fi
  note "not registered: $target"
  exit 0
fi

# stale: records of $id, from the database.
paths=$("$LSREGISTER" -dump 2>/dev/null | awk -v id="$id" 'BEGIN { RS = "\n-{20,}\n" }
  /^bundle id:/ && $0 ~ ("\nidentifier: +" id "\n") {
    if (match($0, /\npath: +[^\n]*/)) { p = substr($0, RSTART, RLENGTH); sub(/^\npath: +/, "", p); sub(/ \(0x[0-9a-f]+\)$/, "", p); print p }
  }')

# Check every target first; change nothing until all are allowed.
targets=()
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  [[ -e "$p" ]] && continue                     # bundle exists: not stale
  if [[ -n "$sandbox" ]]; then
    case "$(resolve "$p")/" in "$sandbox"/*) ;; *) continue ;; esac   # test mode: only records in the sandbox
  fi
  if ! allowed "$p"; then note "left alone (Applications folder): $p"; continue; fi
  if [[ -z "$sandbox" ]] && ! known_root "$p"; then note "left alone (not a temporary or build folder): $p"; continue; fi
  targets+=("$p")
done <<<"$paths"

if [[ ${#targets[@]} == 0 ]]; then note "no stale records of $id to clear"; exit 0; fi

# clear <path>: placeholder bundle at the path, unregister, delete what was created. 0 when cleared.
clear_record() {
  local p="$1" top rc=0
  # The topmost folder that does not exist yet is created for the placeholder and removed with it.
  top="$p"; while [[ ! -e "$(dirname "$top")" ]]; do top=$(dirname "$top"); done
  allowed "$top" || { note "placeholder folder not allowed: $top"; return 1; }
  mkdir -p "$p/Contents" 2>/dev/null || { note "cannot create a placeholder at $p"; rm -rf "$top" 2>/dev/null; return 1; }
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $PLACEHOLDER_ID" \
    -c "Add :CFBundlePackageType string APPL" "$p/Contents/Info.plist" >/dev/null 2>&1 || rc=1
  [[ $rc != 0 ]] || "$LSREGISTER" -u "$p" >/dev/null 2>&1 || rc=$?
  rm -rf "$top"
  return $rc
}

failed=0
for p in "${targets[@]}"; do
  if [[ $check == 1 ]]; then note "would remove stale record: $p"; continue; fi
  if clear_record "$p"; then note "removed stale record: $p"; else note "could not remove the record of $p"; failed=1; fi
done
exit $failed

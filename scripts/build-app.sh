#!/usr/bin/env bash
# Build the app bundle, stamped and signed.
#
#   build-app.sh                       Dev build: build/TalkMargin Dev.app (com.long.meetingprompter.dev, no document
#                                      types, own settings and data folder). Refused while that bundle runs.
#   build-app.sh --out DIR             Production bundle at DIR/TalkMargin.app, nothing installed (for make-dmg.sh).
#                                      Refused for ~/Applications and /Applications: installs go through update.sh.
#                                      It is a registrable copy: unregister and delete it after packing
#                                      (scripts/registrations.sh unregister DIR/TalkMargin.app; rm -r ...).
#   build-app.sh --out DIR --verify-id com.long.meetingprompter.verify-NAME
#                                      Verification bundle (that id, no document types) at DIR/TalkMargin.app.
#   build-app.sh --install [update.sh options]
#                                      Stage the production bundle and install it with scripts/update.sh --app, the one
#                                      install routine (refuses while any copy runs, under any name; retires other copies
#                                      only after the new one is verified). Then remove stale LaunchServices records of the
#                                      production id (scripts/registrations.sh). The staging copy is unregistered and
#                                      deleted on every exit.
#                                      Test mode: MP_UPDATE_SANDBOX=<root> as for update.sh, with --dest inside it and
#                                      --verify-id (a production-id bundle is never staged in a sandbox).
#
# Stamp (checked by make-dmg.sh and update.sh): CFBundleShortVersionString from VERSION, CFBundleVersion from BUILD_NUMBER
# (a whole number that does not depend on git history; release.sh requires it to rise with every release),
# MPGitCommit = short commit of HEAD, with -dirty when tracked files have uncommitted changes.
# MP_SIGN_IDENTITY: codesign identity (default: the first Apple Development identity; ad-hoc, with a warning, when
# there is none: Accessibility and other grants then reset with every build).
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
. scripts/lib/paths.sh

# Bundle and executable name; must match APP_NAME in scripts/dist.conf. Ids, settings, data folder and lock keep
# their meetingprompter names (compatibility). Earlier names, removed or retired when found: LEGACY_NAMES.
APP_NAME=TalkMargin
EXE_NAME=TalkMargin
LEGACY_NAMES=(MeetingPrompter)
# Copied into Contents/Resources before signing (design/ stays out of the bundle).
RESOURCES=(AppIcon.icns MenuBarIconTemplate.pdf MenuBarIconTemplate.png MenuBarIconTemplate@2x.png)
PROD_ID=com.long.meetingprompter
DEV_ID=com.long.meetingprompter.dev
VERIFY_PREFIX=com.long.meetingprompter.verify-
PLISTBUDDY=/usr/libexec/PlistBuddy

die() { echo "build-app: $*" >&2; exit 1; }
refuse() { echo "build-app: refused: $*" >&2; exit 2; }

mode=dev out="" verify_id=""
update_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) [[ $mode == dev ]] || die "--out and --install exclude each other"; mode=out; out="${2:?--out needs a folder}"; shift 2 ;;
    --install) [[ $mode == dev ]] || die "--out and --install exclude each other"; mode=install; shift ;;
    --verify-id) verify_id="${2:?--verify-id needs an id}"; shift 2 ;;
    *) [[ $mode == install ]] || die "unknown option $1"; update_args+=("$1"); shift ;;
  esac
done
if [[ -n "$verify_id" ]]; then
  [[ "$verify_id" == "$VERIFY_PREFIX"* && "$verify_id" =~ ^[A-Za-z0-9.-]+$ ]] || die "--verify-id must be $VERIFY_PREFIX<name>"
  [[ $mode != dev ]] || die "--verify-id needs --out or --install"
fi
# Fail closed before building anything.
if [[ $mode == out ]] && in_app_folder "$out"; then
  refuse "--out $out is an Applications folder; install with --install (scripts/update.sh) instead"
fi
if [[ $mode == install ]]; then
  if [[ -n "${MP_UPDATE_SANDBOX+set}" ]]; then
    [[ -n "$verify_id" ]] || refuse "test mode (MP_UPDATE_SANDBOX) installs only a --verify-id bundle"
    [[ -n "$MP_UPDATE_SANDBOX" && -f "$MP_UPDATE_SANDBOX/.mp-update-sandbox" ]] || refuse "sandbox root '${MP_UPDATE_SANDBOX}' missing or unmarked"
  else
    [[ -z "$verify_id" ]] || refuse "--verify-id bundles are installed only in test mode (MP_UPDATE_SANDBOX)"
  fi
fi

swift build -c release --product MeetingPrompter
binary="$(swift build -c release --show-bin-path)/MeetingPrompter"

identity="${MP_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
fi
if [[ -z "$identity" ]]; then
  echo "build-app: warning: no signing identity (set MP_SIGN_IDENTITY); signing ad-hoc, so Accessibility and other grants reset with every build" >&2
  identity=-
fi

version=$(tr -d '[:space:]' < VERSION 2>/dev/null || true)
build_number=$(tr -d '\r\n' < BUILD_NUMBER 2>/dev/null || true)
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || die "BUILD_NUMBER must hold one whole number, the build number (found '${build_number}')"
commit=$(git rev-parse --short HEAD)
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || commit="$commit-dirty"

# make_bundle <path.app> <production|dev|verify>: layout, stamped Info.plist, resources, and the signature last.
make_bundle() {
  local app="$1" variant="$2" plist="$1/Contents/Info.plist"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$binary" "$app/Contents/MacOS/$EXE_NAME"
  cp Resources/Info.plist "$plist"
  case "$variant" in
    dev) "$PLISTBUDDY" -c "Set :CFBundleIdentifier $DEV_ID" -c "Set :CFBundleName $APP_NAME Dev" \
           -c "Set :CFBundleDisplayName $APP_NAME Dev" -c "Delete :CFBundleDocumentTypes" "$plist" ;;
    verify) "$PLISTBUDDY" -c "Set :CFBundleIdentifier $verify_id" -c "Delete :CFBundleDocumentTypes" "$plist" ;;
  esac
  [[ -z "$version" ]] || "$PLISTBUDDY" -c "Set :CFBundleShortVersionString $version" "$plist"
  "$PLISTBUDDY" -c "Set :CFBundleVersion $build_number" -c "Add :MPGitCommit string $commit" "$plist"
  local r
  for r in "${RESOURCES[@]}"; do cp "Resources/$r" "$app/Contents/Resources/$r"; done
  codesign --force --sign "$identity" "$app"
}


# Staging folders are unregistered and deleted on every exit, so no stale record is left behind.
stages=()
cleanup() {
  local s a
  for s in ${stages[@]+"${stages[@]}"}; do
    for a in "$s"/*.app; do
      [[ -d "$a" ]] || continue
      scripts/registrations.sh unregister "$a" >/dev/null 2>&1 || echo "build-app: could not unregister $a" >&2
    done
    rm -rf "$s"
  done
}
trap cleanup EXIT

new_stage() {
  local s
  s=$(mktemp -d "$1/.MeetingPrompter-stage.XXXXXX")
  stages+=("$s")
  STAGE="$s"
}

# place <variant> <dest.app>: build in a staging folder on the same volume and put it at dest with one rename
# (swapping with the previous bundle, which the cleanup deletes). Refused while dest runs: never replace a running app.
place() {
  local variant="$1" dest="$2" parent stage_root running
  parent="$(dirname "$dest")"
  mkdir -p "$parent"
  running=$(running_from "$dest" "$EXE_NAME" | tr '\n' ' ')
  if [[ -n "$running" ]]; then echo "build-app: $dest is running (pid ${running% }); nothing was changed. Quit it first." >&2; exit 4; fi
  stage_root="$HOME/Library/Caches"
  [[ "$(stat -f %d "$stage_root")" == "$(stat -f %d "$parent")" ]] || stage_root="$parent"
  new_stage "$stage_root"
  make_bundle "$STAGE/$(basename "$dest")" "$variant"
  running=$(running_from "$dest" "$EXE_NAME" | tr '\n' ' ')
  if [[ -n "$running" ]]; then echo "build-app: $dest started meanwhile (pid ${running% }); nothing was changed." >&2; exit 4; fi
  swift scripts/swap-into-place.swift "$STAGE/$(basename "$dest")" "$dest" >/dev/null
  echo "Placed $dest (${version:-?}, build $build_number, $commit)"
}

case "$mode" in
  dev)
    # Bundles of earlier builds here: a production-id copy (Open With could launch it) and dev bundles under
    # earlier names. Removed unless running.
    for name in "${LEGACY_NAMES[@]}"; do
      for legacy in "$root/build/$name.app" "$root/build/$name Dev.app"; do
        [[ -d "$legacy" ]] || continue
        if [[ -n "$(running_from "$legacy" "$name")" ]]; then
          echo "build-app: $legacy is running; quit it, then run this again to remove it." >&2
        else
          scripts/registrations.sh unregister "$legacy" || true
          rm -rf "$legacy"
          echo "Removed $legacy (earlier name)"
        fi
      done
    done
    place dev "$root/build/$APP_NAME Dev.app"
    ;;
  out)
    mkdir -p "$out"
    variant=production
    [[ -z "$verify_id" ]] || variant=verify
    place "$variant" "$(cd "$out" && pwd -P)/$APP_NAME.app"
    ;;
  install)
    stage_root="$HOME/Library/Caches"
    [[ -z "${MP_UPDATE_SANDBOX+set}" ]] || stage_root=$(cd "$MP_UPDATE_SANDBOX" && pwd -P)
    new_stage "$stage_root"
    variant=production
    [[ -z "$verify_id" ]] || variant=verify
    make_bundle "$STAGE/$APP_NAME.app" "$variant"
    rc=0
    scripts/update.sh ${update_args[@]+"${update_args[@]}"} --app "$STAGE/$APP_NAME.app" || rc=$?
    [[ $rc == 0 ]] || exit $rc
    # Records of deleted copies (old builds, test runs) cannot be removed by update.sh's unregister.
    # The install has succeeded at this point; a cleanup problem is reported, not an install failure.
    scripts/registrations.sh stale "${verify_id:-$PROD_ID}" \
      || echo "build-app: warning: some stale LaunchServices records were not cleared (see above); the install itself succeeded" >&2
    ;;
esac

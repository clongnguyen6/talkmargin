# Path checks shared by build-app.sh and registrations.sh; source me.

# Physical path of a path whose folders may not exist: the deepest existing ancestor resolved,
# the rest appended (/tmp/x -> /private/tmp/x).
physical_path() {
  local p="$1" rest=""
  [[ "$p" == /* ]] || p="$PWD/$p"
  # The deepest existing folder: a missing part, or an existing file (e.g. a running executable), is kept as a name.
  while [[ ! -d "$p" && "$p" != / ]]; do rest="/$(basename "$p")$rest"; p=$(dirname "$p"); done
  echo "$(cd "$p" && pwd -P)$rest"
}

# The account's real home (not $HOME, not CFFIXED_USER_HOME), as update.sh determines it.
real_home() {
  local h
  h=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  echo "${h:-/Users/$(id -un)}"
}

# 0 when <path> is ~/Applications or /Applications (or inside either), physically compared.
# <home> defaults to the real home; tests pass another.
in_app_folder() {
  local r a home="${2:-$(real_home)}"
  r=$(physical_path "$1")
  for a in "$(physical_path "$home/Applications")" "$(physical_path /Applications)"; do
    case "$r/" in "$a"/*) return 0 ;; esac
  done
  return 1
}

# Pids of processes running <app>/Contents/MacOS/<exe> (default TalkMargin). Compared physically: ps shows
# the path as launched (/tmp/...), which may differ from the resolved one (/private/tmp/...).
running_from() {
  local exe_name="${2:-TalkMargin}" exe
  exe=$(physical_path "$1/Contents/MacOS/$exe_name")
  ps -axo pid=,comm= | while read -r pid comm; do
    [[ "$comm" == */Contents/MacOS/"$exe_name" ]] || continue
    [[ "$(physical_path "$comm")" == "$exe" ]] && echo "$pid"
  done || true
}

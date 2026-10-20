#!/usr/bin/env bash
# Rebuild the final TalkMargin icon assets from design/icon-concepts/soft-reply/generated-source.png.
# Usage: design/final/src/build.sh   (MAKE_ICNS overrides scripts/make-icns.sh)
# SF_COMPARE=1 also writes a local, git-ignored sheet with SF Symbols to design/final/build/.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
make_icns="${MAKE_ICNS:-$root/scripts/make-icns.sh}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swift "$here/tile-mask.swift" "$work/tile-mask.png"
python3 -I "$here/app-icon.py" "$root/design/icon-concepts/soft-reply/generated-source.png" "$work/tile-mask.png" "$root/Resources/AppIcon-1024.png"
"$make_icns" "$root/Resources/AppIcon-1024.png" "$root/Resources/AppIcon.icns"

swift "$here/menu-glyph.swift" "$work"
mv "$work/MenuBarIconTemplate.svg" "$root/design/final/"
mv "$work"/MenuBarIconTemplate.pdf "$work"/MenuBarIconTemplate.png "$work"/MenuBarIconTemplate@2x.png "$root/Resources/"

swift "$here/contact-sheet.swift" "$root" "$root/design/final/contact-sheet.png"
# Optional local comparison with SF Symbols (Apple artwork): written under build/, which git ignores. Never publish it.
if [[ "${SF_COMPARE:-0}" == 1 ]]; then
  mkdir -p "$root/design/final/build"
  swift "$here/contact-sheet.swift" "$root" "$root/design/final/build/contact-sheet-sf-compare.png" --sf-compare
fi

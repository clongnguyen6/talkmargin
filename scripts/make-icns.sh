#!/usr/bin/env bash
# Make an .icns from a 1024x1024 PNG master. Default output: Resources/AppIcon.icns.
# Usage: scripts/make-icns.sh master.png [out.icns]
set -euo pipefail
cd "$(dirname "$0")/.."

master="${1:?usage: make-icns.sh master.png [out.icns]}"
out="${2:-Resources/AppIcon.icns}"

[[ -f "$master" ]] || { echo "make-icns: no such file: $master" >&2; exit 1; }
width=$(sips -g pixelWidth "$master" | awk '/pixelWidth/ {print $2}')
height=$(sips -g pixelHeight "$master" | awk '/pixelHeight/ {print $2}')
[[ "$width" == 1024 && "$height" == 1024 ]] || { echo "make-icns: master must be 1024x1024, got ${width}x${height}" >&2; exit 1; }
sips -g hasAlpha "$master" | grep -q 'hasAlpha: yes' || echo "make-icns: warning: master has no alpha channel (square corners)" >&2

work=$(mktemp -d /tmp/mp-icns.XXXXXX)
trap 'rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir "$iconset"
# name:pixels
for spec in 16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 128x128:128 128x128@2x:256 \
            256x256:256 256x256@2x:512 512x512:512 512x512@2x:1024; do
  sips -z "${spec#*:}" "${spec#*:}" "$master" --out "$iconset/icon_${spec%%:*}.png" >/dev/null
done
mkdir -p "$(dirname "$out")"
iconutil -c icns -o "$out" "$iconset"
echo "Wrote $out"

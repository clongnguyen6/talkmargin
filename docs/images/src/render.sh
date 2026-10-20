#!/usr/bin/env bash
# Renders the docs/images/*.png screenshots offscreen: the app's own sources (copied into a scratch package),
# synthetic notes (examples/demo-meeting.md) and a synthetic chat. The overlay is never put on screen; files
# live in a scratch home (CFFIXED_USER_HOME). No app bundle, lock, event tap or permission is involved.
# Usage: docs/images/src/render.sh
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd -P)
work=$(mktemp -d /tmp/talkmargin-shots.XXXXXX)
# UserDefaults ignores CFFIXED_USER_HOME: the harness's own domain (its executable name) is deleted on every exit.
domain=TalkMarginDocShots
trap 'defaults delete "$domain" >/dev/null 2>&1 || true; rm -f "$HOME/Library/Preferences/$domain.plist"; rm -rf "$work"' EXIT
pkg="$work/pkg"
mkdir -p "$pkg/Sources/$domain" "$work/home"
cp -R "$repo/Sources/PrompterCore" "$pkg/Sources/"
cp "$repo"/Sources/MeetingPrompter/*.swift "$pkg/Sources/$domain/"
# The app's main.swift (instance lock, AppDelegate, tap) is replaced by the harness.
cp "$repo/docs/images/src/Shots.swift" "$pkg/Sources/$domain/main.swift"
# The only change to the app code, in the copy: the overlay is never ordered on screen.
file="$pkg/Sources/$domain/OverlayController.swift"
sed -i '' 's|panel\.orderFrontRegardless()|_ = panel // harness: never on screen|' "$file"
grep -q 'harness: never on screen' "$file" || { echo "render: patch did not apply" >&2; exit 1; }
cat > "$pkg/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "$domain",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "PrompterCore"),
        .executableTarget(name: "$domain", dependencies: ["PrompterCore"]),
    ]
)
EOF
swift build -c release --package-path "$pkg"
mkdir -p "$repo/docs/images"
CFFIXED_USER_HOME="$work/home" "$pkg/.build/release/$domain" "$repo/examples/demo-meeting.md" "$repo/docs/images"

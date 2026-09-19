#!/bin/sh
# Generate the Xcode project, build for iOS devices and optionally install/launch on the paired iPhone.
#   ./build.sh [install] [launch]      DEVICE=<CoreDevice UUID> to pick the phone
# Signing identifiers come from blinko.env (see blinko.env.example).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"   # xcodegen is usually installed by Homebrew
command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen" >&2; exit 2; }
[ -f "$HERE/blinko.env" ] && . "$HERE/blinko.env"
: "${BLINKO_BUNDLE_ID:=com.example.blinko}"
[ -n "$BLINKO_TEAM_ID" ] || { echo "set BLINKO_TEAM_ID (cp blinko.env.example blinko.env and edit)" >&2; exit 2; }
export BLINKO_TEAM_ID BLINKO_BUNDLE_ID
DEVICE=${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/available \(paired\)/ && /iPhone/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-/) print $i; exit}')}
cd "$HERE" && xcodegen generate --quiet
DERIVED="$HERE/build"
set +e
xcodebuild -project "$HERE/Blinko.xcodeproj" -scheme Blinko -configuration Debug \
    -destination "generic/platform=iOS" -derivedDataPath "$DERIVED" -allowProvisioningUpdates build 2>&1 \
    | grep -E "error:|warning: .*Sources|BUILD|Signing"
status=${pipestatus[1]:-${PIPESTATUS[1]}}
set -e
[ "$status" = 0 ] || { echo "xcodebuild failed" >&2; exit 1; }
APP=$(find "$DERIVED/Build/Products/Debug-iphoneos" -maxdepth 1 -name "*.app" | head -1)
[ -n "$APP" ] || { echo "build failed" >&2; exit 1; }
echo "built: $APP"
for a in "$@"; do
    case "$a" in
        install) [ -n "$DEVICE" ] || { echo "no paired iPhone found (set DEVICE=<CoreDevice UUID>)" >&2; exit 2; }
                 xcrun devicectl device install app --device "$DEVICE" "$APP" ;;
        launch)  xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$BLINKO_BUNDLE_ID" ;;
    esac
done

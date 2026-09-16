#!/bin/sh
# Generate the Xcode project, build for iOS devices and optionally install/launch on the paired iPhone.
#   ./build.sh [install] [launch]      DEVICE=<CoreDevice UUID> to pick the phone
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
DEVICE=${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/available \(paired\)/ && /iPhone/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-/) print $i; exit}')}
cd "$HERE" && xcodegen generate --quiet
DERIVED="$HERE/build"
xcodebuild -project "$HERE/RSLogViewer.xcodeproj" -scheme RSLogViewer -configuration Debug \
    -destination "generic/platform=iOS" -derivedDataPath "$DERIVED" -allowProvisioningUpdates build 2>&1 | grep -E "error:|warning: .*Sources|BUILD|Signing" || true
APP=$(find "$DERIVED/Build/Products/Debug-iphoneos" -maxdepth 1 -name "*.app" | head -1)
[ -n "$APP" ] || { echo "build failed" >&2; exit 1; }
echo "built: $APP"
for a in "$@"; do
    case "$a" in
        install) [ -n "$DEVICE" ] || { echo "no paired iPhone found (set DEVICE=<CoreDevice UUID>)" >&2; exit 2; }
                 xcrun devicectl device install app --device "$DEVICE" "$APP" ;;
        launch)  xcrun devicectl device process launch --terminate-existing --device "$DEVICE" com.federicopaglioni.rslogviewer ;;
    esac
done

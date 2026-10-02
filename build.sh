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
mkdir -p "$DERIVED"
# xcodebuild's own exit status goes through a file: the pipeline's status is grep's, and the
# ${pipestatus[1]:-${PIPESTATUS[1]}} this used is xcodebuild's only under zsh; under sh it is
# grep's too, so a failed build went on to install the app left by the previous one.
STATUS="$DERIVED/.xcodebuild-status"
rm -f "$STATUS"
set +e
{ xcodebuild -project "$HERE/Blinko.xcodeproj" -scheme Blinko -configuration Debug \
    -destination "generic/platform=iOS" -derivedDataPath "$DERIVED" -allowProvisioningUpdates build 2>&1
  echo $? > "$STATUS"; } \
    | grep -E "error:|warning: .*Sources|BUILD|Signing"
set -e
status=$(cat "$STATUS" 2>/dev/null || echo 1)
[ "$status" = 0 ] || { echo "xcodebuild failed (exit $status)" >&2; exit 1; }
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

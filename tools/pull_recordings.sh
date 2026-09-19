#!/bin/sh
# Copy all recordings from the iOS app container to <ios repo>/build/recordings (or $1).
HERE=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$HERE/blinko.env" ] && . "$HERE/blinko.env"
: "${BLINKO_BUNDLE_ID:=com.example.blinko}"
D=${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/available \(paired\)/ && /iPhone/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-/) print $i; exit}')}
OUT=${1:-$HERE/build/recordings}
mkdir -p "$OUT"
xcrun devicectl device copy from --device "$D" --source Documents/recordings --destination "$OUT" --domain-type appDataContainer --domain-identifier "$BLINKO_BUNDLE_ID" 2>&1 | grep -iE "error" 
ls -la "$OUT"/*.rsrec "$OUT"/recordings/*.rsrec 2>/dev/null

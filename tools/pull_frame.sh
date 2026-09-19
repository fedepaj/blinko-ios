#!/bin/sh
# Pull the latest dumped frame (and diag file) from the iPhone app container.
HERE=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$HERE/build"
[ -f "$HERE/blinko.env" ] && . "$HERE/blinko.env"
: "${BLINKO_BUNDLE_ID:=com.example.blinko}"
D=${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/available \(paired\)/ && /iPhone/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-/) print $i; exit}')}
OUT=${1:-$HERE/build/frame.ppm}
xcrun devicectl device copy from --device "$D" --source Documents/frame.ppm --destination "$OUT" --domain-type appDataContainer --domain-identifier "$BLINKO_BUNDLE_ID" >/dev/null 2>&1
xcrun devicectl device copy from --device "$D" --source Documents/blinko_diag.txt --destination "$HERE/build/blinko_diag.txt" --domain-type appDataContainer --domain-identifier "$BLINKO_BUNDLE_ID" >/dev/null 2>&1
ls -la "$OUT"

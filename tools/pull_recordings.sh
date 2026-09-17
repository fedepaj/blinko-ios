#!/bin/sh
# Copy all recordings from the iOS app container to <ios repo>/build/recordings (or $1).
HERE=$(cd "$(dirname "$0")/.." && pwd)
D=${DEVICE:-43301909-46B3-50D8-9320-E9D61DBF0201}
OUT=${1:-$HERE/build/recordings}
mkdir -p "$OUT"
xcrun devicectl device copy from --device "$D" --source Documents/recordings --destination "$OUT" --domain-type appDataContainer --domain-identifier com.federicopaglioni.rslogviewer 2>&1 | grep -iE "error" 
ls -la "$OUT"/*.rsrec "$OUT"/recordings/*.rsrec 2>/dev/null

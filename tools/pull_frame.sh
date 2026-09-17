#!/bin/sh
# Pull the latest dumped frame (and diag file) from the iPhone app container.
HERE=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$HERE/build"
D=${DEVICE:-43301909-46B3-50D8-9320-E9D61DBF0201}
OUT=${1:-$HERE/build/frame.ppm}
xcrun devicectl device copy from --device "$D" --source Documents/frame.ppm --destination "$OUT" --domain-type appDataContainer --domain-identifier com.federicopaglioni.rslogviewer >/dev/null 2>&1
xcrun devicectl device copy from --device "$D" --source Documents/blinko_diag.txt --destination "$HERE/build/blinko_diag.txt" --domain-type appDataContainer --domain-identifier com.federicopaglioni.rslogviewer >/dev/null 2>&1
ls -la "$OUT"

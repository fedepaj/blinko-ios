# blinko-ios

Blinko Viewer for iPhone (SwiftUI + AVFoundation): manual exposure, focus at
infinity, 1080p at up to 240 fps, BGRA capture, shared C receiver from the git
submodule `core/`. Project generated with xcodegen (`project.yml`).

## Requirements

- macOS with Xcode 15 or newer (iOS 17 deployment target) and `xcodegen`
  (`brew install xcodegen`).
- An iPhone paired to the Mac; the app needs a real camera, the simulator is
  of no use.
- Signing identifiers in `blinko.env`: `cp blinko.env.example blinko.env` and
  fill in `BLINKO_TEAM_ID` and `BLINKO_BUNDLE_ID` (a free Apple ID works, with
  a limit of three sideloaded apps).

## Build and run

```sh
git submodule update --init
./build.sh                   # generate the project and build
./build.sh install launch    # DEVICE=<CoreDevice UUID> to pick the phone
tools/pull_frame.sh          # fetch the diagnostic log and last dumped frame
tools/pull_recordings.sh     # copy the .rsrec recordings off the phone
```

`make build` and `make install` are shortcuts. In the app: **Live** is the
camera preview with a marker ring per tracked light, the profile chart and the
stats bar; **Console** lists the decoded messages by source and slot; **Lab**
holds the strobe calibration and the replay list; **Settings** has the camera
controls (fps, exposure, ISO, lens, zoom), the decoder options and a Debug
section. Hold the phone 1–3 cm from the board.

## Remote session

Settings › Debug › *Remote session* opens a TCP server on port 7777 that lets
a computer drive the app: read and change settings, sample stats and messages,
grab a frame, record, and pull or replay recordings. Drive it with
`tools/rslive.py`, over USB (recommended) or over the Wi-Fi address shown in
Settings:

```sh
pymobiledevice3 usbmux forward 7777 7777 &
tools/rslive.py get                       # settings + camera
tools/rslive.py watch                     # live stats and messages
tools/rslive.py set fps 120               # or exposure 0 (0..1, 0 = shortest)
tools/rslive.py frame out.png
tools/rslive.py record --seconds 2 --note "R4 rgb" --out ../testdata
tools/rslive.py files | replay NAME | delete --all
```

It is also usable as a library: `with RSLive() as s: s.record(2, "note", dir)`.

## Replay

Turn on Settings › Debug › *Recording mode* to get a Record button on the Live
screen; recordings are written as `.rsrec` (BGRA frames plus motion data) into
the app's Documents folder. Lab › *Replay a recording* runs one back through
the multi-source receiver on the phone — the messages show up in the Console
tagged `replay` — which is the quickest way to check a decoder change against
a real capture. The same recordings replay on a computer with
`core/tools/replay.py`, and `rslive.py replay NAME` starts a replay remotely.

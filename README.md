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
stats bar (`fps`, `pkt/s`, `rows/chip`, `contrast`, `mode`, `peak`, `pilots`,
`msgs`); **Console** lists the decoded messages by source and slot; **Lab**
holds the strobe calibration and the replay list; **Settings** has the camera
controls (fps, exposure, ISO, lens, zoom), the decoder options and a Debug
section. Hold the phone 1–3 cm from the board. A light's three channels are
decoded concurrently (GCD).

## Throughput and limits

Measured on an iPhone 14 at 120 fps (exposure 15 µs) with a Nano R4 a few
centimetres from the camera, sending three streams with one copy of each
packet. One packet carries one message byte, and rates are of distinct
packets:

| board setting | distinct packets/s |
|---|---|
| T = 60 µs (the default) | about 470 |
| T = 45 µs | about 240 |

Limits: the LED blob must be taller than a packet in the frame (about 320 rows
at T = 60 µs on this sensor, 5.1 µs per row), so a few centimetres with the
main camera; the exposure is 15 µs at 120 fps, so any T the board offers
works; a LED that saturates the sensor (`peak` at 255 in the stats bar; the
remote stats also give `sat`, the fraction of rows that clip) loses packets,
lower its brightness on the board (`bright 40`) or move back. The receiver
runs at the camera's frame rate; when the phone throttles (`thermal` is
`serious` or `critical` in the remote stats) the frame rate drops to 85–110
fps and the yield with it.

The row time the receiver uses is 5.1 µs until the Lab's strobe calibration
measures this phone's; the measured value is kept across launches (see
`docs/CALIBRATION.md` in the
[umbrella repository](https://github.com/fedepaj/blinko)).

## Remote session

The app runs a TCP server on port 7777 (Settings › Debug › *Remote session*,
on by default) that lets a computer drive it: read and change settings, sample
stats and messages, grab a frame, record, list, replay and delete recordings.
The server has no authentication, so it only accepts connections from the
phone itself, which is what a USB forward is; *Allow Wi-Fi (LAN) connections*
(off by default) opens it to the network, at the address shown in Settings.
Both switches are remembered. Drive it with `tools/rslive.py`:

```sh
pymobiledevice3 usbmux forward 7777 7777 &
tools/rslive.py get                       # settings + camera
tools/rslive.py watch                     # live stats and messages
tools/rslive.py set fps 120               # or exposure 0 (0..1, 0 = shortest)
tools/rslive.py frame out.png
tools/rslive.py record --seconds 2 --note "R4 rgb" --out ../testdata   # 0.1 to 10 s
tools/rslive.py files | replay NAME | delete --all
```

`record` sends the recording to the computer and removes it from the phone
unless `--keep` is given. The client's `pull NAME` command is for the Android
app; a recording kept on the iPhone is fetched with `tools/pull_recordings.sh`.
`rslive.py` is also usable as a library:
`with RSLive() as s: s.record(2, "note", dir)`. Every command, field and reply:
[`docs/REMOTE.md`](https://github.com/fedepaj/blinko/blob/main/docs/REMOTE.md)
in the umbrella repository.

## Recordings and replay

Settings › Debug › *Recording mode* puts a *Record 2 s* button on the Live
screen. Recordings are `.rsrec` files in `Documents/recordings` of the app's
container: a JSON header followed by the BGRA frames with every fourth column
kept, each with its timestamp and the motion sensors' readings
([`docs/RECORDINGS.md`](https://github.com/fedepaj/blinko/blob/main/docs/RECORDINGS.md)
in the umbrella repository). A recording is about 250 MB per second at
120 fps, and **the app does not decode while it records**.

Lab › *Replay a recording* runs one back through the multi-source receiver on
the phone: the messages show up in the Console tagged `replay`. Live decoding
pauses while a replay runs, and a recording cannot be started meanwhile. The
same recordings replay on a computer with `core/tools/replay.py`, and
`rslive.py replay NAME` starts a replay remotely.

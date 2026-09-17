# blinko-ios

Blinko Viewer for iPhone (SwiftUI + AVFoundation): manual exposure, focus at
infinity, 1080p at up to 240 fps, BGRA capture, shared C receiver from the git
submodule `core/`. Project generated with xcodegen (`project.yml`).

```sh
git submodule update --init
./build.sh install launch    # DEVICE=<CoreDevice UUID> to pick the phone
tools/pull_frame.sh          # fetch the diagnostic log and last dumped frame
```

# Local validation — November 5, 2026

Validated on the current Apple Silicon Mac with Xcode 27.1, Swift 6.4, macOS SDK 27 and a macOS 14 deployment target. The local FFmpeg bundle is based on installed FFmpeg 8.0.1.

## Passed

- `FFMPEG_TEST_DIRECTORY="$PWD/Resources/Tools" swift test`: **20 tests, zero failures, zero skips**. Conversion tests explicitly selected the bundled tools directory.
- `xcodebuild -project VideoConverter.xcodeproj -scheme VideoConverter -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO test`: **20 tests, zero failures**, including the application build.
- CPU calibration against macOS `getrusage`: passed with the platform Mach timebase conversion enabled.
- Bundler copied and relocated 93 Mach-O executable/library files, signed the copies ad hoc and verified both tool versions.
- Running app's Engine view resolved FFmpeg and ffprobe inside its own `Contents/Resources/Tools` directory.
- Imported a folder containing two synthetic 45-second audio/video files through the native file picker. Both were auto-detected and converted concurrently to H.264/AAC MP4.
- Navigated Convert, Logs, Metrics and Engine while work ran. Progress, FPS, speed, output bytes and ETA updated without blocking navigation.
- Reviewed diagnostic log lines; FFmpeg's realtime-input lag warnings remained visible on successful jobs.
- Duplicated the two completed jobs through the bulk-action menu and converted again. Four jobs completed, with numbered destination files and preserved source files.
- Quit/relaunch restored completed queue history with scheduling stopped.
- Saved public interface screenshots: [queue](Images/queue.png) and [metrics](Images/metrics.png). A separate log screenshot remains local and is excluded from Git because its command lines contain machine-specific paths; the public visual guide uses a fictional log mockup.

The only Xcode build notices were App Intents metadata extraction being skipped because the app does not use App Intents. No Swift compilation warnings were reported.

## Not claimed

Signed/notarized or App Store distribution, Intel or universal-binary operation, clean-machine relocation, exhaustive hardware encoder/codec/container coverage, damaged-file corpus recovery, full frame-by-frame output verification, every FFmpeg workflow, GPU/network/power counters, VoiceOver auditing, or an exhaustive dark-mode/minimum-window-size UI pass. See `TESTING.md` and `DISTRIBUTION.md` for the remaining release checks.

Synthetic sample files and outputs remain under the ignored `build/SampleMedia` folder. The running app has completed sample history and scheduling is stopped.

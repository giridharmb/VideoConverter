# Verification guide

## Automated checks

`swift test` builds `ConverterCore` under Swift 6 and runs behavioral unit/integration tests. The Xcode scheme runs the same tests against the framework used by the app.

Coverage includes:

- literal command argument construction with spaces/quotes in filenames;
- input and timing validation, missing streams, copy/filter conflicts;
- reserved advanced flags and malformed JSON;
- audio-only mapping and trim duration;
- collision-safe output allocation, including simultaneous equal basenames;
- progress parsing, unknown duration and nonfinite values;
- sparse ffprobe JSON and no-media rejection;
- real video-to-video conversion and MP3 audio extraction;
- independent failure of invalid input and import deduplication;
- concurrency slots, stop scheduling, process pause/resume, cancellation and retry;
- preservation of existing files;
- queue round trip, unsupported version rejection, interrupted-job recovery;
- independent stdout/stderr draining with 5,000 ordered diagnostic lines and a trailing line without newline;
- actual OS process counter sampling;
- CPU percentage calibration against `getrusage`, including Mach timebase scaling on Apple Silicon.

Tests create synthetic media with lavfi in unique temporary directories. FFmpeg-dependent tests skip if unavailable, so check the skip count. Tests do not prove compatibility with all FFmpeg versions, codecs, damaged containers, hardware profiles, or filesystem types.

SQLite tests cover bound strings, separate retry attempts, idempotent logs, batch rollback, bounded busy handling, future-schema rejection, owner-only file permissions, session retention, long-running writer preservation and foreign keys. Engine tests also verify conversion continues when SQLite cannot open, phase timings are populated, and old queues without timings still load.

Use the release stress commands in the README for performance work; keep generated fixtures/results out of Git. The headless runner uses the actual engine but does not exercise SwiftUI. GUI comparisons must record a separate application session and distinguish imported jobs from restored history. Results and methodology are in [STRESS_RESULTS.md](STRESS_RESULTS.md).

## Manual interface pass

1. Launch the app. Confirm FFmpeg is detected and capabilities appear in Engine. Repeat with a manually selected tools directory and a missing/invalid directory.
2. Import a video, an audio file, a folder containing a non-media file, and paths with spaces/quotes. Confirm file rows appear promptly and inspection does not freeze navigation.
3. Select a job and review every detected stream. Choose a preset, edit settings, and apply. Select several jobs and apply a shared output folder. Confirm active jobs retain captured settings.
4. Convert several long inputs at concurrency 2. Watch progress, FPS and speed. Navigate among tabs and edit a pending job while encoding.
5. Pause one worker, resume it, pause again, then cancel it. Confirm the cancelled worker exits, its slot is released, and the next file runs. Confirm Stop queue leaves existing work running but prevents new starts.
6. Retry a failed job after correcting its settings. Duplicate a completed job with a different format; confirm a new output name and preserved source.
7. Convert into a directory with existing similarly named files. Confirm numbering and unchanged existing contents. Try an unwritable/full destination and an unsupported codec/container combination; inspect the useful error and continued queue.
8. Filter logs by selected job, follow/unfollow, search, export, clear view, and inspect rotated disk logs. Export a queue CSV and metrics CSV.
9. Compare app/worker CPU and memory with Activity Monitor; expect sampling and memory-accounting differences. CPU may exceed 100%. File cache hits can show zero physical read I/O. Test thermal/permission-unavailable values on suitable hardware.
10. Quit with active work, choose Keep Converting, and verify it continues. Quit again and choose Stop and Quit. Relaunch: queue/history recover, no work starts automatically. A force quit is a separate destructive test; use only disposable media/state.
11. Resize to the minimum window dimensions and use light/dark system appearances. Check settings scrolling, long errors, large font/VoiceOver labels, keyboard menus and multi-selection.
12. For a bundled release, relocate the app and test on a Mac without Homebrew. Check that Engine reports the app's `Contents/Resources/Tools` path.

## Known limits to verify before release

No exhaustive codec/container matrix, adversarial codec fuzzing, network-volume fault injection, Intel hardware coverage, two-pass normalization, arbitrary multi-input/output workflows, or signed/notarized distribution is claimed. Structural output probing does not validate every decoded frame. Force-killing the app cannot guarantee child cleanup; graceful quit is the supported cancellation path.

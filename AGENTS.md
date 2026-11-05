# Instructions for AI coding agents

## Project and intent

This is a native macOS 14+ SwiftUI application written in Swift 6. The objective is a detailed but approachable FFmpeg audio/video converter with a nonblocking queue and real local observability. Read `README.md` and `Documentation/ARCHITECTURE.md` before changing the scheduler, process runner or output handling.

`Documentation/DIAGRAMS.md` explains concurrency, the job state machine, cancellation and output commit using GitHub-rendered Mermaid. `Documentation/UI_GUIDE.md` maps the user workflow to editable SVG mockups and real screenshots. Update the relevant diagrams when changing those contracts; diagrams describe implemented behavior, not a speculative roadmap. SVG examples use illustrative values, not measured performance.

Read `Documentation/CHUNKED_CONVERSION.md` before changing parallel video execution. The app target is in `VideoConverter.xcodeproj` with scheme `VideoConverter`; opening `Package.swift` selects a package without the graphical app.

## Build and test

Read `Documentation/TELEMETRY.md` for the SQLite schema, timing definitions, retention and backup rules, and `Documentation/STRESS_RESULTS.md` for measured results and limitations. Headless engine timings are not GUI frame-time measurements.

```sh
swift test
xcodebuild -project VideoConverter.xcodeproj -scheme VideoConverter \
  -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO test
```

FFmpeg integration tests use the installed tools and generate their own temporary fixtures. They skip if tools are absent; report skips. To test the local bundle, run `FFMPEG_TEST_DIRECTORY="$PWD/Resources/Tools" swift test`. No test should depend on a user's real media or persisted application support directory. Use a temporary directory for each engine under test and call `shutdown()`.

`project.yml` is the canonical XcodeGen configuration. After adding/removing files or changing targets/resources, run `xcodegen generate` and retain the generated project and shared scheme. The root Swift package builds the core and tests; Xcode builds the actual app. No third-party Swift packages are necessary.

## Invariants to preserve

1. Views and `AppStore` are MainActor presentation code. Never run synchronous media probing, encoding, directory traversal, blocking pipe reads, or `waitUntilExit` there.
2. Every queue action enters the store's FIFO command stream. Only `ConversionEngine` mutates jobs, slot counts, output reservations, or worker lifecycle state. Do not create a new parallel scheduler in a view.
3. Send immutable Sendable values between actors. Keep Swift 6 complete concurrency checking enabled. The process wrapper's unchecked sendability is justified by its lock; do not spread unchecked annotations to silence warnings.
4. Pause retains a conversion slot. Cancelled jobs with an outstanding task cannot be retried or removed until the old worker is reaped. Lower concurrency affects future launches, not existing processes.
5. Drain stdout and stderr independently on utility workers. Maintain bounded log/event/capture buffers and coalesced UI updates. Do not emit a MainActor Task for every log line.
6. Execute FFmpeg using `Process.arguments`. Never use `/bin/sh -c`, `system()`, or the human-readable command string to execute user parameters. Advanced arrays remain literal strings; keep managed flags reserved.
7. Preserve sources and existing outputs. Keep per-job staging on the destination volume, reserve final paths before launch, use no-overwrite encoding, validate output, and commit without replacement. A rename collision must fail safely.
8. A failed or corrupt input must not stop unrelated conversions. Warnings must remain visible even when FFmpeg returns success. Do not silently substitute codecs or claim broken media was fully repaired.
9. Use `ProcessController` for pause, resume, cancel and launch. Do not persist or signal old PIDs after relaunch. Normal quit must stop/drain work before saving and terminating.
10. Restore interrupted jobs as failed/manual-retry and never auto-start a saved queue. Preserve unreadable queue data rather than overwriting it. Handle Codable/schema compatibility when adding fields.
11. Metrics represent real process counters. Distinguish app and worker CPU/memory, document units and unavailable counters, and retain bounded history. Do not imply GPU/network/power metrics exist when they do not.
12. Keep the UI accessible and native: labels, keyboard commands, text selection for diagnostics, status text as well as color, scrollable settings, nonmodal file-panel callbacks, and system appearance support.
13. `TelemetryDatabase` owns its SQLite connection on an actor. Bind values, reuse prepared statements per batch, keep WAL transactions and busy waits short, and never query SQL in a view. Diagnostic persistence failure must not cancel conversion; JSON queue recovery remains authoritative.
14. Surface process-stream, buffer and database losses. Record retries as separate attempts; preserve monotonic phase timings on failures/cancellation. Never remove output verification to improve benchmark numbers. Invalid/nonfinite settings must remain loggable without dropping unrelated diagnostics.
15. Publish idle snapshots only for changed data. Chart equality assumes append-only metric history with a new timestamp for each sample. Update that contract if samples become mutable. Avoid assigning unchanged selection/Dock values on every snapshot.
16. Keep the worker stream (256 events), stderr batches (16 lines), pending logs (4,096) and one burst flusher (threshold 512) bounded. Count lost stderr lines, not just batch envelopes. Shutdown must await ticker/flusher work and persist pending logs, not substitute the smaller live-view ring. Retention must preserve the current writer's session beyond 30 days.
17. The conversion limit is a shared worker-slot budget. Sum `ConversionPlan.workerSlots`, not parent job count. A chunked file captures its available allocation at launch and keeps that reservation through pause/join/verification. Input inspections keep their separate two-slot budget. Never multiply a full per-file pool by the number of queue slots.
18. Each chunk-pool lane owns a fresh `ProcessController`, reused sequentially by that lane only. Signal all controllers on pause/resume/cancel/quit; preserve pause/cancel-before-launch behavior. Probe timeouts exclude explicit pause time. Parent task ownership lasts until all children are reaped.
19. Chunks are video-only closed-GOP MP4s with a common time base/rate and exact expected frame counts. Join only after every chunk verifies, using controlled relative manifest names with concat safe mode. Encode original audio once during final joining. Never independently encode lossy audio chunks, silently skip failed chunks, or bypass final verification/commit safety.
20. Keep chunk mode opt-in and reject unsupported settings before launch. Source-offset/rate metadata checks are heuristics, not proof of CFR timing; do not promise arbitrary VFR frame accuracy. Optional settings/media/progress fields preserve older queue/default decoding. Retry restarts the whole job and removes only its own staging directory, including chunks; it does not resume completed pieces.

## Where changes belong

- Models/settings: `Sources/ConverterCore/Models.swift`.
- Validation and FFmpeg mapping: `CommandBuilder.swift`; cover meaningful parser/validation changes in tests.
- Chunk eligibility, frame ranges, argv and safe concat manifest: `ChunkPlanner.swift`; preserve rational rates, independent video segments and one continuous audio encode. Chunk execution/progress stays inside `ConversionEngine`.
- Queue policies/state transitions: `ConversionEngine.swift`; extend integration coverage for lifecycle changes.
- Signals/processes/pipes: `ProcessRunner.swift`; test cancellation before/during launch and while paused.
- Probing: `MediaProbe.swift`; preserve timeout behavior and optional JSON field handling.
- Recovery and disk logs: `QueuePersistence.swift`.
- OS counters: `Telemetry.swift`.
- SQLite history: `TelemetryDatabase.swift`; version and migrate existing schemas rather than dropping/recreating user data. The optional job timings field keeps older JSON queues readable.
- Stress tools: `Sources/ConverterStress` and `Scripts/{make-stress-fixtures,run-stress-matrix,analyze-telemetry}.py`.
- Presentation/native panels: `Sources/VideoConverter`; UI does not own worker processes.
- Packaging: `Scripts/bundle-ffmpeg.py` and `project.yml`.

## Resource and distribution rules

`Resources/Tools` contains locally generated, architecture-specific FFmpeg executables and native libraries. Only its `.gitkeep` placeholder is tracked; the binaries are ignored. Preserve that placeholder so the included Xcode project builds from a clean clone without missing folder resources. Do not check in native binaries or large media fixtures. The bundler copies already installed software and makes no downloads. Never silently replace the user's FFmpeg installation or fetch an unverified binary. Source icon assets are generated by `Scripts/create-icon.swift` and can be committed.

The worker-process integration is intentional: FFmpeg's libraries run in child processes, not in the UI address space. Do not describe this as a direct Swift/C library binding. One source and one managed output per job are supported; do not promise a GUI for every FFmpeg workflow.

Do not claim the app is distribution-ready. Signing, notarization, sandbox redesign for the App Store, architecture validation, and FFmpeg/dependency license obligations require their own release work. Keep `Documentation/DISTRIBUTION.md` accurate when packaging changes.

## Finishing a change

SQLite is the macOS system library (`SQLite3`/`libsqlite3`), not a downloaded dependency. Do not commit database/WAL/SHM files, synthetic media, raw logs or raw metrics. Back up a live database with SQLite's backup API or `.backup`, not a standalone file copy. Public reports contain only reviewed path-free summaries and synthetic fixture manifests.

For performance changes, use Release builds and identical fixtures/negative controls. Run benchmark scenarios sequentially; do not compile or render docs during timed batches. Interleave thread comparisons with `--threads 0 2 --repeat 3`. Report source-size tolerance, host/thermal state, repetitions, cache effects, expected negative failures, telemetry losses and the GUI/headless distinction. CRF is not a fixed compression ratio; size alone does not measure output quality.

Run appropriate core tests and the Xcode build/test scheme. For UI changes, launch the app and inspect affected screens in light/dark appearance and at the minimum window size when practical. Report what was actually verified and any skipped integration tests. Update the user-facing documentation when workflow, supported features or limitations change.

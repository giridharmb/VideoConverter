# Architecture and concurrency

## Responsibilities

```text
SwiftUI views (MainActor)
    │ synchronous command enqueue; no conversion work
    ▼
AppStore → AsyncStream<AppCommand> (FIFO)
    │ one command-consumer Task
    ▼
ConversionEngine actor
    ├── jobs, state transitions, slot limits, output reservations
    ├── inspection Tasks (maximum 2)
    ├── conversion Tasks (1–8 shared worker slots, paused jobs retain reservations)
    ├── bounded per-file chunk task groups (optional; same shared budget)
    ├── ProcessController per pool lane (lock-protected signals/lifecycle)
    │      └── ProcessRunner → dispatch worker + stdout/stderr readers
    │             └── FFmpeg / ffprobe + their native libraries
    ├── QueuePersistence actor → atomic queue writes + rotating logs
    ├── TelemetryDatabase actor → batched SQLite WAL history
    ├── TelemetrySampler → macOS process counters
    └── AsyncStream<EngineSnapshot> (newest only)
                       ▼
                  AppStore → SwiftUI
```

This is a small model/view/store design with an actor scheduler and immutable snapshot messages. There is no generic workflow framework, dependency-injection container, polling shell script, or command shell in the conversion path. The core is a separate framework and Swift package so it can be tested without launching the UI.

## File map

| File | Responsibility |
| --- | --- |
| `Sources/ConverterCore/Models.swift` | Sendable/Codable settings, media, jobs, commands and snapshots |
| `CommandBuilder.swift` | Validate settings, select streams, allocate a collision-safe destination, generate literal argv, parse machine-readable progress |
| `ChunkPlanner.swift` | Validate chunk eligibility, align frame ranges, create video-only segment argv and an ordered safe concat/audio assembly plan |
| `ProcessRunner.swift` | Locate tools; launch processes away from MainActor; independently drain pipes; bound captures; handle pause/resume/termination |
| `MediaProbe.swift` | Timeout-protected ffprobe execution and typed JSON decoding |
| `ConversionEngine.swift` | Single owner of all job state, scheduler, command dispatch, worker/event lifecycle, output commit and reservations |
| `QueuePersistence.swift` | Versioned JSON recovery, atomic writes and rotating disk logs |
| `Telemetry.swift` | Process CPU/memory/I/O/thread deltas, thermal state and filesystem free space |
| `TelemetryDatabase.swift` | Actor-confined SQLite sessions/attempts/logs/samples/operations, bound transactions and retention |
| `Sources/VideoConverter/AppStore.swift` | MainActor observable adapter, FIFO ingress, dialogs, exports and persisted UI defaults |
| `VideoConverterApp.swift` | App entry, menus, graceful quit |
| `ContentView.swift` | Navigation and shared native UI components |
| `QueueView.swift` | Jobs, drag/drop, search/filter, bulk actions, progress and scheduling controls |
| `InspectorView.swift` | Output/video/audio/expert editing and command preview |
| `LogsView.swift`, `MetricsView.swift`, `EngineView.swift` | Observability and backend configuration |

## Main-thread contract

Button actions update small UI state or enqueue a value into `AsyncStream`. `AppStore` runs one consumer task to preserve click ordering. It awaits actor command handling but never blocks the main thread. Media import enumeration, command preview filesystem checks, and text file exports run in detached utility tasks. Native file panels use asynchronous completion callbacks.

The engine actor runs independently of MainActor. Queue state never leaks as shared mutable references. It publishes value snapshots at most about every 300 ms for streaming updates, with immediate snapshots for command/state changes. The snapshot stream keeps only its newest snapshot; a slow UI does not build an unbounded backlog. Parsing/logging does not create a new MainActor task for every FFmpeg line.

`Process.waitUntilExit`, pipe reads, and reader joins are blocking APIs. They run on GCD utility workers, not on MainActor or inside the Swift cooperative executor. stdout and stderr are drained independently to avoid pipe deadlock. Launch uses argument arrays and closed stdin. Stderr travels in batches of up to 16 lines, capped at 8,192 characters per line before entering the 256-event-per-worker stream. Stdout progress remains line-based. The two readers can interleave events, while each pipe's line order is preserved. Dropped batches count their constituent lines; discarded progress events count individually.

The engine's scheduled task starts long work and returns; subsequent UI commands can cancel, pause or adjust future jobs while workers run. One operation that must be serialized is the final output rename: it runs synchronously on the engine actor after cancellation is checked, so a cancel command cannot race between successful rename and terminal-state assignment. This short filesystem operation is outside MainActor. Slow/unresponsive network volumes can delay the engine actor; UI navigation remains separate.

## State machine

```text
waiting → inspecting → ready → running ⇄ paused → completed
            │                    │         │
            └── failed           ├─ failed┘
                                 └─ cancelled

failed/cancelled --retry--> ready (known media) or waiting (needs probe)
any nonterminal state --cancel--> cancelled
recovered inspecting/running/paused --> failed (interrupted)
duplicate --> new waiting/ready job with a new UUID
```

The task dictionary remains populated until a cancelled worker actually exits. Retry and removal reject jobs with live tasks even if their visible state is already cancelled. This avoids an old task updating a newly started attempt. Conversion plans remain allocated until worker cleanup, so cancellation cannot temporarily oversubscribe the conversion limit.

Inspection is independent of queue Start/Stop and has two slots. The conversion limit is a shared worker-slot budget: standard files reserve one slot, chunked files reserve up to their requested workers within the remaining budget. The scheduler sums plan reservations rather than counting parent jobs. Paused jobs retain all their slots. A file keeps its captured allocation through joining and verification, even when those stages need only one process. Lowering concurrency affects future launches; Stop scheduling prevents new files while active chunk pipelines continue.

For optional chunk mode, the engine owns a bounded task group and an array of controllers per file. Each pool lane reuses its controller sequentially; no controller owns simultaneous processes. Per-chunk progress is duration-weighted, with final progress reserved for assembly/verification. All segments must pass frame-count checks before a safe relative-name concat manifest is used. The final process copies encoded video and encodes original audio continuously. Failure cancels/drains siblings before releasing reservations. See [Chunk execution, constraints and measurements](CHUNKED_CONVERSION.md).

Settings are captured on job creation. Apply affects inactive, non-completed jobs only, including failed/cancelled jobs before Retry. Selecting one job loads a copy into the UI editor. Presets update the editor; they do not mutate existing jobs implicitly. The scheduler builds commands from each job's captured settings.

## Worker lifecycle and cancellation

Idle snapshots now publish only for new metric samples or changed errors, rather than at every 300 ms tick. Progress/log changes remain coalesced at about 300 ms and state/command changes publish immediately. `MetricCharts` skips work when sample history is unchanged; AppStore does not assign unchanged selection or Dock badge values. SQLite collects UI snapshot-delivery and 100 ms heartbeat delay observations to help detect regressions.

`ProcessController` is the only `@unchecked Sendable` wrapper around a `Process`. All its mutable state is protected by one `NSLock`. The lock covers launch versus cancel, preventing a cancel-before-launch race from leaving an orphan worker. Desired pause state is preserved across sequential encoding/verification processes; a process launched while paused is stopped immediately.

`ProcessRunner.run` bridges GCD to Swift concurrency with a checked continuation and a task cancellation handler. Cancel marks the controller cancelled, resumes a stopped process, sends SIGTERM, then sends SIGKILL after two seconds if the controller still owns a live process. PID signaling is performed while holding the same lock, so an exited process is not retained for delayed escalation. Every retry receives a new controller.

ffprobe inspection and output verification use a throwing task group: the probe races a 60-second timeout that excludes deliberate controller pause time. Losing work is cancelled and the process reaped before the task group exits. Encoding has no fixed timeout because valid workloads can take hours. Its progress uses FFmpeg `-progress pipe:1`; diagnostics use stderr. The GUI does not infer completion from `progress=end`: only process success, successful output probe, and successful commit can mark a job completed.

Normal quit stops command ingress, drains accepted commands, stops scheduling, cancels maintenance/conversion/inspection tasks, waits for process exit, flushes persistence, then replies to AppKit's termination request. Directory import enumeration may finish later but checks the shutdown flag before inserting jobs. Hard crash/force quit cannot run this cleanup; the persisted queue marks interrupted jobs for manual retry. Do not assume a worker from a hard-killed parent is still owned or kill a persisted PID; PIDs can be reused.

## Output transaction

1. Validate settings and streams. Select a filename that differs from the source and is absent from both the filesystem and the actor's reservation set.
2. Reserve that output before launching any asynchronous work.
3. Create the per-job staging directory on the destination volume. Retry removes only this job's own staging directory, including any prior partial/chunk files. Check destination free space.
4. Run FFmpeg with no overwrite and no stdin. Recovery flags are optional per job.
5. Check the exit code, probe the staging output and require audio/video and nonzero size. Check cancellation.
6. Move the file into its final destination without replacing an existing file. Since staging is on the same volume, normal commits use a rename. A competing creator causes a failure.
7. Set terminal state, release the reservation/slot/controller/parser, preserve partial files on failure, and schedule the next ready job.

No conversion command intentionally deletes a source file. No bulk queue action deletes media. Advanced FFmpeg options can create side effects outside the managed output; they are a trusted escape hatch, not a sandbox. Full output decode verification is intentionally absent because it would add a complete extra pass to every conversion.

## Persistence and observability

`queue.json` is versioned and saved with Foundation atomic write. State-changing commands set a dirty flag; ticks coalesce saves to about one per second. Normal shutdown flushes explicitly. Progress ticks themselves do not force writes. If load fails, future saves are disabled for that engine lifetime so corrupt or newer-version data survives for investigation.

Logs are appended in batches on the persistence actor, separately from job state. Each line is timestamped and tagged with level and job UUID. The app keeps 2,000 live log entries and up to 4,096 pending entries. At 512 pending entries, one asynchronous flush task drains batches to text and SQLite storage instead of waiting for the periodic tick. This reduces losses during short diagnostic bursts while preserving bounded memory. Stream and pending-buffer losses are counted separately and included in `telemetry_health`. Disk logs rotate at roughly 5 MiB, retaining one predecessor. Logging failures appear as a persistence banner rather than causing recursive log errors. Shutdown awaits in-flight flushes and writes the entire remaining pending batch, independently of the smaller live-view ring.

Telemetry samples the app PID and known active worker PIDs. CPU and disk rates use deltas per PID and monotonic elapsed time, avoiding negative rates when a worker exits. Memory is current physical footprint. Completed workers' lifetime counters are not summed into the live process totals. The 300-sample ring is independent of persistent queue history. These are diagnostic OS samples, not billing/accounting values.

The configurable keep-awake assertion exists only while at least one conversion is running. When work is paused, complete, failed, cancelled, or shutting down, the assertion is released. It prevents idle system sleep, not display sleep or an explicit user sleep command.

## Extension rules

`TelemetryDatabase` separately records sessions, retry attempts, per-job phase timings, logs, OS samples and operation durations. One actor owns the system SQLite connection. Writes bind values and reuse prepared statements within batched WAL transactions; a bounded busy timeout and surfaced loss/error counts keep diagnostic failures independent of conversion. JSON remains authoritative recovery. See [Telemetry](TELEMETRY.md) for schema/retention and [Stress results](STRESS_RESULTS.md) for observations. Old queues without the optional `timings` field continue to decode.

- Add a user-facing setting to `ConversionSettings`, then validation/argv generation, editor binding and a behavior test. Preserve decode compatibility by adding explicit defaults or migrating older persisted settings when changing the schema.
- Add queue actions to `AppCommand` and handle them on the engine actor. Never let views access `Process` or mutate jobs directly.
- Put platform counter changes in `TelemetrySampler`. Expose unavailable values honestly; never fill a chart with synthetic data.
- Keep arguments as arrays. Command display escaping is for copying/review only; never execute the displayed shell string.
- For multi-input/multi-output editing, introduce an explicit plan model with managed inputs/outputs and a compatible persistence migration. Do not hide extra output paths inside preset strings.
- To replace the CLI backend with a directly linked C API, preserve the engine's command/state/output transaction contracts. Implement library context interruption, timestamps, filtering, muxing and encoder capability checks behind a new worker boundary rather than moving C work into SwiftUI.

## Primary references

- [FFmpeg command, progress and stream mapping documentation](https://ffmpeg.org/ffmpeg.html)
- [FFmpeg codec, format and recovery options](https://ffmpeg.org/ffmpeg-all.html)
- [ffprobe JSON output](https://ffmpeg.org/ffprobe.html)
- [Apple: Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- [Swift concurrency and actor isolation](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
- [Apple XNU process resource counter implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c) (CPU Mach ticks are scaled with `mach_timebase_info` before calculating rates)

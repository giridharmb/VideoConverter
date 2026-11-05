# System diagrams

These Mermaid diagrams render directly on GitHub. Their source lives in this document, alongside the implementation. For detailed invariants and file ownership, see [Architecture](ARCHITECTURE.md). For screen mockups and screenshots, see the [Visual guide](UI_GUIDE.md).

## Component and isolation boundaries

```mermaid
flowchart TB
    subgraph UI["Main actor · presentation"]
        Views["SwiftUI: Convert / Logs / Metrics / Engine"]
        Store["AppStore: observable view state"]
        Commands["AsyncStream of AppCommand · FIFO"]
        Views -->|"enqueue a command"| Store
        Store --> Commands
    end
    subgraph Core["Swift concurrency · independent of the main actor"]
        Engine["ConversionEngine actor\nSingle owner of jobs, slots and reservations"]
        Probe["Inspection tasks\nMaximum 2"]
        Convert["Conversion tasks\n1–8 shared file/chunk worker slots"]
        Chunks["Optional bounded chunk group\nVideo-only segments; continuous final audio"]
        Save["QueuePersistence actor\nAtomic JSON + rotating logs"]
        SQL["TelemetryDatabase actor\nBatched SQLite WAL transactions"]
        Telemetry["TelemetrySampler\nCPU, memory, I/O, threads, thermal, disk"]
        Snapshots["EngineSnapshot stream\nNewest snapshot only"]
        Engine --> Probe
        Engine --> Convert
        Convert --> Chunks
        Engine --> Save
        Engine --> SQL
        Engine --> Telemetry
        Engine --> Snapshots
    end
    subgraph Workers["GCD utility threads + child processes"]
        Runner["ProcessRunner\nIndependent stdout / stderr readers"]
        Controller["ProcessController\nLock-protected launch and signals"]
        FFmpeg["FFmpeg / ffprobe executables\nNative codec and format libraries"]
        Runner --> Controller --> FFmpeg
    end
    Commands --> Engine
    Probe --> Runner
    Convert --> Runner
    Chunks --> Runner
    FFmpeg -->|"Progress and diagnostics"| Runner
    Runner -->|"Bounded events"| Engine
    Snapshots -->|"Coalesced updates"| Store
    SQL --> History["Local sessions, attempts, logs, metrics and timings"]
    Telemetry -.->|"Sample live app and worker PIDs"| FFmpeg
```

The SwiftUI process does not directly link the FFmpeg C API. The executable frontends load those libraries inside child processes. A native codec crash becomes a job error rather than a decoder crash inside the view process. The [parallel chunk workflow](CHUNKED_CONVERSION.md) has its own execution diagram and timing constraints.

## One click through a completed conversion

```mermaid
sequenceDiagram
    actor User
    participant UI as SwiftUI / AppStore
    participant Queue as Command FIFO
    participant Engine as ConversionEngine actor
    participant Probe as ffprobe worker
    participant Encode as FFmpeg worker
    participant Disk as Destination filesystem
    User->>UI: Add files with current settings
    UI->>Queue: Enqueue add command, return to event loop
    Queue->>Engine: Handle add
    Engine->>Engine: Enumerate off main actor, create jobs
    Engine->>Probe: Inspect up to two inputs
    Probe-->>Engine: Streams, duration, codecs, size
    Engine-->>UI: Publish ready jobs
    User->>UI: Start queue
    UI->>Queue: Enqueue start command
    Queue->>Engine: Enable scheduling
    Engine->>Engine: Validate settings, reserve final output name
    Engine->>Disk: Create per-job staging directory, check free space
    Engine->>Encode: Launch literal argument array, stdin disabled
    loop Encoding while UI remains interactive
        Encode-->>Engine: stdout progress, stderr diagnostics
        Engine-->>UI: Progress and log snapshots, about every 300 ms
        Note over UI,Engine: Other clicks may enqueue pause, cancel, or edits for pending jobs
    end
    Encode-->>Engine: Exit status
    alt Encode succeeded
        Engine->>Probe: Verify staged audio/video output
        Probe-->>Engine: Readable output and nonzero size
        Engine->>Disk: Move staged output without replacing a destination
        alt Commit succeeds
            Disk-->>Engine: Final output committed
            Engine-->>UI: Completed, preserve any diagnostics
        else Destination appeared or filesystem error
            Disk-->>Engine: Rename error
            Engine-->>UI: Failed, preserve existing file and partial output
        end
    else Encode failed or verification failed
        Engine-->>UI: Failed with diagnostics, retain partial output
    end
    Engine->>Engine: Release reservation / slot, schedule next ready job
```

Verification checks the output container and streams; it does not decode every frame. A final destination created by another program causes a safe failure. Settings edits never mutate an already active job.

## Job lifecycle

```mermaid
stateDiagram-v2
    [*] --> Waiting: Import
    Waiting --> Inspecting: Inspection slot available
    Inspecting --> Ready: Audio or video detected
    Inspecting --> Failed: Invalid media or probe timeout
    Ready --> Running: Queue enabled and conversion slot available
    Ready --> Failed: Settings or output planning invalid
    Running --> Paused: Pause
    Paused --> Running: Resume
    Running --> Completed: Encode, verification and commit succeed
    Running --> Failed: Encode, verification or commit fails
    Paused --> Failed: Worker or verification failure
    Waiting --> Cancelled: Cancel
    Inspecting --> Cancelled: Cancel
    Ready --> Cancelled: Cancel
    Running --> Cancelled: Cancel
    Paused --> Cancelled: Cancel
    Failed --> Ready: Retry with known media after worker exits
    Failed --> Waiting: Retry without media after worker exits
    Cancelled --> Ready: Retry with known media after worker exits
    Cancelled --> Waiting: Retry without media after worker exits
    Completed --> [*]: Remove history entry
    note right of Paused
        Retains all reserved worker slots.
        Stop queue only stops new launches.
    end note
    note left of Failed
        Interrupted active jobs recover here.
        Relaunch never automatically starts the queue.
    end note
```

Duplicating a job creates a separate UUID in Waiting or Ready, depending on whether media information is already available. Failed and cancelled rows can be edited before retry. Live task ownership prevents retry/removal from racing a dying worker.

## Pause, cancel, and graceful quit

```mermaid
flowchart LR
    Pause["Pause command"] --> Lock["ProcessController lock"]
    Lock --> Stop["Remember pause state\nSIGSTOP if a process is live"]
    Resume["Resume command"] --> Continue["Clear pause state\nSIGCONT"]
    Cancel["Cancel command / task cancellation"] --> Mark["Mark controller cancelled\nPrevent later launch"]
    Mark --> Wake["SIGCONT\nWake a stopped worker"]
    Wake --> Term["SIGTERM"]
    Term --> Check{"Still owned and running\nafter two seconds?"}
    Check -->|Yes| Kill["SIGKILL"]
    Check -->|No| Reap["Reap process and finish pipe readers"]
    Kill --> Reap
    Reap --> Release["Release task, slot and reservation"]
    Quit["Normal application quit"] --> Drain["Stop command ingress\nDrain accepted commands"]
    Drain --> Cancel
    Release --> Persist["Await ticker and burst flusher\nFlush JSON, text and SQLite; end session"]
```

A remembered pause applies even when requested before process launch. Every retry uses a fresh controller. A hard crash cannot execute graceful shutdown, and persisted PIDs are never used as authority to signal a process after relaunch.

## Managed output transaction

```mermaid
flowchart LR
    Source["Source media\nRead only"] --> Plan["Validate settings\nReserve unique destination"]
    Plan --> Staging["Hidden destination-volume staging\n.videoconverter-UUID/output.ext"]
    Staging --> Encode["FFmpeg with no overwrite"]
    Encode --> Success{"Exit status 0?"}
    Success -->|No| Partial["Retain partial file\nRecord job error"]
    Success -->|Yes| Verify["ffprobe output\nRequire audio/video + nonzero size"]
    Verify --> Valid{"Verification passed?"}
    Valid -->|No| Partial
    Valid -->|Yes| Commit["Check cancellation\nMove without replacement"]
    Commit --> Moved{"Move succeeded?"}
    Moved -->|No| Partial
    Moved -->|Yes| Final["Visible final output\nMark completed"]
```

Retry discards only that same job's prior staging output before a new attempt. Removing queue rows leaves files untouched. Expert arguments remain trusted FFmpeg options and can introduce side files outside the managed output transaction.

## Real observability, bounded history

```mermaid
flowchart TB
    App["App PID"] --> Counters["proc_pid_rusage + proc_pidinfo"]
    Workers["Live worker PIDs"] --> Counters
    Counters --> Rates["Mach ticks → seconds\nDelta / monotonic elapsed time"]
    Rates --> Metrics["300 metric samples\nAbout one every 0.9 seconds"]
    OS["Thermal state + destination free space"] --> Metrics
    Progress["FFmpeg stdout progress"] --> Parser["ProgressParser\nTime, FPS, speed, bytes, ETA"]
    Errors["FFmpeg stderr + application events"] --> Batch["Up to 16 lines per stderr event\n256 events per worker"]
    Batch --> Logs["2,000 live log entries\nLoss counters for bounded ingestion"]
    Batch --> Pending["4,096 pending log entries\nOne burst flusher starts at 512"]
    Pending --> Disk["Rotating disk logs\nAbout 5 MiB + one previous file"]
    Pending --> SQL["TelemetryDatabase actor\nSQLite WAL history"]
    Metrics --> SQL
    Timing["Job phases + command, UI and flush timings"] --> SQL
    Metrics --> Snapshot["Engine snapshot"]
    Parser --> Snapshot
    Logs --> Snapshot
    Snapshot --> UI["Queue / Logs / Metrics views"]
    UI --> Export["User-requested text or CSV export"]
```

CPU uses 100% per logical core. Memory is physical footprint; disk rates are kernel-accounted physical I/O, so cache hits may report zero. GPU, network and power usage are not collected. No analytics service is configured.

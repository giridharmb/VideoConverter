import Foundation
import IOKit.pwr_mgt

private final class DroppedProcessEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment(by count: Int = 1) { lock.withLock { value += count } }
    var count: Int { lock.withLock { value } }
}

public actor ConversionEngine {
    public nonisolated let snapshots: AsyncStream<EngineSnapshot>
    private let snapshotContinuation: AsyncStream<EngineSnapshot>.Continuation
    private var snapshot = EngineSnapshot()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var controllers: [UUID: ProcessController] = [:]
    private var parsers: [UUID: ProgressParser] = [:]
    private var plans: [UUID: ConversionPlan] = [:]
    private var reservedOutputs: Set<String> = []
    private var pendingLogs: [LogEntry] = []
    private var persistenceDirty = false
    private var persistenceHealthy = true
    private var initializing = false
    private var initialized = false
    private var toolDirectory = ""
    private var telemetry = TelemetrySampler()
    private var ticker: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?
    private var shuttingDown = false
    private var lastPersist = Date.distantPast
    private var tickNumber = 0
    private let persistence: QueuePersistence
    private let database: TelemetryDatabase
    private var databaseReady = false
    private var pendingJobs: [String: JobRecord] = [:]
    private var pendingMetrics: [MetricSample] = []
    private var pendingOperations: [PerformanceEvent] = []
    private var attempts: [UUID: Int] = [:]
    private var inspectionStarts: [UUID: Double] = [:]
    private var uiDirty = false
    private var logFlushTask: Task<Void, Never>?
    private var sleepAssertion: IOPMAssertionID = 0

    public init(storageDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VideoConverter"),
                telemetryDatabaseURL: URL? = nil, sessionLabel: String = "application") {
        let stream = AsyncStream<EngineSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        snapshots = stream.stream; snapshotContinuation = stream.continuation
        persistence = QueuePersistence(directory: storageDirectory)
        let databaseURL = telemetryDatabaseURL ?? storageDirectory.appendingPathComponent("telemetry.sqlite")
        database = TelemetryDatabase(url: databaseURL, label: sessionLabel)
        snapshot.telemetryDatabasePath = databaseURL.path
        snapshot.sessionID = database.sessionID
    }

    public func handle(_ command: AppCommand) async {
        guard !shuttingDown else { return }
        let commandStart = ProcessInfo.processInfo.systemUptime
        defer { recordPerformance(name: "command", durationMs: elapsed(commandStart), detail: command.operationName) }
        switch command {
        case .initialize: await initialize(); return
        case .add(let urls, let settings):
            Task { await self.importURLs(urls, settings: settings) }
        case .start: snapshot.queueRunning = true
        case .stopScheduling: snapshot.queueRunning = false
        case .setConcurrency(let count): snapshot.concurrency = min(8, max(1, count))
        case .setPreventSleep(let enabled): snapshot.preventSleep = enabled
        case .setTools(let path):
            guard tasks.isEmpty, maintenance == nil else { log(.warning, "Finish or cancel active work before changing FFmpeg."); break }
            toolDirectory = path
            maintenance = Task { await self.detectTools(); self.maintenance = nil; self.schedule() }
        case .cancel(let ids):
            for id in ids {
                guard let i = index(id), !snapshot.jobs[i].state.isTerminal else { continue }
                controllers[id]?.cancel(); tasks[id]?.cancel()
                snapshot.jobs[i].state = .cancelled; snapshot.jobs[i].message = "Cancelled"; snapshot.jobs[i].finishedAt = Date()
                recordJob(id)
                log(.info, "Cancelled", job: id)
            }
        case .pause(let ids):
            for id in ids {
                if let i = index(id), snapshot.jobs[i].state == .running, controllers[id] != nil {
                    controllers[id]?.pause(); snapshot.jobs[i].state = .paused; snapshot.jobs[i].message = "Paused"
                    recordJob(id)
                }
            }
        case .resume(let ids):
            for id in ids {
                if let i = index(id), snapshot.jobs[i].state == .paused {
                    controllers[id]?.resume(); snapshot.jobs[i].state = .running; snapshot.jobs[i].message = "Converting"
                    recordJob(id)
                }
            }
        case .retry(let ids):
            for id in ids {
                if let i = index(id), [.failed, .cancelled].contains(snapshot.jobs[i].state), tasks[id] == nil {
                    recordJob(id)
                    attempts[id, default: 1] += 1
                    snapshot.jobs[i].state = snapshot.jobs[i].media == nil ? .waiting : .ready
                    snapshot.jobs[i].progress = JobProgress(); snapshot.jobs[i].message = "Ready to retry"
                    snapshot.jobs[i].finishedAt = nil; snapshot.jobs[i].startedAt = nil; snapshot.jobs[i].output = nil
                    snapshot.jobs[i].warningCount = 0
                    snapshot.jobs[i].timings = JobTimings()
                    recordJob(id)
                }
            }
        case .apply(let ids, let settings):
            for id in ids {
                if let i = index(id), !snapshot.jobs[i].state.isActive, snapshot.jobs[i].state != .completed, tasks[id] == nil {
                    snapshot.jobs[i].settings = settings
                    recordJob(id)
                }
            }
        case .duplicate(let ids, let settings):
            let copies = snapshot.jobs.filter { ids.contains($0.id) }.map { original in
                var copy = ConversionJob(input: original.input, settings: settings)
                copy.media = original.media; copy.state = original.media == nil ? .waiting : .ready
                copy.message = original.media == nil ? "Waiting for inspection" : "Ready"
                return copy
            }
            snapshot.jobs.append(contentsOf: copies)
            for copy in copies { recordJob(copy.id) }
        case .remove(let ids): snapshot.jobs.removeAll { ids.contains($0.id) && tasks[$0.id] == nil }
        case .clearFinished: snapshot.jobs.removeAll { $0.state.isTerminal && tasks[$0.id] == nil }
        case .clearLogs: snapshot.logs.removeAll()
        case .moveFirst(let ids): snapshot.jobs = snapshot.jobs.filter { ids.contains($0.id) } + snapshot.jobs.filter { !ids.contains($0.id) }
        }
        persistenceDirty = true
        schedule()
        publish()
    }

    private func initialize() async {
        guard !initialized, !initializing else { return }
        initializing = true
        do { try await database.start(); databaseReady = true }
        catch { snapshot.telemetryError = error.localizedDescription }
        do {
            if let saved = try await persistence.load() {
                snapshot.concurrency = min(8, max(1, saved.concurrency)); toolDirectory = saved.toolDirectory
                snapshot.preventSleep = saved.preventSleep ?? true
                snapshot.jobs = saved.jobs.map { job in
                    var job = job; job.workerPID = nil
                    if job.state.isActive {
                        job.state = .failed; job.message = "Interrupted by application exit. Retry to restart safely."
                        job.finishedAt = Date()
                    }
                    return job
                }
                for job in snapshot.jobs { recordJob(job.id) }
                log(.info, "Restored \(snapshot.jobs.count) jobs. The queue never starts automatically after relaunch.")
            }
        } catch {
            persistenceHealthy = false
            snapshot.persistenceError = "Queue recovery failed; the saved file will not be overwritten: \(error.localizedDescription)"
            log(.error, snapshot.persistenceError!)
        }
        initialized = true; initializing = false
        await detectTools()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await self?.tick()
            }
        }
        schedule(); publish()
    }

    private func detectTools() async {
        do {
            let directory = toolDirectory
            let tools = try await Task.detached(priority: .utility) { try ToolPaths.discover(directory: directory) }.value
            snapshot.tools = tools
            let version = try await ProcessRunner.capture(executable: tools.ffmpeg, arguments: ["-version"])
            guard version.status == 0 else { throw ConverterError.message("FFmpeg could not start: \(version.diagnostic)") }
            snapshot.engineDescription = String(decoding: version.output, as: UTF8.self).components(separatedBy: "\n").first ?? "FFmpeg"
            var capabilities = ""
            for option in ["-encoders", "-decoders", "-formats", "-filters", "-hwaccels"] {
                let result = try await ProcessRunner.capture(executable: tools.ffmpeg, arguments: ["-hide_banner", option])
                capabilities += "\n\(option.uppercased())\n" + String(decoding: result.output, as: UTF8.self) + result.diagnostic
            }
            snapshot.capabilities = capabilities
            log(.info, "\(snapshot.engineDescription) · \(tools.ffmpeg.path)")
        } catch { snapshot.tools = nil; snapshot.engineDescription = error.localizedDescription; log(.error, error.localizedDescription) }
        persistenceDirty = true; schedule(); publish()
    }

    private func importURLs(_ urls: [URL], settings: ConversionSettings) async {
        let expanded = await Task.detached(priority: .utility) { () -> [URL] in
            var files: [URL] = []
            for url in urls where url.isFileURL {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values?.isDirectory == true {
                    if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                        while let file = enumerator.nextObject() as? URL {
                            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(file) }
                        }
                    }
                } else if values?.isRegularFile == true { files.append(url) }
            }
            return files
        }.value
        guard !shuttingDown else { return }
        var existing = Set(snapshot.jobs.map { $0.input.standardizedFileURL.path })
        var added = 0
        for url in expanded where existing.insert(url.standardizedFileURL.path).inserted {
            let job = ConversionJob(input: url, settings: settings)
            snapshot.jobs.append(job); recordJob(job.id); added += 1
        }
        log(.info, "Added \(added) files; skipped \(expanded.count - added) duplicates. Folder contents are inspected by ffprobe.")
        persistenceDirty = true; schedule(); publish()
    }

    private func schedule() {
        guard let tools = snapshot.tools, initialized, !shuttingDown, maintenance == nil else { return }
        var inspections = snapshot.jobs.filter { $0.state == .inspecting }.count
        for i in snapshot.jobs.indices where snapshot.jobs[i].state == .waiting && inspections < 2 {
            let job = snapshot.jobs[i]
            let controller = ProcessController()
            snapshot.jobs[i].state = .inspecting; snapshot.jobs[i].message = "Detecting streams…"
            inspectionStarts[job.id] = ProcessInfo.processInfo.systemUptime
            recordJob(job.id)
            controllers[job.id] = controller; inspections += 1
            tasks[job.id] = Task {
                do {
                    let media = try await MediaProbe.inspect(job.input, tools: tools, controller: controller)
                    self.inspected(job.id, result: .success(media))
                } catch { self.inspected(job.id, result: .failure(error)) }
            }
        }
        guard snapshot.queueRunning else { return }
        var active = plans.count
        for i in snapshot.jobs.indices where snapshot.jobs[i].state == .ready && tasks[snapshot.jobs[i].id] == nil && active < snapshot.concurrency {
            let job = snapshot.jobs[i]
            let planningStart = ProcessInfo.processInfo.systemUptime
            do {
                let plan = try CommandBuilder.make(job: job, reserved: reservedOutputs)
                if snapshot.jobs[i].timings == nil { snapshot.jobs[i].timings = JobTimings() }
                snapshot.jobs[i].timings?.planningMs = elapsed(planningStart)
                reservedOutputs.insert(plan.output.path); plans[job.id] = plan; active += 1
                snapshot.jobs[i].output = plan.output; snapshot.jobs[i].command = [tools.ffmpeg.path] + plan.arguments
                snapshot.jobs[i].state = .running; snapshot.jobs[i].message = "Preparing conversion"
                snapshot.jobs[i].startedAt = Date()
                recordJob(job.id)
                let controller = ProcessController(); controllers[job.id] = controller; parsers[job.id] = ProgressParser()
                log(.info, CommandBuilder.display([tools.ffmpeg.path] + plan.arguments), job: job.id)
                tasks[job.id] = Task { await self.convert(job: job, plan: plan, tools: tools, controller: controller) }
            } catch {
                if snapshot.jobs[i].timings == nil { snapshot.jobs[i].timings = JobTimings() }
                snapshot.jobs[i].timings?.planningMs = elapsed(planningStart)
                snapshot.jobs[i].state = .failed; snapshot.jobs[i].message = error.localizedDescription; snapshot.jobs[i].finishedAt = Date()
                recordJob(job.id)
                log(.error, error.localizedDescription, job: job.id); persistenceDirty = true
            }
        }
    }

    private func inspected(_ id: UUID, result: Result<MediaInfo, Error>) {
        tasks[id] = nil; controllers[id] = nil
        guard let i = index(id) else { return }
        snapshot.jobs[i].workerPID = nil
        if snapshot.jobs[i].timings == nil { snapshot.jobs[i].timings = JobTimings() }
        if let start = inspectionStarts.removeValue(forKey: id) { snapshot.jobs[i].timings?.inspectionMs = elapsed(start) }
        if snapshot.jobs[i].state != .cancelled {
            switch result {
            case .success(let media): snapshot.jobs[i].media = media; snapshot.jobs[i].state = .ready; snapshot.jobs[i].message = "Ready"
            case .failure(let error): snapshot.jobs[i].state = .failed; snapshot.jobs[i].message = error.localizedDescription; snapshot.jobs[i].finishedAt = Date(); log(.error, error.localizedDescription, job: id)
            }
        }
        recordJob(id)
        persistenceDirty = true; schedule(); publish()
    }

    private func convert(job: ConversionJob, plan: ConversionPlan, tools: ToolPaths, controller: ProcessController) async {
        var failure: String?
        var timings = job.timings ?? JobTimings()
        if let i = index(job.id), let current = snapshot.jobs[i].timings { timings = current }
        var phase = "preparation"
        var phaseStart = ProcessInfo.processInfo.systemUptime
        do {
            try Task.checkCancellation()
            try await Task.detached(priority: .utility) {
                let fm = FileManager.default
                try fm.createDirectory(at: plan.staging.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Staging belongs only to this job. Retrying discards the interrupted partial output.
                if fm.fileExists(atPath: plan.staging.path) { try fm.removeItem(at: plan.staging) }
                let attrs = try fm.attributesOfFileSystem(forPath: plan.staging.deletingLastPathComponent().path)
                if let free = attrs[.systemFreeSize] as? NSNumber, free.int64Value < 100 * 1024 * 1024 {
                    throw ConverterError.message("Less than 100 MB is free on the destination volume.")
                }
            }.value
            timings.preparationMs = elapsed(phaseStart)
            try Task.checkCancellation()
            phase = "encoding"; phaseStart = ProcessInfo.processInfo.systemUptime
            let events = AsyncStream<ProcessEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
            let dropped = DroppedProcessEvents()
            let reader = Task { for await event in events.stream { self.process(event, jobID: job.id, duration: plan.duration) } }
            let result: ProcessResult
            do {
                result = try await ProcessRunner.run(executable: tools.ffmpeg, arguments: plan.arguments, controller: controller) {
                    if case .dropped(let event) = events.continuation.yield($0) {
                        if case .stderrBatch(let lines) = event { dropped.increment(by: lines.count) }
                        else { dropped.increment() }
                    }
                }
            } catch {
                events.continuation.finish(); await reader.value
                snapshot.telemetryDroppedEvents += dropped.count; snapshot.telemetryProcessDrops += dropped.count
                throw error
            }
            events.continuation.finish(); await reader.value
            snapshot.telemetryDroppedEvents += dropped.count; snapshot.telemetryProcessDrops += dropped.count
            timings.encodingMs = elapsed(phaseStart)
            try Task.checkCancellation()
            guard result.status == 0 else { throw ConverterError.message("FFmpeg exited with code \(result.status). \(result.diagnostic.suffix(2500))") }
            phase = "verification"; phaseStart = ProcessInfo.processInfo.systemUptime
            let verified = try await MediaProbe.inspect(plan.staging, tools: tools, controller: controller)
            timings.verificationMs = elapsed(phaseStart); timings.outputBytes = verified.size
            guard verified.size > 0 else { throw ConverterError.message("FFmpeg produced an empty output.") }
            try Task.checkCancellation()
            phase = "commit"; phaseStart = ProcessInfo.processInfo.systemUptime
            // The commit runs on the engine actor without suspension: cancellation cannot race the rename.
            try FileManager.default.moveItem(at: plan.staging, to: plan.output)
            timings.commitMs = elapsed(phaseStart)
        } catch {
            failure = error.localizedDescription
            switch phase {
            case "encoding": timings.encodingMs = elapsed(phaseStart)
            case "verification": timings.verificationMs = elapsed(phaseStart)
            case "commit": timings.commitMs = elapsed(phaseStart)
            default: timings.preparationMs = elapsed(phaseStart)
            }
        }
        if let i = index(job.id) {
            snapshot.jobs[i].timings = timings
            if snapshot.jobs[i].state != .cancelled {
                snapshot.jobs[i].state = failure == nil ? .completed : .failed
                snapshot.jobs[i].message = failure ?? (snapshot.jobs[i].warningCount > 0 ? "Completed with diagnostics · review logs" : "Completed")
                if failure == nil { snapshot.jobs[i].progress.fraction = 1 }
            }
            snapshot.jobs[i].workerPID = nil; snapshot.jobs[i].finishedAt = Date()
            recordJob(job.id)
            log(failure == nil ? .info : .error, snapshot.jobs[i].message, job: job.id)
        }
        let stagingDirectory = plan.staging.deletingLastPathComponent()
        // Failed/cancelled partial files stay available for diagnosis; a successful staging directory is empty.
        if failure == nil { Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: stagingDirectory) } }
        reservedOutputs.remove(plan.output.path); plans[job.id] = nil; tasks[job.id] = nil; controllers[job.id] = nil; parsers[job.id] = nil
        persistenceDirty = true; schedule(); publish()
    }

    private func process(_ event: ProcessEvent, jobID: UUID, duration: Double) {
        guard let i = index(jobID) else { return }
        switch event {
        case .stderrBatch(let lines):
            for line in lines { process(.stderr(line), jobID: jobID, duration: duration) }
        case .started(let pid): snapshot.jobs[i].workerPID = pid; uiDirty = true
            if snapshot.jobs[i].state == .running { snapshot.jobs[i].message = "Converting" }
        case .stdout(let line):
            if let progress = parsers[jobID]?.consume(line, duration: duration) { snapshot.jobs[i].progress = progress; uiDirty = true }
        case .stderr(let line):
            guard !line.isEmpty else { return }
            let lower = line.lowercased()
            let level: LogLevel = lower.contains("error") || lower.contains("invalid") ? .error : .warning
            snapshot.jobs[i].warningCount += 1
            log(level, line, job: jobID)
        }
    }

    private func tick() async {
        guard !shuttingDown else { return }
        let tickStart = ProcessInfo.processInfo.systemUptime
        let previousErrors = [snapshot.persistenceError, snapshot.telemetryError]
        let previousDropped = snapshot.telemetryDroppedEvents
        tickNumber += 1
        if tickNumber % 3 == 0 {
            let pids = controllers.values.compactMap(\.processIdentifier)
            let diskURL = snapshot.jobs.first(where: { $0.state == .running })?.output?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
            // Kernel queries are quick; all samples run on this actor, never on the UI actor.
            let sample = telemetry.sample(pids: pids, diskURL: diskURL)
            snapshot.metrics.append(sample); pendingMetrics.append(sample)
            uiDirty = true
            if pendingMetrics.count > 300 { pendingMetrics.removeFirst(); snapshot.telemetryDroppedEvents += 1 }
            if snapshot.metrics.count > 300 { snapshot.metrics.removeFirst(snapshot.metrics.count - 300) }
        }
        if persistenceDirty && Date().timeIntervalSince(lastPersist) >= 1 {
            persistenceDirty = false; lastPersist = Date()
            let saved = SavedQueue(jobs: snapshot.jobs, concurrency: snapshot.concurrency, toolDirectory: toolDirectory, preventSleep: snapshot.preventSleep)
            if persistenceHealthy {
                do { try await persistence.save(saved); snapshot.persistenceError = nil }
                catch { snapshot.persistenceError = "Queue could not be saved: \(error.localizedDescription)" }
            }
        }
        if !pendingLogs.isEmpty {
            let entries = pendingLogs; pendingLogs.removeAll(keepingCapacity: true)
            do { try await persistence.append(entries) }
            catch { snapshot.persistenceError = "Logs could not be saved: \(error.localizedDescription)" }
            await flushDatabase(logs: entries)
        } else if tickNumber % 3 == 0 {
            await flushDatabase(logs: [])
        }
        recordPerformance(name: "engine_tick", durationMs: elapsed(tickStart))
        if previousErrors != [snapshot.persistenceError, snapshot.telemetryError] || previousDropped != snapshot.telemetryDroppedEvents { uiDirty = true }
        if uiDirty { publish() }
    }

    public func shutdown() async {
        shuttingDown = true
        snapshot.queueRunning = false
        maintenance?.cancel()
        await maintenance?.value
        for controller in controllers.values { controller.cancel() }
        for task in tasks.values { task.cancel() }
        let active = Array(tasks.values)
        for task in active { await task.value }
        ticker?.cancel(); await ticker?.value; ticker = nil
        await logFlushTask?.value; logFlushTask = nil
        if persistenceHealthy { try? await persistence.save(SavedQueue(jobs: snapshot.jobs, concurrency: snapshot.concurrency, toolDirectory: toolDirectory, preventSleep: snapshot.preventSleep)) }
        let remainingLogs = pendingLogs; pendingLogs.removeAll()
        try? await persistence.append(remainingLogs)
        await flushDatabase(logs: remainingLogs)
        if databaseReady {
            do { try await database.finish() }
            catch { snapshot.telemetryError = error.localizedDescription }
            databaseReady = false
        }
        snapshotContinuation.finish()
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }
    }

    public func currentSnapshot() -> EngineSnapshot { snapshot }
    public func recordPerformance(name: String, durationMs: Double, jobID: UUID? = nil, detail: String = "") {
        guard !shuttingDown else { return }
        if pendingOperations.count >= 4096 { pendingOperations.removeFirst(); snapshot.telemetryDroppedEvents += 1 }
        pendingOperations.append(PerformanceEvent(name: name, durationMs: durationMs, jobID: jobID, detail: detail))
    }
    private func elapsed(_ start: Double) -> Double { (ProcessInfo.processInfo.systemUptime - start) * 1000 }
    private func recordJob(_ id: UUID) {
        guard let i = index(id) else { return }
        let attempt = attempts[id, default: 1]
        let key = "\(id.uuidString):\(attempt)"
        if pendingJobs[key] == nil && pendingJobs.count >= 4096, let first = pendingJobs.keys.first {
            pendingJobs.removeValue(forKey: first); snapshot.telemetryDroppedEvents += 1
        }
        pendingJobs[key] = JobRecord(job: snapshot.jobs[i], attempt: attempt)
    }
    private func flushDatabase(logs: [LogEntry]) async {
        guard databaseReady else {
            snapshot.telemetryDroppedEvents += logs.count + pendingJobs.count + pendingMetrics.count + pendingOperations.count
            pendingJobs.removeAll(); pendingMetrics.removeAll(); pendingOperations.removeAll()
            return
        }
        var batch = TelemetryBatch()
        batch.jobs = Array(pendingJobs.values); pendingJobs.removeAll(keepingCapacity: true)
        batch.operations = pendingOperations; pendingOperations.removeAll(keepingCapacity: true)
        batch.metrics = pendingMetrics; pendingMetrics.removeAll(keepingCapacity: true)
        batch.logs = logs
        guard !batch.isEmpty else { return }
        batch.operations.append(PerformanceEvent(name: "telemetry_health", durationMs: 0,
            detail: "{\"dropped_total\":\(snapshot.telemetryDroppedEvents),\"process_stream\":\(snapshot.telemetryProcessDrops),\"pending_log_buffer\":\(snapshot.telemetryLogBufferDrops)}"))
        do {
            let duration = try await database.write(batch)
            snapshot.telemetryError = nil
            recordPerformance(name: "database_flush", durationMs: duration, detail: "jobs=\(batch.jobs.count), logs=\(batch.logs.count), metrics=\(batch.metrics.count), operations=\(batch.operations.count)")
        } catch {
            snapshot.telemetryDroppedEvents += batch.jobs.count + batch.operations.count + batch.metrics.count + batch.logs.count
            snapshot.telemetryError = "Telemetry write failed; conversions continue: \(error.localizedDescription)"
        }
    }
    private func index(_ id: UUID) -> Int? { snapshot.jobs.firstIndex { $0.id == id } }
    private func publish() {
        snapshot.sequence &+= 1; snapshot.publishedAt = Date()
        let shouldKeepAwake = !shuttingDown && snapshot.preventSleep && snapshot.jobs.contains { $0.state == .running }
        if shouldKeepAwake && sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                      IOPMAssertionLevel(kIOPMAssertionLevelOn), "Converting media" as CFString, &sleepAssertion)
        } else if !shouldKeepAwake && sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0
        }
        snapshotContinuation.yield(snapshot)
        uiDirty = false
    }
    private func log(_ level: LogLevel, _ message: String, job: UUID? = nil) {
        let entry = LogEntry(level: level, jobID: job, message: String(message.prefix(8192)))
        uiDirty = true
        snapshot.logs.append(entry); pendingLogs.append(entry)
        if snapshot.logs.count > 2000 { snapshot.logs.removeFirst(snapshot.logs.count - 2000) }
        if pendingLogs.count > 4096 {
            let removed = pendingLogs.count - 4096
            pendingLogs.removeFirst(removed); snapshot.telemetryDroppedEvents += removed
            snapshot.telemetryLogBufferDrops += removed
        }
        if pendingLogs.count >= 512, logFlushTask == nil, !shuttingDown {
            logFlushTask = Task { await self.flushLogBurst() }
        }
    }
    private func flushLogBurst() async {
        while pendingLogs.count >= 512 && !shuttingDown {
            let entries = pendingLogs; pendingLogs.removeAll(keepingCapacity: true)
            do { try await persistence.append(entries) }
            catch { snapshot.persistenceError = "Logs could not be saved: \(error.localizedDescription)"; uiDirty = true }
            await flushDatabase(logs: entries)
        }
        logFlushTask = nil
    }
}

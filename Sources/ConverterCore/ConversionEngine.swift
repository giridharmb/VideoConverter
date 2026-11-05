import Foundation
import IOKit.pwr_mgt

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
    private var sleepAssertion: IOPMAssertionID = 0

    public init(storageDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VideoConverter")) {
        let stream = AsyncStream<EngineSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        snapshots = stream.stream; snapshotContinuation = stream.continuation
        persistence = QueuePersistence(directory: storageDirectory)
    }

    public func handle(_ command: AppCommand) async {
        guard !shuttingDown else { return }
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
                log(.info, "Cancelled", job: id)
            }
        case .pause(let ids):
            for id in ids {
                if let i = index(id), snapshot.jobs[i].state == .running, controllers[id] != nil {
                    controllers[id]?.pause(); snapshot.jobs[i].state = .paused; snapshot.jobs[i].message = "Paused"
                }
            }
        case .resume(let ids):
            for id in ids {
                if let i = index(id), snapshot.jobs[i].state == .paused {
                    controllers[id]?.resume(); snapshot.jobs[i].state = .running; snapshot.jobs[i].message = "Converting"
                }
            }
        case .retry(let ids):
            for id in ids {
                if let i = index(id), [.failed, .cancelled].contains(snapshot.jobs[i].state), tasks[id] == nil {
                    snapshot.jobs[i].state = snapshot.jobs[i].media == nil ? .waiting : .ready
                    snapshot.jobs[i].progress = JobProgress(); snapshot.jobs[i].message = "Ready to retry"
                    snapshot.jobs[i].finishedAt = nil; snapshot.jobs[i].startedAt = nil; snapshot.jobs[i].output = nil
                    snapshot.jobs[i].warningCount = 0
                }
            }
        case .apply(let ids, let settings):
            for id in ids {
                if let i = index(id), !snapshot.jobs[i].state.isActive, snapshot.jobs[i].state != .completed, tasks[id] == nil {
                    snapshot.jobs[i].settings = settings
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
            snapshot.jobs.append(ConversionJob(input: url, settings: settings)); added += 1
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
            do {
                let plan = try CommandBuilder.make(job: job, reserved: reservedOutputs)
                reservedOutputs.insert(plan.output.path); plans[job.id] = plan; active += 1
                snapshot.jobs[i].output = plan.output; snapshot.jobs[i].command = [tools.ffmpeg.path] + plan.arguments
                snapshot.jobs[i].state = .running; snapshot.jobs[i].message = "Preparing conversion"
                snapshot.jobs[i].startedAt = Date()
                let controller = ProcessController(); controllers[job.id] = controller; parsers[job.id] = ProgressParser()
                log(.info, CommandBuilder.display([tools.ffmpeg.path] + plan.arguments), job: job.id)
                tasks[job.id] = Task { await self.convert(job: job, plan: plan, tools: tools, controller: controller) }
            } catch {
                snapshot.jobs[i].state = .failed; snapshot.jobs[i].message = error.localizedDescription; snapshot.jobs[i].finishedAt = Date()
                log(.error, error.localizedDescription, job: job.id); persistenceDirty = true
            }
        }
    }

    private func inspected(_ id: UUID, result: Result<MediaInfo, Error>) {
        tasks[id] = nil; controllers[id] = nil
        guard let i = index(id) else { return }
        snapshot.jobs[i].workerPID = nil
        if snapshot.jobs[i].state != .cancelled {
            switch result {
            case .success(let media): snapshot.jobs[i].media = media; snapshot.jobs[i].state = .ready; snapshot.jobs[i].message = "Ready"
            case .failure(let error): snapshot.jobs[i].state = .failed; snapshot.jobs[i].message = error.localizedDescription; snapshot.jobs[i].finishedAt = Date(); log(.error, error.localizedDescription, job: id)
            }
        }
        persistenceDirty = true; schedule(); publish()
    }

    private func convert(job: ConversionJob, plan: ConversionPlan, tools: ToolPaths, controller: ProcessController) async {
        var failure: String?
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
            try Task.checkCancellation()
            let events = AsyncStream<ProcessEvent>.makeStream(bufferingPolicy: .bufferingNewest(2000))
            let reader = Task { for await event in events.stream { self.process(event, jobID: job.id, duration: plan.duration) } }
            let result: ProcessResult
            do {
                result = try await ProcessRunner.run(executable: tools.ffmpeg, arguments: plan.arguments, controller: controller) { events.continuation.yield($0) }
            } catch {
                events.continuation.finish(); await reader.value; throw error
            }
            events.continuation.finish(); await reader.value
            try Task.checkCancellation()
            guard result.status == 0 else { throw ConverterError.message("FFmpeg exited with code \(result.status). \(result.diagnostic.suffix(2500))") }
            let verified = try await MediaProbe.inspect(plan.staging, tools: tools, controller: controller)
            guard verified.size > 0 else { throw ConverterError.message("FFmpeg produced an empty output.") }
            try Task.checkCancellation()
            // The commit runs on the engine actor without suspension: cancellation cannot race the rename.
            try FileManager.default.moveItem(at: plan.staging, to: plan.output)
        } catch { failure = error.localizedDescription }
        if let i = index(job.id) {
            if snapshot.jobs[i].state != .cancelled {
                snapshot.jobs[i].state = failure == nil ? .completed : .failed
                snapshot.jobs[i].message = failure ?? (snapshot.jobs[i].warningCount > 0 ? "Completed with diagnostics · review logs" : "Completed")
                if failure == nil { snapshot.jobs[i].progress.fraction = 1 }
            }
            snapshot.jobs[i].workerPID = nil; snapshot.jobs[i].finishedAt = Date()
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
        case .started(let pid): snapshot.jobs[i].workerPID = pid
            if snapshot.jobs[i].state == .running { snapshot.jobs[i].message = "Converting" }
        case .stdout(let line):
            if let progress = parsers[jobID]?.consume(line, duration: duration) { snapshot.jobs[i].progress = progress }
        case .stderr(let line):
            guard !line.isEmpty else { return }
            let lower = line.lowercased()
            let level: LogLevel = lower.contains("error") || lower.contains("invalid") ? .error : .warning
            snapshot.jobs[i].warningCount += 1
            log(level, line, job: jobID)
        }
    }

    private func tick() async {
        tickNumber += 1
        if tickNumber % 3 == 0 {
            let pids = controllers.values.compactMap(\.processIdentifier)
            let diskURL = snapshot.jobs.first(where: { $0.state == .running })?.output?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
            // Kernel queries are quick; all samples run on this actor, never on the UI actor.
            snapshot.metrics.append(telemetry.sample(pids: pids, diskURL: diskURL))
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
        }
        publish()
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
        ticker?.cancel(); ticker = nil
        if persistenceHealthy { try? await persistence.save(SavedQueue(jobs: snapshot.jobs, concurrency: snapshot.concurrency, toolDirectory: toolDirectory, preventSleep: snapshot.preventSleep)) }
        try? await persistence.append(pendingLogs); pendingLogs.removeAll()
        snapshotContinuation.finish()
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }
    }

    public func currentSnapshot() -> EngineSnapshot { snapshot }
    private func index(_ id: UUID) -> Int? { snapshot.jobs.firstIndex { $0.id == id } }
    private func publish() {
        let shouldKeepAwake = !shuttingDown && snapshot.preventSleep && snapshot.jobs.contains { $0.state == .running }
        if shouldKeepAwake && sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                      IOPMAssertionLevel(kIOPMAssertionLevelOn), "Converting media" as CFString, &sleepAssertion)
        } else if !shouldKeepAwake && sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0
        }
        snapshotContinuation.yield(snapshot)
    }
    private func log(_ level: LogLevel, _ message: String, job: UUID? = nil) {
        let entry = LogEntry(level: level, jobID: job, message: String(message.prefix(8192)))
        snapshot.logs.append(entry); pendingLogs.append(entry)
        if snapshot.logs.count > 2000 { snapshot.logs.removeFirst(snapshot.logs.count - 2000) }
        if pendingLogs.count > 2000 { pendingLogs.removeFirst(pendingLogs.count - 2000) }
    }
}

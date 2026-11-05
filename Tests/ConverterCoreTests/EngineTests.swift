import XCTest
import Darwin
@testable import ConverterCore

final class EngineTests: XCTestCase, @unchecked Sendable {
    private final class PipeLines: @unchecked Sendable {
        private let lock = NSLock()
        private var output: [String] = [], errors: [String] = []
        func append(_ event: ProcessEvent) {
            lock.withLock {
                switch event {
                case .stdout(let line): output.append(line)
                case .stderr(let line): errors.append(line)
                case .stderrBatch(let lines): errors.append(contentsOf: lines)
                case .started: break
                }
            }
        }
        var values: ([String], [String]) { lock.withLock { (output, errors) } }
    }
    func testConcurrentPipesPreserveBatchedDiagnosticLinesAndTrailingData() async throws {
        let lines = PipeLines()
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/awk"), arguments: [
            "BEGIN { for(i=1;i<=5000;i++){print i; print i > \"/dev/stderr\"} printf \"tail\"; printf \"tail\" > \"/dev/stderr\" }"
        ]) { lines.append($0) }
        XCTAssertEqual(result.status, 0)
        let expected = (1...5000).map(String.init) + ["tail"]
        let (output, errors) = lines.values
        XCTAssertEqual(output, expected); XCTAssertEqual(errors, expected)
        XCTAssertTrue(result.diagnostic.hasSuffix("5000\ntail"))
    }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VideoConverterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func tools() throws -> ToolPaths {
        do { return try ToolPaths.discover(directory: ProcessInfo.processInfo.environment["FFMPEG_TEST_DIRECTORY"] ?? "") }
        catch { throw XCTSkip("Install FFmpeg to run media integration tests.") }
    }
    private func fixture(at url: URL, tools: ToolPaths, duration: Double = 2) async throws {
        let result = try await ProcessRunner.run(executable: tools.ffmpeg, arguments: [
            "-hide_banner", "-v", "error", "-nostdin", "-n", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", String(duration), "-c:v", "mpeg4", "-c:a", "aac", "-shortest", url.path
        ])
        XCTAssertEqual(result.status, 0, result.diagnostic)
    }
    private func engine(storage: URL) async -> ConversionEngine {
        let engine = ConversionEngine(storageDirectory: storage)
        await engine.handle(.initialize)
        if let directory = ProcessInfo.processInfo.environment["FFMPEG_TEST_DIRECTORY"] {
            await engine.handle(.setTools(directory))
        }
        return engine
    }
    private func wait(_ engine: ConversionEngine, timeout: Double = 20, until predicate: @Sendable (EngineSnapshot) -> Bool) async throws -> EngineSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = await engine.currentSnapshot()
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(30))
        }
        let last = await engine.currentSnapshot()
        XCTFail("Timed out. Jobs: \(last.jobs.map { "\($0.state): \($0.message)" })")
        throw ConverterError.message("Test timed out")
    }
    func testPersistenceRoundTripAndUnsupportedVersion() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = QueuePersistence(directory: directory)
        let saved = SavedQueue(jobs: [ConversionJob(input: directory.appendingPathComponent("one.mkv"), settings: .init())], concurrency: 3, toolDirectory: "")
        try await persistence.save(saved)
        let loaded = try await persistence.load()
        XCTAssertEqual(loaded?.jobs.first?.id, saved.jobs.first?.id); XCTAssertEqual(loaded?.concurrency, 3)
        try Data("{\"version\":999,\"jobs\":[],\"concurrency\":2,\"toolDirectory\":\"\"}".utf8).write(to: directory.appendingPathComponent("queue.json"))
        do { _ = try await persistence.load(); XCTFail("Expected unsupported version") } catch {}
    }
    func testCancellationTerminatesPausedProcess() async throws {
        let controller = ProcessController()
        let started = Date()
        let task = Task { try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], controller: controller) }
        try await Task.sleep(for: .milliseconds(200))
        controller.pause(); controller.cancel()
        _ = try await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
    func testPauseRequestedBeforeLaunchIsPreserved() async throws {
        let controller = ProcessController(); controller.pause()
        let started = Date()
        let task = Task {
            _ = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["0.1"], controller: controller)
            return Date()
        }
        try await Task.sleep(for: .milliseconds(300)); controller.resume()
        let ended = try await task.value
        XCTAssertGreaterThan(ended.timeIntervalSince(started), 0.25)
    }
    func testProbeTimeoutReapsWorker() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("slow-probe")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let controller = ProcessController(), started = Date()
        do {
            _ = try await MediaProbe.inspect(script, tools: ToolPaths(ffmpeg: script, ffprobe: script), controller: controller, timeout: .milliseconds(100))
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertNil(controller.processIdentifier); XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }
    func testTelemetrySamplesCurrentProcessWithoutInventedCounters() throws {
        var sampler = TelemetrySampler()
        _ = sampler.sample(pids: [], diskURL: FileManager.default.temporaryDirectory)
        let sample = sampler.sample(pids: [], diskURL: FileManager.default.temporaryDirectory)
        XCTAssertGreaterThan(sample.appMemory, 0); XCTAssertGreaterThan(sample.threads, 0)
        XCTAssertEqual(sample.workerCPU, 0); XCTAssertEqual(sample.activeWorkers, 0)
        XCTAssertGreaterThan(sample.availableDisk, 0); XCTAssertEqual(sample.unavailableProcesses, 0)
    }
    func testCPUSampleAgreesWithIndependentGetrusageClock() {
        func cpuSeconds(_ usage: rusage) -> Double {
            Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        var sampler = TelemetrySampler(), before = rusage(), after = rusage()
        let directory = FileManager.default.temporaryDirectory
        _ = sampler.sample(pids: [], diskURL: directory)
        getrusage(RUSAGE_SELF, &before)
        let start = ProcessInfo.processInfo.systemUptime
        var checksum = 0.0
        repeat {
            for value in 1...1000 { checksum += sqrt(Double(value)) }
        } while ProcessInfo.processInfo.systemUptime - start < 0.15
        let sample = sampler.sample(pids: [], diskURL: directory)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        getrusage(RUSAGE_SELF, &after)
        let reference = (cpuSeconds(after) - cpuSeconds(before)) / elapsed * 100
        XCTAssertGreaterThan(checksum, 0); XCTAssertGreaterThan(reference, 0)
        XCTAssertEqual(sample.appCPU / reference, 1, accuracy: 0.3, "CPU Mach tick conversion must match getrusage's independent microsecond clock")
    }
    func testRealVideoAndAudioConversionContinuesAfterInvalidInput() async throws {
        let tools = try tools(), directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input with ' quote.mkv")
        try await fixture(at: input, tools: tools)
        let invalid = directory.appendingPathComponent("broken.bin")
        try Data("not media".utf8).write(to: invalid)
        let engine = await engine(storage: directory.appendingPathComponent("state"))
        var settings = ConversionSettings(); settings.outputDirectory = directory.path
        await engine.handle(.add([invalid, input, input], settings))
        await engine.handle(.start)
        let end = try await wait(engine) { $0.jobs.count == 2 && $0.jobs.allSatisfy { $0.state.isTerminal } }
        XCTAssertEqual(end.jobs.filter { $0.state == .failed }.count, 1)
        let completed = try XCTUnwrap(end.jobs.first { $0.state == .completed })
        let output = try XCTUnwrap(completed.output)
        let info = try await MediaProbe.inspect(output, tools: tools, controller: ProcessController())
        XCTAssertTrue(info.hasVideo); XCTAssertTrue(info.hasAudio); XCTAssertEqual(completed.progress.fraction, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
        await engine.shutdown()

        let audioEngine = await self.engine(storage: directory.appendingPathComponent("audio-state"))
        var audio = ConversionPreset.audio.settings; audio.startSeconds = 0.5; audio.durationSeconds = 1
        await audioEngine.handle(.add([input], audio)); await audioEngine.handle(.start)
        let audioEnd = try await wait(audioEngine) { $0.jobs.count == 1 && $0.jobs[0].state.isTerminal }
        XCTAssertEqual(audioEnd.jobs[0].state, .completed, audioEnd.jobs[0].message)
        let audioURL = try XCTUnwrap(audioEnd.jobs[0].output)
        let audioInfo = try await MediaProbe.inspect(audioURL, tools: tools, controller: ProcessController())
        XCTAssertTrue(audioInfo.hasAudio); XCTAssertFalse(audioInfo.hasVideo)
        XCTAssertLessThan(audioInfo.duration, 1.2)
        await audioEngine.shutdown()
    }
    func testParallelLimitStopSchedulingPauseCancelAndRetry() async throws {
        let tools = try tools(), directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputs = (0..<3).map { directory.appendingPathComponent("input-\($0).mkv") }
        try await fixture(at: inputs[0], tools: tools, duration: 4)
        for url in inputs.dropFirst() { try FileManager.default.copyItem(at: inputs[0], to: url) }
        let engine = await engine(storage: directory.appendingPathComponent("state"))
        await engine.handle(.setConcurrency(2))
        var settings = ConversionSettings(); settings.extraInputArguments = "[\"-re\"]"
        await engine.handle(.add(inputs, settings))
        let ready = try await wait(engine) { $0.jobs.count == 3 && $0.jobs.allSatisfy { $0.state == .ready } }
        XCTAssertFalse(ready.queueRunning)
        await engine.handle(.start)
        let running = try await wait(engine) { $0.jobs.filter { $0.state == .running && $0.workerPID != nil }.count == 2 }
        XCTAssertEqual(running.jobs.filter { $0.state == .ready }.count, 1)
        await engine.handle(.stopScheduling)
        let id = running.jobs.first { $0.state == .running }!.id
        await engine.handle(.pause([id]))
        let paused = await engine.currentSnapshot()
        XCTAssertEqual(paused.jobs.first { $0.id == id }?.state, .paused)
        await engine.handle(.resume([id])); await engine.handle(.pause([id])); await engine.handle(.cancel([id]))
        _ = try await wait(engine) { $0.jobs.first { $0.id == id }?.workerPID == nil }
        await engine.handle(.apply([id], ConversionSettings()))
        await engine.handle(.retry([id]))
        let retried = await engine.currentSnapshot()
        XCTAssertEqual(retried.jobs.first { $0.id == id }?.state, .ready)
        await engine.handle(.start)
        let end = try await wait(engine) { $0.jobs.allSatisfy { $0.state.isTerminal } }
        XCTAssertTrue(end.jobs.allSatisfy { $0.state == .completed }, "\(end.jobs.map(\.message))")
        await engine.shutdown()
    }
    func testParallelOutputCollisionAndExistingFileArePreserved() async throws {
        let tools = try tools(), directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("a"), b = directory.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let first = a.appendingPathComponent("same.mkv"), second = b.appendingPathComponent("same.mkv")
        try await fixture(at: first, tools: tools)
        try FileManager.default.copyItem(at: first, to: second)
        let existing = directory.appendingPathComponent("same_converted.mp4")
        let sentinel = Data("preserve existing".utf8); try sentinel.write(to: existing)
        var settings = ConversionSettings(); settings.outputDirectory = directory.path
        let engine = await engine(storage: directory.appendingPathComponent("state"))
        await engine.handle(.add([first, second], settings)); await engine.handle(.start)
        let end = try await wait(engine) { $0.jobs.count == 2 && $0.jobs.allSatisfy { $0.state.isTerminal } }
        XCTAssertTrue(end.jobs.allSatisfy { $0.state == .completed }, "\(end.jobs.map(\.message))")
        XCTAssertEqual(Set(end.jobs.compactMap(\.output)).count, 2)
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        await engine.shutdown()
    }
    func testInterruptedQueueRestoresSafelyWithoutAutoStart() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var job = ConversionJob(input: directory.appendingPathComponent("missing.mov"), settings: .init())
        job.state = .running; job.workerPID = 12345
        let persistence = QueuePersistence(directory: directory)
        try await persistence.save(SavedQueue(jobs: [job], concurrency: 2, toolDirectory: ""))
        let engine = ConversionEngine(storageDirectory: directory)
        await engine.handle(.initialize)
        let restored = await engine.currentSnapshot()
        XCTAssertFalse(restored.queueRunning); XCTAssertEqual(restored.jobs.first?.state, .failed); XCTAssertNil(restored.jobs.first?.workerPID)
        await engine.shutdown()
    }
    func testDatabaseFailureDoesNotStopConversionAndTimingsAreCaptured() async throws {
        let tools = try tools(), directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.mkv")
        try await fixture(at: input, tools: tools)
        let blocked = directory.appendingPathComponent("not-a-database")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let engine = ConversionEngine(storageDirectory: directory.appendingPathComponent("state"), telemetryDatabaseURL: blocked)
        await engine.handle(.initialize)
        await engine.handle(.add([input], .init())); await engine.handle(.start)
        let final = try await wait(engine) { $0.jobs.count == 1 && $0.jobs[0].state.isTerminal }
        XCTAssertEqual(final.jobs[0].state, .completed, final.jobs[0].message)
        XCTAssertNotNil(final.telemetryError)
        let timing = try XCTUnwrap(final.jobs[0].timings)
        XCTAssertGreaterThan(timing.inspectionMs, 0); XCTAssertGreaterThan(timing.encodingMs, 0)
        XCTAssertGreaterThan(timing.verificationMs, 0); XCTAssertGreaterThan(timing.outputBytes, 0)
        await engine.shutdown()
    }
    func testOldQueueWithoutTimingsStillDecodes() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let queue = SavedQueue(jobs: [ConversionJob(input: directory.appendingPathComponent("one.mkv"), settings: .init())], concurrency: 2, toolDirectory: "")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(queue)) as? [String: Any])
        var jobs = try XCTUnwrap(json["jobs"] as? [[String: Any]])
        jobs[0].removeValue(forKey: "timings"); json["jobs"] = jobs
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("queue.json"))
        let store = QueuePersistence(directory: directory)
        let loaded = try await store.load()
        XCTAssertEqual(loaded?.jobs.count, 1); XCTAssertNil(loaded?.jobs[0].timings)
    }
}

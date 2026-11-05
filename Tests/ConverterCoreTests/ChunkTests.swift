import XCTest
import Darwin
@testable import ConverterCore

final class ChunkTests: XCTestCase, @unchecked Sendable {
    private func job() -> ConversionJob {
        var job = ConversionJob(input: URL(fileURLWithPath: "/tmp/source ' with spaces.mp4"), settings: .init())
        job.settings.chunking = ChunkSettings(workers: 4, seconds: 2)
        job.media = MediaInfo(duration: 20, size: 1000, format: "mp4", streams: [
            MediaStream(index: 0, codec: "h264", kind: "video", frameRate: "30/1", durationSeconds: 20, frameCount: 600),
            MediaStream(index: 1, codec: "aac", kind: "audio")])
        return job
    }
    func testFrameAlignedPlanAndSharedWorkerBudget() throws {
        var job = job(); job.settings.startSeconds = 5; job.settings.durationSeconds = 7.5
        let plan = try CommandBuilder.make(job: job, workerLimit: 3)
        let chunks = try XCTUnwrap(plan.chunks)
        XCTAssertEqual(chunks.workers, 3); XCTAssertEqual(plan.workerSlots, 3)
        XCTAssertEqual(chunks.segments.map(\.frames), [60, 60, 60, 45])
        XCTAssertEqual(chunks.totalFrames, 225); XCTAssertEqual(plan.duration, 7.5)
        for segment in chunks.segments {
            XCTAssertTrue(segment.arguments.contains("-an")); XCTAssertTrue(segment.arguments.contains("-frames:v"))
            XCTAssertEqual(segment.arguments.last, segment.output.path)
            XCTAssertFalse(segment.arguments.contains("-t"))
        }
        XCTAssertTrue(chunks.joinArguments.contains("1:a:0?"))
        XCTAssertTrue(chunks.manifest.contains("file 'video-00000.mp4'")); XCTAssertFalse(chunks.manifest.contains("/tmp/"))
        XCTAssertEqual(try CommandBuilder.make(job: job, workerLimit: 1).workerSlots, 1)
    }
    func testUnsafeOrUnsupportedChunkCombinationsAreRejected() {
        var values: [ConversionJob] = []
        var j = job(); j.settings.videoCodec = "copy"; values.append(j)
        j = job(); j.settings.audioCodec = "copy"; values.append(j)
        j = job(); j.settings.subtitles = true; values.append(j)
        j = job(); j.settings.deinterlace = true; values.append(j)
        j = job(); j.settings.videoFilter = "reverse"; values.append(j)
        j = job(); j.settings.extraInputArguments = "[\"-re\"]"; values.append(j)
        j = job(); j.settings.format = .webm; values.append(j)
        j = job(); j.settings.format = .mp3; values.append(j)
        j = job(); j.settings.chunking?.seconds = .nan; values.append(j)
        j = job(); j.settings.chunking?.workers = 9; values.append(j)
        j = job(); j.media?.streams[0].frameRate = "0/0"; values.append(j)
        j = job(); j.settings.frameRate = "1/0"; values.append(j)
        j = job(); j.settings.frameRate = "nan"; values.append(j)
        j = job(); j.media?.startTime = 0; j.media?.streams[0].startTime = 2; values.append(j)
        j = job(); j.media?.streams[0].nominalFrameRate = "60/1"; values.append(j)
        j = job(); j.media?.streams[0].frameCount = nil; j.media?.streams[0].durationSeconds = 100_000
        j.settings.chunking?.seconds = 1; values.append(j)
        for value in values { XCTAssertThrowsError(try CommandBuilder.make(job: value)) }
    }
    func testOldSettingsDecodeWithoutChunking() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ConversionSettings())) as? [String: Any])
        json.removeValue(forKey: "chunking")
        XCTAssertNil(try JSONDecoder().decode(ConversionSettings.self, from: JSONSerialization.data(withJSONObject: json)).chunking)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job())) as? [String: Any])
        old.removeValue(forKey: "chunkProgress"); old.removeValue(forKey: "workerPIDs")
        var media = try XCTUnwrap(old["media"] as? [String: Any])
        media.removeValue(forKey: "startTime")
        var streams = try XCTUnwrap(media["streams"] as? [[String: Any]])
        for i in streams.indices {
            for key in ["durationSeconds", "frameCount", "startTime", "nominalFrameRate"] { streams[i].removeValue(forKey: key) }
        }
        media["streams"] = streams; old["media"] = media
        let restored = try JSONDecoder().decode(ConversionJob.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(restored.chunkProgress); XCTAssertNil(restored.media?.streams[0].frameCount)
    }
    private func tools() throws -> ToolPaths {
        do { return try ToolPaths.discover(directory: ProcessInfo.processInfo.environment["FFMPEG_TEST_DIRECTORY"] ?? "") }
        catch { throw XCTSkip("Install FFmpeg for chunk integration tests.") }
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Chunk tests ' \(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func fixture(_ url: URL, tools: ToolPaths, rate: String = "30000/1001", duration: Double = 6.5, size: String = "320x180") async throws {
        let result = try await ProcessRunner.run(executable: tools.ffmpeg, arguments: ["-v", "error", "-nostdin", "-n", "-f", "lavfi", "-i",
            "testsrc2=size=\(size):rate=\(rate)", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", String(duration),
            "-c:v", "libx264", "-preset", "ultrafast", "-crf", "0", "-threads", "2", "-c:a", "aac", url.path])
        XCTAssertEqual(result.status, 0, result.diagnostic)
    }
    private func wait(_ engine: ConversionEngine, timeout: Double = 30, until predicate: @Sendable (EngineSnapshot) -> Bool) async throws -> EngineSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = await engine.currentSnapshot()
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(20))
        }
        let last = await engine.currentSnapshot()
        XCTFail("Timed out: \(last.jobs.map { "\($0.state): \($0.message)" })")
        throw ConverterError.message("Test timeout")
    }
    private func engine(_ root: URL) async -> ConversionEngine {
        let engine = ConversionEngine(storageDirectory: root.appendingPathComponent("state"))
        await engine.handle(.initialize)
        if let path = ProcessInfo.processInfo.environment["FFMPEG_TEST_DIRECTORY"] { await engine.handle(.setTools(path)) }
        await engine.handle(.setConcurrency(2))
        return engine
    }
    private func hashes(_ input: URL, tools: ToolPaths, audio: Bool = false) async throws -> [String] {
        let args = ["-v", "error", "-i", input.path, "-map", audio ? "0:a:0" : "0:v:0"]
            + (audio ? ["-c:a", "pcm_s16le", "-f", "hash", "-hash", "sha256", "-"] : ["-fps_mode", "passthrough", "-f", "framemd5", "-"])
        let result = try await ProcessRunner.run(executable: tools.ffmpeg, arguments: args)
        XCTAssertEqual(result.status, 0, result.diagnostic)
        return String(decoding: result.output, as: UTF8.self).split(separator: "\n").filter { !$0.hasPrefix("#") }
            .map { $0.split(separator: ",").last!.trimmingCharacters(in: .whitespaces) }
    }
    func testRationalRateChunksPreserveEveryFrameAndContinuousAudio() async throws {
        try await compareLossless(trimStart: 0, trimDuration: 0)
        try await compareLossless(trimStart: 0.51, trimDuration: 3.2)
    }
    private func compareLossless(trimStart: Double, trimDuration: Double) async throws {
        let tools = try tools(), root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source ' name.mp4"); try await fixture(input, tools: tools)
        var settings = ConversionSettings(); settings.chunking = ChunkSettings(workers: 4, seconds: 1)
        settings.startSeconds = trimStart; settings.durationSeconds = trimDuration
        settings.quality = 0; settings.encoderPreset = "ultrafast"
        let engine = await engine(root)
        await engine.handle(.add([input], settings)); await engine.handle(.start)
        let end = try await wait(engine) { $0.jobs.count == 1 && $0.jobs[0].state.isTerminal }
        let result = end.jobs[0]
        XCTAssertEqual(result.state, .completed, result.message)
        let output = try XCTUnwrap(result.output), media = try XCTUnwrap(result.media)
        let plan = try CommandBuilder.make(job: result)
        let chunks = try XCTUnwrap(plan.chunks)
        XCTAssertEqual(result.chunkProgress?.workers, 2)
        XCTAssertEqual(result.chunkProgress?.completed, chunks.segments.count)
        let sourceHashes = try await hashes(input, tools: tools)
        let actualHashes = try await hashes(output, tools: tools)
        let first = Int(ceil(trimStart * chunks.frameRate - 0.000001))
        XCTAssertEqual(actualHashes, Array(sourceHashes[first..<(first + Int(chunks.totalFrames))]), "No lost, repeated or reordered frames at rational-rate chunk boundaries")
        var reference = ConversionJob(input: input, settings: settings)
        reference.media = media; reference.settings.chunking = nil; reference.settings.format = .m4a
        reference.settings.startSeconds = Double(first) / chunks.frameRate; reference.settings.durationSeconds = chunks.duration
        let audioPlan = try CommandBuilder.make(job: reference)
        try FileManager.default.createDirectory(at: audioPlan.staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        let audio = try await ProcessRunner.run(executable: tools.ffmpeg, arguments: audioPlan.arguments)
        XCTAssertEqual(audio.status, 0, audio.diagnostic)
        let audioHashes = try await hashes(output, tools: tools, audio: true)
        let referenceHashes = try await hashes(audioPlan.staging, tools: tools, audio: true)
        XCTAssertEqual(audioHashes, referenceHashes, "Chunking must not add per-chunk audio padding or gaps")
        XCTAssertEqual(result.progress.fraction, 1); XCTAssertTrue(result.workerPIDs?.isEmpty ?? true)
        await engine.shutdown()
    }
    func testHEVCAlternateContainersAndMutedOutput() async throws {
        let tools = try tools(), root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.mp4"); try await fixture(input, tools: tools, rate: "30", duration: 3)
        let engine = await engine(root)
        var settings = ConversionSettings(); settings.videoCodec = "libx265"; settings.encoderPreset = "ultrafast"
        settings.chunking = ChunkSettings(workers: 2, seconds: 1); settings.mute = true
        await engine.handle(.add([input], settings))
        let ready = try await wait(engine) { $0.jobs.count == 1 && $0.jobs[0].state == .ready }
        for format: OutputFormat in [.mkv, .mov] { settings.format = format; await engine.handle(.duplicate([ready.jobs[0].id], settings)) }
        await engine.handle(.start)
        let end = try await wait(engine) { $0.jobs.count == 3 && $0.jobs.allSatisfy { $0.state.isTerminal } }
        for job in end.jobs {
            XCTAssertEqual(job.state, .completed, job.message)
            if job.state == .completed, let output = job.output {
                let media = try await MediaProbe.inspect(output, tools: tools, controller: ProcessController())
                XCTAssertTrue(media.hasVideo); XCTAssertFalse(media.hasAudio)
                XCTAssertEqual(media.duration, 3, accuracy: 0.08)
            }
        }
        await engine.shutdown()
    }
    func testChunkFailureStopsJoinButOtherJobsContinue() async throws {
        let tools = try tools(), root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.mp4"); try await fixture(input, tools: tools, rate: "30", duration: 3)
        let engine = await engine(root)
        var bad = ConversionSettings(); bad.chunking = ChunkSettings(workers: 2, seconds: 1); bad.encoderPreset = "invalid-preset"; bad.suffix = "_failedchunk"
        await engine.handle(.add([input], bad))
        let ready = try await wait(engine) { $0.jobs.count == 1 && $0.jobs[0].state == .ready }
        await engine.handle(.duplicate([ready.jobs[0].id], .init())); await engine.handle(.start)
        let end = try await wait(engine) { $0.jobs.count == 2 && $0.jobs.allSatisfy { $0.state.isTerminal } }
        XCTAssertEqual(end.jobs[0].state, .failed); XCTAssertEqual(end.jobs[1].state, .completed, end.jobs[1].message)
        XCTAssertTrue(end.jobs[0].chunkProgress?.segments.contains { $0.state == .failed } ?? false)
        if let output = end.jobs[0].output { XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)) }
        await engine.shutdown()
    }
    func testSharedBudgetPauseCancelAndRetryReapEveryChunkWorker() async throws {
        let tools = try tools(), root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.mp4"); try await fixture(input, tools: tools, rate: "30", duration: 8, size: "1280x720")
        let engine = await engine(root)
        var settings = ConversionSettings(); settings.videoCodec = "libx265"; settings.encoderPreset = "slow"
        settings.chunking = ChunkSettings(workers: 4, seconds: 2)
        await engine.handle(.add([input], settings))
        let ready = try await wait(engine) { $0.jobs.count == 1 && $0.jobs[0].state == .ready }
        let id = ready.jobs[0].id
        await engine.handle(.duplicate([id], .init())); await engine.handle(.start)
        let running = try await wait(engine) { $0.jobs[0].workerPIDs?.count == 2 }
        XCTAssertEqual(running.jobs[0].chunkProgress?.workers, 2); XCTAssertEqual(running.jobs[1].state, .ready)
        let pids = try XCTUnwrap(running.jobs[0].workerPIDs)
        await engine.handle(.pause([id])); await engine.handle(.stopScheduling)
        var sampler = TelemetrySampler()
        _ = sampler.sample(pids: pids, diskURL: root)
        try await Task.sleep(for: .milliseconds(250))
        let usage = sampler.sample(pids: pids, diskURL: root)
        XCTAssertLessThan(usage.workerCPU, 10, "All chunk processes must stop during pause")
        let paused = await engine.currentSnapshot()
        XCTAssertEqual(paused.jobs[0].state, .paused); XCTAssertEqual(paused.jobs[1].state, .ready)
        await engine.handle(.cancel([id]))
        _ = try await wait(engine) { $0.jobs[0].state == .cancelled && ($0.jobs[0].workerPIDs?.isEmpty ?? true) }
        for pid in pids { XCTAssertEqual(kill(pid, 0), -1, "Cancelled chunk workers must be reaped") }
        settings.videoCodec = "libx264"; settings.encoderPreset = "ultrafast"
        await engine.handle(.apply([id], settings)); await engine.handle(.retry([id])); await engine.handle(.start)
        let end = try await wait(engine) { $0.jobs.allSatisfy { $0.state.isTerminal } }
        XCTAssertTrue(end.jobs.allSatisfy { $0.state == .completed }, "\(end.jobs.map(\.message))")
        XCTAssertEqual(end.jobs[0].chunkProgress?.completed, 4)
        await engine.shutdown()
    }
    func testProbeTimeoutDoesNotRunWhileWorkerIsPaused() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("probe")
        try Data("#!/bin/sh\nprintf '%s' '{\"streams\":[{\"index\":0,\"codec_type\":\"video\"}]}'\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let controller = ProcessController(); controller.pause()
        let task = Task { try await MediaProbe.inspect(script, tools: ToolPaths(ffmpeg: script, ffprobe: script), controller: controller, timeout: .seconds(1)) }
        try await Task.sleep(for: .milliseconds(1300)); controller.resume()
        let media = try await task.value
        XCTAssertTrue(media.hasVideo)
    }
    func testTrimmedChunkOutputPreservesMetadataAndChapterOffsets() async throws {
        let tools = try tools(), root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("raw.mp4"); try await fixture(raw, tools: tools, rate: "30", duration: 5)
        let metadata = root.appendingPathComponent("chapters.txt")
        try Data(";FFMETADATA1\ntitle=Chunk chapter test\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=2000\ntitle=Opening\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=2000\nEND=5000\ntitle=Ending\n".utf8).write(to: metadata)
        let input = root.appendingPathComponent("input.mp4")
        let attached = try await ProcessRunner.run(executable: tools.ffmpeg, arguments: ["-v", "error", "-n", "-i", raw.path, "-f", "ffmetadata", "-i", metadata.path,
            "-map", "0", "-map_metadata", "1", "-map_chapters", "1", "-c", "copy", input.path])
        XCTAssertEqual(attached.status, 0, attached.diagnostic)
        let engine = await engine(root)
        var settings = ConversionSettings(); settings.chunking = ChunkSettings(workers: 2, seconds: 1)
        settings.startSeconds = 1; settings.durationSeconds = 3
        await engine.handle(.add([input], settings)); await engine.handle(.start)
        let end = try await wait(engine) { $0.jobs.count == 1 && $0.jobs[0].state.isTerminal }
        XCTAssertEqual(end.jobs[0].state, .completed, end.jobs[0].message)
        let output = try XCTUnwrap(end.jobs[0].output)
        let probe = try await ProcessRunner.run(executable: tools.ffprobe, arguments: ["-v", "error", "-show_chapters", "-show_format", "-of", "json", output.path])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: probe.output) as? [String: Any])
        let format = try XCTUnwrap(json["format"] as? [String: Any])
        XCTAssertEqual((format["tags"] as? [String: String])?["title"], "Chunk chapter test")
        let chapters = try XCTUnwrap(json["chapters"] as? [[String: Any]])
        XCTAssertEqual(chapters.count, 2)
        if chapters.count == 2 {
            XCTAssertEqual(Double(chapters[0]["start_time"] as? String ?? ""), 0)
            XCTAssertEqual(Double(chapters[0]["end_time"] as? String ?? ""), 1)
            XCTAssertEqual(Double(chapters[1]["start_time"] as? String ?? ""), 1)
            XCTAssertEqual(Double(chapters[1]["end_time"] as? String ?? ""), 3)
        }
        await engine.shutdown()
    }
}

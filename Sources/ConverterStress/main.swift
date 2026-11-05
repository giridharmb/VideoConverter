import Foundation
import ConverterCore
import Darwin

struct Options {
    var values: [String: String] = [:]
    init() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count % 2 == 0 else { throw ConverterError.message("Expected --option value pairs.") }
        for i in stride(from: 0, to: args.count, by: 2) { values[args[i]] = args[i + 1] }
        guard values["--fixtures"] != nil, values["--output"] != nil else {
            throw ConverterError.message("Usage: ConverterStress --fixtures DIR --output DIR [--database PATH] [--parallel 4] [--threads 0] [--label NAME] [--mode matrix|log-flood] [--negative true]")
        }
    }
    func integer(_ key: String, default value: Int) -> Int { Int(values[key] ?? "") ?? value }
}

struct Profile: Sendable {
    var name: String
    var settings: ConversionSettings
    static func matrix(threads: Int, output: String, flood: Bool) -> [Profile] {
        func profile(_ name: String, _ change: (inout ConversionSettings) -> Void) -> Profile {
            var s = ConversionSettings(); s.outputDirectory = output; s.suffix = "_\(name)"; s.threads = threads
            change(&s)
            return Profile(name: name, settings: s)
        }
        if flood {
            return (0..<4).map { n in profile("debug-remux-\(n)") {
                $0.format = .mkv; $0.videoCodec = "copy"; $0.audioCodec = "copy"
                $0.extraOutputArguments = "[\"-loglevel\",\"debug\"]"
            } }
        }
        var profiles = [Profile]()
        for crf in [18, 23, 32] { profiles.append(profile("h264-crf\(crf)") { $0.quality = crf }) }
        for crf in [22, 30] { profiles.append(profile("hevc-crf\(crf)") { $0.videoCodec = "libx265"; $0.quality = crf }) }
        for crf in [24, 36] { profiles.append(profile("vp9-crf\(crf)") {
            $0.format = .webm; $0.videoCodec = "libvpx-vp9"; $0.audioCodec = "libopus"; $0.quality = crf
        }) }
        profiles.append(profile("remux") { $0.format = .mkv; $0.videoCodec = "copy"; $0.audioCodec = "copy" })
        for bitrate in ["64k", "192k"] { profiles.append(profile("mp3-\(bitrate)") {
            $0.format = .mp3; $0.audioCodec = "libmp3lame"; $0.audioBitrate = bitrate
        }) }
        for bitrate in ["96k", "192k"] { profiles.append(profile("aac-\(bitrate)") {
            $0.format = .m4a; $0.audioCodec = "aac"; $0.audioBitrate = bitrate
        }) }
        profiles.append(profile("flac") { $0.format = .flac; $0.audioCodec = "flac" })
        profiles.append(profile("wav") { $0.format = .wav; $0.audioCodec = "pcm_s16le" })
        return profiles
    }
}

@main
struct StressMain {
    static func main() async {
        do { try await run(Options()) }
        catch { FileHandle.standardError.write(Data("Stress run failed: \(error.localizedDescription)\n".utf8)); exit(1) }
    }

    static func wait(_ engine: ConversionEngine, timeout: Double = 600, predicate: @Sendable (EngineSnapshot) -> Bool) async throws -> EngineSnapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            let start = ProcessInfo.processInfo.systemUptime
            let snapshot = await engine.currentSnapshot()
            await engine.recordPerformance(name: "actor_ping", durationMs: (ProcessInfo.processInfo.systemUptime - start) * 1000)
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ConverterError.message("Stress scenario exceeded its timeout.")
    }

    static func run(_ options: Options) async throws {
        let fixtures = URL(fileURLWithPath: options.values["--fixtures"]!, isDirectory: true)
        let output = URL(fileURLWithPath: options.values["--output"]!, isDirectory: true)
        let parallel = options.integer("--parallel", default: 4), threads = options.integer("--threads", default: 0)
        guard (1...8).contains(parallel), threads >= 0 else { throw ConverterError.message("Parallelism must be 1–8 and threads nonnegative.") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let valid = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
            .filter { ["mp4", "mkv", "mov", "webm", "avi"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        guard valid.count >= 5 else { throw ConverterError.message("Generate the five format fixtures before running the benchmark.") }
        let profiles = Profile.matrix(threads: threads, output: output.path, flood: options.values["--mode"] == "log-flood")
        let negative = options.values["--negative"] == "true"
        var inputs = valid
        if negative { inputs += [fixtures.appendingPathComponent("negative/invalid.bin"), fixtures.appendingPathComponent("negative/truncated.mp4")] }
        let label = options.values["--label"] ?? "stress-c\(parallel)-t\(threads)"
        let database = options.values["--database"].map { URL(fileURLWithPath: $0) } ?? TelemetryDatabase.defaultURL
        let engine = ConversionEngine(storageDirectory: output.appendingPathComponent("state"), telemetryDatabaseURL: database, sessionLabel: label)
        do {
            await engine.handle(.initialize)
            let initialized = await engine.currentSnapshot()
            guard initialized.tools != nil, initialized.telemetryError == nil else {
                throw ConverterError.message(initialized.telemetryError ?? initialized.engineDescription)
            }
            let config: [String: Any] = ["parallel": parallel, "threads": threads, "label": label, "mode": options.values["--mode"] ?? "matrix",
                "fixtures": valid.count, "profiles": profiles.map(\.name), "ffmpeg": initialized.engineDescription,
                "os": ProcessInfo.processInfo.operatingSystemVersionString, "build": "release", "negative_cases": negative]
            let configJSON = String(decoding: try JSONSerialization.data(withJSONObject: config, options: .sortedKeys), as: UTF8.self)
            await engine.recordPerformance(name: "scenario_config", durationMs: 0, detail: configJSON)
            await engine.handle(.setConcurrency(parallel)); await engine.handle(.setPreventSleep(false))
            await engine.handle(.add(inputs, profiles[0].settings))
            let inputCount = inputs.count
            let inspected = try await wait(engine, timeout: 90) { $0.jobs.count == inputCount && $0.jobs.allSatisfy { [.ready, .failed].contains($0.state) } }
            let original = inspected.jobs.filter { valid.contains($0.input) }
            guard original.allSatisfy({ $0.state == .ready }) else { throw ConverterError.message("A valid fixture failed inspection.") }
            let ids = Set(original.map(\.id))
            for profile in profiles.dropFirst() { await engine.handle(.duplicate(ids, profile.settings)) }
            let total = inputs.count + (profiles.count - 1) * valid.count
            let batchStart = ProcessInfo.processInfo.systemUptime
            await engine.handle(.start)
            let final = try await wait(engine) { $0.jobs.count == total && $0.jobs.allSatisfy { $0.state.isTerminal } }
            let wallMs = (ProcessInfo.processInfo.systemUptime - batchStart) * 1000
            await engine.recordPerformance(name: "batch_wall", durationMs: wallMs, detail: "jobs=\(total)")
            let unexpected = final.jobs.filter { valid.contains($0.input) && $0.state != .completed }
            await engine.handle(.stopScheduling)
            // Give the last live worker counters one final sampling window before closing the session.
            try await Task.sleep(for: .seconds(1))
            await engine.shutdown()
            let closed = await engine.currentSnapshot()
            let summary: [String: Any] = ["session_id": final.sessionID, "label": label, "jobs": total,
                "completed": final.jobs.filter { $0.state == .completed }.count, "failed": final.jobs.filter { $0.state == .failed }.count,
                "unexpected_failures": unexpected.map(\.message), "wall_seconds": wallMs / 1000,
                "telemetry_dropped": closed.telemetryDroppedEvents, "telemetry_error": closed.telemetryError ?? "", "database": database.path]
            let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("summary.json"), options: .atomic)
            print(String(decoding: data, as: UTF8.self))
            guard unexpected.isEmpty, closed.telemetryError == nil else { throw ConverterError.message("Unexpected conversion or telemetry failure. See summary.json.") }
        } catch { await engine.shutdown(); throw error }
    }
}

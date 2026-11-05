import Foundation

public struct ConversionPlan: Sendable {
    public let arguments: [String]
    public let output: URL
    public let staging: URL
    public let duration: Double
    public let chunks: ChunkPlan?
    public var workerSlots: Int { chunks?.workers ?? 1 }
}

public enum CommandBuilder {
    public static func extraArguments(_ json: String) throws -> [String] {
        guard let data = json.data(using: .utf8), let args = try? JSONDecoder().decode([String].self, from: data) else {
            throw ConverterError.message("Advanced arguments must be a JSON array of strings, for example [\"-g\", \"60\"].")
        }
        let reserved: Set<String> = ["-y", "-n", "-i", "-progress", "-stats_period", "-stdin", "-nostdin", "-stats", "-nostats"]
        guard !args.contains(where: { reserved.contains($0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? $0) || $0.contains("\0") }) else {
            throw ConverterError.message("Input files, overwrite policy, stdin, and progress options are managed by the application.")
        }
        return args
    }

    public static func make(job: ConversionJob, reserved: Set<String> = [], workerLimit: Int = 8) throws -> ConversionPlan {
        guard let media = job.media else { throw ConverterError.message("Inspect media before conversion.") }
        let s = job.settings
        guard s.startSeconds.isFinite, s.durationSeconds.isFinite, s.startSeconds >= 0, s.durationSeconds >= 0,
              s.width >= 0, s.height >= 0, s.sampleRate >= 0, s.channels >= 0, s.threads >= 0,
              (0...51).contains(s.quality) else { throw ConverterError.message("Dimensions, timing, quality, and thread settings are outside their valid range.") }
        if media.duration > 0, s.startSeconds >= media.duration { throw ConverterError.message("Trim start must be before the end of the media.") }
        if s.format.audioOnly && (!media.hasAudio || s.mute) { throw ConverterError.message("The selected audio output requires an audio stream and audio enabled.") }
        if !media.hasVideo && (!media.hasAudio || s.mute) { throw ConverterError.message("No enabled audio or video streams remain.") }
        guard !s.suffix.contains("/"), !s.suffix.contains("\0") else { throw ConverterError.message("Filename suffix cannot contain a slash or null character.") }
        let directory = s.outputDirectory.isEmpty ? job.input.deletingLastPathComponent() : URL(fileURLWithPath: s.outputDirectory, isDirectory: true)
        let stem = job.input.deletingPathExtension().lastPathComponent + s.suffix
        var output = directory.appendingPathComponent(stem).appendingPathExtension(s.format.rawValue)
        var number = 2
        while FileManager.default.fileExists(atPath: output.path) || reserved.contains(output.path) || output.standardizedFileURL == job.input.standardizedFileURL {
            output = directory.appendingPathComponent("\(stem)_\(number)").appendingPathExtension(s.format.rawValue)
            number += 1
        }
        let staging = directory.appendingPathComponent(".videoconverter-\(job.id.uuidString)", isDirectory: true)
            .appendingPathComponent("output.\(s.format.rawValue)")
        var args = ["-hide_banner", "-nostdin", "-n", "-loglevel", "warning", "-nostats", "-stats_period", "0.3", "-progress", "pipe:1"]
        if s.recoverCorruption { args += ["-fflags", "+discardcorrupt+genpts", "-err_detect", "ignore_err"] }
        args += try extraArguments(s.extraInputArguments)
        if s.startSeconds > 0 { args += ["-ss", String(s.startSeconds)] }
        args += ["-i", job.input.path]
        if s.durationSeconds > 0 { args += ["-t", String(s.durationSeconds)] }
        if !s.format.audioOnly && media.hasVideo {
            let stream = s.videoStream.map { "0:\($0)" } ?? "0:v:0"
            if let index = s.videoStream, !media.streams.contains(where: { $0.index == index && $0.kind == "video" }) {
                throw ConverterError.message("Selected video stream is unavailable.")
            }
            args += ["-map", stream, "-c:v", s.videoCodec]
            if s.videoCodec != "copy" {
                if s.videoBitrate.isEmpty {
                    if s.videoCodec.contains("videotoolbox") { args += ["-b:v", "6000k"] }
                    else if ["libx264", "libx265", "libvpx-vp9", "libaom-av1", "libsvtav1"].contains(s.videoCodec) { args += ["-crf", String(s.quality)] }
                } else { args += ["-b:v", s.videoBitrate] }
                if ["libx264", "libx265"].contains(s.videoCodec) { args += ["-preset", s.encoderPreset, "-pix_fmt", "yuv420p"] }
                var filters: [String] = []
                if s.deinterlace { filters.append("yadif") }
                if s.width > 0 || s.height > 0 { filters.append("scale=\(s.width > 0 ? s.width : -2):\(s.height > 0 ? s.height : -2)") }
                if !s.videoFilter.isEmpty { filters.append(s.videoFilter) }
                if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }
                if !s.frameRate.isEmpty { args += ["-r", s.frameRate] }
            } else if s.width > 0 || s.height > 0 || s.deinterlace || !s.videoFilter.isEmpty || !s.frameRate.isEmpty {
                throw ConverterError.message("Video filters and frame rate changes require re-encoding; choose a video encoder instead of copy.")
            }
        } else { args += ["-vn"] }
        args += try audioArguments(s, media: media, input: 0)
        if s.subtitles && !s.format.audioOnly {
            args += ["-map", "0:s?", "-c:s", [.mp4, .mov].contains(s.format) ? "mov_text" : "copy"]
        } else { args += ["-sn"] }
        args += ["-map_metadata", s.preserveMetadata ? "0" : "-1", "-map_chapters", s.preserveMetadata ? "0" : "-1"]
        if s.fastStart && [.mp4, .mov, .m4a].contains(s.format) { args += ["-movflags", "+faststart"] }
        if s.threads > 0 { args += ["-threads", String(s.threads)] }
        args += try extraArguments(s.extraOutputArguments)
        args.append(staging.path)
        let remaining = max(0, media.duration - s.startSeconds)
        let duration = s.durationSeconds > 0 ? (remaining > 0 ? min(remaining, s.durationSeconds) : s.durationSeconds) : remaining
        let chunks = try s.chunking.map { try ChunkPlanner.make(job: job, staging: staging, configuration: $0, workerLimit: workerLimit) }
        return ConversionPlan(arguments: args, output: output, staging: staging, duration: chunks?.duration ?? duration, chunks: chunks)
    }

    static func audioArguments(_ s: ConversionSettings, media: MediaInfo, input: Int) throws -> [String] {
        var args: [String] = []
        if media.hasAudio && !s.mute {
            if let index = s.audioStream, !media.streams.contains(where: { $0.index == index && $0.kind == "audio" }) {
                throw ConverterError.message("Selected audio stream is unavailable.")
            }
            let map = s.allAudio && !s.format.audioOnly ? "\(input):a?" : (s.audioStream.map { "\(input):\($0)" } ?? "\(input):a:0?")
            args += ["-map", map, "-c:a", s.audioCodec]
            if s.audioCodec != "copy" {
                if !["flac", "pcm_s16le"].contains(s.audioCodec), !s.audioBitrate.isEmpty { args += ["-b:a", s.audioBitrate] }
                if s.sampleRate > 0 { args += ["-ar", String(s.sampleRate)] }
                if s.channels > 0 { args += ["-ac", String(s.channels)] }
                var filters = s.normalizeAudio ? ["loudnorm"] : []
                if !s.audioFilter.isEmpty { filters.append(s.audioFilter) }
                if !filters.isEmpty { args += ["-af", filters.joined(separator: ",")] }
            } else if s.normalizeAudio || !s.audioFilter.isEmpty || s.channels > 0 || s.sampleRate > 0 {
                throw ConverterError.message("Audio filtering and resampling require an audio encoder instead of copy.")
            }
        } else { args += ["-an"] }
        return args
    }

    public static func display(_ arguments: [String]) -> String {
        arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }
}

public struct ProgressParser: Sendable {
    private var values: [String: String] = [:]
    public init() {}
    public mutating func consume(_ line: String, duration: Double) -> JobProgress? {
        let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2 else { return nil }
        values[String(pair[0])] = String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard pair[0] == "progress" else { return nil }
        var progress = JobProgress()
        progress.seconds = max(0, (Double(values["out_time_us"] ?? "") ?? 0) / 1_000_000)
        if !progress.seconds.isFinite { progress.seconds = 0 }
        progress.fraction = duration > 0 ? min(0.999, max(0, progress.seconds / duration)) : 0
        progress.speed = Double(values["speed", default: ""].replacingOccurrences(of: "x", with: "")) ?? 0
        if !progress.speed.isFinite { progress.speed = 0 }
        progress.fps = Double(values["fps"] ?? "") ?? 0
        if !progress.fps.isFinite { progress.fps = 0 }
        progress.frame = Int(values["frame"] ?? "") ?? 0
        progress.bytes = Int64(values["total_size"] ?? "") ?? 0
        if duration > 0 && progress.speed > 0 { progress.eta = max(0, duration - progress.seconds) / progress.speed }
        return progress
    }
}

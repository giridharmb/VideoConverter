import Foundation

public struct ChunkSegment: Sendable {
    public let index: Int
    public let frames: Int64
    public let duration: Double
    public let output: URL
    public let arguments: [String]
}

public struct ChunkPlan: Sendable {
    public let workers: Int
    public let duration: Double
    public let frameRate: Double
    public let totalFrames: Int64
    public let segments: [ChunkSegment]
    public let manifestURL: URL
    public let manifest: String
    public let joinArguments: [String]
}

public enum ChunkPlanner {
    private struct Rate {
        let numerator: Int
        let denominator: Int
        var value: Double { Double(numerator) / Double(denominator) }
        var text: String { "\(numerator)/\(denominator)" }
        init(_ text: String) throws {
            let parts = text.split(separator: "/", omittingEmptySubsequences: false)
            let n: Int, d: Int
            if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), a > 0, b > 0,
               a <= Int(Int32.max), b <= 1_000_000 { n = a; d = b }
            else if parts.count == 1, let number = Double(text), number.isFinite, (1...240).contains(number) {
                n = Int((number * 1_000_000).rounded()); d = 1_000_000
            } else { throw ConverterError.message("Parallel chunks need a known frame rate from 1–240 fps. Set a numeric rate such as 30 or 30000/1001.") }
            var a = n, b = d
            while b != 0 { let remainder = a % b; a = b; b = remainder }
            numerator = n / a; denominator = d / a
            guard (1...240).contains(value) else { throw ConverterError.message("Parallel chunks support 1–240 fps.") }
        }
    }

    public static func make(job: ConversionJob, staging: URL, configuration: ChunkSettings, workerLimit: Int) throws -> ChunkPlan {
        let s = job.settings
        guard let media = job.media, let video = media.streams.first(where: { $0.kind == "video" && (s.videoStream == nil || s.videoStream == $0.index) }),
              [.mp4, .mkv, .mov].contains(s.format), ["libx264", "libx265"].contains(s.videoCodec) else {
            throw ConverterError.message("Parallel chunks require a video source, MP4/MKV/MOV output and libx264 or libx265 re-encoding. Use standard mode for other formats or stream copy.")
        }
        guard (2...8).contains(configuration.workers), configuration.seconds.isFinite, (1...3600).contains(configuration.seconds) else {
            throw ConverterError.message("Choose 2–8 chunk workers and a chunk length of 1–3600 seconds.")
        }
        guard !s.subtitles, !s.deinterlace, s.videoFilter.isEmpty,
              try CommandBuilder.extraArguments(s.extraInputArguments).isEmpty,
              try CommandBuilder.extraArguments(s.extraOutputArguments).isEmpty,
              s.mute || !media.hasAudio || s.audioCodec != "copy" else {
            throw ConverterError.message("Parallel chunks exclude subtitles, deinterlacing, custom video filters, expert arguments and audio stream copy. Use standard mode for these options.")
        }
        let rate = try Rate(s.frameRate.isEmpty ? (video.frameRate ?? "") : s.frameRate)
        let sourceRate = video.frameRate.flatMap { try? Rate($0).value }
        if let videoStart = video.startTime, let mediaStart = media.startTime, abs(videoStart - mediaStart) > 1 / rate.value {
            throw ConverterError.message("This video starts at an offset within its container. Use standard mode to preserve stream timing.")
        }
        if let average = sourceRate, let nominal = video.nominalFrameRate.flatMap({ try? Rate($0).value }), abs(average / nominal - 1) > 0.001 {
            throw ConverterError.message("This source reports variable or inconsistent frame rates. Use standard mode to preserve its timing.")
        }
        let countedDuration = sourceRate.flatMap { fps in video.frameCount.flatMap { $0 > 0 ? Double($0) / fps : nil } }
        let sourceDuration = countedDuration ?? video.durationSeconds ?? media.duration
        guard sourceDuration.isFinite, sourceDuration > 0 else { throw ConverterError.message("Parallel chunks require a finite, known video duration.") }
        let startFrame = ceil(s.startSeconds * rate.value - 0.000001)
        let start = max(0, startFrame / rate.value)
        let remaining = max(0, sourceDuration - start)
        let requested = s.durationSeconds > 0 ? min(remaining, s.durationSeconds) : remaining
        let frameValue = floor(requested * rate.value + 0.0001)
        guard frameValue >= 1, frameValue <= 1_000_000_000 else { throw ConverterError.message("The selected video range is empty or too long for parallel chunks.") }
        let totalFrames = Int64(frameValue)
        let chunkFrames = max(1, Int64(floor(configuration.seconds * rate.value)))
        let count = Int((totalFrames + chunkFrames - 1) / chunkFrames)
        guard count <= 4096 else { throw ConverterError.message("This range would create more than 4,096 chunks. Increase the chunk length.") }
        let workers = min(configuration.workers, max(1, workerLimit), count)
        let threads = s.threads > 0 ? s.threads : max(1, ProcessInfo.processInfo.activeProcessorCount / workers)
        let directory = staging.deletingLastPathComponent()
        var segments: [ChunkSegment] = []
        var manifest = "ffconcat version 1.0\n"
        for index in 0..<count {
            let first = Int64(index) * chunkFrames
            let frames = min(chunkFrames, totalFrames - first)
            let duration = Double(frames) / rate.value
            let output = directory.appendingPathComponent(String(format: "video-%05d.mp4", index))
            var chunkJob = job
            chunkJob.settings.chunking = nil; chunkJob.settings.format = .mp4
            // Seek just before the frame boundary so microsecond rounding cannot skip a CFR frame.
            let seek = start + Double(first) / rate.value
            chunkJob.settings.startSeconds = max(0, (floor(seek * 1_000_000) - 1) / 1_000_000)
            chunkJob.settings.durationSeconds = 0; chunkJob.settings.mute = true
            chunkJob.settings.preserveMetadata = false; chunkJob.settings.fastStart = false
            chunkJob.settings.frameRate = rate.text; chunkJob.settings.videoFilter = "setpts=PTS-STARTPTS"
            chunkJob.settings.threads = threads
            var options = ["-frames:v", String(frames), "-fps_mode", "cfr", "-video_track_timescale", String(rate.numerator), "-flags", "+cgop"]
            if s.videoCodec == "libx265" { options += ["-x265-params", "open-gop=0:pools=\(threads):frame-threads=\(min(threads, 4))"] }
            chunkJob.settings.extraOutputArguments = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
            var args = try CommandBuilder.make(job: chunkJob).arguments
            if let input = args.firstIndex(of: "-i") { args.insert(contentsOf: ["-threads", String(threads)], at: input) }
            args.insert(contentsOf: ["-filter_threads", "1"], at: 0)
            args[args.count - 1] = output.path
            segments.append(ChunkSegment(index: index, frames: frames, duration: duration, output: output, arguments: args))
            manifest += "file '\(output.lastPathComponent)'\nduration \(duration)\n"
        }
        let duration = Double(totalFrames) / rate.value
        let manifestURL = directory.appendingPathComponent("video.ffconcat")
        var join = ["-hide_banner", "-nostdin", "-n", "-loglevel", "warning", "-nostats", "-stats_period", "0.3", "-progress", "pipe:1",
                    "-f", "concat", "-safe", "1", "-i", manifestURL.path]
        if s.recoverCorruption { join += ["-fflags", "+discardcorrupt+genpts", "-err_detect", "ignore_err"] }
        if start > 0 { join += ["-ss", String(start)] }
        join += ["-i", job.input.path, "-t", String(duration), "-map", "0:v:0", "-c:v", "copy"]
        join += try CommandBuilder.audioArguments(s, media: media, input: 1)
        join += ["-sn", "-map_metadata", s.preserveMetadata ? "1" : "-1", "-map_chapters", s.preserveMetadata ? "1" : "-1"]
        if s.fastStart && [.mp4, .mov].contains(s.format) { join += ["-movflags", "+faststart"] }
        if [.mp4, .mov].contains(s.format) { join += ["-video_track_timescale", String(rate.numerator)] }
        if s.threads > 0 { join += ["-threads", String(s.threads)] }
        join.append(staging.path)
        return ChunkPlan(workers: workers, duration: duration, frameRate: rate.value, totalFrames: totalFrames,
                         segments: segments, manifestURL: manifestURL, manifest: manifest, joinArguments: join)
    }
}

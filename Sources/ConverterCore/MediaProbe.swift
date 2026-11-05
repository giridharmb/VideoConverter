import Foundation

public enum MediaProbe {
    public static func inspect(_ url: URL, tools: ToolPaths, controller: ProcessController, timeout: Duration = .seconds(60)) async throws -> MediaInfo {
        try await withThrowingTaskGroup(of: MediaInfo.self) { group in
            group.addTask {
                let result = try await ProcessRunner.run(executable: tools.ffprobe,
                    arguments: ["-v", "error", "-show_format", "-show_streams", "-of", "json", url.path], controller: controller)
                guard result.status == 0 else { throw ConverterError.message("Media inspection failed: \(result.diagnostic.suffix(2000))") }
                return try decode(result.output)
            }
            group.addTask { try await Task.sleep(for: timeout); throw ConverterError.message("Media inspection timed out.") }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    public static func decode(_ data: Data) throws -> MediaInfo {
        struct Probe: Decodable {
            struct Format: Decodable { var duration: String?; var size: String?; var format_name: String?; var bit_rate: String? }
            struct Stream: Decodable {
                var index: Int; var codec_name: String?; var codec_type: String?; var width: Int?; var height: Int?
                var sample_rate: String?; var channels: Int?; var avg_frame_rate: String?; var tags: [String: String]?
            }
            var format: Format?; var streams: [Stream]?
        }
        let probe = try JSONDecoder().decode(Probe.self, from: data)
        let streams = (probe.streams ?? []).map {
            MediaStream(index: $0.index, codec: $0.codec_name ?? "unknown", kind: $0.codec_type ?? "unknown",
                        width: $0.width, height: $0.height, sampleRate: $0.sample_rate,
                        channels: $0.channels, frameRate: $0.avg_frame_rate, language: $0.tags?["language"])
        }
        guard streams.contains(where: { ["video", "audio"].contains($0.kind) }) else {
            throw ConverterError.message("No audio or video streams were detected.")
        }
        let duration = Double(probe.format?.duration ?? "") ?? 0
        return MediaInfo(duration: duration.isFinite ? max(0, duration) : 0,
                         size: Int64(probe.format?.size ?? "") ?? 0,
                         format: probe.format?.format_name ?? "unknown",
                         bitRate: Int64(probe.format?.bit_rate ?? "") ?? 0, streams: streams)
    }
}

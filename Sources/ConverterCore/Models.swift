import Foundation

public enum JobState: String, Codable, Sendable, CaseIterable {
    case waiting, inspecting, ready, running, paused, completed, failed, cancelled
    public var isActive: Bool { self == .running || self == .paused || self == .inspecting }
    public var isTerminal: Bool { [.completed, .failed, .cancelled].contains(self) }
    public var label: String { rawValue.capitalized }
}

public enum OutputFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case mp4, mkv, mov, webm, avi, m4a, mp3, wav, flac, ogg, opus, aac
    public var id: Self { self }
    public var audioOnly: Bool { [.m4a, .mp3, .wav, .flac, .ogg, .opus, .aac].contains(self) }
    public var defaultAudioCodec: String {
        switch self {
        case .webm, .opus: return "libopus"
        case .mp3: return "libmp3lame"
        case .wav: return "pcm_s16le"
        case .flac: return "flac"
        case .ogg: return "libvorbis"
        default: return "aac"
        }
    }
}

public enum ConversionPreset: String, CaseIterable, Identifiable, Sendable {
    case balanced = "MP4 · Balanced"
    case compact = "MP4 · Smaller file (HEVC)"
    case hardware = "MP4 · Apple hardware"
    case web = "WebM · VP9"
    case archive = "MKV · Preserve streams"
    case audio = "MP3 · Extract audio"
    case lossless = "FLAC · Lossless audio"
    public var id: Self { self }
    public var settings: ConversionSettings {
        var value = ConversionSettings()
        switch self {
        case .balanced: break
        case .compact: value.videoCodec = "libx265"; value.quality = 26
        case .hardware: value.videoCodec = "h264_videotoolbox"; value.videoBitrate = "6000k"
        case .web: value.format = .webm; value.videoCodec = "libvpx-vp9"; value.audioCodec = "libopus"; value.quality = 32
        case .archive: value.format = .mkv; value.videoCodec = "copy"; value.audioCodec = "copy"; value.allAudio = true; value.subtitles = true
        case .audio: value.format = .mp3; value.audioCodec = "libmp3lame"
        case .lossless: value.format = .flac; value.audioCodec = "flac"
        }
        return value
    }
}

public struct ConversionSettings: Codable, Sendable, Equatable {
    public var format: OutputFormat = .mp4
    public var videoCodec = "libx264"
    public var audioCodec = "aac"
    public var quality = 23
    public var encoderPreset = "medium"
    public var videoBitrate = ""
    public var audioBitrate = "192k"
    public var width = 0
    public var height = 0
    public var frameRate = ""
    public var sampleRate = 0
    public var channels = 0
    public var startSeconds: Double = 0
    public var durationSeconds: Double = 0
    public var videoStream: Int? = nil
    public var audioStream: Int? = nil
    public var allAudio = false
    public var mute = false
    public var subtitles = false
    public var preserveMetadata = true
    public var fastStart = true
    public var recoverCorruption = true
    public var deinterlace = false
    public var normalizeAudio = false
    public var videoFilter = ""
    public var audioFilter = ""
    public var threads = 0
    public var suffix = "_converted"
    public var outputDirectory = ""
    public var extraInputArguments = "[]"
    public var extraOutputArguments = "[]"
    public init() {}
}

public struct MediaStream: Codable, Sendable, Identifiable, Equatable {
    public var index: Int
    public var codec: String
    public var kind: String
    public var width: Int?
    public var height: Int?
    public var sampleRate: String?
    public var channels: Int?
    public var frameRate: String?
    public var language: String?
    public var id: Int { index }
    public var summary: String {
        var parts = ["#\(index)", kind.uppercased(), codec]
        if let width, let height { parts.append("\(width)×\(height)") }
        if let sampleRate { parts.append("\(sampleRate) Hz") }
        if let channels { parts.append("\(channels) ch") }
        if let language { parts.append(language) }
        return parts.joined(separator: " · ")
    }
}

public struct MediaInfo: Codable, Sendable, Equatable {
    public var duration: Double
    public var size: Int64
    public var format: String
    public var bitRate: Int64
    public var streams: [MediaStream]
    public var hasVideo: Bool { streams.contains { $0.kind == "video" } }
    public var hasAudio: Bool { streams.contains { $0.kind == "audio" } }
    public init(duration: Double, size: Int64, format: String, bitRate: Int64 = 0, streams: [MediaStream]) {
        self.duration = duration; self.size = size; self.format = format; self.bitRate = bitRate; self.streams = streams
    }
}

public struct JobProgress: Codable, Sendable, Equatable {
    public var fraction: Double = 0
    public var seconds: Double = 0
    public var speed: Double = 0
    public var fps: Double = 0
    public var bytes: Int64 = 0
    public var frame: Int = 0
    public var eta: Double? = nil
    public init() {}
}

public struct ConversionJob: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var input: URL
    public var output: URL?
    public var state: JobState = .waiting
    public var settings: ConversionSettings
    public var media: MediaInfo?
    public var progress = JobProgress()
    public var message = "Waiting for inspection"
    public var warningCount = 0
    public var createdAt = Date()
    public var startedAt: Date?
    public var finishedAt: Date?
    public var command: [String] = []
    public var workerPID: Int32?
    public init(input: URL, settings: ConversionSettings) { self.input = input; self.settings = settings }
}

public enum LogLevel: String, Codable, Sendable, CaseIterable { case info, warning, error, debug }
public struct LogEntry: Identifiable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let level: LogLevel
    public let jobID: UUID?
    public let message: String
    public init(level: LogLevel, jobID: UUID? = nil, message: String) {
        self.id = UUID(); self.date = Date(); self.level = level; self.jobID = jobID; self.message = message
    }
}

public struct EngineSnapshot: Sendable {
    public var jobs: [ConversionJob] = []
    public var logs: [LogEntry] = []
    public var tools: ToolPaths?
    public var engineDescription = "Detecting FFmpeg…"
    public var capabilities = ""
    public var queueRunning = false
    public var concurrency = 2
    public var preventSleep = true
    public var metrics: [MetricSample] = []
    public var persistenceError: String?
    public init() {}
}

public enum AppCommand: Sendable {
    case initialize
    case add([URL], ConversionSettings)
    case start, stopScheduling
    case cancel(Set<UUID>), pause(Set<UUID>), resume(Set<UUID>), retry(Set<UUID>)
    case remove(Set<UUID>), clearFinished, clearLogs
    case apply(Set<UUID>, ConversionSettings)
    case duplicate(Set<UUID>, ConversionSettings)
    case setConcurrency(Int)
    case setPreventSleep(Bool)
    case moveFirst(Set<UUID>)
    case setTools(String)
}

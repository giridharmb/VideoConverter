import Foundation

public struct SavedQueue: Codable, Sendable {
    public var version = 1
    public var jobs: [ConversionJob]
    public var concurrency: Int
    public var toolDirectory: String
    public var preventSleep: Bool?
    public init(jobs: [ConversionJob], concurrency: Int, toolDirectory: String, preventSleep: Bool = true) {
        self.jobs = jobs; self.concurrency = concurrency; self.toolDirectory = toolDirectory; self.preventSleep = preventSleep
    }
}

public actor QueuePersistence {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func load() throws -> SavedQueue? {
        let url = directory.appendingPathComponent("queue.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let saved = try JSONDecoder().decode(SavedQueue.self, from: Data(contentsOf: url))
        guard saved.version == 1 else { throw ConverterError.message("Unsupported queue version. Existing queue data was retained.") }
        return saved
    }
    public func save(_ queue: SavedQueue) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(queue).write(to: directory.appendingPathComponent("queue.json"), options: .atomic)
    }
    public func append(_ entries: [LogEntry]) throws {
        guard !entries.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("application.log")
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > 5 * 1024 * 1024 {
            let old = directory.appendingPathComponent("application.previous.log")
            if fm.fileExists(atPath: old.path) { try fm.removeItem(at: old) }
            try fm.moveItem(at: file, to: old)
        }
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let formatter = ISO8601DateFormatter()
        let text = entries.map { "\(formatter.string(from: $0.date)) [\($0.level.rawValue)] [\($0.jobID?.uuidString ?? "app")] \($0.message)" }.joined(separator: "\n") + "\n"
        try handle.write(contentsOf: Data(text.utf8))
    }
}

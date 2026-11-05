import Foundation
import Darwin

public struct ToolPaths: Codable, Sendable {
    public var ffmpeg: URL
    public var ffprobe: URL
    public static func discover(directory: String = "") throws -> ToolPaths {
        let environment = ProcessInfo.processInfo.environment["PATH", default: ""].split(separator: ":").map(String.init)
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Tools").path
        let locations = directory.isEmpty ? [bundled, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].compactMap { $0 } + environment : [directory]
        for location in locations {
            let base = URL(fileURLWithPath: location)
            let ffmpeg = base.appendingPathComponent("ffmpeg")
            let ffprobe = base.appendingPathComponent("ffprobe")
            if FileManager.default.isExecutableFile(atPath: ffmpeg.path), FileManager.default.isExecutableFile(atPath: ffprobe.path) {
                return ToolPaths(ffmpeg: ffmpeg, ffprobe: ffprobe)
            }
        }
        throw ConverterError.message("FFmpeg and ffprobe were not found. Install FFmpeg or choose their folder in Engine settings.")
    }
}

public enum ConverterError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let value): return value } }
}

public enum ProcessEvent: Sendable { case started(Int32), stdout(String), stderr(String) }
public struct ProcessResult: Sendable {
    public let status: Int32
    public let output: Data
    public let diagnostic: String
}

// Process and its signal lifecycle are guarded by the lock; pipes have one reader each.
public final class ProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var paused = false
    public init() {}
    public var processIdentifier: Int32? { lock.withLock { process?.isRunning == true ? process?.processIdentifier : nil } }
    fileprivate func launch(_ process: Process) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try process.run()
            self.process = process
            if paused { kill(process.processIdentifier, SIGSTOP) }
        }
    }
    fileprivate func finished() { lock.withLock { process = nil } }
    public func pause() { lock.withLock { paused = true; if let process, process.isRunning { kill(process.processIdentifier, SIGSTOP) } } }
    public func resume() { lock.withLock { paused = false; if let process, process.isRunning { kill(process.processIdentifier, SIGCONT) } } }
    public func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning {
                kill(process.processIdentifier, SIGCONT)
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            lock.withLock {
                if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

private final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    func append(_ data: Data, isError: Bool) {
        lock.withLock {
            if isError {
                stderr.append(data)
                if stderr.count > 64 * 1024 { stderr.removeFirst(stderr.count - 64 * 1024) }
            } else if stdout.count < 16 * 1024 * 1024 {
                stdout.append(data.prefix(16 * 1024 * 1024 - stdout.count))
            }
        }
    }
    func result(status: Int32) -> ProcessResult {
        lock.withLock { ProcessResult(status: status, output: stdout, diagnostic: String(decoding: stderr, as: UTF8.self)) }
    }
}

public enum ProcessRunner {
    public static func capture(executable: URL, arguments: [String], timeout: Duration = .seconds(10)) async throws -> ProcessResult {
        try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            group.addTask { try await run(executable: executable, arguments: arguments) }
            group.addTask { try await Task.sleep(for: timeout); throw ConverterError.message("Tool capability detection timed out.") }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    public static func run(executable: URL, arguments: [String], controller: ProcessController = ProcessController(),
                           event: @escaping @Sendable (ProcessEvent) -> Void = { _ in }) async throws -> ProcessResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    let output = Pipe(), errors = Pipe()
                    process.standardOutput = output
                    process.standardError = errors
                    process.standardInput = FileHandle.nullDevice
                    process.environment = ProcessInfo.processInfo.environment.merging(["AV_LOG_FORCE_NOCOLOR": "1"]) { _, new in new }
                    do { try controller.launch(process) }
                    catch { continuation.resume(throwing: error); return }
                    event(.started(process.processIdentifier))
                    let captured = CapturedOutput()
                    let readers = DispatchGroup()
                    for (pipe, isError) in [(output, false), (errors, true)] {
                        readers.enter()
                        DispatchQueue.global(qos: .utility).async {
                            defer { readers.leave() }
                            var pending = Data()
                            while true {
                                let data = pipe.fileHandleForReading.availableData
                                if data.isEmpty { break }
                                captured.append(data, isError: isError)
                                pending.append(data)
                                while let newline = pending.firstIndex(of: 10) {
                                    let line = String(decoding: pending[..<newline], as: UTF8.self)
                                    pending.removeSubrange(...newline)
                                    event(isError ? .stderr(line) : .stdout(line))
                                }
                                if pending.count > 64 * 1024 {
                                    event(isError ? .stderr(String(decoding: pending, as: UTF8.self)) : .stdout(String(decoding: pending, as: UTF8.self)))
                                    pending.removeAll(keepingCapacity: true)
                                }
                            }
                            if !pending.isEmpty {
                                let line = String(decoding: pending, as: UTF8.self)
                                event(isError ? .stderr(line) : .stdout(line))
                            }
                            try? pipe.fileHandleForReading.close()
                        }
                    }
                    process.waitUntilExit()
                    readers.wait()
                    controller.finished()
                    continuation.resume(returning: captured.result(status: process.terminationStatus))
                }
            }
        } onCancel: { controller.cancel() }
    }
}

import Foundation
import SQLite3

public struct PerformanceEvent: Sendable {
    public var date = Date()
    public var jobID: UUID?
    public var name: String
    public var durationMs: Double
    public var detail: String
    public init(name: String, durationMs: Double, jobID: UUID? = nil, detail: String = "") {
        self.name = name; self.durationMs = durationMs; self.jobID = jobID; self.detail = detail
    }
}

public struct JobRecord: Sendable {
    public var job: ConversionJob
    public var attempt: Int
    public init(job: ConversionJob, attempt: Int = 1) { self.job = job; self.attempt = attempt }
}

public struct TelemetryBatch: Sendable {
    public var jobs: [JobRecord] = []
    public var logs: [LogEntry] = []
    public var metrics: [MetricSample] = []
    public var operations: [PerformanceEvent] = []
    public init() {}
    public var isEmpty: Bool { jobs.isEmpty && logs.isEmpty && metrics.isEmpty && operations.isEmpty }
}

// One connection is confined to TelemetryDatabase. Its lifetime never escapes that actor.
private final class SQLiteConnection {
    let handle: OpaquePointer
    init(url: URL) throws {
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to allocate SQLite connection"
            if let pointer { sqlite3_close(pointer) }
            throw ConverterError.message("SQLite open failed: \(message)")
        }
        handle = pointer
        sqlite3_busy_timeout(handle, 100)
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    func error() -> ConverterError { .message("SQLite: \(String(cString: sqlite3_errmsg(handle)))") }
    func scalar(_ sql: String) throws -> Int32 {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        return sqlite3_column_int(statement, 0)
    }
    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }
}

private enum SQLValue {
    case text(String), number(Double), integer(Int64), null
}

/// Local diagnostic storage, separate from authoritative JSON queue recovery.
public actor TelemetryDatabase {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoConverter/telemetry.sqlite")
    }
    public nonisolated let url: URL
    public nonisolated let sessionID: String
    private var connection: SQLiteConnection?
    private var writes = 0
    private let label: String

    public init(url: URL, sessionID: String = UUID().uuidString, label: String = "application") {
        self.url = url; self.sessionID = sessionID; self.label = label
    }

    public func start() throws {
        guard connection == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteConnection(url: url)
        let version = try db.scalar("PRAGMA user_version")
        guard version <= 1 else { throw ConverterError.message("SQLite telemetry schema \(version) is newer than supported; existing data was preserved.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try db.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA wal_autocheckpoint=1000;")
        try db.execute(Self.schema)
        connection = db
        do {
            try insert("INSERT INTO sessions(id,label,started_at,logical_cpus,physical_memory_bytes) VALUES(?,?,?,?,?)", [
                .text(sessionID), .text(label), .number(Date().timeIntervalSince1970),
                .integer(Int64(ProcessInfo.processInfo.activeProcessorCount)), .integer(Int64(clamping: ProcessInfo.processInfo.physicalMemory))
            ], db: db)
            try prune(db)
        } catch { connection = nil; throw error }
    }

    @discardableResult
    public func write(_ batch: TelemetryBatch) throws -> Double {
        guard !batch.isEmpty else { return 0 }
        guard let db = connection else { throw ConverterError.message("SQLite telemetry session is not open.") }
        let started = ProcessInfo.processInfo.systemUptime
        try db.execute("BEGIN IMMEDIATE")
        do {
            // Prepared statements are reused inside the transaction, including large diagnostic batches.
            try withStatement(Self.jobSQL, db: db) { statement in
                for record in batch.jobs {
                    let job = record.job, timing = job.timings ?? JobTimings()
                    let encoder = JSONEncoder()
                    encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
                    let settings = String(decoding: try encoder.encode(job.settings), as: UTF8.self)
                    try bindAndStep(statement, [
                        .text(sessionID), .text(job.id.uuidString), .integer(Int64(record.attempt)), .text(job.input.path),
                        .text(job.media?.format ?? ""), .integer(job.media?.size ?? 0), .number(job.media?.duration ?? 0),
                        job.output.map { .text($0.path) } ?? .null, .text(job.settings.format.rawValue),
                        .text(job.settings.videoCodec), .text(job.settings.audioCodec), .integer(Int64(job.settings.quality)),
                        .integer(Int64(job.settings.threads)), .text(job.state.rawValue), .text(job.message),
                        .integer(Int64(job.warningCount)), .number(job.createdAt.timeIntervalSince1970),
                        job.startedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
                        job.finishedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
                        .number(timing.inspectionMs), .number(timing.planningMs), .number(timing.preparationMs),
                        .number(timing.encodingMs), .number(timing.verificationMs), .number(timing.commitMs),
                        .integer(timing.outputBytes), .text(settings)
                    ], db: db)
                }
            }
            try withStatement("INSERT OR IGNORE INTO logs(session_id,id,at,level,job_id,message) VALUES(?,?,?,?,?,?)", db: db) { statement in
                for log in batch.logs {
                    try bindAndStep(statement, [.text(sessionID), .text(log.id.uuidString), .number(log.date.timeIntervalSince1970),
                        .text(log.level.rawValue), log.jobID.map { .text($0.uuidString) } ?? .null, .text(log.message)], db: db)
                }
            }
            try withStatement("INSERT INTO metrics(session_id,at,app_cpu,worker_cpu,app_memory,worker_memory,read_bps,write_bps,threads,workers,thermal,disk_free,unavailable) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", db: db) { statement in
                for m in batch.metrics {
                    try bindAndStep(statement, [.text(sessionID), .number(m.date.timeIntervalSince1970), .number(m.appCPU), .number(m.workerCPU),
                        .integer(Int64(clamping: m.appMemory)), .integer(Int64(clamping: m.workerMemory)), .number(m.readBytesPerSecond),
                        .number(m.writeBytesPerSecond), .integer(Int64(m.threads)), .integer(Int64(m.activeWorkers)),
                        .text(m.thermalState), .integer(m.availableDisk), .integer(Int64(m.unavailableProcesses))], db: db)
                }
            }
            try withStatement("INSERT INTO operations(session_id,at,job_id,name,duration_ms,detail) VALUES(?,?,?,?,?,?)", db: db) { statement in
                for op in batch.operations {
                    try bindAndStep(statement, [.text(sessionID), .number(op.date.timeIntervalSince1970), op.jobID.map { .text($0.uuidString) } ?? .null,
                        .text(op.name), .number(op.durationMs), .text(op.detail)], db: db)
                }
            }
            writes += 1
            if writes % 300 == 0 { try prune(db) }
            try db.execute("COMMIT")
        } catch { try? db.execute("ROLLBACK"); throw error }
        return (ProcessInfo.processInfo.systemUptime - started) * 1000
    }

    public func finish() throws {
        guard let db = connection else { return }
        defer { connection = nil }
        try insert("UPDATE sessions SET finished_at=? WHERE id=?", [.number(Date().timeIntervalSince1970), .text(sessionID)], db: db)
        // PASSIVE never waits for a reader to release its snapshot.
        try db.execute("PRAGMA wal_checkpoint(PASSIVE)")
    }

    private func insert(_ sql: String, _ values: [SQLValue], db: SQLiteConnection) throws {
        try withStatement(sql, db: db) { try bindAndStep($0, values, db: db) }
    }
    private func withStatement(_ sql: String, db: SQLiteConnection, body: (OpaquePointer) throws -> Void) throws {
        let statement = try db.prepare(sql); defer { sqlite3_finalize(statement) }
        try body(statement)
    }
    private func bindAndStep(_ statement: OpaquePointer, _ values: [SQLValue], db: SQLiteConnection) throws {
        sqlite3_reset(statement); sqlite3_clear_bindings(statement)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text): result = text.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case .number(let number): result = number.isFinite ? sqlite3_bind_double(statement, index, number) : sqlite3_bind_null(statement, index)
            case .integer(let number): result = sqlite3_bind_int64(statement, index, number)
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw db.error() }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw db.error() }
    }
    private func prune(_ db: SQLiteConnection) throws {
        // A long-running writer must keep its own foreign-key parent alive.
        try insert("""
            DELETE FROM sessions WHERE id <> ? AND (started_at < unixepoch('now','-30 days')
              OR (finished_at IS NOT NULL AND id NOT IN (SELECT id FROM sessions ORDER BY started_at DESC LIMIT 100)))
            """, [.text(sessionID)], db: db)
        try db.execute("""
            DELETE FROM logs WHERE rowid IN (SELECT rowid FROM logs ORDER BY at DESC LIMIT -1 OFFSET 100000);
            DELETE FROM metrics WHERE rowid IN (SELECT rowid FROM metrics ORDER BY at DESC LIMIT -1 OFFSET 100000);
            DELETE FROM operations WHERE rowid IN (SELECT rowid FROM operations ORDER BY at DESC LIMIT -1 OFFSET 100000);
            """)
    }

    private static let jobSQL = """
        INSERT INTO jobs(session_id,id,attempt,input_path,input_format,input_bytes,input_duration,output_path,output_format,
        video_codec,audio_codec,quality,encoder_threads,state,message,warnings,created_at,started_at,finished_at,
        inspection_ms,planning_ms,preparation_ms,encoding_ms,verification_ms,commit_ms,output_bytes,settings_json)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(session_id,id,attempt) DO UPDATE SET input_format=excluded.input_format,input_bytes=excluded.input_bytes,
        input_duration=excluded.input_duration,output_path=excluded.output_path,output_format=excluded.output_format,
        video_codec=excluded.video_codec,audio_codec=excluded.audio_codec,quality=excluded.quality,encoder_threads=excluded.encoder_threads,
        state=excluded.state,message=excluded.message,warnings=excluded.warnings,started_at=excluded.started_at,finished_at=excluded.finished_at,
        inspection_ms=excluded.inspection_ms,planning_ms=excluded.planning_ms,preparation_ms=excluded.preparation_ms,
        encoding_ms=excluded.encoding_ms,verification_ms=excluded.verification_ms,commit_ms=excluded.commit_ms,
        output_bytes=excluded.output_bytes,settings_json=excluded.settings_json
        """
    private static let schema = """
        BEGIN;
        CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,label TEXT NOT NULL,started_at REAL NOT NULL,finished_at REAL,
          logical_cpus INTEGER NOT NULL,physical_memory_bytes INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS jobs(session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,id TEXT NOT NULL,
          attempt INTEGER NOT NULL,input_path TEXT NOT NULL,input_format TEXT NOT NULL,input_bytes INTEGER NOT NULL,
          input_duration REAL NOT NULL,output_path TEXT,output_format TEXT NOT NULL,video_codec TEXT NOT NULL,audio_codec TEXT NOT NULL,
          quality INTEGER NOT NULL,encoder_threads INTEGER NOT NULL,state TEXT NOT NULL,message TEXT NOT NULL,warnings INTEGER NOT NULL,
          created_at REAL NOT NULL,started_at REAL,finished_at REAL,inspection_ms REAL NOT NULL,planning_ms REAL NOT NULL,
          preparation_ms REAL NOT NULL,encoding_ms REAL NOT NULL,verification_ms REAL NOT NULL,commit_ms REAL NOT NULL,
          output_bytes INTEGER NOT NULL,settings_json TEXT NOT NULL,PRIMARY KEY(session_id,id,attempt));
        CREATE TABLE IF NOT EXISTS logs(session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,id TEXT NOT NULL,
          at REAL NOT NULL,level TEXT NOT NULL,job_id TEXT,message TEXT NOT NULL,PRIMARY KEY(session_id,id));
        CREATE TABLE IF NOT EXISTS metrics(session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,at REAL NOT NULL,
          app_cpu REAL NOT NULL,worker_cpu REAL NOT NULL,app_memory INTEGER NOT NULL,worker_memory INTEGER NOT NULL,
          read_bps REAL NOT NULL,write_bps REAL NOT NULL,threads INTEGER NOT NULL,workers INTEGER NOT NULL,thermal TEXT NOT NULL,
          disk_free INTEGER NOT NULL,unavailable INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS operations(session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,at REAL NOT NULL,
          job_id TEXT,name TEXT NOT NULL,duration_ms REAL,detail TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS jobs_session_state ON jobs(session_id,state);
        CREATE INDEX IF NOT EXISTS logs_at ON logs(at);
        CREATE INDEX IF NOT EXISTS logs_session_job ON logs(session_id,job_id,at);
        CREATE INDEX IF NOT EXISTS metrics_at ON metrics(at);
        CREATE INDEX IF NOT EXISTS metrics_session_at ON metrics(session_id,at);
        CREATE INDEX IF NOT EXISTS operations_at ON operations(at);
        CREATE INDEX IF NOT EXISTS operations_session_name ON operations(session_id,name,at);
        PRAGMA user_version=1;
        COMMIT;
        """
}

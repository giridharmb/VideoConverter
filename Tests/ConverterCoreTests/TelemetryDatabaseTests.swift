import XCTest
import SQLite3
@testable import ConverterCore

final class TelemetryDatabaseTests: XCTestCase, @unchecked Sendable {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TelemetryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func scalar(_ url: URL, _ sql: String) throws -> String {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "NULL"
    }
    func testBatchBindsTextPreservesAttemptsAndPersistsAllKinds() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("telemetry.sqlite")
        let database = TelemetryDatabase(url: url, sessionID: "test-session", label: "quoted ' scenario")
        try await database.start()
        var job = ConversionJob(input: root.appendingPathComponent("name ' ;.mkv"), settings: .init())
        job.settings.startSeconds = .nan
        job.state = .failed; job.timings?.encodingMs = 123
        let log = LogEntry(level: .warning, jobID: job.id, message: "quote '; DROP TABLE jobs; -- 🎬")
        var batch = TelemetryBatch(); batch.jobs = [JobRecord(job: job)]; batch.logs = [log, log]
        batch.metrics = [MetricSample()]; batch.operations = [PerformanceEvent(name: "test", durationMs: 1.5)]
        try await database.write(batch)
        job.state = .completed; job.timings?.outputBytes = 1000
        batch = TelemetryBatch(); batch.jobs = [JobRecord(job: job, attempt: 2)]
        try await database.write(batch); try await database.finish()
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM jobs"), "2")
        XCTAssertEqual(try scalar(url, "SELECT state FROM jobs WHERE attempt=1"), "failed")
        XCTAssertEqual(try scalar(url, "SELECT output_bytes FROM jobs WHERE attempt=2"), "1000")
        XCTAssertEqual(try scalar(url, "SELECT json_extract(settings_json,'$.startSeconds') FROM jobs WHERE attempt=1"), "NaN")
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM logs"), "1")
        XCTAssertEqual(try scalar(url, "SELECT message FROM logs"), log.message)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM metrics"), "1")
        XCTAssertEqual(try scalar(url, "SELECT duration_ms FROM operations"), "1.5")
        XCTAssertNotEqual(try scalar(url, "SELECT finished_at FROM sessions"), "NULL")
        XCTAssertEqual(try scalar(url, "PRAGMA journal_mode"), "wal")
        XCTAssertEqual(try scalar(url, "PRAGMA quick_check"), "ok")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testFailedBatchRollsBackAndNextBatchWorks() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("telemetry.sqlite"), database = TelemetryDatabase(url: root.appendingPathComponent("telemetry.sqlite"))
        try await database.start()
        var batch = TelemetryBatch(); batch.logs = [LogEntry(level: .info, message: "must roll back")]
        batch.metrics = [MetricSample(date: Date(timeIntervalSince1970: .nan))]
        do { try await database.write(batch); XCTFail("Expected NOT NULL violation") } catch {}
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM logs"), "0")
        batch.metrics = []; try await database.write(batch)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM logs"), "1")
        try await database.finish()
    }
    func testConcurrentWriterWaitIsBoundedAndRetryIsPossible() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("telemetry.sqlite"), database = TelemetryDatabase(url: root.appendingPathComponent("telemetry.sqlite"))
        try await database.start()
        var lock: OpaquePointer?; XCTAssertEqual(sqlite3_open(url.path, &lock), SQLITE_OK)
        defer { sqlite3_close(lock) }
        XCTAssertEqual(sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        var batch = TelemetryBatch(); batch.logs = [LogEntry(level: .info, message: "busy")]
        let started = ProcessInfo.processInfo.systemUptime
        do { try await database.write(batch); XCTFail("Expected a busy database") } catch {}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
        XCTAssertEqual(sqlite3_exec(lock, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        try await database.write(batch); try await database.finish()
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM logs"), "1")
    }
    func testFutureSchemaIsPreservedAndRejected() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("telemetry.sqlite")
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version=99; CREATE TABLE future_data(value TEXT); INSERT INTO future_data VALUES('keep');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let database = TelemetryDatabase(url: url)
        do { try await database.start(); XCTFail("Expected future schema rejection") } catch {}
        XCTAssertEqual(try scalar(url, "PRAGMA user_version"), "99")
        XCTAssertEqual(try scalar(url, "SELECT value FROM future_data"), "keep")
    }
    func testMultipleSessionsAndForeignKeyRetention() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("telemetry.sqlite")
        for n in 0..<2 {
            let database = TelemetryDatabase(url: url, label: "run-\(n)")
            try await database.start()
            var batch = TelemetryBatch(); batch.logs = [LogEntry(level: .info, message: "run \(n)")]
            try await database.write(batch); try await database.finish()
        }
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM sessions"), "2")
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM logs"), "2")
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE sessions SET started_at=0", nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let database = TelemetryDatabase(url: url); try await database.start(); try await database.finish()
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM sessions"), "1")
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM logs"), "0")
    }
    func testRetentionPreservesLongRunningWriterSession() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("telemetry.sqlite")
        let database = TelemetryDatabase(url: url)
        try await database.start()
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE sessions SET started_at=0", nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        var batch = TelemetryBatch(); batch.logs = [LogEntry(level: .info, message: "still running")]
        for _ in 0..<301 { try await database.write(batch) }
        try await database.finish()
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM sessions"), "1")
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM logs"), "1")
    }
}

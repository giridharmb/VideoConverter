import XCTest
@testable import ConverterCore

final class CommandBuilderTests: XCTestCase {
    private func job(_ settings: ConversionSettings = .init()) -> ConversionJob {
        var job = ConversionJob(input: URL(fileURLWithPath: "/tmp/source ' with spaces.mkv"), settings: settings)
        job.media = MediaInfo(duration: 120, size: 1024, format: "matroska", streams: [
            MediaStream(index: 0, codec: "h264", kind: "video", width: 1920, height: 1080),
            MediaStream(index: 1, codec: "aac", kind: "audio", channels: 2)
        ])
        return job
    }
    func testDefaultVideoCommandUsesArgumentArrayAndManagedProgress() throws {
        let plan = try CommandBuilder.make(job: job())
        XCTAssertTrue(plan.arguments.contains("/tmp/source ' with spaces.mkv"))
        XCTAssertTrue(plan.arguments.contains("pipe:1"))
        XCTAssertTrue(plan.arguments.contains("-n"))
        XCTAssertFalse(plan.arguments.contains("-y"))
        XCTAssertEqual(plan.arguments.last, plan.staging.path)
        XCTAssertEqual(plan.duration, 120)
        XCTAssertNotEqual(plan.output, plan.staging)
    }
    func testAudioExtractionExcludesVideoAndHonorsTrim() throws {
        var settings = ConversionPreset.audio.settings
        settings.startSeconds = 10; settings.durationSeconds = 15
        let plan = try CommandBuilder.make(job: job(settings))
        XCTAssertTrue(plan.arguments.contains("-vn"))
        XCTAssertFalse(plan.arguments.contains("-c:v"))
        XCTAssertTrue(plan.arguments.contains("libmp3lame"))
        XCTAssertEqual(plan.duration, 15)
    }
    func testCopyWithFiltersFailsBeforeLaunching() {
        var settings = ConversionPreset.archive.settings
        settings.width = 640
        XCTAssertThrowsError(try CommandBuilder.make(job: job(settings)))
        settings.width = 0; settings.normalizeAudio = true
        XCTAssertThrowsError(try CommandBuilder.make(job: job(settings)))
    }
    func testAudioOnlyWithoutAudioAndInvalidStreamAreRejected() {
        var audio = job(ConversionPreset.audio.settings)
        audio.media?.streams.removeAll { $0.kind == "audio" }
        XCTAssertThrowsError(try CommandBuilder.make(job: audio))
        var video = job(); video.settings.videoStream = 99
        XCTAssertThrowsError(try CommandBuilder.make(job: video))
    }
    func testCollisionPolicyPreservesSourceAndReservedNames() throws {
        var value = job(); value.settings.suffix = ""; value.settings.format = .mkv
        let first = try CommandBuilder.make(job: value)
        XCTAssertNotEqual(first.output.standardizedFileURL, value.input.standardizedFileURL)
        let second = try CommandBuilder.make(job: value, reserved: [first.output.path])
        XCTAssertNotEqual(first.output, second.output)
    }
    func testUnsafeSuffixAndNonfiniteTimingAreRejected() {
        var value = job(); value.settings.suffix = "../escape"
        XCTAssertThrowsError(try CommandBuilder.make(job: value))
        value.settings.suffix = "_converted"; value.settings.startSeconds = .nan
        XCTAssertThrowsError(try CommandBuilder.make(job: value))
        value.settings.startSeconds = 120
        XCTAssertThrowsError(try CommandBuilder.make(job: value))
    }
    func testAdvancedArgumentsAreLiteralJSONAndCannotReplaceManagedFlags() throws {
        XCTAssertEqual(try CommandBuilder.extraArguments("[\"-vf\",\"scale=640:-2\"]"), ["-vf", "scale=640:-2"])
        for input in ["-vf scale", "{}", "[1]", "[\"-y\"]", "[\"-i\",\"file.mp4\"]", "[\"-progress=bad\"]"] {
            XCTAssertThrowsError(try CommandBuilder.extraArguments(input))
        }
        XCTAssertEqual(try CommandBuilder.extraArguments("[\"$(touch /tmp/never)\"]"), ["$(touch /tmp/never)"])
    }
    func testProgressUsesMicrosecondsAndClampsBeforeSuccessfulCommit() {
        var parser = ProgressParser()
        for line in ["out_time_us=5000000", "fps=30", "speed=2.0x", "total_size=2048", "frame=150"] {
            XCTAssertNil(parser.consume(line, duration: 10))
        }
        let p = parser.consume("progress=continue", duration: 10)
        XCTAssertEqual(p?.fraction, 0.5); XCTAssertEqual(p?.eta, 2.5); XCTAssertEqual(p?.bytes, 2048)
        _ = parser.consume("out_time_us=20000000", duration: 10)
        XCTAssertEqual(parser.consume("progress=end", duration: 10)?.fraction, 0.999)
    }
    func testUnknownDurationAndMalformedProgressAreSafe() {
        var parser = ProgressParser()
        for line in ["noise", "out_time_us=N/A", "speed=nanx", "fps=inf"] { _ = parser.consume(line, duration: 0) }
        let p = parser.consume("progress=continue", duration: 0)
        XCTAssertEqual(p?.fraction, 0); XCTAssertEqual(p?.speed, 0); XCTAssertEqual(p?.fps, 0); XCTAssertNil(p?.eta)
    }
    func testProbeDecodesAbsentOptionalFields() throws {
        let data = Data("{\"streams\":[{\"index\":0,\"codec_type\":\"audio\",\"codec_name\":\"flac\"}],\"format\":{\"duration\":\"N/A\"}}".utf8)
        let info = try MediaProbe.decode(data)
        XCTAssertTrue(info.hasAudio); XCTAssertFalse(info.hasVideo); XCTAssertEqual(info.duration, 0)
        XCTAssertThrowsError(try MediaProbe.decode(Data("{\"streams\":[]}".utf8)))
    }
}

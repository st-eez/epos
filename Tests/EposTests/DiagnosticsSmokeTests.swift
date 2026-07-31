import AVFoundation
import XCTest
@testable import Epos

/// Smoke coverage for the diagnostic log sink, recording-ID log context,
/// timing-diagnostics redaction, and the dogfood tap.
final class DiagnosticsSmokeTests: XCTestCase {
    func testDiagnosticLogSinkWritesDirectFile() throws {
        let directory = try makeTemporaryDirectory()
        let sink = DiagnosticLogSink(
            configuration: .init(enabled: true, maxFileBytes: 100_000, maxFileCount: 7),
            directory: directory
        )

        sink.append(level: .info, category: "test", message: "hello\tworld\nnext")
        sink.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 1)
        let contents = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(contents.contains("\tinfo\ttest\thello world next"))
    }

    func testDiagnosticLogSinkCanBeDisabled() throws {
        let directory = try makeTemporaryDirectory()
        let sink = DiagnosticLogSink(
            configuration: .init(enabled: false),
            directory: directory
        )

        sink.append(level: .info, category: "test", message: "ignored")
        sink.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(files.isEmpty)
    }

    func testDiagnosticLogConfigurationDefaultsAreDogfoodSized() {
        let configuration = DiagnosticLogConfiguration.load(from: [:])

        XCTAssertTrue(configuration.enabled)
        XCTAssertEqual(configuration.maxFileBytes, 10_000_000)
        XCTAssertEqual(configuration.maxFileCount, 14)
        XCTAssertEqual(configuration.maxMessageCharacters, 20_000)
    }

    func testDiagnosticLogConfigurationDisablesDogfoodLogInTestProcesses() {
        // Test runs share the dogfood log directory with the installed app; fixture
        // errors and synthetic guard decisions logged from `swift test` read as
        // real-usage failures during triage. The default sink must stay silent
        // whenever a test runner's XCTest* environment is present.
        let configuration = DiagnosticLogConfiguration.load(from: [
            "XCTestConfigurationFilePath": "/tmp/whatever.xctestconfiguration"
        ])

        XCTAssertFalse(configuration.enabled)
        // And the live process running this very test must be detected too.
        XCTAssertFalse(DiagnosticLogConfiguration.load().enabled)
    }

    func testDiagnosticLogConfigurationReadsDogfoodLimitOverrides() {
        let configuration = DiagnosticLogConfiguration.load(from: [
            "EPOS_DIAGNOSTIC_MAX_FILE_BYTES": "123456",
            "EPOS_DIAGNOSTIC_MAX_FILE_COUNT": "3",
            "EPOS_DIAGNOSTIC_MAX_MESSAGE_CHARS": "4567"
        ])

        XCTAssertEqual(configuration.maxFileBytes, 123_456)
        XCTAssertEqual(configuration.maxFileCount, 3)
        XCTAssertEqual(configuration.maxMessageCharacters, 4_567)
    }

    func testDiagnosticLogSinkUsesConfiguredMessageLimit() throws {
        let directory = try makeTemporaryDirectory()
        let sink = DiagnosticLogSink(
            configuration: .init(
                enabled: true,
                maxFileBytes: 100_000,
                maxFileCount: 7,
                maxMessageCharacters: 12
            ),
            directory: directory
        )

        sink.append(level: .info, category: "test", message: "abcdefghijklmnop")
        sink.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let contents = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(contents.contains("\tinfo\ttest\tabcdefghijkl\n"))
    }

    func testEposLoggerPrefixesActiveRecordingID() throws {
        RecordingLogContext.clear()
        defer { RecordingLogContext.clear() }
        let directory = try makeTemporaryDirectory()
        let sink = DiagnosticLogSink(
            configuration: .init(enabled: true, maxFileBytes: 100_000, maxFileCount: 7),
            directory: directory
        )
        let logger = EposLogger(category: "test", diagnostics: sink)

        RecordingLogContext.activate("rec-test")
        logger.info("hello")
        sink.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let contents = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(contents.contains("\tinfo\ttest\trecordingID=rec-test hello"))
    }

    func testRecordingLogContextClearSpecificIDDoesNotClearNewerID() {
        RecordingLogContext.clear()
        defer { RecordingLogContext.clear() }

        RecordingLogContext.activate("old-rec")
        RecordingLogContext.activate("new-rec")
        RecordingLogContext.clear("old-rec")

        XCTAssertEqual(RecordingLogContext.currentRecordingID, "new-rec")
    }

    func testTranscriptTimingDiagnosticsRedactsTranscriptTextByDefault() {
        var diagnostics = TranscriptTimingDiagnostics()
        diagnostics.start(now: Date(timeIntervalSince1970: 100))

        let message = diagnostics.eventMessage(
            kind: .partial,
            eventText: "private dictated phrase\nnext\tline",
            finalText: "private",
            partialText: "dictated phrase\nnext\tline",
            displayText: "private dictated phrase next line",
            now: Date(timeIntervalSince1970: 101.234)
        )

        XCTAssertTrue(message.contains("transcript timing"))
        XCTAssertTrue(message.contains("seq=1"))
        XCTAssertTrue(message.contains("kind=partial"))
        XCTAssertTrue(message.contains("elapsedMs=1234"))
        XCTAssertTrue(message.contains("eventChars=33"))
        XCTAssertTrue(message.contains("finalChars=7"))
        XCTAssertTrue(message.contains("partialChars=25"))
        // The display is the cleaned stream, not `finalText + partialText` (which is
        // 32 characters here); its count has to come from the display itself.
        XCTAssertTrue(message.contains("displayChars=33"))
        XCTAssertFalse(message.contains("private dictated phrase"))
        XCTAssertFalse(message.contains("eventText="))
        XCTAssertFalse(message.contains("finalText="))
        XCTAssertFalse(message.contains("partialText="))
        XCTAssertFalse(message.contains("displayText="))
    }

    /// `displayText=` must be the text the user actually watched — the cleaned
    /// stream the one final write also applies — not the raw `finalText + partialText`
    /// concatenation it used to carry. That field is the whole point of the opt-in:
    /// a log claiming the display was the raw assembly hides the exact divergence
    /// (streamed vs typed) it exists to investigate.
    func testTranscriptTimingDiagnosticsLogsTheStreamedDisplayNotTheRawAssembly() {
        var diagnostics = TranscriptTimingDiagnostics(includeTranscriptText: true)
        diagnostics.start(now: Date(timeIntervalSince1970: 100))

        let message = diagnostics.eventMessage(
            kind: .partial,
            eventText: "the the uh build is broken",
            finalText: "the the ",
            partialText: "uh build is broken",
            displayText: "the build is broken",
            now: Date(timeIntervalSince1970: 101.234)
        )

        XCTAssertTrue(message.contains(#"eventText="the the uh build is broken""#))
        XCTAssertTrue(message.contains(#"finalText="the the ""#))
        XCTAssertTrue(message.contains(#"partialText="uh build is broken""#))
        XCTAssertTrue(message.contains(#"displayText="the build is broken""#))
        XCTAssertFalse(message.contains(#"displayText="the the uh build is broken""#))
    }

    @MainActor
    func testCoordinatorTranscriptTimingLogRedactsRawTranscriptTextByDefault() throws {
        let directory = try makeTemporaryDirectory()
        let sink = DiagnosticLogSink(
            configuration: .init(enabled: true, maxFileBytes: 100_000, maxFileCount: 7),
            directory: directory
        )
        let coordinator = AppCoordinator(
            textInsertion: RecordingTextInsertionBackend(),
            diagnostics: sink,
            autoStart: false
        )

        coordinator.handlePartialTranscript("raw partial\nnext\tline")
        coordinator.logTranscriptTiming(kind: .partial, eventText: "raw partial\nnext\tline")
        coordinator.handleFinalTranscriptSegment("raw final")
        coordinator.logTranscriptTiming(kind: .final, eventText: "raw final")
        sink.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 1)
        let contents = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(contents.contains("\tinfo\tcoordinator\ttranscript timing seq=1 kind=partial"))
        XCTAssertTrue(contents.contains("\tinfo\tcoordinator\ttranscript timing seq=2 kind=final"))
        XCTAssertFalse(contents.contains("raw partial"))
        XCTAssertFalse(contents.contains("raw final"))
        XCTAssertFalse(contents.contains("eventText="))
        XCTAssertFalse(contents.contains("finalText="))
        XCTAssertFalse(contents.contains("partialText="))
        XCTAssertFalse(contents.contains("displayText="))
    }

    func testDogfoodTapDiscardsRecordingWhenTranscriptIsEmpty() throws {
        let directory = try makeTemporaryDirectory()
        let tap = DogfoodTap(recordingsDirectory: directory)
        tap.write(try makePCMBuffer())
        tap.stop(keeping: false)
        tap.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(files.isEmpty)
    }

    func testDogfoodTapKeepsRecordingWhenTranscriptExists() throws {
        let directory = try makeTemporaryDirectory()
        let tap = DogfoodTap(recordingsDirectory: directory)
        tap.write(try makePCMBuffer())
        tap.stop(keeping: true)
        tap.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.filter { $0.pathExtension == "wav" }.count, 1)
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("EposTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makePCMBuffer() throws -> AVAudioPCMBuffer {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128) else {
        throw XCTSkip("Unable to create PCM buffer")
    }
    buffer.frameLength = 128
    if let samples = buffer.floatChannelData?[0] {
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = 0.01
        }
    }
    return buffer
}

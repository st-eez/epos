import AVFoundation
import XCTest
@testable import SteezFlow

final class SmokeTests: XCTestCase {
    @MainActor
    func testCoordinatorStartsIdle() {
        // autoStart: false so the global NSEvent monitor isn't installed during tests.
        let coordinator = AppCoordinator(autoStart: false)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(coordinator.finalText, "")
        XCTAssertEqual(coordinator.partial, "")
        XCTAssertEqual(coordinator.displayText, "")
    }

    func testPermissionsSnapshotReturns() {
        let snapshot = PermissionsGate().snapshot()
        _ = snapshot.microphone
        _ = snapshot.speech
        _ = snapshot.accessibility
    }

    func testTranscriberInstantiates() {
        let transcriber = Transcriber(locale: Locale(identifier: "en-US"))
        XCTAssertEqual(transcriber.locale.identifier, "en-US")
    }

    func testSpeechContextParsesPhrases() {
        let contents = """
        # ignored
        CMUX

          AGENTS.md
        CMUX
        /
        """

        XCTAssertEqual(SpeechContext.parse(contents), ["CMUX", "AGENTS.md", "/"])
    }

    func testSpeechContextCapsPhraseCount() {
        let contents = (0..<105).map { "phrase-\($0)" }.joined(separator: "\n")

        let phrases = SpeechContext.parse(contents)

        XCTAssertEqual(phrases.count, SpeechContext.maxPhraseCount)
        XCTAssertEqual(phrases.last, "phrase-99")
    }

    func testSpeechContextCreatesMissingConfigFile() throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("speech-context.txt")
        let context = SpeechContext(fileURL: fileURL)

        XCTAssertEqual(context.load(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testInjectorPasteEmptyStringNoop() {
        TextInjector().paste("")
    }

    func testRecordingIndicatorMeterRespondsToSpeechRange() {
        let quietHeights = (0..<5).map { RecordingIndicator.barHeight($0, amplitude: 0.005) }
        let speechHeights = (0..<5).map { RecordingIndicator.barHeight($0, amplitude: 0.03) }
        let loudHeights = (0..<5).map { RecordingIndicator.barHeight($0, amplitude: 0.08) }

        XCTAssertGreaterThan(speechHeights.reduce(0, +), quietHeights.reduce(0, +))
        XCTAssertGreaterThan(loudHeights.reduce(0, +), speechHeights.reduce(0, +))
        XCTAssertGreaterThan(loudHeights.max() ?? 0, quietHeights.max() ?? 0)
    }

    func testRecordingIndicatorKeepsRecentTranscriptVisible() {
        let transcript = "open the project and run the full test suite then summarize the last failure in the final response"
        let display = RecordingIndicator.recentDisplayText(transcript, maxCharacters: 54)

        XCTAssertTrue(display.hasPrefix("..."))
        XCTAssertFalse(display.contains("open the project"))
        XCTAssertTrue(display.contains("last failure in the final response"))
    }

    func testRecordingIndicatorDefaultPreviewKeepsNewestText() {
        let transcript = (0..<80).map { "word\($0)" }.joined(separator: " ")
        let display = RecordingIndicator.recentDisplayText(transcript)

        XCTAssertTrue(display.hasPrefix("..."))
        XCTAssertFalse(display.contains("word0 word1 word2"))
        XCTAssertTrue(display.contains("word77 word78 word79"))
    }

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

    /// Regression: pre-fix, `Transcriber.finish()` hung in `await drain?.value`
    /// because Apple's `SpeechTranscriber.results` does not terminate after
    /// `cancelAndFinishNow()` on an analyzer that received zero input. Reproduces
    /// when fn is tapped too fast for any audio buffer to arrive.
    func testFinishWithoutInputReturnsPromptly() async throws {
        let transcriber = Transcriber(locale: Locale(identifier: "en-US"))
        do {
            _ = try await transcriber.start()
        } catch {
            throw XCTSkip("Transcriber.start() unavailable in test env: \(error)")
        }

        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await transcriber.finish()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        XCTAssertTrue(finished, "Transcriber.finish() hung with no input")
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SteezFlowTests-\(UUID().uuidString)", isDirectory: true)
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

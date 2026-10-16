import Foundation
import XCTest
@testable import Epos

@MainActor
final class RecognitionEventReplayTests: XCTestCase {
    func testCapturedRecognitionEvents() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["EPOS_RECOGNITION_REPLAY_INPUT"],
              let output = environment["EPOS_RECOGNITION_REPLAY_OUTPUT"] else {
            throw XCTSkip("Set recognition replay input and output paths to replay captured Speech events")
        }
        let rows = try String(contentsOfFile: input, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(CapturedRecognition.self, from: Data($0.utf8))
        }
        _ = try XCTUnwrap(rows.first, "Capture contains no recordings")
        try rows.forEach { try $0.validate() }
        let outputURL = URL(fileURLWithPath: output)
        try Data().write(to: outputURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        for row in rows {
            let result = try await replay(row)
            try handle.write(contentsOf: JSONEncoder().encode(result))
            try handle.write(contentsOf: Data("\n".utf8))
        }
    }

    private func replay(_ row: CapturedRecognition) async throws -> RecognitionReplayOutput {
        let backend = RecordingInsertionBackend()
        let trace = ReplayTransportTrace()
        let transport = FakeInlinePreviewTransport(onSend: { trace.record($0) })
        let suite = "EposRecognitionReplay-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var display = ""
        var publications: [ReplayPublication] = []
        var eventIndex = -1
        var eventStarted = ContinuousClock.now
        let recording = RecordingSession(
            recordingID: nil, audio: FakeMicrophoneCapture(), transcriber: FakeTranscriber(),
            textInsertion: backend, targetObserverFactory: { StableOpaqueObserver() },
            settings: Settings(inlinePreview: true),
            canonicalizer: TranscriptCanonicalizer(records: row.correctionDictionaryRecords),
            diagnostics: .shared,
            evidenceRecorder: CorrectionEvidenceRecorder(
                evidence: CorrectionEvidenceStore(defaults: defaults), captureDelays: [], currentRecordingID: { nil }
            ), isShortcutHeld: { true }, isMicrophoneAccessMissing: { false }, includeTranscriptText: false,
            onEvent: { _, event in
                if case .transcript(_, _, let text) = event {
                    display = text
                    publications.append(ReplayPublication(
                        eventIndex: eventIndex, text: text, milliseconds: trace.elapsedMilliseconds(),
                        processingMilliseconds: replayMilliseconds(from: eventStarted, to: .now)
                    ))
                }
            }
        )
        let preview = try XCTUnwrap(recording.makeInlinePreviewSession(bundleIdentifier: "com.test.app", transport: transport))
        recording.stageFinalizationSessions(
            inlinePreview: preview,
            insertion: FinalTranscriptInsertionSession(insertionSession: backend.startInsertionSession(), target: StableOpaqueObserver())
        )
        await preview.begin()
        let started = trace.started
        var released = false
        var eventProcessing: [Double] = []
        for (index, event) in row.recognitionTimeline.events.enumerated() {
            if !released, row.recognitionTimeline.releaseMilliseconds <= event.milliseconds {
                try await ContinuousClock().sleep(until: started.advanced(by: .milliseconds(row.recognitionTimeline.releaseMilliseconds)), tolerance: .zero)
                recording.release()
                released = true
            }
            try await ContinuousClock().sleep(until: started.advanced(by: .milliseconds(event.milliseconds)), tolerance: .zero)
            eventIndex = index
            eventStarted = .now
            if event.isFinal {
                recording.handleFinalTranscriptSegment(event.text)
                await recording.commitConfirmedPhraseIfHeld()
            } else {
                recording.handlePartialTranscript(event.text)
            }
            eventProcessing.append(replayMilliseconds(from: eventStarted, to: .now))
        }
        if !released {
            try await ContinuousClock().sleep(until: started.advanced(by: .milliseconds(row.recognitionTimeline.releaseMilliseconds)), tolerance: .zero)
            recording.release()
        }
        recording.promotePartialTranscriptAsFallbackFinalIfNeeded()
        let route = await recording.commitFinalTranscript(display)
        await preview.discard()
        let commands = trace.commands
        let delivered = try commands.filter { $0.line.hasPrefix("seal") || $0.line.hasPrefix("commit") }.map {
            try decodePayload($0.line)
        }.joined()
        XCTAssertEqual(route, .completed(.accepted, viaIME: true), row.file)
        XCTAssertEqual(delivered, display, row.file)
        XCTAssertTrue(backend.inserted.isEmpty, row.file)
        return RecognitionReplayOutput(
            file: row.file, referenceDesignation: row.referenceDesignation,
            delivered: delivered, route: String(describing: route),
            score: TranscriptEvalScoring.wordErrorScore(reference: row.reference, hypothesis: delivered),
            publications: publications, commands: commands, eventProcessingMilliseconds: eventProcessing
        )
    }

    private func decodePayload(_ line: String) throws -> String {
        let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let payload = String(try XCTUnwrap(fields.last))
        if fields[0].hasSuffix("64") {
            return try XCTUnwrap(Data(base64Encoded: payload).flatMap { String(data: $0, encoding: .utf8) })
        }
        return payload
    }
}

private struct CapturedRecognition: Decodable {
    struct Timeline: Decodable {
        struct Event: Decodable {
            let milliseconds: Double
            let isFinal: Bool
            let text: String
        }
        let events: [Event]
        let releaseMilliseconds: Double
    }
    struct Metrics: Decodable {
        let expectedAudioFrames: UInt64
        let submittedAudioFrames: UInt64
        let consumedAudioFrames: UInt64
    }
    let file: String
    let reference: String
    let referenceDesignation: String
    let correctionDictionaryRecords: [CorrectionRecord]
    let transcript: String
    let error: String?
    let metrics: Metrics
    let recognitionTimeline: Timeline

    func validate() throws {
        guard error == nil, metrics.expectedAudioFrames > 0,
              metrics.expectedAudioFrames == metrics.submittedAudioFrames,
              metrics.expectedAudioFrames == metrics.consumedAudioFrames,
              !recognitionTimeline.events.isEmpty,
              recognitionTimeline.releaseMilliseconds.isFinite,
              recognitionTimeline.releaseMilliseconds >= 0 else { throw InvalidCapture(file: file) }
        var previous = 0.0
        var final = "", partial = ""
        for event in recognitionTimeline.events {
            guard event.milliseconds.isFinite, event.milliseconds >= previous else { throw InvalidCapture(file: file) }
            previous = event.milliseconds
            if event.isFinal { final += event.text; partial = "" } else { partial = event.text }
        }
        guard (final + partial).trimmingCharacters(in: .whitespacesAndNewlines) == transcript else {
            throw InvalidCapture(file: file)
        }
    }
}

private struct RecognitionReplayOutput: Encodable {
    let file: String
    let referenceDesignation: String
    let delivered: String
    let route: String
    let score: TranscriptWordErrorScore
    let publications: [ReplayPublication]
    let commands: [ReplayCommand]
    let eventProcessingMilliseconds: [Double]
}

private struct ReplayPublication: Encodable {
    let eventIndex: Int
    let text: String
    let milliseconds: Double
    let processingMilliseconds: Double
}

private struct ReplayCommand: Encodable {
    let line: String
    let milliseconds: Double
}

private final class ReplayTransportTrace: @unchecked Sendable {
    let started = ContinuousClock.now
    private let lock = NSLock()
    private var stored: [ReplayCommand] = []
    var commands: [ReplayCommand] { lock.withLock { stored } }

    func elapsedMilliseconds() -> Double { replayMilliseconds(from: started, to: .now) }
    func record(_ line: String) {
        lock.withLock { stored.append(ReplayCommand(line: line, milliseconds: elapsedMilliseconds())) }
    }
}

private func replayMilliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
    let components = start.duration(to: end).components
    return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
}

private struct InvalidCapture: Error {
    let file: String
}

import XCTest
@testable import Epos

final class ReliabilityDiagnosticsTests: XCTestCase {
    func testEveryOutcomeHasStableAuditToken() {
        XCTAssertEqual(
            [
                ReliabilityOutcome.setupFailed.rawValue,
                ReliabilityOutcome.noInput.rawValue,
                ReliabilityOutcome.recognizerFailed.rawValue,
                ReliabilityOutcome.emptyTranscript.rawValue,
                ReliabilityOutcome.targetRefused.rawValue,
                ReliabilityOutcome.backendRefused.rawValue,
                ReliabilityOutcome.deliveryVerified.rawValue,
                ReliabilityOutcome.deliveryMismatch.rawValue,
                ReliabilityOutcome.writeAcceptedUnverified.rawValue,
                ReliabilityOutcome.cancelledBeforeAudio.rawValue
            ],
            [
                "setup-failed",
                "no-input",
                "recognizer-failed",
                "empty-transcript",
                "target-refused",
                "backend-refused",
                "delivery-verified",
                "delivery-mismatch",
                "write-accepted-unverified",
                "cancelled-before-audio"
            ]
        )
    }

    func testTerminalOutcomeIsStructuredPrivacySafeAndEmittedOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EposReliability-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = DiagnosticLogSink(
            configuration: .init(enabled: true),
            directory: directory
        )
        let recording = ReliabilityRecording(recordingID: "rec-test", diagnostics: sink)

        recording.recordAudioBuffer(frameCount: 320)
        recording.markReleased()
        recording.emit(
            .deliveryVerified,
            transcriptUTF16: 12,
            writeAttempted: true,
            writeAccepted: true,
            readbackAvailable: true,
            readbackMatched: true
        )
        recording.emit(.deliveryMismatch, transcriptUTF16: 999)
        sink.flush()

        let log = try String(
            contentsOf: try XCTUnwrap(
                FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                ).first
            ),
            encoding: .utf8
        )
        let outcomes = log.components(separatedBy: "\n").filter {
            $0.contains("reliability outcome")
        }
        XCTAssertEqual(outcomes.count, 1)
        let outcome = try XCTUnwrap(outcomes.first)
        XCTAssertTrue(outcome.contains("recordingID=rec-test reliability outcome schema=1"))
        XCTAssertTrue(outcome.contains("outcome=delivery-verified"))
        XCTAssertTrue(outcome.contains("audioBuffers=1 audioFrames=320 transcriptUTF16=12"))
        XCTAssertTrue(outcome.contains("writeAttempted=true writeAccepted=true"))
        XCTAssertTrue(outcome.contains("readbackAvailable=true readbackMatched=true"))
        XCTAssertFalse(outcome.contains("secret transcript"))
        XCTAssertFalse(outcome.contains("999"))
    }

    func testPreReleaseOutcomeUsesUnknownLatency() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EposReliability-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = DiagnosticLogSink(
            configuration: .init(enabled: true),
            directory: directory
        )
        let recording = ReliabilityRecording(recordingID: "setup", diagnostics: sink)

        recording.emit(.setupFailed)
        sink.flush()

        let url = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first
        )
        let log = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(log.contains("outcome=setup-failed"))
        XCTAssertTrue(log.contains("latencyMs=-1"))
    }

    func testRecognizerFailureRemainsOutcomeWhileDeliveryEvidenceIsPreserved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EposReliability-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = DiagnosticLogSink(
            configuration: .init(enabled: true),
            directory: directory
        )
        let recording = ReliabilityRecording(recordingID: "fallback", diagnostics: sink)

        recording.emitFinal(
            recognizerFailed: true,
            insertionResult: .accepted,
            delivery: .matched,
            transcriptUTF16: 18
        )
        sink.flush()

        let url = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first
        )
        let log = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(log.contains("outcome=recognizer-failed"))
        XCTAssertTrue(log.contains("transcriptUTF16=18"))
        XCTAssertTrue(log.contains("writeAttempted=true writeAccepted=true"))
        XCTAssertTrue(log.contains("readbackAvailable=true readbackMatched=true"))
    }
}

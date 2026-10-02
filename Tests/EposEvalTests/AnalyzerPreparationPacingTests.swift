import AVFoundation
import Foundation
import Speech
import XCTest
@testable import EposEval

final class AnalyzerPreparationPacingTests: XCTestCase {
    func testStartupAudioKeepsTheHoldTimelineAndEveryFrame() async throws {
        let audio = try makeAudio()
        let hold = ContinuousClock.now.advanced(by: .seconds(-2))
        let deadlines = PreparationDeadlines()
        let (stream, continuation) = AsyncStream<(AnalyzerInput, UInt64)>.makeStream()
        let feed = try await audio.feed(into: continuation, holdStarted: hold) {
            deadlines.append($0)
        }
        continuation.finish()

        XCTAssertEqual(deadlines.values.count, 2)
        for (expected, deadline) in zip([0.05, 0.075], deadlines.values) {
            let elapsed = hold.duration(to: deadline).components
            XCTAssertEqual(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                           expected, accuracy: 0.000_001)
        }
        var received: [UInt64] = []
        for await (_, frames) in stream { received.append(frames) }
        XCTAssertEqual(received, [800, 400])
        XCTAssertEqual(feed.submittedFrames, 1_200)
        try audio.verifyFrames(submitted: feed.submittedFrames, consumed: received.reduce(0, +))
    }

    func testAFrameMismatchCannotProduceSuccessfulMetrics() throws {
        let audio = try makeAudio()
        XCTAssertThrowsError(try audio.verifyFrames(submitted: 1_200, consumed: 1_199)) {
            guard case PreparationEvalError.audioFrameMismatch = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }
        XCTAssertThrowsError(try audio.verifyFrames(submitted: 800, consumed: 1_200))
    }

    func testBacklogRefusalFailsInsteadOfScoringTruncatedAudio() async throws {
        let audio = try makeAudio()
        let (stream, continuation) = AsyncStream<(AnalyzerInput, UInt64)>.makeStream(bufferingPolicy: .bufferingOldest(1))
        defer { continuation.finish() }
        do {
            _ = try await audio.feed(into: continuation, holdStarted: .now) { _ in }
            XCTFail("the second buffer must be refused")
        } catch PreparationEvalError.audioInputRefused {
            // The result must not masquerade as a faster, shorter recording.
        }
        continuation.finish()
        var received: [UInt64] = []
        for await (_, frames) in stream { received.append(frames) }
        XCTAssertEqual(received, [800])
    }

    func testCancellationDuringAnUncooperativeWaitDoesNotFeedTheAnalyzer() async throws {
        let audio = try makeAudio()
        let (stream, continuation) = AsyncStream<(AnalyzerInput, UInt64)>.makeStream()
        let entered = expectation(description: "wait entered")
        let gate = PreparationWaitGate()
        defer { gate.release() }
        let task = Task {
            try await audio.feed(into: continuation, holdStarted: .now) { _ in
                entered.fulfill()
                await gate.wait()
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        gate.release()
        do {
            _ = try await task.value
            XCTFail("the canceled trial must stop")
        } catch is CancellationError {
            // The test waiter ignores cancellation; the feeder checks after it.
        }
        continuation.finish()
        var consumed: UInt64 = 0
        for await (_, frames) in stream { consumed += frames }
        XCTAssertEqual(consumed, 0)
    }

    private func makeAudio() throws -> AnalyzerPreparationAudio {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                               channels: 1, interleaved: true))
        let buffers = try [800, 400].map { frames in
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            buffer.int16ChannelData?[0].initialize(repeating: 0, count: frames)
            return buffer
        }
        return AnalyzerPreparationAudio(format: format, buffers: buffers, durationSeconds: 0.075)
    }
}

private final class PreparationDeadlines: @unchecked Sendable {
    private let lock = NSLock()
    private var deadlines: [ContinuousClock.Instant] = []
    var values: [ContinuousClock.Instant] { lock.withLock { deadlines } }
    func append(_ deadline: ContinuousClock.Instant) { lock.withLock { deadlines.append(deadline) } }
}

private final class PreparationWaitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if released { return true }
                self.continuation = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func release() {
        let pending = lock.withLock {
            released = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}

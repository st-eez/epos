import AVFoundation
import XCTest
@testable import Epos

@MainActor
final class RecordingCuePlaybackTests: XCTestCase {
    func testCaptureClosingDuringPreparationDiscardsStartCue() async throws {
        let preparing = expectation(description: "start cue preparing")
        let endPlayed = expectation(description: "end cue played")
        let gate = DispatchSemaphore(value: 0)
        let start = try SilentCuePlayer()
        let end = try SilentCuePlayer { endPlayed.fulfill() }
        let playback = RecordingCue.Playback(makeStart: {
            preparing.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 3), .success)
            return start
        }, makeEnd: { end })

        playback.playStart()
        await fulfillment(of: [preparing], timeout: 1)
        playback.captureStopped()
        playback.playEnd()
        gate.signal()
        await fulfillment(of: [endPlayed], timeout: 1)
        XCTAssertEqual(start.playCount, 0)
        XCTAssertEqual(end.playCount, 1)
    }

    func testRepeatedCaptureCleanupPreservesPendingEndCue() async throws {
        let startPlayed = expectation(description: "start cue played")
        let preparing = expectation(description: "end cue preparing")
        let endPlayed = expectation(description: "end cue played")
        let gate = DispatchSemaphore(value: 0)
        let start = try SilentCuePlayer { startPlayed.fulfill() }
        let end = try SilentCuePlayer { endPlayed.fulfill() }
        let playback = RecordingCue.Playback(makeStart: { start }, makeEnd: {
            preparing.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 3), .success)
            return end
        })

        playback.playStart()
        await fulfillment(of: [startPlayed], timeout: 1)
        playback.captureStopped()
        playback.playEnd()
        await fulfillment(of: [preparing], timeout: 1)
        playback.captureStopped()
        playback.captureStopped()
        gate.signal()
        await fulfillment(of: [endPlayed], timeout: 1)
        XCTAssertEqual(end.playCount, 1)
    }

    func testNewCaptureDiscardsEndCueStillPreparing() async throws {
        let preparing = expectation(description: "end cue preparing")
        let startPlayed = expectation(description: "new start cue played")
        let gate = DispatchSemaphore(value: 0)
        let start = try SilentCuePlayer { startPlayed.fulfill() }
        let end = try SilentCuePlayer()
        let playback = RecordingCue.Playback(makeStart: { start }, makeEnd: {
            preparing.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 3), .success)
            return end
        })

        playback.captureStopped()
        playback.playEnd()
        await fulfillment(of: [preparing], timeout: 1)
        playback.playStart()
        gate.signal()
        await fulfillment(of: [startPlayed], timeout: 1)
        XCTAssertEqual(start.playCount, 1)
        XCTAssertEqual(end.playCount, 0)
    }
}

private final class SilentCuePlayer: AVAudioPlayer, @unchecked Sendable {
    private let countLock = NSLock()
    private var count = 0
    private let onPlay: @Sendable () -> Void
    var playCount: Int { countLock.withLock { count } }

    init(onPlay: @escaping @Sendable () -> Void = {}) throws {
        self.onPlay = onPlay
        let reference = try XCTUnwrap(RecordingCue.makeStartSound())
        try super.init(data: XCTUnwrap(reference.data), fileTypeHint: nil)
    }

    override func prepareToPlay() -> Bool { true }

    override func play() -> Bool {
        countLock.withLock { count += 1 }
        onPlay()
        return true
    }
}

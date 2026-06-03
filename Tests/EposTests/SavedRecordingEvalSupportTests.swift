import Foundation
import XCTest
@testable import Epos

final class SavedRecordingEvalSupportTests: XCTestCase {
    func testSelectedRecordingsUsesExplicitRecordingFilesInConfiguredOrder() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeRecording("a.wav", in: directory)
        try makeRecording("b.wav", in: directory)
        try makeRecording("c.wav", in: directory)

        let selected = try SavedRecordingEvalSupport.selectedRecordings(
            in: directory,
            limit: 1,
            latest: false,
            environment: ["EPOS_EVAL_RECORDING_FILES": "b.wav, a.wav"]
        )

        XCTAssertEqual(selected.map(\.lastPathComponent), ["b.wav", "a.wav"])
    }

    func testSelectedRecordingsRejectsMissingExplicitRecording() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try SavedRecordingEvalSupport.selectedRecordings(
            in: directory,
            limit: nil,
            latest: false,
            environment: ["EPOS_EVAL_RECORDING_FILES": "missing.wav"]
        )) { error in
            XCTAssertTrue(String(describing: error).contains("recording not found"))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeRecording(_ name: String, in directory: URL) throws {
        try Data().write(to: directory.appendingPathComponent(name))
    }
}

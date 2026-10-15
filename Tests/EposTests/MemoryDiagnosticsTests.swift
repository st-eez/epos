import Darwin
import XCTest
@testable import Epos

@MainActor
final class MemoryDiagnosticsTests: XCTestCase {
    func testSamplesPreserveBytesStateTriggerAndRecordingID() {
        let state = MemoryTestState()
        var rows: [(String, String?)] = []
        let diagnostics = MemoryDiagnostics(
            sample: { .available(residentBytes: 123_456, physicalFootprintBytes: 234_567) },
            state: { state.value },
            emit: { rows.append(($0, $1)) }
        )
        diagnostics.record(.readiness)
        state.value = .finalizing
        diagnostics.record(.recordingComplete, recordingID: "example")

        XCTAssertEqual(rows.map(\.0), [
            "memory sample schema=1 trigger=readiness state=idle outcome=available "
                + "residentBytes=123456 physicalFootprintBytes=234567",
            "memory sample schema=1 trigger=recording-complete state=finalizing outcome=available "
                + "residentBytes=123456 physicalFootprintBytes=234567"
        ])
        XCTAssertNil(rows[0].1)
        XCTAssertEqual(rows[1].1, "example")
    }

    func testSamplingFailureDoesNotFabricateZeroBytes() {
        var rows: [String] = []
        let diagnostics = MemoryDiagnostics(
            sample: { .unavailable(kernelReturn: KERN_INVALID_ARGUMENT) },
            state: { .idle },
            emit: { message, _ in rows.append(message) }
        )
        diagnostics.record(.periodic)

        XCTAssertEqual(rows, [
            "memory sample schema=1 trigger=periodic state=idle outcome=unavailable "
                + "kernelReturn=\(KERN_INVALID_ARGUMENT)"
        ])
        XCTAssertFalse(rows[0].contains("Bytes="))
    }

    func testNativeSelfSampleReturnsResidentAndPhysicalFootprintBytes() {
        guard case .available(let residentBytes, let physicalFootprintBytes) = ProcessMemorySample.read() else {
            return XCTFail("native task_vm_info sampling failed in the test process")
        }
        XCTAssertGreaterThan(residentBytes, 0)
        XCTAssertGreaterThan(physicalFootprintBytes, 0)
    }

    func testRuntimePolicySuppressesTestsEvaluationsAndDisabledLogs() {
        XCTAssertTrue(MemoryDiagnostics.shouldRun(environment: [:], isTestProcess: false))
        for environment in [
            ["SWIFT_TESTING_ENABLED": "1"],
            ["XCTestConfigurationFilePath": "test"],
            ["EPOS_RUN_ANALYZER_PREPARATION_EVAL": "1"],
            ["EPOS_RUN_SIGNED_APPLE_PRESET_EVAL": "1"],
            ["EPOS_DIAGNOSTIC_LOGS": "0"]
        ] {
            XCTAssertFalse(MemoryDiagnostics.shouldRun(environment: environment, isTestProcess: false))
        }
        XCTAssertFalse(MemoryDiagnostics.shouldRun(environment: [:], isTestProcess: true))
        XCTAssertFalse(MemoryDiagnostics.shouldRun())
    }

    func testPeriodicSamplesUseCurrentStateAndOneMinuteSleeps() async {
        let (ticks, continuation) = AsyncStream<Void>.makeStream()
        let periodic = expectation(description: "two scheduled samples")
        periodic.expectedFulfillmentCount = 2
        let state = MemoryTestState()
        var rows: [String] = []
        let diagnostics = MemoryDiagnostics(
            sample: { .available(residentBytes: 10, physicalFootprintBytes: 20) },
            state: { state.value },
            emit: { message, _ in
                rows.append(message)
                if message.contains("trigger=periodic") { periodic.fulfill() }
            },
            sleep: { duration in
                XCTAssertEqual(duration, .seconds(60))
                var iterator = ticks.makeAsyncIterator()
                guard await iterator.next() != nil else { throw CancellationError() }
            }
        )
        diagnostics.start()
        diagnostics.start()
        XCTAssertEqual(rows.count, 1, "starting twice must not duplicate launch sampling or the timer")
        XCTAssertTrue(rows[0].contains("trigger=launch state=idle"))
        state.value = .recording
        continuation.yield(())
        continuation.yield(())
        await fulfillment(of: [periodic], timeout: 2)
        diagnostics.stop()
        continuation.finish()

        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.dropFirst().allSatisfy { $0.contains("trigger=periodic state=recording") })
    }

    func testReleasingOwnerCancelsSleepingTaskWithoutRetainingDiagnostics() async {
        let sleeping = expectation(description: "timer is waiting")
        let cancelled = expectation(description: "owner destruction cancels timer")
        var diagnostics: MemoryDiagnostics? = MemoryDiagnostics(
            sample: { .available(residentBytes: 1, physicalFootprintBytes: 2) },
            state: { .idle },
            emit: { _, _ in },
            sleep: { _ in
                sleeping.fulfill()
                do {
                    try await Task.sleep(for: .seconds(3_600))
                    XCTFail("the wait must be cancelled")
                } catch {
                    cancelled.fulfill()
                    throw error
                }
            }
        )
        weak let owner = diagnostics
        diagnostics?.start()
        await fulfillment(of: [sleeping], timeout: 2)
        diagnostics = nil
        XCTAssertNil(owner)
        await fulfillment(of: [cancelled], timeout: 2)
    }
}

@MainActor
private final class MemoryTestState {
    var value = CoordinatorState.idle
}

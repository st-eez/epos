import AppKit
import XCTest
@testable import Epos

@MainActor
final class ElectronAccessibilityWakerTests: XCTestCase {
    func testStartWakesTheFrontmostApplication() async {
        let woken = expectation(description: "frontmost app poked")
        let expectedPid = NSRunningApplication.current.processIdentifier
        let waker = ElectronAccessibilityWaker(
            notificationCenter: NotificationCenter(),
            frontmostApplication: { .current },
            wake: { pid in
                XCTAssertEqual(pid, expectedPid)
                woken.fulfill()
                return .woke
            }
        )
        waker.start()
        await fulfillment(of: [woken], timeout: 2)
    }

    func testEveryActivationWakesTheActivatedApplication() async {
        let center = NotificationCenter()
        let first = expectation(description: "first activation poked")
        let second = expectation(description: "second activation poked")
        let wakes = WakeCounter()
        let waker = ElectronAccessibilityWaker(
            notificationCenter: center,
            frontmostApplication: { nil },
            wake: { _ in
                (wakes.increment() == 1 ? first : second).fulfill()
                return .woke
            }
        )
        waker.start()
        center.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]
        )
        // Each activation re-asserts; a later one is only ever folded into a wake
        // that has not run yet, so this test separates them by the first's arrival.
        await fulfillment(of: [first], timeout: 2)
        center.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]
        )
        await fulfillment(of: [second], timeout: 2)
    }

    func testActivationStormWhileAWakeRunsCollapsesToOneReassert() async {
        let center = NotificationCenter()
        let running = expectation(description: "first wake running")
        let reasserted = expectation(description: "storm re-asserted once")
        let release = DispatchSemaphore(value: 0)
        let wakes = WakeCounter()
        let waker = ElectronAccessibilityWaker(
            notificationCenter: center,
            frontmostApplication: { .current },
            wake: { _ in
                switch wakes.increment() {
                case 1:
                    running.fulfill()
                    release.wait()
                case 2:
                    reasserted.fulfill()
                default:
                    XCTFail("activation storm did not coalesce")
                }
                return .woke
            }
        )
        waker.start()
        await fulfillment(of: [running], timeout: 2)
        for _ in 0..<10 {
            center.post(
                name: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]
            )
        }
        release.signal()
        await fulfillment(of: [reasserted], timeout: 2)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(wakes.value, 2)
    }

    func testWakeQueueCoalescesPerProcessIdentifier() {
        let queue = AccessibilityWakeQueue()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let ranEverything = expectation(description: "queue drained")
        ranEverything.expectedFulfillmentCount = 3
        let firstPid = WakeCounter()
        let secondPid = WakeCounter()

        queue.enqueue(processIdentifier: 1) {
            _ = firstPid.increment()
            started.signal()
            release.wait()
            ranEverything.fulfill()
        }
        guard started.wait(timeout: .now() + 2) == .success else {
            release.signal()
            return XCTFail("the first wake never started")
        }
        // The queue is occupied, so every one of these is either the single
        // pending wake for its pid or a coalesced duplicate.
        for _ in 0..<10 {
            queue.enqueue(processIdentifier: 1) {
                _ = firstPid.increment()
                ranEverything.fulfill()
            }
            queue.enqueue(processIdentifier: 2) {
                _ = secondPid.increment()
                ranEverything.fulfill()
            }
        }
        release.signal()
        wait(for: [ranEverything], timeout: 2)
        XCTAssertEqual(firstPid.value, 2)
        XCTAssertEqual(secondPid.value, 1)
    }

    func testActivationWithoutApplicationInfoWakesNothing() async {
        let center = NotificationCenter()
        let waker = ElectronAccessibilityWaker(
            notificationCenter: center,
            frontmostApplication: { nil },
            wake: { _ in
                XCTFail("no application to wake")
                return .unsupported
            }
        )
        waker.start()
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // Give a wrongly-spawned wake task room to run before the assertion window closes.
        try? await Task.sleep(for: .milliseconds(50))
    }

    func testPressTimeReassertWakesTheFrontmostApplicationOnlyOnceStarted() async {
        let started = expectation(description: "frontmost app poked at start")
        let pressed = expectation(description: "frontmost app poked at press time")
        let wakes = WakeCounter()
        var frontmostReads = 0
        let waker = ElectronAccessibilityWaker(
            notificationCenter: NotificationCenter(),
            frontmostApplication: {
                frontmostReads += 1
                return .current
            },
            wake: { _ in
                (wakes.increment() == 1 ? started : pressed).fulfill()
                return .woke
            }
        )
        // Not started (the test-runner state): a press must stay off the machine.
        waker.wakeFrontmostApplication()
        XCTAssertEqual(frontmostReads, 0, "a pre-start press must not inspect the real frontmost app")
        waker.start()
        await fulfillment(of: [started], timeout: 2)
        waker.wakeFrontmostApplication()
        await fulfillment(of: [pressed], timeout: 2)
    }
}

/// Wake counts are tallied off the main thread by the wake queue.
private final class WakeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

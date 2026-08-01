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
                return true
            }
        )
        waker.start()
        await fulfillment(of: [woken], timeout: 2)
    }

    func testEveryActivationWakesTheActivatedApplication() async {
        let center = NotificationCenter()
        let woken = expectation(description: "activated app poked on each activation")
        woken.expectedFulfillmentCount = 2
        let waker = ElectronAccessibilityWaker(
            notificationCenter: center,
            frontmostApplication: { nil },
            wake: { _ in
                woken.fulfill()
                return true
            }
        )
        waker.start()
        for _ in 0..<2 {
            center.post(
                name: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]
            )
        }
        await fulfillment(of: [woken], timeout: 2)
    }

    func testActivationWithoutApplicationInfoWakesNothing() async {
        let center = NotificationCenter()
        let waker = ElectronAccessibilityWaker(
            notificationCenter: center,
            frontmostApplication: { nil },
            wake: { _ in
                XCTFail("no application to wake")
                return false
            }
        )
        waker.start()
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // Give a wrongly-spawned wake task room to run before the assertion window closes.
        try? await Task.sleep(for: .milliseconds(50))
    }
}

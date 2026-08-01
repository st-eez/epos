import AppKit
import ApplicationServices
import Foundation

/// Wakes the dormant accessibility tree of Chromium-based (Electron) apps so the
/// fn-press target capture can see their focused element.
///
/// Chromium keeps a renderer's accessibility tree unbuilt until an assistive
/// client announces itself; until then the system-wide focused-element read that
/// anchors every insertion session returns `.noValue`, and dictation into such an
/// app is refused without ever being unsafe — or possible. Setting the
/// Electron-documented `AXManualAccessibility` attribute on the app element is
/// that announcement (verified live against Claude.app, 2026-07-31).
///
/// Behavioral choices, each for determinism:
/// - The wake happens at app activation, not at fn press, so the tree build —
///   which Chromium performs asynchronously — is done long before a capture
///   depends on it.
/// - Every activation re-asserts the attribute. The set is idempotent, and
///   re-asserting self-heals Chromium's disable-after-idle behavior, which put
///   Claude.app's tree back to sleep mid-session when the flag was cleared.
/// - The attribute is never unset. Clearing it is what re-broke the first live
///   repro, and it would also yank the tree from any other assistive client.
/// - Hosts that don't support the attribute (every native app) fail the set with
///   no side effect, which keeps the wake unconditional instead of guessing at
///   Electron detection.
@MainActor
public final class ElectronAccessibilityWaker {
    private nonisolated static let manualAccessibilityAttribute = "AXManualAccessibility"

    private let notificationCenter: NotificationCenter
    private let frontmostApplication: @MainActor () -> NSRunningApplication?
    private let wake: @Sendable (pid_t) -> Bool
    private var activationObserver: NSObjectProtocol?
    private let log = EposLogger(category: "inject")

    public init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        frontmostApplication: @escaping @MainActor () -> NSRunningApplication? = {
            NSWorkspace.shared.frontmostApplication
        },
        wake: @escaping @Sendable (pid_t) -> Bool = ElectronAccessibilityWaker.requestManualAccessibility
    ) {
        self.notificationCenter = notificationCenter
        self.frontmostApplication = frontmostApplication
        self.wake = wake
    }

    /// Wakes the app that is frontmost right now, then every app the user
    /// activates from here on. Idempotent per activation; safe before the
    /// Accessibility grant, where the set simply fails until trust arrives.
    /// The subscription is app-lifetime — there is deliberately no teardown,
    /// and the notification block captures no `self`.
    public func start() {
        guard activationObserver == nil else { return }
        if let frontmost = frontmostApplication() {
            wakeDetached(
                processIdentifier: frontmost.processIdentifier,
                bundleIdentifier: frontmost.bundleIdentifier
            )
        }
        activationObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [wake, log] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
            Self.wakeDetached(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                wake: wake,
                log: log
            )
        }
    }

    private func wakeDetached(processIdentifier: pid_t, bundleIdentifier: String?) {
        Self.wakeDetached(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            wake: wake,
            log: log
        )
    }

    /// The AX set is synchronous IPC into the target app, bounded by a messaging
    /// timeout but still nothing the main actor should wait on per app switch.
    private nonisolated static func wakeDetached(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        wake: @escaping @Sendable (pid_t) -> Bool,
        log: EposLogger
    ) {
        Task.detached(priority: .utility) {
            guard wake(processIdentifier) else { return }
            log.info(
                "woke accessibility tree of \(bundleIdentifier ?? "pid \(processIdentifier)")"
            )
        }
    }

    public nonisolated static func requestManualAccessibility(processIdentifier: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let application = AXUIElementCreateApplication(processIdentifier)
        // Bounded so a wedged target app cannot stall the wake task; generous
        // against the sub-millisecond healthy case.
        AXUIElementSetMessagingTimeout(application, 0.25)
        return AXUIElementSetAttributeValue(
            application,
            manualAccessibilityAttribute as CFString,
            kCFBooleanTrue
        ) == .success
    }
}

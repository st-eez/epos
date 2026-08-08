import AppKit
import ApplicationServices
import Foundation
import Synchronization

/// Serial off-actor runner for the blocking `AXManualAccessibility` set, with
/// per-pid coalescing.
///
/// The set is synchronous IPC into the target app; a wedged host burns the full
/// messaging timeout. Running one per app activation on the Swift cooperative
/// pool let a handful of wedged targets occupy every cooperative thread, after
/// which unrelated `Task {}` work elsewhere in the app (one per system-wide
/// modifier keypress, among others) queued behind it. A dedicated serial queue
/// bounds the blocking to exactly one thread that is not the pool's.
///
/// Coalescing falls out of the same seam: while a wake for a pid is queued and
/// not yet running, further requests for that pid are dropped, so an app-switch
/// storm collapses instead of stacking. A pid is un-pended when its work item
/// starts, not when it finishes, so an activation that arrives during a wake
/// still re-asserts afterwards — at most one running plus one queued per pid.
final class AccessibilityWakeQueue: Sendable {
    private let queue = DispatchQueue(label: "com.steez.Epos.accessibility-wake", qos: .utility)
    private let pending = Mutex<Set<pid_t>>([])

    /// Runs `work` on the serial queue unless a wake for `processIdentifier` is
    /// already queued and waiting.
    func enqueue(processIdentifier: pid_t, work: @escaping @Sendable () -> Void) {
        let enqueued = pending.withLock { $0.insert(processIdentifier).inserted }
        guard enqueued else { return }
        queue.async {
            self.pending.withLock { _ = $0.remove(processIdentifier) }
            work()
        }
    }
}

/// Wakes the dormant accessibility tree of Chromium-based (Electron) apps so the
/// fn-press target capture can see their focused element.
///
/// Chromium keeps a renderer's accessibility tree unbuilt until an assistive
/// client announces itself; until then the system-wide focused-element read that
/// anchors every insertion session returns `.noValue`, and dictation into such an
/// app is refused without ever being unsafe — or possible. Setting the
/// Electron-documented `AXManualAccessibility` attribute on the app element is
/// that announcement (verified live against Claude.app, 2026-07-31; the
/// attribute's getter reads false even after a successful set, so a resolving
/// focused element — not the readback — is the health signal).
///
/// Behavioral choices, each for determinism:
/// - The wake happens at app activation, not first at fn press, so the tree
///   build — which Chromium performs asynchronously — is done long before a
///   capture depends on it. A press-time re-assert backstops the long
///   single-app session and the grant that arrives without an app switch.
/// - Every activation re-asserts the attribute. The set is idempotent, and
///   re-asserting self-heals Chromium's disable-after-idle behavior, which put
///   Claude.app's tree back to sleep mid-session when the flag was cleared.
///   Activations that pile up on a pid whose wake has not run yet coalesce into
///   that one pending wake (see `AccessibilityWakeQueue`); the assert still
///   lands, it just doesn't land once per redundant switch.
/// - The attribute is never unset. Clearing it is what re-broke the first live
///   repro, and it would also yank the tree from any other assistive client.
/// - Hosts that don't support the attribute (every native app) fail the set with
///   no side effect, which keeps the wake unconditional instead of guessing at
///   Electron detection.
@MainActor
public final class ElectronAccessibilityWaker {
    /// A classified wake attempt: the AX set's distinct failure modes matter for
    /// triage (never-attempted vs timed-out vs unsupported read very differently
    /// against a "no fn-press target was captured" refusal) and must not collapse
    /// into one discarded Bool at the point of measurement.
    public enum WakeAttempt: Equatable, Sendable {
        case woke
        /// The host has no `AXManualAccessibility` — every native app, on every
        /// activation. Logged at debug so the discrimination is preserved
        /// without an info line per app switch.
        case unsupported
        /// No Accessibility grant yet. The user-facing permission story is owned
        /// by `PermissionsGate` and the capture-time error log.
        case untrusted
        /// The set itself errored (a wedged host times out as `.cannotComplete`).
        case failed(AXError)
    }

    private nonisolated static let manualAccessibilityAttribute = "AXManualAccessibility"

    private let notificationCenter: NotificationCenter
    private let frontmostApplication: @MainActor () -> NSRunningApplication?
    private let wake: @Sendable (pid_t) -> WakeAttempt
    private var activationObserver: NSObjectProtocol?
    private let log = EposLogger(category: "inject")
    private let wakeQueue = AccessibilityWakeQueue()

    public init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        frontmostApplication: @escaping @MainActor () -> NSRunningApplication? = {
            NSWorkspace.shared.frontmostApplication
        },
        wake: @escaping @Sendable (pid_t) -> WakeAttempt = ElectronAccessibilityWaker.requestManualAccessibility
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
        wakeFrontmostApplicationNow()
        activationObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [wake, log, wakeQueue] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
            Self.enqueueWake(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                on: wakeQueue,
                wake: wake,
                log: log
            )
        }
    }

    /// Press-time re-assert: fn press calls this so a tree that re-slept during
    /// a long single-app session, or a grant that arrived without an app switch,
    /// is corrected while the recording runs. Asynchronous — it cannot rescue
    /// the current capture from a fully cold tree, but it makes the very next
    /// press deterministic instead of waiting for an app switch. A no-op until
    /// `start()`, which is how test-driven recordings stay off the machine.
    public func wakeFrontmostApplication() {
        guard activationObserver != nil else { return }
        wakeFrontmostApplicationNow()
    }

    private func wakeFrontmostApplicationNow() {
        guard let frontmost = frontmostApplication() else { return }
        Self.enqueueWake(
            processIdentifier: frontmost.processIdentifier,
            bundleIdentifier: frontmost.bundleIdentifier,
            on: wakeQueue,
            wake: wake,
            log: log
        )
    }

    /// The AX set is synchronous IPC into the target app, bounded by a messaging
    /// timeout but still nothing the main actor — or the shared cooperative
    /// thread pool — should wait on per app switch. `AccessibilityWakeQueue`
    /// owns both the off-pool thread and the per-pid coalescing.
    private nonisolated static func enqueueWake(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        on wakeQueue: AccessibilityWakeQueue,
        wake: @escaping @Sendable (pid_t) -> WakeAttempt,
        log: EposLogger
    ) {
        wakeQueue.enqueue(processIdentifier: processIdentifier) {
            let host = bundleIdentifier ?? "pid \(processIdentifier)"
            switch wake(processIdentifier) {
            case .woke:
                log.info("woke accessibility tree of \(host)")
            case .unsupported:
                log.debug("accessibility wake unsupported by \(host)")
            case .untrusted:
                log.debug("accessibility wake skipped for \(host): not trusted")
            case .failed(let error):
                log.debug("accessibility wake failed for \(host) (AXError \(error.rawValue))")
            }
        }
    }

    public nonisolated static func requestManualAccessibility(processIdentifier: pid_t) -> WakeAttempt {
        guard AXIsProcessTrusted() else { return .untrusted }
        let application = AXUIElementCreateApplication(processIdentifier)
        // Bounded so a wedged target app cannot stall the wake task; generous
        // against the sub-millisecond healthy case.
        AXUIElementSetMessagingTimeout(application, 0.25)
        let result = AXUIElementSetAttributeValue(
            application,
            manualAccessibilityAttribute as CFString,
            kCFBooleanTrue
        )
        switch result {
        case .success: return .woke
        case .attributeUnsupported: return .unsupported
        default: return .failed(result)
        }
    }
}

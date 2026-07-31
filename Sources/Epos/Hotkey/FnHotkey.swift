import AppKit
import Foundation

/// Push-to-talk fn-key global hotkey.
/// Carbon's RegisterEventHotKey does not support fn-only, so we listen via NSEvent.
@MainActor
public final class FnHotkey {
    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?

    /// How often the tracked key state is reconciled against the hardware while fn
    /// is held. The external contract that forces this to exist: macOS stops
    /// delivering `flagsChanged` to global monitors while secure input is active
    /// (password fields, the lock screen, `sudo` in a terminal), so a release
    /// pressed inside that window never arrives. `isDown` then stays true forever —
    /// the mic stays hot, and the edge guard below swallows every later press.
    ///
    /// This is a stuck-state backstop, not a latency path: a real release arrives
    /// as an event within a few milliseconds and ends the recording there. The
    /// interval is therefore set by how long a wedged hot mic is tolerable, not by
    /// responsiveness, and the poll is a single modifier-flags read.
    public static let stuckKeyReconcileInterval: Duration = .milliseconds(500)

    private static let log = EposLogger(category: "coordinator")

    private var monitor: Any?
    private var isDown = false
    private var reconcileTask: Task<Void, Never>?
    private let hardwareStateReader: @MainActor () -> Bool
    private let reconcileInterval: Duration

    /// The live hardware fn-key state, read straight from the current modifier flags
    /// (not the cached edge state) so a caller can re-check whether fn is still held
    /// after an async gap — e.g. to recover a press that arrived while busy.
    public var isFunctionKeyDown: Bool {
        hardwareStateReader()
    }

    /// `hardwareStateReader` and `reconcileInterval` are injectable so the
    /// stuck-key reconciliation can be tested without a real key or a real wait.
    public init(
        hardwareStateReader: (@MainActor () -> Bool)? = nil,
        reconcileInterval: Duration = FnHotkey.stuckKeyReconcileInterval
    ) {
        self.hardwareStateReader = hardwareStateReader ?? {
            NSEvent.modifierFlags.contains(.function)
        }
        self.reconcileInterval = reconcileInterval
    }

    public func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let pressed = event.modifierFlags.contains(.function)
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(pressed: pressed)
            }
        }
    }

    public func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        stopReconciling()
        isDown = false
    }

    /// The one place the tracked state changes, so a reconciled release and a real
    /// release that arrives late cannot both fire `onRelease`: whichever lands first
    /// clears `isDown` and the other is swallowed by the edge guard.
    /// Internal so tests can drive the transitions the global monitor delivers.
    func handleFlagsChanged(pressed: Bool) {
        guard pressed != isDown else { return }
        isDown = pressed
        if pressed {
            startReconciling()
            onPress?()
        } else {
            stopReconciling()
            onRelease?()
        }
    }

    private func startReconciling() {
        stopReconciling()
        let interval = reconcileInterval
        reconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.isDown else { return }
                guard !self.isFunctionKeyDown else { continue }
                Self.log.info("fn release reconciled: hardware reports the key up, no release event arrived")
                self.handleFlagsChanged(pressed: false)
                return
            }
        }
    }

    private func stopReconciling() {
        reconcileTask?.cancel()
        reconcileTask = nil
    }
}

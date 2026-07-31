import Foundation

/// Launch gate for the dogfood remote control (`EPOS_DEBUG_DICTATION_TRIGGER=1`):
/// lets a script start and finish a REAL recording without the fn key, so UI
/// behavior can be observed and frame-captured deterministically. Inert without
/// the env var. Post from a shell via a tiny Swift script (JXA's
/// `$.NSDistributedNotificationCenter.defaultCenter` silently resolves to the
/// process-LOCAL center and never delivers — verified live):
///
///   xcrun swift - <<'EOF'
///   import Foundation
///   DistributedNotificationCenter.default().postNotificationName(
///       Notification.Name("com.steez.Epos.debug.startRecording"),
///       object: nil, userInfo: nil, deliverImmediately: true)
///   EOF
enum DebugDictationTriggerPolicy {
    static let environmentKey = "EPOS_DEBUG_DICTATION_TRIGGER"
    static let startNotification = Notification.Name("com.steez.Epos.debug.startRecording")
    static let finishNotification = Notification.Name("com.steez.Epos.debug.finishRecording")

    static func load(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[environmentKey] == "1"
    }
}

/// Arms the dogfood remote control: distributed notifications drive the REAL
/// start/finish handlers, exactly as the fn key would. Returns the observer tokens
/// to retain — empty, and nothing observed, unless the env var is set.
@MainActor
func armDebugDictationTrigger(
    log: EposLogger,
    onStart: @escaping @Sendable @MainActor () -> Void,
    onFinish: @escaping @Sendable @MainActor () -> Void
) -> [NSObjectProtocol] {
    guard DebugDictationTriggerPolicy.load() else { return [] }
    let center = DistributedNotificationCenter.default()
    let observers = [
        center.addObserver(
            forName: DebugDictationTriggerPolicy.startNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onStart() }
        },
        center.addObserver(
            forName: DebugDictationTriggerPolicy.finishNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onFinish() }
        },
    ]
    log.info("debug dictation trigger armed")
    return observers
}

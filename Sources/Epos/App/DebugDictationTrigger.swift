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

import Foundation
@testable import Epos

/// Grants that change between reads, for the behavior that reacts to one arriving
/// after launch (the fn monitor reinstall).
final class MutablePermissionGrants: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PermissionsSnapshot

    init(
        microphone: PermissionStatus = .granted,
        speech: PermissionStatus = .granted,
        accessibility: PermissionStatus = .granted
    ) {
        stored = PermissionsSnapshot(
            microphone: microphone,
            speech: speech,
            accessibility: accessibility
        )
    }

    var accessibility: PermissionStatus {
        get { lock.withLock { stored.accessibility } }
        set {
            lock.withLock {
                stored = PermissionsSnapshot(
                    microphone: stored.microphone,
                    speech: stored.speech,
                    accessibility: newValue
                )
            }
        }
    }

    var gate: PermissionsGate {
        PermissionsGate(
            microphone: { [self] in lock.withLock { stored.microphone } },
            speech: { [self] in lock.withLock { stored.speech } },
            accessibility: { [self] in lock.withLock { stored.accessibility } }
        )
    }
}

extension PermissionsGate {
    /// A gate with staged grants. TCC state cannot be set from a test process and
    /// the xctest host's own grants vary by machine, so any coordinator that runs
    /// a session has to be handed its grants explicitly — the empty-transcript path
    /// consults the microphone grant, and reading the host's would make the outcome
    /// depend on whoever ran the suite.
    static func stub(
        microphone: PermissionStatus = .granted,
        speech: PermissionStatus = .granted,
        accessibility: PermissionStatus = .granted
    ) -> PermissionsGate {
        PermissionsGate(
            microphone: { microphone },
            speech: { speech },
            accessibility: { accessibility }
        )
    }
}

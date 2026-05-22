import AVFoundation
import ApplicationServices
import Foundation
import Speech

public enum PermissionStatus: Equatable {
    case notDetermined
    case denied
    case granted
}

public struct PermissionsSnapshot: Equatable {
    public let microphone: PermissionStatus
    public let speech: PermissionStatus
    public let accessibility: PermissionStatus
}

public final class PermissionsGate {
    public init() {}

    public func snapshot() -> PermissionsSnapshot {
        PermissionsSnapshot(
            microphone: micStatus(),
            speech: speechStatus(),
            accessibility: accessibilityStatus()
        )
    }

    public func requestAll() async -> PermissionsSnapshot {
        // TODO: AVCaptureDevice.requestAccess(for: .audio)
        // TODO: SFSpeechRecognizer.requestAuthorization
        // TODO: AXIsProcessTrustedWithOptions prompt
        snapshot()
    }

    private func micStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .notDetermined
        case .authorized: .granted
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    private func speechStatus() -> PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: .notDetermined
        case .authorized: .granted
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    private func accessibilityStatus() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }
}

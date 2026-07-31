import AVFoundation
import ApplicationServices
import Foundation
import Speech

public enum PermissionStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case granted
}

public struct PermissionsSnapshot: Equatable, Sendable {
    public let microphone: PermissionStatus
    public let speech: PermissionStatus
    public let accessibility: PermissionStatus
}

public struct PermissionsGate: Sendable {
    private let log = EposLogger(category: "permissions")
    private let microphone: @Sendable () -> PermissionStatus
    private let speech: @Sendable () -> PermissionStatus
    private let accessibility: @Sendable () -> PermissionStatus

    public init() {
        self.init(
            microphone: Self.micStatus,
            speech: Self.speechStatus,
            accessibility: Self.accessibilityStatus
        )
    }

    /// The three status reads are injectable so decisions that hang off a grant —
    /// diagnosing a silent recording as a revoked microphone, reinstalling the fn
    /// monitor when Accessibility trust arrives — are testable. TCC state itself
    /// is not settable from a test process, and `requestAll()` still prompts for
    /// real, so only the reads are seams.
    init(
        microphone: @escaping @Sendable () -> PermissionStatus,
        speech: @escaping @Sendable () -> PermissionStatus,
        accessibility: @escaping @Sendable () -> PermissionStatus
    ) {
        self.microphone = microphone
        self.speech = speech
        self.accessibility = accessibility
    }

    public func snapshot() -> PermissionsSnapshot {
        PermissionsSnapshot(
            microphone: microphone(),
            speech: speech(),
            accessibility: accessibility()
        )
    }

    public func requestAll() async -> PermissionsSnapshot {
        log.info("requestAll: begin")

        _ = await AVCaptureDevice.requestAccess(for: .audio)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in
                continuation.resume()
            }
        }

        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        let result = snapshot()
        log.info("requestAll: end")
        return result
    }

    private static let micStatus: @Sendable () -> PermissionStatus = {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .notDetermined
        case .authorized: .granted
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    private static let speechStatus: @Sendable () -> PermissionStatus = {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: .notDetermined
        case .authorized: .granted
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    private static let accessibilityStatus: @Sendable () -> PermissionStatus = {
        AXIsProcessTrusted() ? .granted : .denied
    }
}
